# zq VM Architecture Rewrite: Fork/Backtrack Model

## Status Quo Analysis

### Current Architecture Summary

**Compiler** (`src/query/src/compiler.zig`, ~5350 lines): Recursive-descent parser that emits `RawInstr` into a linear array. The `fuse()` function collapses consecutive `load_key | pipe | load_key` chains into `load_path` and remaps all jump targets from raw to fused indices. String operands start as `StrRef` (offset+len into intern buffer) and become `[]const u8` slices after fuse resolves the final string_buf.

**VM** (`src/query/src/vm.zig`, ~7420 lines): A `ResultIterator` struct with `next()` as the external API. Internally, `step()` loops calling `execOne()` for each instruction. Multiple output values are produced by returning from `step()` on each `output` instruction. Re-entering `step()` continues from the saved `ip`.

**Current generator strategy**: Generators (comma, try-catch, empty, iterate) do NOT compose through backtracking. Instead, the compiler uses three workarounds:
1. **Comma** (`a, b`): `save_input / <a> / output / restore_input / <b>` -- each branch terminates at its own `output` instruction.
2. **Pipe distribution**: `(a, b) | c` is rewritten at compile time to `(a | c), (b | c)` by re-parsing the right side for each branch.
3. **Iterate** (`.[]`): Pushes an `IterFrame` with `resume_ip`. When `ip >= instructions.len`, `advanceFrame()` sets the next element and resets `ip = resume_ip`.
4. **Range**: Same as iterate but with `RangeFrame`.
5. **Reduce/foreach**: Materializes generators into arrays via `array_collect_start/end`, iterates over the materialized array.

**Why this breaks**: The linear model cannot compose generators. When `try-catch` wraps a generator, or generators appear in arithmetic operands, or `empty` needs to skip "one output" inside nested contexts, the workarounds create exponential code duplication and still fail on ~214 tests. The `skip_output` flag is a band-aid for `empty`. The `distributeBinaryOp` function duplicates code N*M times for Cartesian products.

### Specific Failures Caused by Linear Model
- `empty` inside nested generators (kills entire execution instead of backtracking)
- Generators in try-catch (unwinding is per-frame, not per-forkpoint)
- `first(expr)`, `limit(n; expr)` require dedicated frame types
- `label/break` unwind logic is fragile (10+ saved stack depths per frame)
- `.[] | try .foo` does not continue to next element after error

---

## New Architecture: Fork/Backtrack

### Core Concept

Replace all the separate frame stacks (IterFrame, RangeFrame, TryFrame, LabelFrame, LimitFrame, CallFrame) with a unified **fork stack**. Every generator point saves a **forkpoint** -- a snapshot of the VM state. When execution needs "the next output," the VM backtracks to the most recent forkpoint and resumes from its saved return address.

The key insight from jq: `next()` is an iterator. The first call executes from `ip=0`. When the program hits `OUTPUT`, it yields a value and returns. Subsequent `next()` calls resume by **backtracking** -- popping the most recent forkpoint and jumping to its backtrack address. This naturally makes every generator composable because they all use the same mechanism.

### New Instruction Set

#### Instructions REMOVED
| Old Instruction | Reason |
|---|---|
| `output` | Replaced by `OUTPUT` (semantic change: yield + backtrack on re-entry) |
| `save_input` | Replaced by fork stack snapshot |
| `restore_input` | Replaced by backtrack restore |
| `iterate` | Replaced by `EACH` which uses fork internally |

#### Instructions ADDED
| New Instruction | Operand | Semantics |
|---|---|---|
| `FORK` | `index` (absolute IP) | Forward: push forkpoint (saving data_stack pos, current, backtrack addr = operand), continue to ip+1. Backtrack: pop forkpoint, restore stack, jump to backtrack addr. |
| `BACKTRACK` | none | Pop most recent forkpoint, restore its state, resume from its backtrack addr. This IS `empty`. |
| `OUTPUT` | none | Yield `current` (or TOS) to caller. Return from `next()`. On next re-entry, execute `BACKTRACK`. |
| `EACH` | none | Pop container from `current`. If empty: `BACKTRACK`. Else: push forkpoint with iteration state and `backtrack_ip = ip` (the EACH itself). Set `current = first_element`, `ip += 1`. On backtrack: advance to next element; if exhausted, pop and backtrack further. |
| `FORK_TRY` | `index` (handler IP) | Like `FORK`, but on backtrack: if backtrack reason is "error," jump to handler. If reason is exhaustion, keep backtracking past. |
| `POP_TRY` | none | Remove the nearest `try_handler` forkpoint (normal exit from try scope). |
| `RAISE` | none | Set backtrack reason to "error," then `BACKTRACK`. Error value is on data stack. |

#### Instructions KEPT (unchanged)
All value-manipulation and control flow instructions that don't interact with generators:

`identity`, `pipe`, `load_key`, `load_index`, `load_computed`, `load_path`, `push_bool`, `push_int`, `push_float`, `push_null`, `push_string`, `push_current`, `add`, `sub`, `mul`, `div`, `mod`, `eq`, `ne`, `lt`, `le`, `gt`, `ge`, `and_op`, `or_op`, `not`, `negate`, `capture_variable`, `load_variable`, `pop_variable`, `call_function`, `return_function`, `jump`, `jump_if_false`, `object_construct_start`, `object_key`, `object_construct_end`, `call_builtin`, `slice`, `navigate_key`, `navigate_index`, `update_key`, `update_index`, `array_collect_start`, `array_collect_end`

### New VM State

#### Fork Stack (replaces 6 separate stacks)

```zig
const ForkType = enum(u8) {
    normal,      // FORK: generators (comma)
    try_handler, // FORK_TRY: error handler
    each,        // .[] iteration
    range,       // range() generator
    label,       // label/break sentinel
    call,        // function call frame
    output,      // OUTPUT re-entry point
};

const Forkpoint = struct {
    saved_data_stack_pos: u32,
    saved_current: Value,
    backtrack_ip: u32,
    fork_type: ForkType,
    aux: ForkAux,
};

const ForkAux = union {
    none: void,
    each_state: EachState,
    range_state: RangeState,
    label_token: u32,
    limit_remaining: u64,
};
```

#### What the fork stack REPLACES
| Old Stack | Replacement |
|---|---|
| `stack: ArrayList(IterFrame)` | `each`-type forkpoints |
| `range_stack: ArrayList(RangeFrame)` | `range`-type forkpoints |
| `try_stack: ArrayList(TryFrame)` | `try_handler`-type forkpoints |
| `label_stack: ArrayList(LabelFrame)` | `label`-type forkpoints |
| `limit_stack: ArrayList(LimitFrame)` | Counter in forkpoint aux |
| `call_stack: ArrayList(CallFrame)` | `call`-type forkpoints |
| `if_stack: ArrayList(Value)` | `saved_current` in forkpoints |

#### What STAYS in ResultIterator
`tape`, `instructions`, `function_table`, `string_buf`, `ip`, `current`, `input_value`, `value_stack` (data stack), `variable_store`, `runtime_tape`, `runtime_tape_view`, `object_construct`, `collect_stack`, `done`, `alloc`, `source_map`

#### What is REMOVED
`stack`, `range_stack`, `try_stack`, `label_stack`, `limit_stack`, `call_stack`, `if_stack`, `pending_break_token`, `skip_output`, `user_error_msg`, `type_error_detail`, `alt_null_depth`

### New `next()` Function Flow

```
pub fn next() -> ?Value:
    if done: return null
    if not initialized: initialize, set current = root value

    if returning_from_output:
        backtrack()  // resume by backtracking from last OUTPUT

    run()  // execute until OUTPUT or exhaustion

fn run():
    while ip < instructions.len:
        execute instruction at ip
        // OUTPUT: yield value, return
        // FORK: push forkpoint, continue
        // BACKTRACK: call backtrack()
        // EACH: push iteration forkpoint, continue
        // FORK_TRY: push try forkpoint, continue
        // RAISE: set error flag, backtrack()
    backtrack()  // ip past end

fn backtrack():
    while fork_stack not empty:
        fp = fork_stack.top()
        match fp.fork_type:
            .normal:
                restore state from fp, pop, ip = fp.backtrack_ip, return
            .each:
                if advance_element(fp): ip = fp.backtrack_ip, return
                else: pop, continue backtracking
            .range:
                if advance_range(fp): ip = fp.backtrack_ip, return
                else: pop, continue backtracking
            .try_handler:
                if error raised: catch it, ip = fp.backtrack_ip, return
                else: pop, continue backtracking
            .output:
                pop, continue backtracking
            .label:
                pop, continue backtracking
            .call:
                restore frame, pop, continue backtracking
    done = true
```

### Compiler Changes

#### Comma (`a, b`)

**Old**: `save_input / <a> / output / restore_input / <b>`

**New**:
```
FORK L_b
<a>
JUMP L_end
L_b:
<b>
L_end:
```

**Chained** (`a, b, c`):
```
FORK L_b
<a>
JUMP L_end
L_b:
FORK L_c
<b>
JUMP L_end
L_c:
<c>
L_end:
```

**Critical consequence**: `(a, b) | c` just compiles to:
```
FORK L_b
<a>
JUMP L_after
L_b:
<b>
L_after:
pipe
<c>
```
No pipe distribution. No `distributeBinaryOp`. No `extractBranches`. No `leftSideHasOutput`. All of that code (~200 lines) is deleted.

#### Try-catch

**New**:
```
FORK_TRY L_handler
<expr>
POP_TRY
JUMP L_past
L_handler:
<handler>
L_past:
```

For `try expr` (no catch): `L_handler` points to `BACKTRACK`.

For `expr?`: same as `try expr` (no catch).

#### `empty`

`empty` = `BACKTRACK`. One instruction. No skip_output flag. No special cases.

#### Iterate (`.[]`)

`EACH` instruction. Pushes forkpoint with iteration state, sets current to first element. On backtrack, advances to next element or exhausts.

#### Range

Range builtins push forkpoints with range state. On backtrack, advance counter or exhaust.

#### Alternative (`//`)

```
FORK_TRY L_right
<a>
DUP
JUMP_IF_FALSE L_falsy
POP_TRY
JUMP L_end
L_falsy:
DROP
BACKTRACK
L_right:
<b>
L_end:
```

This eliminates `alt_null_depth` entirely -- TypeErrors on the left side naturally backtrack through FORK_TRY to the right side.

#### Label/break

Label pushes a `label`-type forkpoint. Break scans fork stack for matching label, unwinds everything between, jumps to label's exit IP.

#### Reduce (Step 2 initially, optimized in Step 3)

**Step 2** (keep materialization): compile as now with `array_collect_start/end`.

**Step 3** (optimized):
```
<INIT>
capture_variable($acc)
FORK L_done
<EXPR>
capture_variable($var)
load_variable($acc)
pipe
<UPDATE>
capture_variable($acc)
BACKTRACK
L_done:
load_variable($acc)
```

---

## Implementation Steps

### Step 1: Fork Stack + Comma + Empty + Iterate + Range

**Compiler changes:**
- Add `fork`, `backtrack`, `each`, `yield_output` to `Instruction.Op` enum
- `parseComma`: emit `fork/jump` pattern instead of `save/output/restore`
- `parsePipe`: DELETE pipe distribution entirely (`leftSideHasOutput`, `extractBranches`, `distributeBinaryOp`, re-parse-right-side block). Just emit `<left> / pipe / <right>`.
- `empty` builtin: emit `backtrack` instead of `call_builtin(empty)`
- Iterate: emit `each` instead of `iterate`
- Final output in `compile()`: emit `yield_output` instead of `output`

**VM changes:**
- Add `Forkpoint` struct and `fork_stack: ArrayList(Forkpoint)` to `ResultIterator`
- Implement `backtrack()` handling `normal`, `each`, `range`, `output` types
- New `FORK` handler: push forkpoint, continue
- New `EACH` handler: push iteration forkpoint, set first element
- New `BACKTRACK` handler: call backtrack()
- New `OUTPUT` handler: yield value, return
- Rewrite `builtinRange1/2/3` to push fork-based range state
- Remove `IterFrame`, `RangeFrame`, `if_stack`, `skip_output`
- Keep `try_stack`, `label_stack`, `limit_stack`, `call_stack` temporarily

**Testing**: 319+ compat tests pass (no regressions). Generator composition tests start passing.

### Step 2: Try-Catch + Alternative + Label/Break + Limit + Call Frames

**Compiler changes:**
- Add `fork_try`, `pop_try`, `raise` opcodes
- Try-catch: emit `fork_try / <expr> / pop_try / jump / <handler>` pattern
- Alternative (`//`): emit fork-based pattern, remove `alt_start/alt_check`
- Label/break: emit fork-based label, break scans fork stack
- Limit: emit fork-based counter

**VM changes:**
- Move try handling into `backtrack()` as `try_handler` forkpoint type
- Move label/break into fork stack scan
- Move limit into fork stack counter
- Move call frames into fork stack
- Remove `try_stack`, `label_stack`, `limit_stack`, `call_stack`
- Remove `alt_null_depth`, `pending_break_token`, `user_error_msg`, `type_error_detail`

**Testing**: Target 450+ compat tests. Generators inside try-catch work. `empty` in any context works.

### Step 3 (Optional): Optimize Reduce/Foreach

Replace materialization with direct fork-based iteration. Performance optimization, not correctness fix.

---

## What Existing Code Can Be KEPT vs Rewritten

### KEPT (~6000 lines, no changes)
- All value-manipulation VM methods: `doAdd`, `doSub`, `doMul`, `doDiv`, `doMod`, comparisons, `doSlice`, `doUpdateKey`, `doUpdateIndex`, `doLoadPath`, `doLoadIndex`, `constructObjectFromFieldsRange`, `buildCollectedArray`, etc. (~2500 lines)
- All builtin implementations except `empty`, `range1-3`, `paths`, `recurse` (~2500 lines)
- Compiler parsing for expressions, primaries, if-then-else, function defs, patterns, scoping (~2000 lines)
- `fuse()` function (minor updates for new opcodes)
- External interface (`root.zig`, `c_abi/root.zig`)
- `types.zig` value system
- Helper functions (`tapeEntryToValue`, `lookupKey`, `lookupIndex`, etc.)

### REWRITTEN (~1500 lines)
- `ResultIterator.init/deinit/reset` (~160 lines)
- `step()`/`next()` outer loop (~100 lines)
- `execOne()` generator-related cases (~200 lines)
- `handleCaughtError` -> `backtrack()` (~150 lines)
- `handleBreak` -> fork stack scan (~60 lines)
- `advanceFrame/advanceRangeFrame` -> backtrack each/range cases (~60 lines)
- `doIterate` -> `EACH` handler (~50 lines)
- `builtinRange1/2/3` (~150 lines)
- `builtinPaths/builtinRecurse` (~200 lines)
- Compiler `parseComma` (~30 lines)
- Compiler `parsePipe` (~120 lines simplified)
- Compiler `parseAlternative` (~30 lines)
- Compiler try-catch emission (~50 lines)

### DELETED (~500 lines)
- `leftSideHasOutput`, `extractBranches`, `distributeBinaryOp` (~90 lines)
- Pipe distribution logic in `parsePipe` (~80 lines)
- `IterFrame`, `RangeFrame`, `TryFrame`, `LabelFrame`, `LimitFrame` types (~100 lines)
- `skip_output` machinery (~30 lines)
- Separate stack management for 6 frame types (~150 lines)
- `alt_null_depth` mechanism (~30 lines)

---

## Risk Assessment

### Low Risk
- Value manipulation instructions (pure, no generator interaction)
- Builtin implementations (non-generator)
- External interface (`next()` signature unchanged)
- Parser/Lexer (not touched)

### Medium Risk
- Object construction with generators (`{a: (1,2)}`)
- Array collection inside generators (`[expr]`)
- Variable scoping across forkpoints (variables are write-once, not restored on backtrack -- matches jq)

### High Risk
- Try-catch + generator composition (the main reason for the rewrite)
- Label/break across generator boundaries
- Pipe distribution removal (relying on fork/backtrack to handle `(a,b) | c`)

### Mitigation
- 533 compat tests as primary safety net
- Run tests after each sub-step
- Keep old code in git branch for comparison

# Module: describe

## Purpose
Streaming JSON schema inferrer. Walks one record's tape at a time, merges
the observed types into a running `Schema` tree, and serializes the
accumulated shape as JSON (compact or pretty). Backs the `--describe`
flag in `main`.

Memory is `O(unique_field_paths)` — each distinct `(path, type)` collapses
into a single `Schema` node, regardless of how many records exhibit it.
Per-record cost is `O(tape_entries)` for the merge walk.

Consumed by:
- `src/main.zig` — `--describe` mode constructs a `SchemaInferrer`,
  feeds every input record's tape via `feedTape`, then serializes the
  result through `serialize` / `serializePretty`.

---

## Public Interface

### Types

```zig
const std   = @import("std");
const types = @import("types");
const Tape  = types.Tape;
const Allocator = std.mem.Allocator;

/// Bitfield of JSON types observed at one schema node. Stored as a
/// packed `u8` so a `Schema` carries this information in one byte.
///
/// Bit layout (LSB first, 6 type bits + 2 reserved):
///
///   bit 0 — null
///   bit 1 — boolean
///   bit 2 — number  (covers int + float)
///   bit 3 — string
///   bit 4 — array
///   bit 5 — object
///   bits 6-7 — `_pad` (reserved zero)
pub const TypeSet = packed struct(u8) {
    null:    bool = false,
    boolean: bool = false,
    number:  bool = false,
    string:  bool = false,
    array:   bool = false,
    object:  bool = false,
    _pad: u2 = 0,

    /// Population count of the six type bits.
    pub fn count(self: TypeSet) u32;
};

/// Recursive schema node describing the observed shape of JSON data.
/// `fields` is populated only when the node has been observed as an
/// object; `elements` only when observed as an array. `presence_count`
/// is incremented every time this node is reached as a child — the
/// difference between `presence_count` and the parent record count
/// drives optional-field detection in the serializer.
pub const Schema = struct {
    types:           TypeSet = .{},
    fields:          ?std.StringArrayHashMapUnmanaged(*Schema) = null,
    elements:        ?*Schema = null,
    presence_count:  u64 = 0,
};

/// Streaming schema inferrer. Holds the running `Schema` plus the
/// record count and the maximum recursion depth. Owns every nested
/// `Schema` allocation through its `allocator`.
pub const SchemaInferrer = struct {
    schema:    Schema = .{},
    count:     u64 = 0,
    max_depth: u32 = 12,
    allocator: Allocator,

    /// Construct an empty inferrer. `max_depth = 0` disables the cap;
    /// any positive value caps recursion (children below the cap are
    /// observed only at the type level — their `fields` / `elements`
    /// are not descended into).
    pub fn init(allocator: Allocator, max_depth: u32) SchemaInferrer;

    /// Free the running schema and every nested allocation.
    pub fn deinit(self: *SchemaInferrer) void;

    /// Walk one record's tape (starting at entry 0), infer its shape,
    /// and merge it into the running schema. Bumps `count`. Surfaces
    /// `error.OutOfMemory` from the field-map / nested-schema growth.
    pub fn feedTape(self: *SchemaInferrer, tape: Tape) !void;

    /// Serialize the accumulated schema as compact JSON. Emits a
    /// minimal `{"type":"empty","count":0}` placeholder when no records
    /// have been fed.
    pub fn serialize(self: *const SchemaInferrer, writer: anytype, sort_keys: bool) !void;

    /// Pretty-printed variant of `serialize`. `indent` controls the
    /// depth-step (mirrors `output.SerializeOpts.Indent` in shape).
    pub fn serializePretty(
        self: *const SchemaInferrer,
        writer: anytype,
        sort_keys: bool,
        indent: Indent,
    ) !void;
};

/// Indentation style for `serializePretty`. Independent of
/// `output.SerializeOpts.Indent` but identical in shape — they don't
/// share a definition because describe is reachable without depending
/// on `output`.
pub const Indent = union(enum) {
    spaces: u8,
    tab,
};
```

### Functions

| Function                      | Signature                                                                       | Description                                                                  |
|-------------------------------|---------------------------------------------------------------------------------|------------------------------------------------------------------------------|
| `SchemaInferrer.init`         | `Allocator, u32 → SchemaInferrer`                                               | Empty inferrer with a recursion-depth cap.                                   |
| `SchemaInferrer.deinit`       | `*SchemaInferrer → void`                                                        | Recursive teardown of the entire schema tree.                                |
| `SchemaInferrer.feedTape`     | `*SchemaInferrer, Tape → !void`                                                 | Merge one record into the running schema. Surfaces OOM only.                 |
| `SchemaInferrer.serialize`    | `*const SchemaInferrer, anytype, bool → !void`                                  | Compact-JSON serialization to any `writeAll`/`writeByte` writer.             |
| `SchemaInferrer.serializePretty` | `*const SchemaInferrer, anytype, bool, Indent → !void`                       | Indented JSON serialization.                                                 |
| `TypeSet.count`               | `TypeSet → u32`                                                                 | Pop-count of the six type bits.                                              |

### Errors

| Error          | When                                                                                                        |
|----------------|-------------------------------------------------------------------------------------------------------------|
| `OutOfMemory`  | `feedTape`: field-map grow, nested `Schema` allocation, key-string dupe.                                   |
| Writer errors  | `serialize` / `serializePretty`: any error returned by the user-supplied `writer.writeAll` / `writeByte`.   |

---

## Constraints & Invariants

- **`TypeSet` is layout-stable.** `packed struct(u8)` means the six
  type bits land in fixed positions — see the bit layout above. The
  `_pad` field is `u2` to round to a byte; it must remain zero.
  Persisting the schema (e.g. for diffing across runs) can rely on
  the byte being a stable representation.
- **Schema is record-merge monotonic.** Each `feedTape` call only
  adds bits to `TypeSet`, only adds keys to `fields`, and only sets
  `elements` if absent. Schemas never narrow — observing one
  `null`-typed record sets `types.null = true` permanently.
- **Optional fields are inferred from `presence_count` vs. record count.**
  A field is "optional" when `0 < presence_count < record_count` at
  serialization time. The serializer surfaces `"optional": true` on
  such nodes. This is why `feedTape` increments `count` BEFORE the
  walk — every child it touches gets `presence_count++` and the ratio
  stays meaningful.
- **`max_depth` clamps recursion, not output.** When the cap is hit,
  the type bit for the container (object / array) is still set, but
  `fields` / `elements` are NOT populated. Deep schemas thus surface
  as `"object"` or `"array"` leaves at the cap. `max_depth = 0`
  disables the cap; the default in `init` callers is project-specific.
- **Field keys are duplicated into the inferrer's allocator.** Tape
  string memory is borrowed; the inferrer's keys outlive any single
  tape, so each new field key is `dupe`'d on first sight. `deinit`
  walks the field map and frees every key.
- **Key sorting is opt-in.** Both serializers take a `sort_keys`
  flag. With `false`, fields appear in insertion order
  (`StringArrayHashMapUnmanaged` is insertion-ordered); with `true`,
  fields are emitted lexicographically. Insertion order is the
  default in main because it tends to match the structural order
  users expect when scanning real data.
- **Numeric types collapse.** `int` and `float` both set the
  `number` bit. The schema does NOT distinguish integer from
  floating-point — it's a JSON-level shape, not a Zig-level one.
- **Not thread-safe.** `feedTape` mutates the running schema. Each
  worker / thread that wants concurrent inference holds its own
  `SchemaInferrer`; merging across inferrers is not exposed.
- **Empty input has a deterministic shape.** Both `serialize` and
  `serializePretty` emit `{"type":"empty","count":0}` (with
  appropriate whitespace) when `count == 0`, so downstream tools see
  a valid JSON document for empty input.

---

## Dependencies

- `src/types.zig` — `Tape`, `Tape.Entry` (consumed read-only)
- stdlib only beyond that: `std.StringArrayHashMapUnmanaged`,
  `std.heap.page_allocator` (for sort scratch only), `std.fmt.bufPrint`,
  `std.mem.sort`

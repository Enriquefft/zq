# /module: Create or Work on a Deep Module

## Purpose

Unified command for module lifecycle:
- If module doesn't exist → Create new module
- If module exists → Work on existing module

## Process

### Step 1: Read Context (Always First)

Before anything else, read:
1. `.claude/context/ARCHITECTURE.md` — understand constraints, decisions, conventions
2. `.claude/context/MANIFEST.md` — understand what modules already exist and their dependencies

**Do not proceed until both files are read.**

> Note: Never modify `ARCHITECTURE.md`. If the work reveals a needed architectural
> decision, suggest it to the human as a proposed addition — do not write it yourself.

---

### Step 2: Detect Module State

Ask user for module name, then:
1. Check if `services/[module-name]/` exists
2. If NOT exists → Go to Step 3 (Create)
3. If exists → Go to Step 4 (Work)

---

### Step 3: Create Module (New)

#### 3a. Module Definition

Ask user for:
- Module name (e.g., "auth", "database")
- Brief purpose
- Key responsibilities

Cross-check against ARCHITECTURE.md constraints and MANIFEST.md existing modules before proceeding.

#### 3b. Interface Design

Generate `INTERFACE.md` using `.claude/templates/INTERFACE.md` as the template:
- Purpose
- Public Interface (Types, Functions)
- Constraints & Invariants

**Get human approval before proceeding.**

#### 3c. Scaffold Structure

Create:
```
services/[module-name]/
├── [module entry point]   # Public types + exports
├── INTERFACE.md           # Approved interface
└── src/
    ├── core impl
    └── private helpers

tests/services/
└── [boundary test file]
```

#### 3d. Write Boundary Tests

- Test all public functions
- Test edge cases
- Lock in expected behavior

#### 3e. Initial Implementation

Implement to satisfy both INTERFACE.md and boundary tests.

---

### Step 4: Work on Module (Existing)

#### 4a. Read Contract

Read and understand:
- `services/[module-name]/INTERFACE.md`
- `tests/services/[boundary test file]`
- `services/[module-name]/[entry point]`

**Do not modify INTERFACE.md unless evolving contract.**

#### 4b. Identify Changes

Ask user what needs changing:
- Bug fixes
- Performance improvements
- Internal refactoring
- Feature additions (within scope)

#### 4c. Modify Implementation

Only modify files in `services/[module-name]/src/`

#### 4d. Run Boundary Tests

Use appropriate test command for detected language.

#### 4e. Verify

- Boundary tests pass
- Interface contract maintained
- No breaking changes

---

### Step 5: Update MANIFEST.md (Always Last)

After all work is complete and tests pass, update `.claude/context/MANIFEST.md`:
- Add new module to inventory (if created)
- Update status, dependencies, or purpose (if changed)
- Append a row to Recent Changes with today's date and what was done

**This is the last step. Do not update MANIFEST.md before the work is verified.**

---

## Success Criteria

Create mode:
- [ ] ARCHITECTURE.md and MANIFEST.md read at start
- [ ] Interface approved
- [ ] Structure created
- [ ] Boundary tests written
- [ ] Implementation passes tests
- [ ] MANIFEST.md updated

Work mode:
- [ ] ARCHITECTURE.md and MANIFEST.md read at start
- [ ] Boundary tests pass
- [ ] Contract unchanged (or evolved with approval)
- [ ] Implementation improved
- [ ] MANIFEST.md updated

---

## AI Inference Guidelines

**Language Detection:**
- Examine file extensions, package management files, build config
- Adapt file patterns (.go, .py, .ts, .java, .rs)
- Use language-appropriate test commands

**Structure Preservation:**
- Keep INTERFACE.md as contract
- Keep src/ for implementation
- Keep tests/ separate

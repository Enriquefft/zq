# /module: Create or Work on a Deep Module

## Purpose

Unified command for module lifecycle:
- If module doesn't exist → Create new module
- If module exists → Work on existing module

## Process

### Step 1: Read Context (Always First)

Before anything else, read:
1. `.claude/context/ARCHITECTURE.md` — understand constraints, decisions, conventions, and **Module Layout**
2. `.claude/context/MANIFEST.md` — understand what modules already exist and their dependencies

**Do not proceed until both files are read.**

> Note: Never modify `ARCHITECTURE.md`. If the work reveals a needed architectural
> decision, suggest it to the human as a proposed addition — do not write it yourself.

All path references throughout this command come from the `## Module Layout` section of `ARCHITECTURE.md`, with `{name}` replaced by the actual module name.

---

### Step 2: Detect Module State

Ask user for module name, then:
1. Check if the module root path (from Module Layout) exists
2. If NOT exists → Go to Step 3 (Create)
3. If exists → Go to Step 4 (Work)

---

### Step 3: Create Module (New)

#### 3a. Module Definition

Ask user for:
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

Using the Module Layout paths, create:
```
{module_root}/
├── [module entry point]   # Public types + exports
├── INTERFACE.md           # Approved interface
└── {impl}/
    ├── core impl
    └── private helpers

{tests_root}/
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

Using the Module Layout paths, read:
- `{module_root}/INTERFACE.md`
- `{module_root}/[entry point]`

**Do not modify INTERFACE.md. If the user explicitly asks to change the interface, treat it as a contract evolution — follow the Interface Change Rule in 4d.**

Check if boundary tests exist at `{tests_root}/`:
- If YES: read them and continue.
- If NO: write boundary tests derived from `INTERFACE.md` before making any changes. Cover all public functions and key edge cases. This is required — do not proceed with changes until boundary tests exist.

#### 4b. Load Dependency Interfaces Only

From MANIFEST.md, identify modules this module depends on.

For each dependency:
- Read ONLY `{dependency_module_root}/INTERFACE.md`
- **Never read the dependency's implementation code** (`{impl}/` files or entry point)

The interface is the contract. Internal implementation of dependencies is irrelevant and must not be consulted.

#### 4c. Identify Changes

Ask user what needs changing:
- Bug fixes
- Performance improvements
- Internal refactoring
- Feature additions (within scope)

#### 4d. Interface Change Rule

If the work requires changing another module's interface:
- **Stop immediately. Do not make the change.**
- Describe to the user exactly what interface change is needed and why.
- Wait for explicit approval and direction before proceeding.

This rule is absolute — never modify another module's `INTERFACE.md` or public API.

#### 4e. Modify Implementation

Only modify files inside `{module_root}/{impl}/`

#### 4f. Run Boundary Tests

Use appropriate test command for detected language.

#### 4g. Verify

- Boundary tests pass
- Interface contract maintained
- No breaking changes to this module or its dependencies

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
- [ ] Structure created using project layout paths from ARCHITECTURE.md
- [ ] Boundary tests written
- [ ] Implementation passes tests
- [ ] MANIFEST.md updated

Work mode:
- [ ] ARCHITECTURE.md and MANIFEST.md read at start
- [ ] Dependency interfaces read (never implementation code)
- [ ] Boundary tests pass
- [ ] Contract unchanged (or changed only after following 4d Interface Change Rule)
- [ ] No dependency interfaces modified (user consulted if needed)
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
- Keep implementation separate from public entry point
- Keep tests separate

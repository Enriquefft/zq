# /status: Report Project State

## Purpose

Provide a current snapshot of project state and keep `.claude/context/MANIFEST.md` up to date.

## Process

### Step 1: Read Project Context

Read `.claude/context/ARCHITECTURE.md` for:
- Project overview and tech stack
- Architecture style and constraints

### Step 2: Scan Services Directory

For each module in `services/`:
1. Read `INTERFACE.md`
2. Check if implementation files exist
3. Check if tests exist in `tests/services/`

### Step 3: Update MANIFEST.md

Rewrite `.claude/context/MANIFEST.md` with current state:
- Update module inventory table (module name, purpose, status, dependencies, today's date)
- Regenerate dependency graph from each module's `INTERFACE.md` `## Dependencies` section
- Append a row to Recent Changes for any module that changed since last run
- Note any gaps (missing tests, incomplete implementations)

### Step 4: Report Status

Format as:
```
## Project Status

**Modules Found:**
- [module-name]: [CREATED|PARTIAL|TESTS_PENDING]
  Purpose: [from INTERFACE.md]
  Interface: [complete/incomplete]
  Tests: [present/missing]

**Recent Work:**
[Summarize from MANIFEST.md Recent Changes]

**Active Context:**
- Language: [detected language]
- Active module: [if currently working on one]
```

### Step 5: Test Status Summary

Check if tests pass:
- Identify appropriate test command for detected language
- Run tests and report results
- Note any failing tests

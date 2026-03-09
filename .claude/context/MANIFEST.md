# Project Manifest

> Auto-maintained by /status. Do not edit manually.

## Overview
| Metric | Value |
|--------|-------|
| Total Modules | 1 |
| Active | 1 |

## Module Inventory
| Module | Purpose | Status | Dependencies | Last Updated |
|--------|---------|--------|--------------|--------------|
| `error` | Centralized error creation with rich diagnostic context. Lazy line/col resolution via binary-search LineTable — never computed on the hot path. | Active | stdlib only | 2026-03-09 |

## Dependency Graph
```
error (no deps)
```

## Recent Changes
| Date | Module | Action | Details |
|------|--------|--------|---------|
| 2026-03-09 | `error` | Created | Scaffolded module with LineTable, resolve, raise. 14 boundary tests pass. |

## Gaps & TODOs
| Priority | Gap | Suggestion |
|----------|-----|------------|
| — | `ErrorKind` variants are a starter set | Extend as tokenizer/parser modules are added |

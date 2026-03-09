zq
A better JQ implemented in zig

Goal: 10x-20x performance improvement over jq via parallelization, SIMD, and zero-allocation parsing, with first-class support for JSONL and streaming/incomplete data.

@.claude/context/ARCHITECTURE.md


- Avoid all kind of workaround or bandaids.
- Only use production ready scalable code, coupled with proper coding practices. Always pick the correct way to do things.

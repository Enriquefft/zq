#!/usr/bin/env just --justfile

# Build the project in release mode
build:
    zig build -Doptimize=ReleaseFast

# Run all tests
test:
    zig build test

# Development build (unoptimized, faster compilation)
dev:
    zig build

# Build and run with arguments
run *ARGS:
    zig build -Doptimize=ReleaseFast && ./zig-out/bin/zq {{ARGS}}

# Run regex latency probe (Phase 0 will expand this to a full microbench)
bench:
    zig build bench-regex -Doptimize=ReleaseFast

# Record the benchmark demo GIF
demo:
    vhs demo/benchmark.tape

# Measure release binary size: total, section breakdown, top symbols
binsize:
    @zig build -Doptimize=ReleaseFast
    @printf '\n── Stripped release ──────────────────────────────\n'
    @ls -l zig-out/bin/zq | awk '{printf "size: %s bytes (%.2f MiB)\n", $5, $5/1048576}'
    @printf '\n── Section sizes (size -A) ───────────────────────\n'
    @size -A zig-out/bin/zq
    @zig build -Doptimize=ReleaseFast -Dstrip=false
    @printf '\n── Unstripped release (for symbol attribution) ───\n'
    @ls -l zig-out/bin/zq | awk '{printf "size: %s bytes (%.2f MiB)\n", $5, $5/1048576}'
    @printf '\n── Top 30 symbols by size (nm -S --size-sort) ────\n'
    @nm -S --size-sort zig-out/bin/zq 2>/dev/null | tail -30
    @zig build -Doptimize=ReleaseFast
    @printf '\nRestored stripped release binary at zig-out/bin/zq.\n'

# Show available commands
help:
    @just --list

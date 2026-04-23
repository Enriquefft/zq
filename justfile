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

# Show available commands
help:
    @just --list

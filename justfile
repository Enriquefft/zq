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

# Run performance microbench
bench:
    zig build -Doptimize=ReleaseFast && ./zig-out/bin/microbench

# Show available commands
help:
    @just --list

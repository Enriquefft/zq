//! Parallel JSON-structural region scanner.
//!
//! Splits a contiguous byte buffer into N equally-sized regions aligned
//! on 32-byte boundaries (for SIMD efficiency), runs the dual-variant
//! scanner over each region in parallel, and serially stitches the
//! per-region results into a list of absolute depth-0 record-boundary
//! offsets.
//!
//! Single source of truth: every byte is consumed by `boundary.feedBytesParallel`,
//! which mirrors `boundary.feedBytes` but tracks signed local depth and
//! records every outside-string `\n` as a candidate. The stitch step
//! filters candidates against the running depth delta carried across
//! regions.
//!
//! Two variants per region:
//!
//!   * **out** — assume the region begins outside any string.
//!   * **in_str** — assume the region begins inside a string with no
//!     escape pending.
//!
//! The stitch picks variant **in_str** iff the prior region's
//! `end_in_string` is true. The third theoretical variant (in-string +
//! escape pending) is rare enough to be handled by the *carry rescan*
//! path in `stitch`: the region's precomputed variants are discarded
//! and `feedBytesParallel` is re-run synchronously over `data[1..]`
//! (consuming the escaped byte). No third stored variant.

const std = @import("std");
const boundary = @import("boundary.zig");

pub const ScannerState = boundary.ScannerState;

/// A single in-region candidate boundary — a `\n` byte observed
/// outside a string with no escape pending. Whether it is an
/// *actual* depth-0 boundary depends on the running depth carried
/// across earlier regions, which `stitch` resolves.
pub const Candidate = struct {
    local_offset: u32,
    depth_at_offset: i32,
};

/// Result of scanning one region under one variant.
pub const VariantResult = struct {
    end_in_string: bool,
    end_escape_pending: bool,
    depth_delta: i32,
    candidates: []const Candidate,
};

pub const DualResult = struct {
    out: VariantResult,
    in_str: VariantResult,
    region_len: u32,
};

pub const Region = struct {
    base: usize,
    data: []const u8,
    dual: DualResult,
    arena: ?*std.heap.ArenaAllocator = null,
};

/// 32-byte alignment for region cuts. Matches `simd.zig` VEC_LEN — the
/// scanner can hit the SIMD fast path on chunk start without spillover.
/// Alignment is for performance only; correctness is handled by the
/// dual-variant + carry-rescan stitch.
pub const REGION_ALIGN: usize = 32;

/// Below this byte count the parallel split is a net loss (thread
/// spawn overhead dominates the scan). Caller falls back to a single
/// region scanned in the calling thread.
pub const MIN_PARALLEL_BYTES: usize = 64 * 1024;

/// Match `src/pool/root.zig` THREAD_STACK_SIZE — keep one convention
/// project-wide so threads have predictable resource cost.
pub const THREAD_STACK_SIZE: usize = 2 * 1024 * 1024;

/// Scan one region under both variants. `arena` is the per-region
/// arena allocator (caller owns its lifetime). Both candidate slices
/// in the returned `DualResult` are arena-owned.
pub fn scanRegionDual(data: []const u8, arena: std.mem.Allocator) error{OutOfMemory}!DualResult {
    var out_state = ScannerState{ .in_string = false, .escape_pending = false };
    var out_depth: i32 = 0;
    var out_list: std.ArrayList(Candidate) = .{};
    try boundary.feedBytesParallel(&out_state, &out_depth, data, &out_list, arena);
    const out_slice = try out_list.toOwnedSlice(arena);

    var in_state = ScannerState{ .in_string = true, .escape_pending = false };
    var in_depth: i32 = 0;
    var in_list: std.ArrayList(Candidate) = .{};
    try boundary.feedBytesParallel(&in_state, &in_depth, data, &in_list, arena);
    const in_slice = try in_list.toOwnedSlice(arena);

    return .{
        .out = .{
            .end_in_string = out_state.in_string,
            .end_escape_pending = out_state.escape_pending,
            .depth_delta = out_depth,
            .candidates = out_slice,
        },
        .in_str = .{
            .end_in_string = in_state.in_string,
            .end_escape_pending = in_state.escape_pending,
            .depth_delta = in_depth,
            .candidates = in_slice,
        },
        .region_len = @intCast(data.len),
    };
}

/// Round `x` up to the next multiple of `align_to`.
fn roundUp(x: usize, align_to: usize) usize {
    return ((x + align_to - 1) / align_to) * align_to;
}

/// Split `data` into approximately `n_regions` chunks. The first
/// region always begins at offset 0; later region bases are rounded
/// up to `REGION_ALIGN`. The final region absorbs any trailing slack.
fn computeBases(data_len: usize, n_regions: usize, out_bases: []usize) usize {
    std.debug.assert(out_bases.len >= n_regions);
    if (n_regions == 0 or data_len == 0) {
        out_bases[0] = 0;
        return 1;
    }
    const ideal = data_len / n_regions;
    var written: usize = 0;
    out_bases[written] = 0;
    written += 1;
    var k: usize = 1;
    while (k < n_regions) : (k += 1) {
        const ideal_cut = ideal * k;
        const aligned = roundUp(ideal_cut, REGION_ALIGN);
        if (aligned >= data_len) break;
        if (aligned <= out_bases[written - 1]) continue; // alignment collapsed
        out_bases[written] = aligned;
        written += 1;
    }
    return written;
}

/// Per-thread scratch passed into the worker entrypoint.
const ThreadCtx = struct {
    data: []const u8,
    arena: *std.heap.ArenaAllocator,
    result: *DualResult,
    err: ?anyerror,
};

fn workerEntry(ctx: *ThreadCtx) void {
    const arena_alloc = ctx.arena.allocator();
    const r = scanRegionDual(ctx.data, arena_alloc) catch |e| {
        ctx.err = e;
        return;
    };
    ctx.result.* = r;
}

/// Scan `data` in parallel across (up to) `n_regions` worker threads.
/// On success returns an owned slice of `Region` — each region's
/// `dual.{out,in_str}.candidates` slice is owned by the per-region
/// arena that the returned `Region.arena` points to. Free the whole
/// thing with `freeRegions(alloc, regions)`.
///
/// `alloc` must be thread-safe because each worker initializes its
/// own `ArenaAllocator` from it. (`std.heap.ArenaAllocator.init` only
/// stores the parent without touching it; the parent is touched on
/// `arena.deinit` and on every `arena.allocator().alloc`. Workers
/// never touch the parent — the arena's per-thread state grows; the
/// single freeRegions call from the calling thread releases.)
///
/// Single-region fallback: if `n_regions <= 1` or `data.len <
/// MIN_PARALLEL_BYTES`, the function runs serially in the calling
/// thread. Same applies on `Thread.spawn` failure (silent fallback,
/// not propagated).
pub fn scanRegions(
    data: []const u8,
    n_regions: usize,
    alloc: std.mem.Allocator,
) error{ OutOfMemory, ThreadSpawnFailed }![]Region {
    if (n_regions == 0) return error.OutOfMemory; // caller bug
    const want_parallel = n_regions > 1 and data.len >= MIN_PARALLEL_BYTES;
    const effective_regions: usize = if (want_parallel) n_regions else 1;

    // Compute bases & per-region slice ranges.
    var bases_buf = try alloc.alloc(usize, effective_regions);
    defer alloc.free(bases_buf);
    const actual = computeBases(data.len, effective_regions, bases_buf);
    const bases = bases_buf[0..actual];

    // Ownership flag: once true, the errdefers below stop touching
    // `regions` and `arenas` because their resources have been handed
    // off to the returned slice.
    var ownership_transferred = false;
    var regions = try alloc.alloc(Region, actual);
    errdefer if (!ownership_transferred) alloc.free(regions);

    // Build per-region arenas + thread contexts. Arenas are heap-allocated
    // so workers can write into them by pointer (the ArenaAllocator value
    // can't move while a worker holds its allocator). On any failure path
    // we tear down everything we've created so far.
    var arenas = alloc.alloc(*std.heap.ArenaAllocator, actual) catch return error.OutOfMemory;
    var arenas_created: usize = 0;
    errdefer if (!ownership_transferred) {
        var k: usize = 0;
        while (k < arenas_created) : (k += 1) {
            arenas[k].deinit();
            alloc.destroy(arenas[k]);
        }
        alloc.free(arenas);
    };
    {
        var k: usize = 0;
        while (k < actual) : (k += 1) {
            const a = alloc.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
            a.* = std.heap.ArenaAllocator.init(alloc);
            arenas[k] = a;
            arenas_created += 1;
        }
    }

    // Slice ranges.
    var slices = alloc.alloc([]const u8, actual) catch return error.OutOfMemory;
    defer alloc.free(slices);
    {
        var k: usize = 0;
        while (k < actual) : (k += 1) {
            const start = bases[k];
            const end = if (k + 1 < actual) bases[k + 1] else data.len;
            slices[k] = data[start..end];
        }
    }

    // Serial path: skip thread spawn entirely. Used for n_regions==1
    // and for the small-input fallback.
    if (actual == 1) {
        const r = scanRegionDual(slices[0], arenas[0].allocator()) catch return error.OutOfMemory;
        regions[0] = .{
            .base = bases[0],
            .data = slices[0],
            .dual = r,
            .arena = arenas[0],
        };
        // Hand arena ownership off to the region; free the arenas array
        // itself (the per-region arena is now reachable via region.arena).
        alloc.free(arenas);
        ownership_transferred = true;
        return regions;
    }

    // Parallel path.
    var ctxs = alloc.alloc(ThreadCtx, actual) catch return error.OutOfMemory;
    defer alloc.free(ctxs);
    var results = alloc.alloc(DualResult, actual) catch return error.OutOfMemory;
    defer alloc.free(results);
    var threads = alloc.alloc(std.Thread, actual) catch return error.OutOfMemory;
    defer alloc.free(threads);

    var spawned: usize = 0;
    var spawn_failed = false;
    {
        var k: usize = 0;
        while (k < actual) : (k += 1) {
            ctxs[k] = .{
                .data = slices[k],
                .arena = arenas[k],
                .result = &results[k],
                .err = null,
            };
        }
    }
    {
        var k: usize = 0;
        while (k < actual) : (k += 1) {
            const t = std.Thread.spawn(.{ .stack_size = THREAD_STACK_SIZE }, workerEntry, .{&ctxs[k]}) catch {
                spawn_failed = true;
                break;
            };
            threads[k] = t;
            spawned += 1;
        }
    }

    // Join whatever did spawn.
    {
        var k: usize = 0;
        while (k < spawned) : (k += 1) threads[k].join();
    }

    if (spawn_failed) {
        // Run the un-spawned tail (and any whose result is uninitialised) serially.
        var k: usize = spawned;
        while (k < actual) : (k += 1) {
            const r = try scanRegionDual(slices[k], arenas[k].allocator());
            results[k] = r;
        }
    }

    // Check for worker errors. Workers can only return OutOfMemory; map
    // any unexpected variant down to OutOfMemory for the public surface.
    {
        var k: usize = 0;
        while (k < actual) : (k += 1) {
            if (ctxs[k].err) |_| return error.OutOfMemory;
        }
    }

    // Compose Regions.
    {
        var k: usize = 0;
        while (k < actual) : (k += 1) {
            regions[k] = .{
                .base = bases[k],
                .data = slices[k],
                .dual = results[k],
                .arena = arenas[k],
            };
        }
    }
    alloc.free(arenas);
    ownership_transferred = true; // ownership now in regions[].arena
    return regions;
}

/// Free all per-region arenas and the regions array. Pairs with
/// `scanRegions`. After this call the candidate slices in `regions`
/// are dangling — caller must have copied/consumed them already.
pub fn freeRegions(alloc: std.mem.Allocator, regions: []Region) void {
    for (regions) |r| {
        if (r.arena) |a| {
            a.deinit();
            alloc.destroy(a);
        }
    }
    alloc.free(regions);
}

/// Stitch: serially walk the per-region results, carrying scanner
/// state across boundaries, and emit absolute depth-0 boundary
/// offsets into `out`. See module doc for the carry-rescan path.
pub fn stitch(
    regions: []const Region,
    out: *std.ArrayList(usize),
    allocator: std.mem.Allocator,
) error{OutOfMemory}!void {
    var accum = ScannerState{};
    var accum_depth: i32 = 0;

    for (regions) |region| {
        if (accum.in_string and accum.escape_pending) {
            // Hybrid carry-rescan: the prior region ended on a `\` inside
            // a string. The first byte of *this* region is the escape
            // target — consume it directly, then run the parallel scanner
            // fresh over data[1..] starting in_string=true. No precomputed
            // variant covers this state; the rescan is the third "variant"
            // computed lazily.
            if (region.data.len == 0) continue;
            accum.escape_pending = false;
            var rstate = ScannerState{ .in_string = true, .escape_pending = false };
            var rdepth: i32 = 0;
            var rcands: std.ArrayList(Candidate) = .{};
            defer rcands.deinit(allocator);
            try boundary.feedBytesParallel(&rstate, &rdepth, region.data[1..], &rcands, allocator);
            for (rcands.items) |cand| {
                if (accum_depth + cand.depth_at_offset == 0) {
                    try out.append(allocator, region.base + 1 + cand.local_offset);
                }
            }
            accum.in_string = rstate.in_string;
            accum.escape_pending = rstate.escape_pending;
            accum_depth += rdepth;
            continue;
        }

        const variant: VariantResult = if (accum.in_string) region.dual.in_str else region.dual.out;
        for (variant.candidates) |cand| {
            if (accum_depth + cand.depth_at_offset == 0) {
                try out.append(allocator, region.base + cand.local_offset);
            }
        }
        accum.in_string = variant.end_in_string;
        accum.escape_pending = variant.end_escape_pending;
        accum_depth += variant.depth_delta;
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "scanRegionDual: empty input both variants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try scanRegionDual("", arena.allocator());
    try testing.expectEqual(@as(usize, 0), r.out.candidates.len);
    try testing.expectEqual(@as(usize, 0), r.in_str.candidates.len);
    try testing.expectEqual(false, r.out.end_in_string);
    try testing.expectEqual(true, r.in_str.end_in_string);
}

test "scanRegionDual: out variant tracks signed depth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Region begins after an open `{`, sees `}` only — depth_delta = -1.
    const r = try scanRegionDual("}\n", arena.allocator());
    try testing.expectEqual(@as(i32, -1), r.out.depth_delta);
    try testing.expectEqual(@as(usize, 1), r.out.candidates.len);
    try testing.expectEqual(@as(i32, -1), r.out.candidates[0].depth_at_offset);
}

test "stitch: single region equals serial feedBytes" {
    const data = "1\n{\"a\":2}\n[3,4]\n";
    var oracle_state = ScannerState{};
    var oracle: std.ArrayList(usize) = .{};
    defer oracle.deinit(testing.allocator);
    try boundary.feedBytes(&oracle_state, data, 0, &oracle, testing.allocator);

    const regions = try scanRegions(data, 1, testing.allocator);
    defer freeRegions(testing.allocator, regions);
    var got: std.ArrayList(usize) = .{};
    defer got.deinit(testing.allocator);
    try stitch(regions, &got, testing.allocator);
    try testing.expectEqualSlices(usize, oracle.items, got.items);
}

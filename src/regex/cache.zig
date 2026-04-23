//! Pattern-compile caches.
//!
//! Two layers, per the regex roadmap:
//!
//!   1. `RegexPool`: filter-compile-time interning. Every distinct string
//!      literal regex in a compiled filter is compiled exactly once, stored
//!      in a flat array, and referenced by a stable `u32` index embedded in
//!      the opcode payload. Lifetime = compiled-filter lifetime.
//!
//!   2. `LruCache`: runtime cache for dynamic patterns (`test($var)`). Each
//!      entry bundles a compiled `Regex` AND its per-iterator `RegexClone`.
//!      The clone is built at insert time — the cache is the single source of
//!      truth for "keyed-by-pattern" regex state. Bounded at 64 entries to
//!      keep adversarial-input allocation bounded. On eviction BOTH the
//!      Regex and the RegexClone are deinit'd. Owner is the `ResultIterator`
//!      (clones are per-iterator; not `Sync`).
//!
//! Design choices:
//!   - `RegexPool` uses a managed `std.StringHashMap(u32)` keyed on a *copy*
//!     of the pattern bytes. Interning a pattern from an AST node must not
//!     assume the AST outlives the pool.
//!   - `LruCache` uses intrusive doubly-linked-list nodes on a separate arena,
//!     plus a hash map from pattern bytes → node. Recently-used → head;
//!     evict tail. Each node owns one (Regex, RegexClone) pair.
//!
//! Both types compile in regex-disabled builds but use the type-aliased
//! `Regex` from `root.zig` — which is itself a stub, so `compile()` just
//! returns `Error.RegexNotCompiled` straight through.

const std = @import("std");
const regex = @import("root.zig");

pub const Error = regex.Error;
const Regex = regex.Regex;
const RegexClone = regex.RegexClone;

/// Resolved LRU entry: a compiled `Regex` plus its per-iterator `RegexClone`.
/// Both are bundled so the cache is the single source of truth — no parallel
/// clone map keyed by `*Regex`.
pub const DynamicEntry = struct {
    regex: *Regex,
    clone: *RegexClone,
};

/// Filter-compile-time regex interner. Each distinct pattern compiles once;
/// subsequent `intern` calls return the existing index.
///
/// Ownership:
///   - The pool owns every `Regex` in `entries`.
///   - The pool owns every pattern-key string in `index.keys()`.
///   - On `deinit`, every `Regex` is freed and every key string is freed.
pub const RegexPool = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Regex),
    index: std.StringHashMap(u32),

    pub fn init(allocator: std.mem.Allocator) RegexPool {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(Regex){},
            .index = std.StringHashMap(u32).init(allocator),
        };
    }

    pub fn deinit(self: *RegexPool) void {
        for (self.entries.items) |*e| e.deinit();
        self.entries.deinit(self.allocator);

        var it = self.index.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.index.deinit();
    }

    /// Look up or compile. Returns the stable `u32` index. Allocates a copy
    /// of `pattern` on first insert so the caller's buffer may be transient.
    pub fn intern(self: *RegexPool, pattern: []const u8) Error!u32 {
        if (self.index.get(pattern)) |idx| return idx;

        var compiled = try Regex.compile(pattern);
        errdefer compiled.deinit();

        const key = self.allocator.dupe(u8, pattern) catch return Error.OutOfMemory;
        errdefer self.allocator.free(key);

        const idx: u32 = @intCast(self.entries.items.len);
        try self.entries.append(self.allocator, compiled);
        errdefer _ = self.entries.pop();

        try self.index.put(key, idx);
        return idx;
    }

    /// Immutable access to an interned entry. Panics on OOB — the compiler
    /// emits indices it got from `intern`, which are guaranteed in-range by
    /// construction.
    pub fn get(self: *const RegexPool, idx: u32) *const Regex {
        return &self.entries.items[idx];
    }

    pub fn len(self: *const RegexPool) usize {
        return self.entries.items.len;
    }
};

/// Bounded LRU cache for dynamic patterns. Every entry owns BOTH a compiled
/// `Regex` and its per-iterator `RegexClone`. Eviction frees both in lockstep
/// — no parallel maps, no eviction hooks, no keyed-by-pointer side stores.
/// Default capacity follows the plan (64 entries).
///
/// Not thread-safe. Owner: one per `ResultIterator` (clones are not `Sync`).
pub fn LruCache(comptime cap: u32) type {
    return struct {
        const Self = @This();

        const Node = struct {
            /// Owned copy of the pattern bytes. Freed on eviction/deinit.
            key: []u8,
            regex: Regex,
            clone: RegexClone,
            prev: ?*Node = null,
            next: ?*Node = null,
        };

        allocator: std.mem.Allocator,
        index: std.StringHashMap(*Node),
        head: ?*Node = null,
        tail: ?*Node = null,
        count: u32 = 0,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .index = std.StringHashMap(*Node).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            var cur = self.head;
            while (cur) |n| {
                const nxt = n.next;
                n.clone.deinit();
                n.regex.deinit();
                self.allocator.free(n.key);
                self.allocator.destroy(n);
                cur = nxt;
            }
            self.index.deinit();
            self.head = null;
            self.tail = null;
            self.count = 0;
        }

        /// Detach a node from the linked list. Does not free anything.
        fn detach(self: *Self, n: *Node) void {
            if (n.prev) |p| p.next = n.next else self.head = n.next;
            if (n.next) |nx| nx.prev = n.prev else self.tail = n.prev;
            n.prev = null;
            n.next = null;
        }

        /// Push at head. Node must be detached already.
        fn pushFront(self: *Self, n: *Node) void {
            n.prev = null;
            n.next = self.head;
            if (self.head) |h| h.prev = n else self.tail = n;
            self.head = n;
        }

        /// Return the cached entry for `pattern`, compiling and cloning on
        /// miss. Promotes to MRU. Returned pointers are stable until the
        /// entry is evicted or the cache is deinit'd.
        pub fn getOrCompile(self: *Self, pattern: []const u8) Error!DynamicEntry {
            if (self.index.get(pattern)) |n| {
                self.detach(n);
                self.pushFront(n);
                return .{ .regex = &n.regex, .clone = &n.clone };
            }

            // Compile + clone up front. Any failure leaves the cache untouched.
            var compiled = try Regex.compile(pattern);
            errdefer compiled.deinit();

            var cloned = try compiled.clone();
            errdefer cloned.deinit();

            const key = self.allocator.dupe(u8, pattern) catch return Error.OutOfMemory;
            errdefer self.allocator.free(key);

            const n = self.allocator.create(Node) catch return Error.OutOfMemory;
            errdefer self.allocator.destroy(n);

            n.* = .{ .key = key, .regex = compiled, .clone = cloned };

            try self.index.put(key, n);
            errdefer _ = self.index.remove(key);

            self.pushFront(n);
            self.count += 1;

            if (self.count > cap) self.evictLru();

            return .{ .regex = &n.regex, .clone = &n.clone };
        }

        fn evictLru(self: *Self) void {
            const t = self.tail orelse return;
            self.detach(t);
            _ = self.index.remove(t.key);
            t.clone.deinit();
            t.regex.deinit();
            self.allocator.free(t.key);
            self.allocator.destroy(t);
            self.count -= 1;
        }

        pub fn size(self: *const Self) u32 {
            return self.count;
        }

        /// Test helper: returns `true` iff pattern is currently resident.
        pub fn contains(self: *const Self, pattern: []const u8) bool {
            return self.index.contains(pattern);
        }
    };
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "RegexPool intern: same pattern returns same index" {
    if (!regex.enabled) return error.SkipZigTest;

    var pool = RegexPool.init(std.testing.allocator);
    defer pool.deinit();

    const a = try pool.intern("foo");
    const b = try pool.intern("bar");
    const a_again = try pool.intern("foo");

    try std.testing.expectEqual(@as(u32, 0), a);
    try std.testing.expectEqual(@as(u32, 1), b);
    try std.testing.expectEqual(a, a_again);
    try std.testing.expectEqual(@as(usize, 2), pool.len());
}

test "RegexPool intern: pattern bytes are copied" {
    if (!regex.enabled) return error.SkipZigTest;

    var pool = RegexPool.init(std.testing.allocator);
    defer pool.deinit();

    // Build a transient pattern buffer on the stack.
    var scratch: [16]u8 = undefined;
    @memcpy(scratch[0..5], "hello");
    const idx = try pool.intern(scratch[0..5]);

    // Obliterate the caller's buffer; pool must still be usable.
    @memset(scratch[0..5], 0);

    const again = try pool.intern("hello");
    try std.testing.expectEqual(idx, again);
}

test "RegexPool compile error surfaces and doesn't corrupt state" {
    if (!regex.enabled) return error.SkipZigTest;

    var pool = RegexPool.init(std.testing.allocator);
    defer pool.deinit();

    const ok = try pool.intern("\\d+");
    try std.testing.expectEqual(@as(u32, 0), ok);

    try std.testing.expectError(Error.RegexCompileFailed, pool.intern("(unclosed"));

    // Pool remains consistent — len == 1, the good entry still works.
    try std.testing.expectEqual(@as(usize, 1), pool.len());
    const again = try pool.intern("\\d+");
    try std.testing.expectEqual(ok, again);
}

test "LruCache: evicts LRU entry on overflow" {
    if (!regex.enabled) return error.SkipZigTest;

    // cap=2 so we can observe eviction without compiling 65 patterns.
    var cache = LruCache(2).init(std.testing.allocator);
    defer cache.deinit();

    _ = try cache.getOrCompile("a");
    _ = try cache.getOrCompile("b");
    try std.testing.expectEqual(@as(u32, 2), cache.size());
    try std.testing.expect(cache.contains("a"));
    try std.testing.expect(cache.contains("b"));

    // Third insertion evicts "a" (the LRU).
    _ = try cache.getOrCompile("c");
    try std.testing.expectEqual(@as(u32, 2), cache.size());
    try std.testing.expect(!cache.contains("a"));
    try std.testing.expect(cache.contains("b"));
    try std.testing.expect(cache.contains("c"));
}

test "LruCache: access promotes to MRU" {
    if (!regex.enabled) return error.SkipZigTest;

    var cache = LruCache(2).init(std.testing.allocator);
    defer cache.deinit();

    _ = try cache.getOrCompile("a");
    _ = try cache.getOrCompile("b");
    // Touch "a" — now "b" is the LRU.
    _ = try cache.getOrCompile("a");
    _ = try cache.getOrCompile("c");

    try std.testing.expect(cache.contains("a"));
    try std.testing.expect(!cache.contains("b"));
    try std.testing.expect(cache.contains("c"));
}

test "LruCache: hit returns same entry pointers across calls" {
    if (!regex.enabled) return error.SkipZigTest;

    var cache = LruCache(4).init(std.testing.allocator);
    defer cache.deinit();

    const e1 = try cache.getOrCompile("pattern");
    const e2 = try cache.getOrCompile("pattern");
    try std.testing.expectEqual(e1.regex, e2.regex);
    try std.testing.expectEqual(e1.clone, e2.clone);
}

test "LruCache: entry bundles Regex + RegexClone as single source of truth" {
    // The LruCache is the single source of truth for dynamic-pattern state.
    // One entry = one (Regex, RegexClone) pair; eviction frees both without
    // any external hook or parallel keyed-by-pointer store.
    if (!regex.enabled) return error.SkipZigTest;

    var cache = LruCache(2).init(std.testing.allocator);
    defer cache.deinit();

    // Insert "a", "b": both usable, both with their own clones.
    const a = try cache.getOrCompile("a");
    const b = try cache.getOrCompile("b");
    try std.testing.expect(try a.clone.isMatch("a"));
    try std.testing.expect(try b.clone.isMatch("b"));

    // Third insert evicts "a"; nothing external needs to be informed because
    // the cache owns both pieces of the entry.
    _ = try cache.getOrCompile("c");
    try std.testing.expect(!cache.contains("a"));
    try std.testing.expect(cache.contains("b"));
    try std.testing.expect(cache.contains("c"));
    try std.testing.expectEqual(@as(u32, 2), cache.size());
}

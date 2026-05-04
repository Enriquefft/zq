//! jq module-system resolver — Phase 2a.
//!
//! Walks the search path for `import "x" as foo;` / `include "x";` /
//! `import "data" as $d;` directives. For `.jq` modules tries both
//! `<root>/<relpath>.jq` and `<root>/<relpath>/<relpath>.jq` (jq's
//! dir-named-after-module convention). For `.json` data files only
//! `<root>/<relpath>.json` is tried.
//!
//! Search-path order (highest priority first):
//!   1. Explicit `module_search_path` from `Opts`.
//!   2. `current_file_dir` from `Opts` (importer-file dir).
//!
//! Modules are memoized by absolute resolved path so a `.jq` file
//! imported under multiple aliases parses once.

const std = @import("std");
const ast = @import("ast");

pub const ResolverError = error{
    OutOfMemory,
    ModuleNotFound,
    ImportSyntaxError,
    ImportIoError,
};

/// Resolved module — owns the parsed AST keyed by absolute path.
pub const ResolvedModule = struct {
    abs_path: []const u8,
    parse_result: ast.ParseResult,
};

/// Resolver state — owns its arena (caller-supplied) and a cache.
pub const Resolver = struct {
    /// Arena used for bookkeeping (paths, cache keys). Module ASTs
    /// own their own ParseResult arenas, allocated via the user
    /// allocator and stored in `cache`.
    arena: *std.heap.ArenaAllocator,
    /// User allocator for ParseResult arenas + IO buffers. Lives
    /// beyond a single compile so cached parses can outlive the
    /// resolver's arena (we still own them; deinitAll drops them).
    user_alloc: std.mem.Allocator,
    explicit_L: []const []const u8,
    cwd: ?[]const u8,
    /// abs_path → owned ResolvedModule. Lifetimes: the ResolvedModule's
    /// abs_path slice is allocated in the resolver's arena; the
    /// parse_result owns its own arena allocated by user_alloc.
    cache: std.StringHashMapUnmanaged(*ResolvedModule) = .{},

    pub fn init(
        arena: *std.heap.ArenaAllocator,
        user_alloc: std.mem.Allocator,
        explicit_L: []const []const u8,
        cwd: ?[]const u8,
    ) Resolver {
        return .{
            .arena = arena,
            .user_alloc = user_alloc,
            .explicit_L = explicit_L,
            .cwd = cwd,
        };
    }

    /// Drop every cached parse. Idempotent. Caller must invoke this
    /// before the resolver's arena is freed (cache entries reference
    /// arena-owned strings as keys but their ParseResult arenas live
    /// in user_alloc and need explicit deinit).
    pub fn deinit(self: *Resolver) void {
        var it = self.cache.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.*.parse_result.deinit();
        }
        self.cache.deinit(self.arena.allocator());
    }

    /// Locate and parse a `.jq` module. Tries `<root>/<relpath>.jq`,
    /// then `<root>/<relpath>/<relpath>.jq` for each search-path
    /// entry (explicit_L first, then cwd). Returns the cached
    /// ResolvedModule on hit.
    pub fn loadJq(self: *Resolver, relpath: []const u8) ResolverError!*ResolvedModule {
        const abs_path = (try self.findJqAbsPath(relpath)) orelse return error.ModuleNotFound;
        return self.loadAndCache(abs_path);
    }

    /// Locate and read a `.json` data file. Tries
    /// `<root>/<relpath>.json` for each search-path entry. Returns
    /// the file contents (caller borrows from resolver's arena).
    pub fn loadJsonBytes(self: *Resolver, relpath: []const u8) ResolverError![]const u8 {
        const arena_alloc = self.arena.allocator();
        for (self.explicit_L) |root| {
            const candidate = std.fmt.allocPrint(arena_alloc, "{s}/{s}.json", .{ root, relpath }) catch return error.OutOfMemory;
            if (std.fs.cwd().readFileAlloc(arena_alloc, candidate, 16 * 1024 * 1024)) |bytes| {
                return bytes;
            } else |_| {}
        }
        if (self.cwd) |c| {
            const candidate = std.fmt.allocPrint(arena_alloc, "{s}/{s}.json", .{ c, relpath }) catch return error.OutOfMemory;
            if (std.fs.cwd().readFileAlloc(arena_alloc, candidate, 16 * 1024 * 1024)) |bytes| {
                return bytes;
            } else |_| {}
        }
        return error.ModuleNotFound;
    }

    fn findJqAbsPath(self: *Resolver, relpath: []const u8) ResolverError!?[]const u8 {
        const arena_alloc = self.arena.allocator();
        // Build candidate roots: explicit search path first, then cwd.
        const candidates_per_root = [_][2][]const u8{
            .{ "{s}/{s}.jq", "" },
            .{ "{s}/{s}/{s}.jq", "" },
        };
        _ = candidates_per_root;

        for (self.explicit_L) |root| {
            const a = std.fmt.allocPrint(arena_alloc, "{s}/{s}.jq", .{ root, relpath }) catch return error.OutOfMemory;
            if (fileExists(a)) return a;
            const b = std.fmt.allocPrint(arena_alloc, "{s}/{s}/{s}.jq", .{ root, relpath, relpath }) catch return error.OutOfMemory;
            if (fileExists(b)) return b;
        }
        if (self.cwd) |c| {
            const a = std.fmt.allocPrint(arena_alloc, "{s}/{s}.jq", .{ c, relpath }) catch return error.OutOfMemory;
            if (fileExists(a)) return a;
            const b = std.fmt.allocPrint(arena_alloc, "{s}/{s}/{s}.jq", .{ c, relpath, relpath }) catch return error.OutOfMemory;
            if (fileExists(b)) return b;
        }
        return null;
    }

    fn loadAndCache(self: *Resolver, abs_path: []const u8) ResolverError!*ResolvedModule {
        if (self.cache.get(abs_path)) |hit| return hit;
        const arena_alloc = self.arena.allocator();

        const src = std.fs.cwd().readFileAlloc(arena_alloc, abs_path, 16 * 1024 * 1024) catch return error.ImportIoError;
        const parsed = ast.parse(src, self.user_alloc);

        const entry = arena_alloc.create(ResolvedModule) catch return error.OutOfMemory;
        entry.* = .{
            .abs_path = abs_path,
            .parse_result = parsed,
        };
        try self.cache.put(arena_alloc, abs_path, entry);
        return entry;
    }
};

fn fileExists(path: []const u8) bool {
    var f = std.fs.cwd().openFile(path, .{}) catch return false;
    f.close();
    return true;
}

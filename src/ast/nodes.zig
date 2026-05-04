const std = @import("std");

/// Byte range in source for error reporting and LSP position mapping.
pub const Span = struct {
    start: u32,
    end: u32,

    pub fn empty() Span {
        return .{ .start = 0, .end = 0 };
    }

    pub fn from(start: u32, end: u32) Span {
        return .{ .start = start, .end = end };
    }
};

/// Arena-allocated AST node. Every node carries a source Span.
pub const Node = struct {
    kind: Kind,
    span: Span,

    pub const Kind = union(enum) {
        // ── Composition ──────────────────────────────────────────────
        program: Program,
        pipe: Pipe,
        comma: Comma,
        func_def: FuncDef,

        // ── Operators ────────────────────────────────────────────────
        alternative: Binary, // //
        or_expr: Binary,
        and_expr: Binary,
        comparison: Comparison,
        arithmetic: Arithmetic,
        unary_neg: Unary, // -expr

        // ── Binding ──────────────────────────────────────────────────
        as_pattern: AsPattern,
        destruct_alt: DestructAlt,

        // ── Primary ──────────────────────────────────────────────────
        identity, // .
        recurse, // ..
        field_access: FieldAccess,
        index_access: IndexAccess,
        iterate, // .[]
        slice: Slice,
        literal: Literal,
        paren: Unary, // (expr)
        variable_ref: VarRef,
        optional: Unary, // expr?

        // ── Constructors ─────────────────────────────────────────────
        array_construct: ArrayConstruct,
        object_construct: ObjectConstruct,
        string_interp: StringInterp,
        format_string: FormatString,

        // ── Calls ────────────────────────────────────────────────────
        builtin_call: BuiltinCall,
        func_call: FuncCall,

        // ── Control flow ─────────────────────────────────────────────
        if_expr: IfExpr,
        try_catch: TryCatch,
        reduce: Reduce,
        foreach: Foreach,
        label_expr: LabelExpr,
        break_expr: BreakExpr,

        // ── Assignment ───────────────────────────────────────────────
        update_assign: UpdateAssign,
        /// Assignment whose LHS is NOT a simple `.path.path[n]` chain.
        /// Emitted by `src/compiler/lower.zig` via the complex-LHS update path
        /// — the LHS is any path expression (parens, comma, pipe, iteration,
        /// function call that produces paths, ...) and the emitter wraps it in
        /// `path_begin`/`path_end` at emit time.
        ///
        /// The strict `.path` LHS stays on `update_assign` so the fast-path
        /// `emitNavigation`/`emitUpdateChain` bytecode shape is preserved
        /// byte-for-byte. Complex LHSs route through this node instead.
        /// Complex LHS choice rationale: Option A (AST-side) — complex
        /// update-assign LHSs are routed through this node rather than
        /// handled in the emitter, keeping `emitNavigation`/`emitUpdateChain`
        /// byte-for-byte stable.
        assign_general: AssignGeneral,

        // ── Suffix chain ─────────────────────────────────────────────
        suffix: Suffix,

        // ── Error recovery ───────────────────────────────────────────
        error_node: ErrorNode,
    };

    // ── Node payload types ──────────────────────────────────────────

    /// Top-level program wrapper (jq module system, Phase 2a).
    /// Wraps the body with optional `module {meta};` and a sequence of
    /// `import "x" as foo;` / `include "x";` directives. Lower-time
    /// processes directives in order before lowering `body`.
    pub const Program = struct {
        module_meta: ?*const Node,
        directives: []const Directive,
        body: *Node,
    };

    /// One module-system directive (`import` or `include`).
    pub const Directive = struct {
        kind: DirectiveKind,
        relpath: []const u8,
        /// Alias for `import "x" as <alias>`. Null for `include`.
        /// For `import "data" as $name`, alias is the variable name and
        /// `is_data` is true.
        alias: ?[]const u8,
        /// True when the import binds a JSON file to a variable (`as $name`).
        is_data: bool,
        /// Optional `{search:"..."}` const-object metadata.
        meta: ?*const Node,
        span: Span,
    };

    pub const DirectiveKind = enum { import_, include_ };

    pub const Pipe = struct {
        left: *Node,
        right: *Node,
    };

    pub const Comma = struct {
        left: *Node,
        right: *Node,
    };

    pub const FuncDef = struct {
        name: []const u8,
        params: []const FuncParam,
        body: *Node,
        rest: *Node, // continuation after ;
    };

    pub const FuncParam = struct {
        name: []const u8,
        is_filter: bool,
        span: Span,
    };

    pub const Binary = struct {
        left: *Node,
        right: *Node,
    };

    pub const Comparison = struct {
        op: CmpOp,
        left: *Node,
        right: *Node,

        pub const CmpOp = enum { eq, ne, lt, le, gt, ge };
    };

    pub const Arithmetic = struct {
        op: ArithOp,
        left: *Node,
        right: *Node,

        pub const ArithOp = enum { add, sub, mul, div, mod };
    };

    pub const Unary = struct {
        operand: *Node,
    };

    pub const AsPattern = struct {
        expr: *Node,
        pattern: Pattern,
        body: *Node,
    };

    pub const DestructAlt = struct {
        expr: *Node,
        patterns: []const Pattern,
        body: *Node,
    };

    pub const FieldAccess = struct {
        name: []const u8,
    };

    pub const IndexAccess = struct {
        index: i64,
    };

    pub const Slice = struct {
        has_from: bool,
        from: i32,
        has_to: bool,
        to: i32,
        /// Computed-bound expressions for `.[expr1:expr2]`. When present, the
        /// emitter routes through `slice_computed`; when null, the literal
        /// `from`/`to` fields are used by the legacy `slice` opcode.
        from_expr: ?*Node = null,
        to_expr: ?*Node = null,
    };

    pub const Literal = union(enum) {
        int: i64,
        float: f64,
        /// Canonical normalized form of an out-of-range numeric literal,
        /// e.g. "9E+999999999".  Backed by the AST arena allocator.
        big_number: []const u8,
        string: []const u8,
        bool_val: bool,
        null_val,
    };

    pub const VarRef = struct {
        name: []const u8,
    };

    pub const ArrayConstruct = struct {
        /// null for empty array []
        expr: ?*Node,
    };

    pub const ObjectConstruct = struct {
        fields: []const ObjectField,
    };

    pub const ObjectField = struct {
        key: ObjectKey,
        value: *Node,
        span: Span,
    };

    pub const ObjectKey = union(enum) {
        /// Plain identifier key, e.g. `{foo: 1}` or `{foo}` shorthand.
        ident: []const u8,
        /// `{$y: VALUE}` form: key is the *runtime value* of variable `$y`
        /// (jq semantics: must be a string). Distinct from the `{$x}`
        /// shorthand which uses `.ident` with the bare name as a literal key.
        dollar_ident: []const u8,
        string: []const u8,
        expr: *Node,
    };

    pub const StringInterp = struct {
        parts: []const StringPart,
    };

    pub const FormatString = struct {
        format: []const u8,
        parts: []const StringPart,
    };

    pub const StringPart = union(enum) {
        literal: []const u8,
        expr: *Node,
    };

    pub const BuiltinCall = struct {
        name: []const u8,
        args: []const *Node,
    };

    pub const FuncCall = struct {
        name: []const u8,
        args: []const *Node,
    };

    pub const IfExpr = struct {
        cond: *Node,
        then_body: *Node,
        elif_chains: []const ElifChain,
        else_body: ?*Node,
    };

    pub const ElifChain = struct {
        cond: *Node,
        body: *Node,
    };

    pub const TryCatch = struct {
        body: *Node,
        catch_body: ?*Node,
    };

    pub const Reduce = struct {
        expr: *Node,
        pattern: Pattern,
        init: *Node,
        update: *Node,
    };

    pub const Foreach = struct {
        expr: *Node,
        pattern: Pattern,
        init: *Node,
        update: *Node,
        extract: ?*Node,
    };

    pub const LabelExpr = struct {
        name: []const u8,
        body: *Node,
    };

    pub const BreakExpr = struct {
        name: []const u8,
    };

    pub const UpdateAssign = struct {
        path: []const PathStep,
        op: AssignOp,
        rhs: *Node,

        pub const AssignOp = enum { pipe_eq, eq, plus_eq, minus_eq, star_eq, slash_eq, percent_eq, double_slash_eq };
    };

    /// Assignment with an arbitrary LHS expression. Walker must re-walk the
    /// LHS as a path expression under `path_begin`/`path_end` to produce the
    /// path set, then apply the compound-update logic from
    /// `compilePathExprUpdate`. Reuses `UpdateAssign.AssignOp` so both
    /// assign nodes speak the same operator alphabet.
    pub const AssignGeneral = struct {
        lhs: *Node,
        op: UpdateAssign.AssignOp,
        rhs: *Node,
        /// Byte offset of the first character of the assignment operator
        /// token (`=`, `|=`, `+=`, ...). Preserved so the walker can stamp
        /// the same `last_tok_offset` the legacy compiler used when it
        /// consumed the operator inside `compilePathExprUpdate`. AST spans
        /// otherwise cover lhs.start → rhs.end and lose the operator byte.
        op_offset: u32,
    };

    pub const PathStep = union(enum) {
        key: []const u8,
        index: i64,
        iterate,
    };

    pub const Suffix = struct {
        base: *Node,
        ops: []const SuffixOp,
    };

    pub const SuffixOp = union(enum) {
        field: []const u8,
        index: i64,
        iterate,
        slice: Slice,
        optional,
        bracket_expr: *Node, // .[expr]
        bracket_str: []const u8,
    };

    pub const ErrorNode = struct {
        message: []const u8,
    };
};

/// Destructuring pattern for `as`, `reduce`, `foreach`.
pub const Pattern = union(enum) {
    simple: []const u8, // variable name
    array: []const Pattern,
    object: []const ObjectPatternField,
};

pub const ObjectPatternField = struct {
    key: PatternKey,
    pattern: Pattern,
};

pub const PatternKey = union(enum) {
    static: []const u8,
    computed: *Node,
};

/// Parse error collected during error-tolerant parsing.
pub const ParseError = struct {
    message: []const u8,
    span: Span,
    kind: Kind,

    pub const Kind = enum {
        unexpected_token,
        missing_token,
        unterminated,
        invalid_literal,
        unknown,
    };
};

/// Result of parsing. Always contains an AST (possibly partial).
pub const ParseResult = struct {
    root: *Node,
    errors: []const ParseError,
    arena: std.heap.ArenaAllocator,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *ParseResult) void {
        if (self.errors.len > 0) {
            self.alloc.free(self.errors);
        }
        self.arena.deinit();
    }

    pub fn hasErrors(self: *const ParseResult) bool {
        return self.errors.len > 0;
    }
};

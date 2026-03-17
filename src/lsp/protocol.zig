const std = @import("std");

// ── LSP Position/Range types ─────────────────────────────────────────────

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const Location = struct {
    uri: []const u8,
    range: Range,
};

// ── Diagnostic ───────────────────────────────────────────────────────────

pub const DiagnosticSeverity = enum(u8) {
    @"error" = 1,
    warning = 2,
    information = 3,
    hint = 4,
};

pub const Diagnostic = struct {
    range: Range,
    severity: DiagnosticSeverity,
    message: []const u8,
    source: []const u8 = "zq",
};

// ── Completion ───────────────────────────────────────────────────────────

pub const CompletionItemKind = enum(u8) {
    text = 1,
    method = 2,
    function = 3,
    constructor = 4,
    field = 5,
    variable = 6,
    class = 7,
    interface = 8,
    module = 9,
    property = 10,
    unit = 11,
    value = 12,
    @"enum" = 13,
    keyword = 14,
    snippet = 15,
    color = 16,
    file = 17,
    reference = 18,
    folder = 19,
    enum_member = 20,
    constant = 21,
    @"struct" = 22,
    event = 23,
    operator = 24,
    type_parameter = 25,
};

pub const InsertTextFormat = enum(u8) {
    plain_text = 1,
    snippet = 2,
};

pub const CompletionItem = struct {
    label: []const u8,
    kind: CompletionItemKind,
    detail: ?[]const u8 = null,
    documentation: ?[]const u8 = null,
    insertText: ?[]const u8 = null,
    insertTextFormat: ?InsertTextFormat = null,
};

// ── Hover ────────────────────────────────────────────────────────────────

pub const Hover = struct {
    contents: MarkupContent,
    range: ?Range = null,
};

pub const MarkupContent = struct {
    kind: []const u8 = "markdown",
    value: []const u8,
};

// ── Semantic Tokens ──────────────────────────────────────────────────────

pub const SemanticTokenTypes = struct {
    pub const keyword = 0;
    pub const function = 1;
    pub const variable = 2;
    pub const string = 3;
    pub const number = 4;
    pub const operator = 5;
    pub const property = 6;
    pub const type_ = 7;
};

pub const SemanticTokenModifiers = struct {
    pub const declaration = 0;
    pub const builtin = 1;
};

// ── Text Document ────────────────────────────────────────────────────────

pub const TextDocumentIdentifier = struct {
    uri: []const u8,
};

pub const TextDocumentItem = struct {
    uri: []const u8,
    languageId: []const u8,
    version: i64,
    text: []const u8,
};

pub const VersionedTextDocumentIdentifier = struct {
    uri: []const u8,
    version: i64,
};

pub const TextDocumentContentChangeEvent = struct {
    text: []const u8,
};

// ── UTF-16 offset conversion ─────────────────────────────────────────────

/// Convert UTF-8 byte offset to UTF-16 character offset.
/// Fast path for ASCII (most jq filters).
pub fn utf8ToUtf16Offset(text: []const u8, byte_offset: u32) u32 {
    var utf16_offset: u32 = 0;
    var i: u32 = 0;
    while (i < byte_offset and i < text.len) {
        const byte = text[i];
        if (byte < 0x80) {
            utf16_offset += 1;
            i += 1;
        } else if (byte < 0xC0) {
            // Continuation byte — skip
            i += 1;
        } else if (byte < 0xE0) {
            utf16_offset += 1;
            i += 2;
        } else if (byte < 0xF0) {
            utf16_offset += 1;
            i += 3;
        } else {
            // 4-byte sequence → 2 UTF-16 code units (surrogate pair)
            utf16_offset += 2;
            i += 4;
        }
    }
    return utf16_offset;
}

/// Convert UTF-16 character offset to UTF-8 byte offset.
pub fn utf16ToUtf8Offset(text: []const u8, utf16_offset: u32) u32 {
    var utf16_count: u32 = 0;
    var i: u32 = 0;
    while (utf16_count < utf16_offset and i < text.len) {
        const byte = text[i];
        if (byte < 0x80) {
            utf16_count += 1;
            i += 1;
        } else if (byte < 0xC0) {
            i += 1;
        } else if (byte < 0xE0) {
            utf16_count += 1;
            i += 2;
        } else if (byte < 0xF0) {
            utf16_count += 1;
            i += 3;
        } else {
            utf16_count += 2;
            i += 4;
        }
    }
    return i;
}

/// Convert a byte offset to (line, character) Position using UTF-16 offsets.
pub fn byteOffsetToPosition(source: []const u8, offset: u32) Position {
    var line: u32 = 0;
    var line_start: u32 = 0;
    var i: u32 = 0;
    while (i < offset and i < source.len) {
        if (source[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
        i += 1;
    }
    const col_bytes = offset - line_start;
    const character = utf8ToUtf16Offset(source[line_start..], col_bytes);
    return .{ .line = line, .character = character };
}

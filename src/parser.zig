const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Language = enum {
    zig,
    typescript,
    javascript,
    python,
    go,
    rust,
    c,
    cpp,
    java,
    ruby,
    fsharp,
    csharp,
    unknown,

    pub fn fromExtension(path: []const u8) Language {
        const exts = .{
            .{ ".zig", Language.zig },
            .{ ".ts", .typescript },
            .{ ".tsx", .typescript },
            .{ ".js", .javascript },
            .{ ".jsx", .javascript },
            .{ ".py", .python },
            .{ ".go", .go },
            .{ ".rs", .rust },
            .{ ".c", .c },
            .{ ".h", .c },
            .{ ".cpp", .cpp },
            .{ ".hpp", .cpp },
            .{ ".cc", .cpp },
            .{ ".java", .java },
            .{ ".rb", .ruby },
            .{ ".fs", .fsharp },
            .{ ".fsx", .fsharp },
            .{ ".cs", .csharp },
        };
        inline for (exts) |pair| {
            if (std.mem.endsWith(u8, path, pair[0])) return pair[1];
        }
        return .unknown;
    }

    pub fn isSupported(self: Language) bool {
        return self != .unknown;
    }

    pub fn name(self: Language) []const u8 {
        return switch (self) {
            .zig => "zig",
            .typescript => "typescript",
            .javascript => "javascript",
            .python => "python",
            .go => "go",
            .rust => "rust",
            .c => "c",
            .cpp => "cpp",
            .java => "java",
            .ruby => "ruby",
            .fsharp => "fsharp",
            .csharp => "csharp",
            .unknown => "unknown",
        };
    }
};

pub const CodeUnitKind = enum {
    function,
    type_def,
    import_decl,
};

pub const CodeUnit = struct {
    kind: CodeUnitKind,
    name: []const u8,
    signature: []const u8,
    file_path: []const u8,
    line_number: u32,
    module_name: []const u8,
};

// --- AST types ---

pub const AstNodeKind = enum {
    function,
    type_def,
    import_decl,
    field,
    variable,

    pub fn label(self: AstNodeKind) []const u8 {
        return switch (self) {
            .function => "fn",
            .type_def => "type",
            .import_decl => "import",
            .field => "field",
            .variable => "var",
        };
    }
};

pub const AstNode = struct {
    kind: AstNodeKind,
    name: []const u8,
    signature: []const u8,
    line_number: u32,
    depth: u16,
};

const AstContext = enum { top, struct_body, enum_body, fn_body };

/// Split camelCase and snake_case identifiers into sub-tokens.
/// Caller owns returned slice.
pub fn splitIdentifier(alloc: Allocator, ident: []const u8) ![][]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    for (ident, 0..) |ch, i| {
        if (ch == '_' or ch == '-' or ch == '.') {
            if (i > start) try parts.append(alloc, ident[start..i]);
            start = i + 1;
        } else if (i > 0 and std.ascii.isUpper(ch) and !std.ascii.isUpper(ident[i - 1])) {
            if (i > start) try parts.append(alloc, ident[start..i]);
            start = i;
        }
    }
    if (start < ident.len) try parts.append(alloc, ident[start..]);
    return parts.toOwnedSlice(alloc);
}

/// Extract code units from source text for a given language.
pub fn parseSource(alloc: Allocator, source: []const u8, file_path: []const u8, lang: Language) ![]CodeUnit {
    var units: std.ArrayList(CodeUnit) = .empty;
    var line_iter = std.mem.splitScalar(u8, source, '\n');
    var line_num: u32 = 0;

    const mod_name = moduleName(file_path);

    while (line_iter.next()) |raw_line| {
        line_num += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        if (tryParseFunction(line, lang)) |fn_name| {
            try units.append(alloc, .{
                .kind = .function,
                .name = try alloc.dupe(u8, fn_name),
                .signature = try alloc.dupe(u8, line),
                .file_path = try alloc.dupe(u8, file_path),
                .line_number = line_num,
                .module_name = try alloc.dupe(u8, mod_name),
            });
        } else if (tryParseType(line, lang)) |type_name| {
            try units.append(alloc, .{
                .kind = .type_def,
                .name = try alloc.dupe(u8, type_name),
                .signature = try alloc.dupe(u8, line),
                .file_path = try alloc.dupe(u8, file_path),
                .line_number = line_num,
                .module_name = try alloc.dupe(u8, mod_name),
            });
        } else if (tryParseImport(line, lang)) |imp_name| {
            try units.append(alloc, .{
                .kind = .import_decl,
                .name = try alloc.dupe(u8, imp_name),
                .signature = try alloc.dupe(u8, line),
                .file_path = try alloc.dupe(u8, file_path),
                .line_number = line_num,
                .module_name = try alloc.dupe(u8, mod_name),
            });
        }
    }
    return units.toOwnedSlice(alloc);
}

// --- pattern matchers ---

fn tryParseFunction(line: []const u8, lang: Language) ?[]const u8 {
    return switch (lang) {
        .zig => extractAfterKeyword(line, "fn "),
        .python => extractAfterKeyword(line, "def ") orelse extractAfterKeyword(line, "async def "),
        .go => extractAfterKeyword(line, "func "),
        .rust => extractAfterKeyword(line, "fn "),
        .typescript, .javascript => extractAfterKeyword(line, "function ") orelse extractAfterKeyword(line, "async function "),
        .java, .csharp => extractJavaLikeMethod(line),
        .ruby => extractAfterKeyword(line, "def "),
        .fsharp => extractAfterKeyword(line, "let "),
        .c, .cpp => extractCFunction(line),
        .unknown => null,
    };
}

fn tryParseType(line: []const u8, lang: Language) ?[]const u8 {
    return switch (lang) {
        .zig => extractZigType(line),
        .python => extractAfterKeyword(line, "class "),
        .go => extractAfterKeyword(line, "type "),
        .rust => extractAfterKeyword(line, "struct ") orelse
            extractAfterKeyword(line, "enum ") orelse
            extractAfterKeyword(line, "trait "),
        .typescript, .javascript => extractAfterKeyword(line, "class ") orelse
            extractAfterKeyword(line, "interface ") orelse
            extractAfterKeyword(line, "type "),
        .java, .csharp => extractAfterKeyword(line, "class ") orelse
            extractAfterKeyword(line, "interface ") orelse
            extractAfterKeyword(line, "enum "),
        .ruby => extractAfterKeyword(line, "class ") orelse extractAfterKeyword(line, "module "),
        .fsharp => extractAfterKeyword(line, "type "),
        .c, .cpp => extractAfterKeyword(line, "struct ") orelse
            extractAfterKeyword(line, "enum ") orelse
            extractAfterKeyword(line, "class "),
        .unknown => null,
    };
}

fn tryParseImport(line: []const u8, lang: Language) ?[]const u8 {
    return switch (lang) {
        .zig => extractZigImport(line),
        .python => extractAfterKeyword(line, "import ") orelse extractAfterKeyword(line, "from "),
        .go => extractAfterKeyword(line, "import "),
        .rust => extractAfterKeyword(line, "use "),
        .typescript, .javascript => extractAfterKeyword(line, "import "),
        .java, .csharp => extractAfterKeyword(line, "using ") orelse extractAfterKeyword(line, "import "),
        .ruby => extractAfterKeyword(line, "require "),
        .fsharp => extractAfterKeyword(line, "open "),
        .c, .cpp => extractAfterKeyword(line, "#include "),
        .unknown => null,
    };
}

// --- helpers ---

fn extractAfterKeyword(line: []const u8, keyword: []const u8) ?[]const u8 {
    // Strip common prefixes (pub, export, async, etc.)
    const stripped = stripPrefixes(line);
    if (!std.mem.startsWith(u8, stripped, keyword)) return null;
    const rest = stripped[keyword.len..];
    return extractIdentifier(rest);
}

fn stripPrefixes(line: []const u8) []const u8 {
    const prefixes = [_][]const u8{
        "export default ",
        "export ",
        "pub(crate) ",
        "pub ",
        "public static ",
        "public ",
        "private ",
        "protected ",
        "static ",
        "abstract ",
        "override ",
        "virtual ",
        "inline ",
        "const ",
    };
    var result = line;
    var changed = true;
    while (changed) {
        changed = false;
        for (prefixes) |prefix| {
            if (std.mem.startsWith(u8, result, prefix)) {
                result = result[prefix.len..];
                changed = true;
                break;
            }
        }
    }
    return result;
}

fn extractIdentifier(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
    // Skip leading non-identifier chars (e.g., '(' in Go receiver)
    var start: usize = 0;
    while (start < s.len and !isIdentChar(s[start])) : (start += 1) {}
    if (start >= s.len) return null;
    var end = start;
    while (end < s.len and isIdentChar(s[end])) : (end += 1) {}
    if (end == start) return null;
    return s[start..end];
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn extractZigType(line: []const u8) ?[]const u8 {
    // Match: `const Foo = struct {` or `pub const Foo = enum {`
    // Handle "pub " directly — stripPrefixes would also strip "const "
    var s = line;
    if (std.mem.startsWith(u8, s, "pub ")) s = s[4..];
    if (!std.mem.startsWith(u8, s, "const ")) return null;
    const rest = s[6..]; // skip "const "
    const eq_pos = std.mem.indexOf(u8, rest, " = ") orelse return null;
    const after_eq = rest[eq_pos + 3 ..];
    const type_keywords = [_][]const u8{ "struct", "enum", "union", "opaque" };
    for (type_keywords) |kw| {
        if (std.mem.startsWith(u8, after_eq, kw)) {
            return rest[0..eq_pos];
        }
    }
    return null;
}

fn extractZigImport(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, "@import(")) |pos| {
        const after = line[pos + 8 ..];
        if (std.mem.indexOf(u8, after, "\"")) |q1| {
            const start = q1 + 1;
            if (std.mem.indexOf(u8, after[start..], "\"")) |q2| {
                return after[start .. start + q2];
            }
        }
    }
    return null;
}

fn extractJavaLikeMethod(line: []const u8) ?[]const u8 {
    // Heuristic: line has `(` and doesn't start with control flow keywords
    const stripped = stripPrefixes(line);
    const control = [_][]const u8{ "if ", "else ", "for ", "while ", "switch ", "return ", "throw ", "new ", "try ", "catch " };
    for (control) |kw| {
        if (std.mem.startsWith(u8, stripped, kw)) return null;
    }
    const paren = std.mem.indexOf(u8, stripped, "(") orelse return null;
    if (paren == 0) return null;
    // Walk backward from '(' to find identifier
    var end = paren;
    while (end > 0 and stripped[end - 1] == ' ') : (end -= 1) {}
    var start = end;
    while (start > 0 and isIdentChar(stripped[start - 1])) : (start -= 1) {}
    if (start == end) return null;
    // Must have a return type before the method name (at least one space before start)
    if (start == 0) return null;
    return stripped[start..end];
}

fn extractCFunction(line: []const u8) ?[]const u8 {
    // Heuristic: has `(`, no `=`, no `#`, no `;` before `(`
    if (line.len == 0 or line[0] == '#') return null;
    const paren = std.mem.indexOf(u8, line, "(") orelse return null;
    const before_paren = line[0..paren];
    if (std.mem.indexOf(u8, before_paren, "=") != null) return null;
    if (std.mem.indexOf(u8, before_paren, ";") != null) return null;
    // Find identifier just before '('
    var end = paren;
    while (end > 0 and line[end - 1] == ' ') : (end -= 1) {}
    var start = end;
    while (start > 0 and isIdentChar(line[start - 1])) : (start -= 1) {}
    if (start == end) return null;
    if (start > 0 and line[start - 1] == '*') start -= 1; // pointer return
    const kw_check = [_][]const u8{ "if", "for", "while", "switch", "return", "sizeof", "typeof" };
    for (kw_check) |kw| {
        if (std.mem.eql(u8, line[start..end], kw)) return null;
    }
    // Strip leading '*'
    var name_start = start;
    while (name_start < end and line[name_start] == '*') : (name_start += 1) {}
    if (name_start == end) return null;
    return line[name_start..end];
}

fn moduleName(file_path: []const u8) []const u8 {
    // Use filename without extension as module name
    const base = std.fs.path.basename(file_path);
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
        return base[0..dot];
    }
    return base;
}

// --- AST parser ---

/// Parse source into a depth-aware AST node list.
/// Caller owns returned slice and must free each node's name and signature.
pub fn parseAst(alloc: Allocator, source: []const u8, lang: Language) ![]AstNode {
    return switch (lang) {
        .python, .ruby => parseAstIndent(alloc, source, lang),
        else => parseAstBrace(alloc, source, lang),
    };
}

fn parseAstBrace(alloc: Allocator, source: []const u8, lang: Language) ![]AstNode {
    var nodes: std.ArrayList(AstNode) = .empty;
    var line_iter = std.mem.splitScalar(u8, source, '\n');
    var line_num: u32 = 0;
    var brace_depth: i32 = 0;
    var ctx_stack: [128]AstContext = .{.top} ** 128;

    while (line_iter.next()) |raw_line| {
        line_num += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        const depth: u16 = if (brace_depth > 0) @intCast(@as(u32, @intCast(brace_depth))) else 0;
        var found_type = false;
        var found_fn = false;

        if (tryParseFunction(line, lang)) |name| {
            try appendAstNode(&nodes, alloc, .function, name, line, line_num, depth);
            found_fn = true;
        } else if (tryParseType(line, lang)) |name| {
            try appendAstNode(&nodes, alloc, .type_def, name, line, line_num, depth);
            found_type = true;
        } else if (tryParseImport(line, lang)) |name| {
            try appendAstNode(&nodes, alloc, .import_decl, name, line, line_num, depth);
        } else {
            const ctx = if (depth < 128) ctx_stack[depth] else .top;
            const in_enum = (ctx == .enum_body);
            if (tryParseMember(line, lang)) |name| {
                const kind: AstNodeKind = if (ctx == .struct_body or ctx == .enum_body) .field else .variable;
                try appendAstNode(&nodes, alloc, kind, name, line, line_num, depth);
            } else if (in_enum) {
                if (extractEnumVariant(line)) |name| {
                    try appendAstNode(&nodes, alloc, .field, name, line, line_num, depth);
                }
            }
        }

        const net = countNetBraces(line, lang);
        const new_depth = brace_depth + net;
        if (net > 0 and new_depth > 0) {
            const nd: usize = @intCast(@as(u32, @intCast(new_depth)));
            if (nd < 128) {
                if (found_type) {
                    ctx_stack[nd] = detectTypeContext(line, lang);
                } else if (found_fn) {
                    ctx_stack[nd] = .fn_body;
                } else {
                    const parent: usize = @intCast(@as(u32, @intCast(@max(0, brace_depth))));
                    ctx_stack[nd] = if (parent < 128) ctx_stack[parent] else .top;
                }
            }
        }
        brace_depth = @max(0, new_depth);
    }

    return nodes.toOwnedSlice(alloc);
}

fn parseAstIndent(alloc: Allocator, source: []const u8, lang: Language) ![]AstNode {
    var nodes: std.ArrayList(AstNode) = .empty;
    var line_iter = std.mem.splitScalar(u8, source, '\n');
    var line_num: u32 = 0;
    var indent_unit: ?u16 = null;

    while (line_iter.next()) |raw_line| {
        line_num += 1;
        const trimmed = std.mem.trimRight(u8, raw_line, " \t\r");
        if (trimmed.len == 0) continue;
        const line = std.mem.trimLeft(u8, trimmed, " \t");
        if (line.len == 0) continue;

        const indent: u16 = @intCast(trimmed.len - line.len);
        if (indent > 0 and indent_unit == null) indent_unit = indent;
        const depth: u16 = if (indent_unit) |u| indent / u else 0;

        if (tryParseFunction(line, lang)) |name| {
            try appendAstNode(&nodes, alloc, .function, name, line, line_num, depth);
        } else if (tryParseType(line, lang)) |name| {
            try appendAstNode(&nodes, alloc, .type_def, name, line, line_num, depth);
        } else if (tryParseImport(line, lang)) |name| {
            try appendAstNode(&nodes, alloc, .import_decl, name, line, line_num, depth);
        } else if (tryParseMember(line, lang)) |name| {
            try appendAstNode(&nodes, alloc, .field, name, line, line_num, depth);
        }
    }

    return nodes.toOwnedSlice(alloc);
}

fn appendAstNode(
    nodes: *std.ArrayList(AstNode),
    alloc: Allocator,
    kind: AstNodeKind,
    name: []const u8,
    signature: []const u8,
    line_number: u32,
    depth: u16,
) !void {
    try nodes.append(alloc, .{
        .kind = kind,
        .name = try alloc.dupe(u8, name),
        .signature = try alloc.dupe(u8, signature),
        .line_number = line_number,
        .depth = depth,
    });
}

fn countNetBraces(line: []const u8, lang: Language) i32 {
    _ = lang;
    var net: i32 = 0;
    var in_string: bool = false;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (in_string) {
            if (c == '\\') {
                i += 2;
                continue;
            }
            if (c == '"') in_string = false;
            i += 1;
            continue;
        }
        if (c == '"') {
            in_string = true;
            i += 1;
            continue;
        }
        // Skip line comments
        if (c == '/' and i + 1 < line.len and line[i + 1] == '/') break;
        if (c == '#') break;
        if (c == '{') net += 1 else if (c == '}') net -= 1;
        i += 1;
    }
    return net;
}

fn detectTypeContext(line: []const u8, lang: Language) AstContext {
    switch (lang) {
        .zig => {
            if (std.mem.indexOf(u8, line, "= enum")) |_| return .enum_body;
            if (std.mem.indexOf(u8, line, "= struct")) |_| return .struct_body;
            if (std.mem.indexOf(u8, line, "= union")) |_| return .struct_body;
            return .struct_body;
        },
        else => {
            if (std.mem.indexOf(u8, line, "enum ")) |_| return .enum_body;
            if (std.mem.indexOf(u8, line, "enum{")) |_| return .enum_body;
            return .struct_body;
        },
    }
}

fn tryParseMember(line: []const u8, lang: Language) ?[]const u8 {
    const stripped = stripPrefixes(line);

    // Language-specific const/var/let declarations
    switch (lang) {
        .zig => {
            // Handle "pub const/var" directly — stripPrefixes eats "const "
            var s = line;
            if (std.mem.startsWith(u8, s, "pub ")) s = s[4..];
            if (std.mem.startsWith(u8, s, "const "))
                return extractIdentifier(s[6..]);
            if (std.mem.startsWith(u8, s, "var "))
                return extractIdentifier(s[4..]);
        },
        .rust => {
            if (std.mem.startsWith(u8, stripped, "let ")) {
                const rest = stripped[4..];
                if (std.mem.startsWith(u8, rest, "mut "))
                    return extractIdentifier(rest[4..]);
                return extractIdentifier(rest);
            }
        },
        .javascript, .typescript => {
            if (std.mem.startsWith(u8, stripped, "const ")) return extractIdentifier(stripped[6..]);
            if (std.mem.startsWith(u8, stripped, "let ")) return extractIdentifier(stripped[4..]);
            if (std.mem.startsWith(u8, stripped, "var ")) return extractIdentifier(stripped[4..]);
        },
        .go => {
            if (std.mem.startsWith(u8, stripped, "var ")) return extractIdentifier(stripped[4..]);
            if (std.mem.indexOf(u8, stripped, " := ") != null) return extractIdentifier(stripped);
        },
        .python => {
            if (std.mem.startsWith(u8, stripped, "self.")) return extractIdentifier(stripped[5..]);
        },
        .ruby => {
            if (stripped.len > 1 and stripped[0] == '@') {
                const start: usize = if (stripped.len > 2 and stripped[1] == '@') 2 else 1;
                return extractIdentifier(stripped[start..]);
            }
            const attr_prefixes = [_][]const u8{ "attr_accessor :", "attr_reader :", "attr_writer :" };
            for (attr_prefixes) |prefix| {
                if (std.mem.startsWith(u8, stripped, prefix)) return extractIdentifier(stripped[prefix.len..]);
            }
        },
        else => {},
    }

    // Colon-typed field: `name: Type`
    switch (lang) {
        .zig, .rust, .typescript, .javascript, .python, .fsharp => {
            if (extractColonField(stripped)) |name| return name;
        },
        else => {},
    }

    // Typed name declaration: `Type name;` (C-family)
    switch (lang) {
        .java, .csharp, .c, .cpp => {
            if (extractTypedNameDecl(stripped)) |name| return name;
        },
        else => {},
    }

    return null;
}

fn extractColonField(line: []const u8) ?[]const u8 {
    var end: usize = 0;
    while (end < line.len and isIdentChar(line[end])) : (end += 1) {}
    if (end == 0 or end + 1 >= line.len) return null;
    if (line[end] != ':' or line[end + 1] != ' ') return null;
    const name = line[0..end];
    const exclude = [_][]const u8{
        "if", "else", "elif", "for", "while", "switch", "return",
        "break", "continue", "case", "default", "except", "finally",
        "try", "with", "match",
    };
    for (exclude) |kw| {
        if (std.mem.eql(u8, name, kw)) return null;
    }
    return name;
}

fn extractTypedNameDecl(line: []const u8) ?[]const u8 {
    if (line.len == 0 or line[0] == '#' or line[0] == '/') return null;
    if (std.mem.indexOf(u8, line, "(") != null) return null;
    if (std.mem.indexOf(u8, line, "{") != null) return null;

    var boundary = line.len;
    if (std.mem.indexOfScalar(u8, line, ';')) |pos| boundary = pos;
    if (std.mem.indexOfScalar(u8, line, '=')) |pos| {
        if (pos < boundary) boundary = pos;
    }

    const decl = std.mem.trimRight(u8, line[0..boundary], " ");
    if (decl.len == 0) return null;

    // Name is the last identifier
    var end = decl.len;
    while (end > 0 and !isIdentChar(decl[end - 1])) : (end -= 1) {}
    var start = end;
    while (start > 0 and isIdentChar(decl[start - 1])) : (start -= 1) {}
    if (start == end or start == 0) return null;

    const name = decl[start..end];
    const kw = [_][]const u8{
        "if", "else", "for", "while", "switch", "return", "break",
        "continue", "case", "default", "throw", "new", "delete",
        "sizeof", "typeof", "goto", "class", "struct", "enum",
        "interface", "extends", "implements", "import", "using",
        "namespace", "package",
    };
    for (kw) |k| {
        if (std.mem.eql(u8, name, k)) return null;
    }
    return name;
}

fn extractEnumVariant(line: []const u8) ?[]const u8 {
    const stripped = std.mem.trimRight(u8, line, ", ;");
    if (stripped.len == 0) return null;

    const eq_pos = std.mem.indexOf(u8, stripped, " =") orelse
        std.mem.indexOf(u8, stripped, "(") orelse
        stripped.len;
    const name_part = std.mem.trimRight(u8, stripped[0..eq_pos], " ");
    if (name_part.len == 0) return null;

    for (name_part) |c| {
        if (!isIdentChar(c)) return null;
    }

    const exclude = [_][]const u8{
        "if", "else", "for", "while", "switch", "return", "break",
        "continue", "pub", "const", "var", "fn",
    };
    for (exclude) |kw| {
        if (std.mem.eql(u8, name_part, kw)) return null;
    }
    return name_part;
}

// -- tests --

test "detect language from extension" {
    try std.testing.expectEqual(Language.zig, Language.fromExtension("src/main.zig"));
    try std.testing.expectEqual(Language.typescript, Language.fromExtension("app/index.ts"));
    try std.testing.expectEqual(Language.python, Language.fromExtension("script.py"));
    try std.testing.expectEqual(Language.unknown, Language.fromExtension("readme.md"));
}

test "parse zig function" {
    const alloc = std.testing.allocator;
    const source = "pub fn handleRequest(req: Request) !Response {\n    return .{};\n}\n";
    const units = try parseSource(alloc, source, "server.zig", .zig);
    defer {
        for (units) |u| {
            alloc.free(u.name);
            alloc.free(u.signature);
            alloc.free(u.file_path);
            alloc.free(u.module_name);
        }
        alloc.free(units);
    }
    try std.testing.expectEqual(@as(usize, 1), units.len);
    try std.testing.expectEqualStrings("handleRequest", units[0].name);
}

test "parse python functions" {
    const alloc = std.testing.allocator;
    const source = "def handle_auth(request):\n    pass\n\nasync def fetch_data(url):\n    pass\n";
    const units = try parseSource(alloc, source, "app.py", .python);
    defer {
        for (units) |u| {
            alloc.free(u.name);
            alloc.free(u.signature);
            alloc.free(u.file_path);
            alloc.free(u.module_name);
        }
        alloc.free(units);
    }
    try std.testing.expectEqual(@as(usize, 2), units.len);
    try std.testing.expectEqualStrings("handle_auth", units[0].name);
    try std.testing.expectEqualStrings("fetch_data", units[1].name);
}

test "split identifier" {
    const alloc = std.testing.allocator;
    const parts = try splitIdentifier(alloc, "handleAuthError");
    defer alloc.free(parts);
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("handle", parts[0]);
    try std.testing.expectEqualStrings("Auth", parts[1]);
    try std.testing.expectEqualStrings("Error", parts[2]);
}

test "parseAst zig with nesting" {
    const alloc = std.testing.allocator;
    const source =
        \\const std = @import("std");
        \\
        \\pub const Language = enum {
        \\    zig,
        \\    python,
        \\    unknown,
        \\};
        \\
        \\pub const Brain = struct {
        \\    entries: std.ArrayList(BrainEntry) = .empty,
        \\    allocator: Allocator,
        \\
        \\    pub fn init(allocator: Allocator) Brain {
        \\        const x = 5;
        \\        return .{ .allocator = allocator };
        \\    }
        \\
        \\    pub fn deinit(self: *Brain) void {
        \\        self.entries.deinit(self.allocator);
        \\    }
        \\};
    ;
    const nodes = try parseAst(alloc, source, .zig);
    defer {
        for (nodes) |n| {
            alloc.free(n.name);
            alloc.free(n.signature);
        }
        alloc.free(nodes);
    }

    // import(std), type(Language), field(zig), field(python), field(unknown),
    // type(Brain), field(entries), field(allocator), fn(init), var(x), fn(deinit)
    try std.testing.expectEqual(@as(usize, 11), nodes.len);

    // import std at depth 0
    try std.testing.expectEqual(AstNodeKind.import_decl, nodes[0].kind);
    try std.testing.expectEqualStrings("std", nodes[0].name);
    try std.testing.expectEqual(@as(u16, 0), nodes[0].depth);

    // type Language at depth 0, enum variants at depth 1
    try std.testing.expectEqual(AstNodeKind.type_def, nodes[1].kind);
    try std.testing.expectEqualStrings("Language", nodes[1].name);
    try std.testing.expectEqual(@as(u16, 0), nodes[1].depth);
    try std.testing.expectEqual(AstNodeKind.field, nodes[2].kind);
    try std.testing.expectEqualStrings("zig", nodes[2].name);
    try std.testing.expectEqual(@as(u16, 1), nodes[2].depth);

    // type Brain at depth 0
    try std.testing.expectEqual(AstNodeKind.type_def, nodes[5].kind);
    try std.testing.expectEqualStrings("Brain", nodes[5].name);
    try std.testing.expectEqual(@as(u16, 0), nodes[5].depth);

    // fields at depth 1
    try std.testing.expectEqual(AstNodeKind.field, nodes[6].kind);
    try std.testing.expectEqualStrings("entries", nodes[6].name);
    try std.testing.expectEqual(@as(u16, 1), nodes[6].depth);

    // fn init at depth 1
    try std.testing.expectEqual(AstNodeKind.function, nodes[8].kind);
    try std.testing.expectEqualStrings("init", nodes[8].name);
    try std.testing.expectEqual(@as(u16, 1), nodes[8].depth);

    // var x at depth 2 inside fn body
    try std.testing.expectEqual(AstNodeKind.variable, nodes[9].kind);
    try std.testing.expectEqualStrings("x", nodes[9].name);
    try std.testing.expectEqual(@as(u16, 2), nodes[9].depth);
}

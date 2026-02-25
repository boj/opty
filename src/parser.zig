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
    const stripped = stripPrefixes(line);
    if (!std.mem.startsWith(u8, stripped, "const ")) return null;
    const rest = stripped[6..]; // skip "const "
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

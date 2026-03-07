const std = @import("std");
const Allocator = std.mem.Allocator;
const parser = @import("parser.zig");

const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

extern fn tree_sitter_zig() *const c.TSLanguage;
extern fn tree_sitter_python() *const c.TSLanguage;

pub const TreeSitterParser = struct {
    alloc: Allocator,
    ts_parser: *c.TSParser,

    pub fn init(alloc: Allocator) TreeSitterParser {
        return .{
            .alloc = alloc,
            .ts_parser = c.ts_parser_new().?,
        };
    }

    pub fn deinit(self: *TreeSitterParser) void {
        c.ts_parser_delete(self.ts_parser);
    }

    pub fn hasGrammar(lang: parser.Language) bool {
        return lang == .zig or lang == .python;
    }

    pub fn parseSource(
        self: *TreeSitterParser,
        source: []const u8,
        file_path: []const u8,
        lang: parser.Language,
    ) ![]parser.CodeUnit {
        if (!hasGrammar(lang)) {
            return parser.parseSource(self.alloc, source, file_path, lang);
        }

        const ts_lang: *const c.TSLanguage = switch (lang) {
            .zig => tree_sitter_zig(),
            .python => tree_sitter_python(),
            else => unreachable,
        };

        _ = c.ts_parser_set_language(self.ts_parser, ts_lang);

        const tree = c.ts_parser_parse_string(
            self.ts_parser,
            null,
            source.ptr,
            @intCast(source.len),
        ) orelse return error.ParseFailed;
        defer c.ts_tree_delete(tree);

        const root = c.ts_tree_root_node(tree);
        const mod_name = moduleName(file_path);

        var units: std.ArrayList(parser.CodeUnit) = .empty;
        errdefer {
            for (units.items) |u| {
                self.alloc.free(u.name);
                self.alloc.free(u.signature);
                self.alloc.free(u.file_path);
                self.alloc.free(u.module_name);
            }
            units.deinit(self.alloc);
        }

        try walkNode(self.alloc, &units, root, source, file_path, mod_name, lang);
        return units.toOwnedSlice(self.alloc);
    }
};

const WalkError = Allocator.Error;

fn walkNode(
    alloc: Allocator,
    units: *std.ArrayList(parser.CodeUnit),
    node: c.TSNode,
    source: []const u8,
    file_path: []const u8,
    mod_name: []const u8,
    lang: parser.Language,
) WalkError!void {
    const node_type = nodeType(node) orelse return;
    const line_number: u32 = c.ts_node_start_point(node).row + 1;

    switch (lang) {
        .zig => {
            if (std.mem.eql(u8, node_type, "function_declaration")) {
                const name = childFieldText(node, "name", source) orelse nodeFirstNamedChildText(node, "identifier", source);
                if (name) |n| {
                    const sig = nodeLineText(source, node);
                    try appendUnit(alloc, units, .function, n, sig, file_path, mod_name, line_number);
                }
                return; // don't recurse into function bodies
            }
            if (std.mem.eql(u8, node_type, "variable_declaration")) {
                if (try handleZigVarDecl(alloc, units, node, source, file_path, mod_name, line_number))
                    return; // was a type def with container body — already walked
            }
            if (std.mem.eql(u8, node_type, "builtin_function")) {
                try handleZigImport(alloc, units, node, source, file_path, mod_name, line_number);
            }
        },
        .python => {
            if (std.mem.eql(u8, node_type, "function_definition")) {
                const name = childFieldText(node, "name", source);
                if (name) |n| {
                    const sig = nodeLineText(source, node);
                    try appendUnit(alloc, units, .function, n, sig, file_path, mod_name, line_number);
                }
                return;
            }
            if (std.mem.eql(u8, node_type, "class_definition")) {
                const name = childFieldText(node, "name", source);
                if (name) |n| {
                    const sig = nodeLineText(source, node);
                    try appendUnit(alloc, units, .type_def, n, sig, file_path, mod_name, line_number);
                }
                return;
            }
            if (std.mem.eql(u8, node_type, "import_statement") or
                std.mem.eql(u8, node_type, "import_from_statement"))
            {
                const sig = nodeLineText(source, node);
                const name = extractImportName(sig);
                if (name) |n| {
                    try appendUnit(alloc, units, .import_decl, n, sig, file_path, mod_name, line_number);
                }
                return;
            }
            if (std.mem.eql(u8, node_type, "decorated_definition")) {
                // Recurse into the actual definition child
                const child_count = c.ts_node_named_child_count(node);
                var i: u32 = 0;
                while (i < child_count) : (i += 1) {
                    const child = c.ts_node_named_child(node, i);
                    const ct = nodeType(child) orelse continue;
                    if (std.mem.eql(u8, ct, "function_definition") or
                        std.mem.eql(u8, ct, "class_definition"))
                    {
                        try walkNode(alloc, units, child, source, file_path, mod_name, lang);
                    }
                }
                return;
            }
        },
        else => {},
    }

    // Recurse into children
    const child_count = c.ts_node_named_child_count(node);
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        try walkNode(alloc, units, c.ts_node_named_child(node, i), source, file_path, mod_name, lang);
    }
}

/// Handle Zig variable declarations. If it's a type def (const X = struct/enum/union),
/// extract it as a type_def and recurse into the container body. Returns true if handled.
fn handleZigVarDecl(
    alloc: Allocator,
    units: *std.ArrayList(parser.CodeUnit),
    node: c.TSNode,
    source: []const u8,
    file_path: []const u8,
    mod_name: []const u8,
    line_number: u32,
) WalkError!bool {
    // variable_declaration's children include an identifier and an expression.
    // For `const Foo = struct { ... }`, the identifier is the name and the
    // expression is the struct_declaration.
    const name = nodeFirstNamedChildText(node, "identifier", source) orelse return false;

    // Check if the value is a container type
    const child_count = c.ts_node_named_child_count(node);
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = c.ts_node_named_child(node, i);
        const ct = nodeType(child) orelse continue;
        if (std.mem.eql(u8, ct, "struct_declaration") or
            std.mem.eql(u8, ct, "enum_declaration") or
            std.mem.eql(u8, ct, "union_declaration") or
            std.mem.eql(u8, ct, "opaque_declaration"))
        {
            const sig = nodeLineText(source, node);
            try appendUnit(alloc, units, .type_def, name, sig, file_path, mod_name, line_number);
            // Recurse into the container body to find nested functions
            const container_children = c.ts_node_named_child_count(child);
            var j: u32 = 0;
            while (j < container_children) : (j += 1) {
                try walkNode(alloc, units, c.ts_node_named_child(child, j), source, file_path, mod_name, .zig);
            }
            return true;
        }
    }

    // It's a regular variable — extract as import if it contains @import
    const sig = nodeLineText(source, node);
    if (std.mem.indexOf(u8, sig, "@import(") != null) {
        const imp_name = extractZigImportModule(sig);
        if (imp_name) |iname| {
            try appendUnit(alloc, units, .import_decl, iname, sig, file_path, mod_name, line_number);
            return true;
        }
    }

    return false;
}

fn handleZigImport(
    alloc: Allocator,
    units: *std.ArrayList(parser.CodeUnit),
    node: c.TSNode,
    source: []const u8,
    file_path: []const u8,
    mod_name: []const u8,
    line_number: u32,
) WalkError!void {
    // For standalone @import() calls not part of a variable_declaration
    const start = c.ts_node_start_byte(node);
    const end = c.ts_node_end_byte(node);
    if (start >= source.len or end > source.len) return;
    const text = source[start..end];
    if (!std.mem.startsWith(u8, text, "@import(")) return;
    const imp_name = extractZigImportModule(text) orelse return;
    try appendUnit(alloc, units, .import_decl, imp_name, text, file_path, mod_name, line_number);
}

// --- Helpers ---

fn nodeType(node: c.TSNode) ?[]const u8 {
    const ptr = c.ts_node_type(node);
    if (ptr == null) return null;
    return std.mem.span(ptr);
}

fn childFieldText(node: c.TSNode, field_name: []const u8, source: []const u8) ?[]const u8 {
    const child = c.ts_node_child_by_field_name(node, field_name.ptr, @intCast(field_name.len));
    if (c.ts_node_is_null(child)) return null;
    const start = c.ts_node_start_byte(child);
    const end = c.ts_node_end_byte(child);
    if (start >= source.len or end > source.len) return null;
    return source[start..end];
}

fn nodeFirstNamedChildText(node: c.TSNode, expected_type: []const u8, source: []const u8) ?[]const u8 {
    const count = c.ts_node_named_child_count(node);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const child = c.ts_node_named_child(node, i);
        const ct = nodeType(child) orelse continue;
        if (std.mem.eql(u8, ct, expected_type)) {
            const start = c.ts_node_start_byte(child);
            const end = c.ts_node_end_byte(child);
            if (start < source.len and end <= source.len) return source[start..end];
        }
    }
    return null;
}

/// Get the first line of text at the node's start position (trimmed).
fn nodeLineText(source: []const u8, node: c.TSNode) []const u8 {
    const start = c.ts_node_start_byte(node);
    if (start >= source.len) return "";
    const rest = source[start..];
    const newline = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    return std.mem.trim(u8, rest[0..newline], " \t\r");
}

fn extractImportName(sig: []const u8) ?[]const u8 {
    // "from foo import bar" → "foo"
    // "import os" → "os"
    if (std.mem.startsWith(u8, sig, "from ")) {
        const rest = sig[5..];
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        if (space > 0) return rest[0..space];
    }
    if (std.mem.startsWith(u8, sig, "import ")) {
        const rest = sig[7..];
        const delim = std.mem.indexOfAny(u8, rest, " ,;") orelse rest.len;
        if (delim > 0) return rest[0..delim];
    }
    return null;
}

fn extractZigImportModule(text: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, text, "@import(") orelse return null;
    const after = text[pos + 8 ..];
    const q1 = std.mem.indexOf(u8, after, "\"") orelse return null;
    const start = q1 + 1;
    const q2 = std.mem.indexOf(u8, after[start..], "\"") orelse return null;
    return after[start .. start + q2];
}

fn moduleName(file_path: []const u8) []const u8 {
    const base = std.fs.path.basename(file_path);
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
        return base[0..dot];
    }
    return base;
}

fn appendUnit(
    alloc: Allocator,
    units: *std.ArrayList(parser.CodeUnit),
    kind: parser.CodeUnitKind,
    name: []const u8,
    signature: []const u8,
    file_path: []const u8,
    mod_name: []const u8,
    line_number: u32,
) !void {
    try units.append(alloc, .{
        .kind = kind,
        .name = try alloc.dupe(u8, name),
        .signature = try alloc.dupe(u8, signature),
        .file_path = try alloc.dupe(u8, file_path),
        .module_name = try alloc.dupe(u8, mod_name),
        .line_number = line_number,
    });
}

// -- Tests --

fn freeCodeUnits(alloc: Allocator, units: []parser.CodeUnit) void {
    for (units) |u| {
        alloc.free(u.name);
        alloc.free(u.signature);
        alloc.free(u.file_path);
        alloc.free(u.module_name);
    }
    alloc.free(units);
}

test "hasGrammar" {
    try std.testing.expect(TreeSitterParser.hasGrammar(.zig));
    try std.testing.expect(TreeSitterParser.hasGrammar(.python));
    try std.testing.expect(!TreeSitterParser.hasGrammar(.go));
    try std.testing.expect(!TreeSitterParser.hasGrammar(.rust));
    try std.testing.expect(!TreeSitterParser.hasGrammar(.unknown));
}

test "parse zig function" {
    const alloc = std.testing.allocator;
    var ts = TreeSitterParser.init(alloc);
    defer ts.deinit();

    const source =
        \\pub fn handleRequest(req: Request) !Response {
        \\    return .{};
        \\}
    ;
    const units = try ts.parseSource(source, "server.zig", .zig);
    defer freeCodeUnits(alloc, units);

    try std.testing.expectEqual(@as(usize, 1), units.len);
    try std.testing.expectEqualStrings("handleRequest", units[0].name);
    try std.testing.expectEqual(parser.CodeUnitKind.function, units[0].kind);
    try std.testing.expectEqual(@as(u32, 1), units[0].line_number);
}

test "parse zig type and nested function" {
    const alloc = std.testing.allocator;
    var ts = TreeSitterParser.init(alloc);
    defer ts.deinit();

    const source =
        \\const std = @import("std");
        \\
        \\pub const Brain = struct {
        \\    entries: u32,
        \\
        \\    pub fn init(allocator: Allocator) Brain {
        \\        return .{};
        \\    }
        \\};
    ;
    const units = try ts.parseSource(source, "brain.zig", .zig);
    defer freeCodeUnits(alloc, units);

    // Should find: import(std), type(Brain), fn(init)
    try std.testing.expectEqual(@as(usize, 3), units.len);

    try std.testing.expectEqual(parser.CodeUnitKind.import_decl, units[0].kind);
    try std.testing.expectEqualStrings("std", units[0].name);
    try std.testing.expectEqual(@as(u32, 1), units[0].line_number);

    try std.testing.expectEqual(parser.CodeUnitKind.type_def, units[1].kind);
    try std.testing.expectEqualStrings("Brain", units[1].name);
    try std.testing.expectEqual(@as(u32, 3), units[1].line_number);

    try std.testing.expectEqual(parser.CodeUnitKind.function, units[2].kind);
    try std.testing.expectEqualStrings("init", units[2].name);
    try std.testing.expectEqual(@as(u32, 6), units[2].line_number);
}

test "parse zig enum" {
    const alloc = std.testing.allocator;
    var ts = TreeSitterParser.init(alloc);
    defer ts.deinit();

    const source =
        \\pub const Language = enum {
        \\    zig,
        \\    python,
        \\    unknown,
        \\};
    ;
    const units = try ts.parseSource(source, "parser.zig", .zig);
    defer freeCodeUnits(alloc, units);

    try std.testing.expectEqual(@as(usize, 1), units.len);
    try std.testing.expectEqual(parser.CodeUnitKind.type_def, units[0].kind);
    try std.testing.expectEqualStrings("Language", units[0].name);
}

test "parse python functions" {
    const alloc = std.testing.allocator;
    var ts = TreeSitterParser.init(alloc);
    defer ts.deinit();

    const source =
        \\def handle_auth(request):
        \\    pass
        \\
        \\async def fetch_data(url):
        \\    pass
    ;
    const units = try ts.parseSource(source, "app.py", .python);
    defer freeCodeUnits(alloc, units);

    try std.testing.expectEqual(@as(usize, 2), units.len);
    try std.testing.expectEqualStrings("handle_auth", units[0].name);
    try std.testing.expectEqual(parser.CodeUnitKind.function, units[0].kind);
    try std.testing.expectEqualStrings("fetch_data", units[1].name);
    try std.testing.expectEqual(parser.CodeUnitKind.function, units[1].kind);
}

test "parse python class and imports" {
    const alloc = std.testing.allocator;
    var ts = TreeSitterParser.init(alloc);
    defer ts.deinit();

    const source =
        \\import os
        \\from pathlib import Path
        \\
        \\class MyServer:
        \\    def __init__(self):
        \\        pass
        \\
        \\    def serve(self, port):
        \\        pass
    ;
    const units = try ts.parseSource(source, "server.py", .python);
    defer freeCodeUnits(alloc, units);

    // imports: os, pathlib; type: MyServer
    try std.testing.expectEqual(@as(usize, 3), units.len);

    try std.testing.expectEqual(parser.CodeUnitKind.import_decl, units[0].kind);
    try std.testing.expectEqualStrings("os", units[0].name);

    try std.testing.expectEqual(parser.CodeUnitKind.import_decl, units[1].kind);
    try std.testing.expectEqualStrings("pathlib", units[1].name);

    try std.testing.expectEqual(parser.CodeUnitKind.type_def, units[2].kind);
    try std.testing.expectEqualStrings("MyServer", units[2].name);
}

test "parse python multiline function signature" {
    const alloc = std.testing.allocator;
    var ts = TreeSitterParser.init(alloc);
    defer ts.deinit();

    const source =
        \\def complex_function(
        \\    arg1: str,
        \\    arg2: int,
        \\    arg3: float,
        \\) -> bool:
        \\    return True
    ;
    const units = try ts.parseSource(source, "utils.py", .python);
    defer freeCodeUnits(alloc, units);

    try std.testing.expectEqual(@as(usize, 1), units.len);
    try std.testing.expectEqualStrings("complex_function", units[0].name);
    try std.testing.expectEqual(parser.CodeUnitKind.function, units[0].kind);
    try std.testing.expectEqual(@as(u32, 1), units[0].line_number);
}

test "fallback for unsupported language" {
    const alloc = std.testing.allocator;
    var ts = TreeSitterParser.init(alloc);
    defer ts.deinit();

    const source = "func main() {\n}\n";
    const units = try ts.parseSource(source, "main.go", .go);
    defer freeCodeUnits(alloc, units);

    // Should fall back to pattern-based parser
    try std.testing.expectEqual(@as(usize, 1), units.len);
    try std.testing.expectEqualStrings("main", units[0].name);
}

test "correct module names" {
    const alloc = std.testing.allocator;
    var ts = TreeSitterParser.init(alloc);
    defer ts.deinit();

    const source = "pub fn hello() void {}\n";
    const units = try ts.parseSource(source, "src/greeter.zig", .zig);
    defer freeCodeUnits(alloc, units);

    try std.testing.expectEqual(@as(usize, 1), units.len);
    try std.testing.expectEqualStrings("greeter", units[0].module_name);
    try std.testing.expectEqualStrings("src/greeter.zig", units[0].file_path);
}

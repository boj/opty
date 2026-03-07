const std = @import("std");
const parser = @import("parser.zig");
const brain_mod = @import("brain.zig");
const refs_mod = @import("refs.zig");
const Allocator = std.mem.Allocator;

const BrainEntry = brain_mod.BrainEntry;
const CodeUnitKind = parser.CodeUnitKind;
const RefMap = refs_mod.RefMap;

pub const DefInfo = struct {
    name: []const u8,
    kind: CodeUnitKind,
    signature: []const u8,
    file_path: []const u8,
    line_number: u32,
    module_name: []const u8,
};

pub const RefInfo = struct {
    name: []const u8,
    kind: CodeUnitKind,
    file_path: []const u8,
    line_number: u32,
};

pub const SiblingInfo = struct {
    name: []const u8,
    kind: CodeUnitKind,
    line_number: u32,
};

pub const SymbolContext = struct {
    definition: ?DefInfo,
    referenced_by: []RefInfo,
    references: []RefInfo,
    siblings: []SiblingInfo,

    pub fn deinit(self: *SymbolContext, alloc: Allocator) void {
        alloc.free(self.referenced_by);
        alloc.free(self.references);
        alloc.free(self.siblings);
    }
};

/// Get full context for a symbol.
pub fn getContext(
    alloc: Allocator,
    ref_map: *const RefMap,
    entries: []const BrainEntry,
    symbol_name: []const u8,
) !SymbolContext {
    // 1. Find the symbol's definition in entries (exact name match).
    var definition: ?DefInfo = null;
    var def_file_path: ?[]const u8 = null;

    for (entries) |entry| {
        if (std.mem.eql(u8, entry.unit.name, symbol_name) and
            (entry.unit.kind == .function or entry.unit.kind == .type_def))
        {
            definition = .{
                .name = entry.unit.name,
                .kind = entry.unit.kind,
                .signature = entry.unit.signature,
                .file_path = entry.unit.file_path,
                .line_number = entry.unit.line_number,
                .module_name = entry.unit.module_name,
            };
            def_file_path = entry.unit.file_path;
            break;
        }
    }

    // 2. Find who references this symbol (from ref_map).
    var referenced_by: std.ArrayList(RefInfo) = .empty;
    defer referenced_by.deinit(alloc);

    if (ref_map.findReferences(symbol_name)) |ref_locs| {
        for (ref_locs) |ref_loc| {
            try referenced_by.append(alloc, .{
                .name = ref_loc.import_name,
                .kind = .import_decl,
                .file_path = ref_loc.file_path,
                .line_number = ref_loc.line_number,
            });
        }
    }

    // 3. Find what this symbol's file imports (dependencies).
    var references_list: std.ArrayList(RefInfo) = .empty;
    defer references_list.deinit(alloc);

    if (def_file_path) |fp| {
        for (entries) |entry| {
            if (entry.unit.kind == .import_decl and std.mem.eql(u8, entry.unit.file_path, fp)) {
                // Try to find where the imported symbol is defined.
                var ref_file: []const u8 = entry.unit.file_path;
                var ref_line: u32 = entry.unit.line_number;
                var ref_kind: CodeUnitKind = .import_decl;

                if (ref_map.findDefinition(entry.unit.name)) |defs| {
                    if (defs.len > 0) {
                        ref_file = defs[0].file_path;
                        ref_line = defs[0].line_number;
                        ref_kind = defs[0].kind;
                    }
                }

                try references_list.append(alloc, .{
                    .name = entry.unit.name,
                    .kind = ref_kind,
                    .file_path = ref_file,
                    .line_number = ref_line,
                });
            }
        }
    }

    // 4. Find other code units in the same file (siblings).
    var siblings_list: std.ArrayList(SiblingInfo) = .empty;
    defer siblings_list.deinit(alloc);

    if (def_file_path) |fp| {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.unit.file_path, fp) and
                !std.mem.eql(u8, entry.unit.name, symbol_name))
            {
                try siblings_list.append(alloc, .{
                    .name = entry.unit.name,
                    .kind = entry.unit.kind,
                    .line_number = entry.unit.line_number,
                });
            }
        }
    }

    return .{
        .definition = definition,
        .referenced_by = try referenced_by.toOwnedSlice(alloc),
        .references = try references_list.toOwnedSlice(alloc),
        .siblings = try siblings_list.toOwnedSlice(alloc),
    };
}

/// Format context as TOON.
pub fn formatContext(alloc: Allocator, ctx: SymbolContext) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    if (ctx.definition) |def| {
        const kind_str = kindLabel(def.kind);
        try buf.print(alloc, "symbol{{name:\"{s}\",kind:{s},file:\"{s}\",line:{d}}}\n", .{
            def.name,
            kind_str,
            def.file_path,
            def.line_number,
        });
        try buf.print(alloc, "signature: {s}\n", .{def.signature});
    } else {
        try buf.print(alloc, "symbol{{not_found}}\n", .{});
    }

    try buf.print(alloc, "referenced_by[{d}]{{name,kind,file,line}}:\n", .{ctx.referenced_by.len});
    for (ctx.referenced_by) |ref| {
        try buf.print(alloc, "{s},{s},{s},{d}\n", .{
            ref.name,
            kindLabel(ref.kind),
            ref.file_path,
            ref.line_number,
        });
    }

    try buf.print(alloc, "references[{d}]{{name,kind,file,line}}:\n", .{ctx.references.len});
    for (ctx.references) |ref| {
        try buf.print(alloc, "{s},{s},{s},{d}\n", .{
            ref.name,
            kindLabel(ref.kind),
            ref.file_path,
            ref.line_number,
        });
    }

    try buf.print(alloc, "siblings[{d}]{{name,kind,line}}:\n", .{ctx.siblings.len});
    for (ctx.siblings) |sib| {
        try buf.print(alloc, "{s},{s},{d}\n", .{
            sib.name,
            kindLabel(sib.kind),
            sib.line_number,
        });
    }

    return buf.toOwnedSlice(alloc);
}

fn kindLabel(kind: CodeUnitKind) []const u8 {
    return switch (kind) {
        .function => "fn",
        .type_def => "type",
        .import_decl => "import",
    };
}

// -- tests --

fn makeEntry(kind: CodeUnitKind, name: []const u8, sig: []const u8, file_path: []const u8, line: u32, module: []const u8) BrainEntry {
    return .{
        .unit = .{
            .kind = kind,
            .name = name,
            .signature = sig,
            .file_path = file_path,
            .line_number = line,
            .module_name = module,
        },
        .vector = .{},
    };
}

test "context with callers and callees" {
    const alloc = std.testing.allocator;

    const entries = [_]BrainEntry{
        makeEntry(.function, "handleAuth", "pub fn handleAuth(req: Request) !Response {", "src/auth.zig", 10, "auth"),
        makeEntry(.import_decl, "validateToken", "const validateToken = @import(\"token.zig\");", "src/auth.zig", 1, "auth"),
        makeEntry(.function, "validateToken", "pub fn validateToken(tok: []const u8) !bool {", "src/token.zig", 5, "token"),
        makeEntry(.import_decl, "handleAuth", "const handleAuth = @import(\"auth.zig\");", "src/main.zig", 2, "main"),
        makeEntry(.function, "loginUser", "pub fn loginUser(user: User) !void {", "src/login.zig", 15, "login"),
        makeEntry(.import_decl, "handleAuth", "const handleAuth = @import(\"auth.zig\");", "src/login.zig", 1, "login"),
    };

    var ref_map = try RefMap.build(alloc, &entries);
    defer ref_map.deinit();

    var ctx = try getContext(alloc, &ref_map, &entries, "handleAuth");
    defer ctx.deinit(alloc);

    // Definition should be found.
    try std.testing.expect(ctx.definition != null);
    try std.testing.expectEqualStrings("handleAuth", ctx.definition.?.name);
    try std.testing.expectEqual(CodeUnitKind.function, ctx.definition.?.kind);
    try std.testing.expectEqualStrings("src/auth.zig", ctx.definition.?.file_path);

    // Referenced by main.zig and login.zig.
    try std.testing.expectEqual(@as(usize, 2), ctx.referenced_by.len);

    // References (imports in auth.zig): validateToken.
    try std.testing.expectEqual(@as(usize, 1), ctx.references.len);
    try std.testing.expectEqualStrings("validateToken", ctx.references[0].name);

    // Siblings in same file (auth.zig): the import of validateToken.
    try std.testing.expectEqual(@as(usize, 1), ctx.siblings.len);
    try std.testing.expectEqualStrings("validateToken", ctx.siblings[0].name);
}

test "symbol with no references" {
    const alloc = std.testing.allocator;

    const entries = [_]BrainEntry{
        makeEntry(.function, "helperFn", "fn helperFn() void {", "src/utils.zig", 5, "utils"),
    };

    var ref_map = try RefMap.build(alloc, &entries);
    defer ref_map.deinit();

    var ctx = try getContext(alloc, &ref_map, &entries, "helperFn");
    defer ctx.deinit(alloc);

    try std.testing.expect(ctx.definition != null);
    try std.testing.expectEqual(@as(usize, 0), ctx.referenced_by.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.references.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.siblings.len);
}

test "siblings lists other symbols in same file" {
    const alloc = std.testing.allocator;

    const entries = [_]BrainEntry{
        makeEntry(.function, "handleAuth", "pub fn handleAuth() void {", "src/auth.zig", 10, "auth"),
        makeEntry(.function, "refreshSession", "pub fn refreshSession() void {", "src/auth.zig", 56, "auth"),
        makeEntry(.type_def, "AuthError", "pub const AuthError = enum {", "src/auth.zig", 12, "auth"),
        makeEntry(.import_decl, "tokenStore", "const tokenStore = @import(\"store.zig\");", "src/auth.zig", 1, "auth"),
    };

    var ref_map = try RefMap.build(alloc, &entries);
    defer ref_map.deinit();

    var ctx = try getContext(alloc, &ref_map, &entries, "handleAuth");
    defer ctx.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), ctx.siblings.len);

    var found_refresh = false;
    var found_error = false;
    var found_store = false;
    for (ctx.siblings) |sib| {
        if (std.mem.eql(u8, sib.name, "refreshSession")) found_refresh = true;
        if (std.mem.eql(u8, sib.name, "AuthError")) found_error = true;
        if (std.mem.eql(u8, sib.name, "tokenStore")) found_store = true;
    }
    try std.testing.expect(found_refresh);
    try std.testing.expect(found_error);
    try std.testing.expect(found_store);
}

test "unknown symbol returns null definition" {
    const alloc = std.testing.allocator;

    const entries = [_]BrainEntry{
        makeEntry(.function, "handleAuth", "pub fn handleAuth() void {", "src/auth.zig", 10, "auth"),
    };

    var ref_map = try RefMap.build(alloc, &entries);
    defer ref_map.deinit();

    var ctx = try getContext(alloc, &ref_map, &entries, "nonExistentSymbol");
    defer ctx.deinit(alloc);

    try std.testing.expect(ctx.definition == null);
    try std.testing.expectEqual(@as(usize, 0), ctx.referenced_by.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.references.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.siblings.len);
}

test "formatContext produces valid TOON" {
    const alloc = std.testing.allocator;

    const entries = [_]BrainEntry{
        makeEntry(.function, "handleAuth", "pub fn handleAuth(req: Request) !Response {", "src/auth.zig", 42, "auth"),
        makeEntry(.import_decl, "validateToken", "const validateToken = @import(\"token.zig\");", "src/auth.zig", 1, "auth"),
        makeEntry(.function, "validateToken", "pub fn validateToken(tok: []const u8) !bool {", "src/token.zig", 8, "token"),
        makeEntry(.import_decl, "handleAuth", "const handleAuth = @import(\"auth.zig\");", "src/login.zig", 15, "login"),
        makeEntry(.function, "refreshSession", "pub fn refreshSession() void {", "src/auth.zig", 56, "auth"),
        makeEntry(.type_def, "AuthError", "pub const AuthError = enum {", "src/auth.zig", 12, "auth"),
    };

    var ref_map = try RefMap.build(alloc, &entries);
    defer ref_map.deinit();

    var ctx = try getContext(alloc, &ref_map, &entries, "handleAuth");
    defer ctx.deinit(alloc);

    const toon = try formatContext(alloc, ctx);
    defer alloc.free(toon);

    // Verify key parts of the output.
    try std.testing.expect(std.mem.indexOf(u8, toon, "symbol{name:\"handleAuth\",kind:fn,file:\"src/auth.zig\",line:42}") != null);
    try std.testing.expect(std.mem.indexOf(u8, toon, "signature: pub fn handleAuth(req: Request) !Response {") != null);
    try std.testing.expect(std.mem.indexOf(u8, toon, "referenced_by[1]{name,kind,file,line}:") != null);
    try std.testing.expect(std.mem.indexOf(u8, toon, "references[1]{name,kind,file,line}:") != null);
    try std.testing.expect(std.mem.indexOf(u8, toon, "siblings[") != null);
}

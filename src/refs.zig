const std = @import("std");
const brain = @import("brain.zig");
const parser = @import("parser.zig");

const BrainEntry = brain.BrainEntry;
const CodeUnit = parser.CodeUnit;
const CodeUnitKind = parser.CodeUnitKind;
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const ArrayList = std.ArrayList;

pub const DefLocation = struct {
    name: []const u8,
    file_path: []const u8,
    line_number: u32,
    kind: CodeUnitKind,
};

pub const RefLocation = struct {
    file_path: []const u8,
    line_number: u32,
    import_name: []const u8,
};

pub const RefMap = struct {
    /// Maps definition name -> defining CodeUnit location(s)
    definitions: StringHashMap(ArrayList(DefLocation)),
    /// Maps definition name -> list of files that import/reference it
    references: StringHashMap(ArrayList(RefLocation)),
    allocator: Allocator,

    /// Build a RefMap from a slice of BrainEntry values.
    /// First pass: collect all function and type_def definitions.
    /// Second pass: for each import_decl, resolve it against known definitions.
    pub fn build(allocator: Allocator, entries: []const BrainEntry) !RefMap {
        var definitions = StringHashMap(ArrayList(DefLocation)).init(allocator);
        var references = StringHashMap(ArrayList(RefLocation)).init(allocator);

        // First pass: collect definitions (functions and type_defs)
        for (entries) |entry| {
            const unit = entry.unit;
            if (unit.kind == .function or unit.kind == .type_def) {
                const gop = try definitions.getOrPut(unit.name);
                if (!gop.found_existing) {
                    gop.value_ptr.* = ArrayList(DefLocation).empty;
                }
                try gop.value_ptr.append(allocator, .{
                    .name = unit.name,
                    .file_path = unit.file_path,
                    .line_number = unit.line_number,
                    .kind = unit.kind,
                });
            }
        }

        // Second pass: resolve imports against definitions
        for (entries) |entry| {
            const unit = entry.unit;
            if (unit.kind != .import_decl) continue;

            const resolved_name = resolveImportName(unit.name, &definitions);
            if (resolved_name) |def_name| {
                const gop = try references.getOrPut(def_name);
                if (!gop.found_existing) {
                    gop.value_ptr.* = ArrayList(RefLocation).empty;
                }
                try gop.value_ptr.append(allocator, .{
                    .file_path = unit.file_path,
                    .line_number = unit.line_number,
                    .import_name = unit.name,
                });
            }
        }

        return .{
            .definitions = definitions,
            .references = references,
            .allocator = allocator,
        };
    }

    /// Find where a symbol is defined.
    pub fn findDefinition(self: *const RefMap, name: []const u8) ?[]const DefLocation {
        const list = self.definitions.get(name) orelse return null;
        if (list.items.len == 0) return null;
        return list.items;
    }

    /// Find all files that reference/import a symbol.
    pub fn findReferences(self: *const RefMap, name: []const u8) ?[]const RefLocation {
        const list = self.references.get(name) orelse return null;
        if (list.items.len == 0) return null;
        return list.items;
    }

    /// Return downstream dependents — files that import the given symbol name.
    /// Alias for findReferences, returns empty slice if none found.
    pub fn dependentsOf(self: *const RefMap, name: []const u8) []const RefLocation {
        return self.findReferences(name) orelse &.{};
    }

    /// Return names of all definitions that the given file imports.
    /// Caller owns the returned slice.
    pub fn dependenciesOf(self: *const RefMap, file_path: []const u8) []const []const u8 {
        // Iterate references map: for each definition name, check if any
        // RefLocation has the given file_path
        var result: ArrayList([]const u8) = .empty;
        var it = self.references.iterator();
        while (it.next()) |kv| {
            const def_name = kv.key_ptr.*;
            const ref_locs = kv.value_ptr.items;
            for (ref_locs) |ref_loc| {
                if (std.mem.eql(u8, ref_loc.file_path, file_path)) {
                    result.append(self.allocator, def_name) catch {};
                    break;
                }
            }
        }
        return result.toOwnedSlice(self.allocator) catch &.{};
    }

    pub fn deinit(self: *RefMap) void {
        // Free definition lists
        var def_it = self.definitions.iterator();
        while (def_it.next()) |kv| {
            kv.value_ptr.deinit(self.allocator);
        }
        self.definitions.deinit();

        // Free reference lists
        var ref_it = self.references.iterator();
        while (ref_it.next()) |kv| {
            kv.value_ptr.deinit(self.allocator);
        }
        self.references.deinit();
    }
};

/// Resolve an import name to a definition name.
/// Tries exact match first, then derives module name from file-like imports
/// (e.g., "foo.zig" -> "foo") and checks if any definition has that name.
fn resolveImportName(import_name: []const u8, definitions: *const StringHashMap(ArrayList(DefLocation))) ?[]const u8 {
    // Direct match: import name matches a definition name exactly
    if (definitions.get(import_name) != null) {
        return import_name;
    }

    // Try deriving a module name from file-like imports:
    // "foo.zig" -> "foo", "foo.py" -> "foo", "./auth" -> "auth", etc.
    const derived = deriveModuleName(import_name);
    if (derived != null) {
        if (definitions.get(derived.?) != null) {
            return derived.?;
        }
    }

    // Try matching the last component of dotted paths:
    // "crate::module::X" -> "X", "from module import X" -> already handled by parser
    if (std.mem.lastIndexOfScalar(u8, import_name, ':')) |pos| {
        if (pos + 1 < import_name.len and import_name[pos + 1] == ':') {
            const last = import_name[pos + 2 ..];
            if (definitions.get(last) != null) {
                return last;
            }
        }
    }

    return null;
}

/// Derive a module name from a file-path-like import string.
fn deriveModuleName(import_name: []const u8) ?[]const u8 {
    // Strip leading "./" or "../"
    var name = import_name;
    while (name.len > 2 and name[0] == '.' and (name[1] == '/' or name[1] == '.')) {
        if (name[1] == '/') {
            name = name[2..];
        } else {
            // "../"
            if (name.len > 2 and name[2] == '/') {
                name = name[3..];
            } else {
                break;
            }
        }
    }

    // Get basename
    const base = std.fs.path.basename(name);
    if (base.len == 0) return null;

    // Strip extension
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
        if (dot > 0) return base[0..dot];
    }

    // No extension — return as-is if it differs from original
    if (!std.mem.eql(u8, base, import_name)) return base;

    return null;
}

// -- tests --

fn makeUnit(kind: CodeUnitKind, name: []const u8, file_path: []const u8, line_number: u32) CodeUnit {
    return .{
        .kind = kind,
        .name = name,
        .signature = "",
        .file_path = file_path,
        .line_number = line_number,
        .module_name = "",
    };
}

fn makeBrainEntry(kind: CodeUnitKind, name: []const u8, file_path: []const u8, line_number: u32) BrainEntry {
    return .{
        .unit = makeUnit(kind, name, file_path, line_number),
        .vector = .{},
    };
}

test "build ref map and find definitions" {
    const alloc = std.testing.allocator;

    const entries = [_]BrainEntry{
        makeBrainEntry(.function, "handleAuth", "src/auth.zig", 10),
        makeBrainEntry(.type_def, "User", "src/models.zig", 5),
        makeBrainEntry(.function, "processPayment", "src/payment.zig", 20),
        makeBrainEntry(.import_decl, "handleAuth", "src/main.zig", 1),
        makeBrainEntry(.import_decl, "User", "src/auth.zig", 2),
    };

    var ref_map = try RefMap.build(alloc, &entries);
    defer ref_map.deinit();

    // Find definitions
    const auth_defs = ref_map.findDefinition("handleAuth").?;
    try std.testing.expectEqual(@as(usize, 1), auth_defs.len);
    try std.testing.expectEqualStrings("src/auth.zig", auth_defs[0].file_path);
    try std.testing.expectEqual(@as(u32, 10), auth_defs[0].line_number);
    try std.testing.expectEqual(CodeUnitKind.function, auth_defs[0].kind);

    const user_defs = ref_map.findDefinition("User").?;
    try std.testing.expectEqual(@as(usize, 1), user_defs.len);
    try std.testing.expectEqualStrings("src/models.zig", user_defs[0].file_path);

    // Unknown definition
    try std.testing.expect(ref_map.findDefinition("nonExistent") == null);
}

test "find references returns all importing files" {
    const alloc = std.testing.allocator;

    const entries = [_]BrainEntry{
        makeBrainEntry(.function, "handleAuth", "src/auth.zig", 10),
        makeBrainEntry(.import_decl, "handleAuth", "src/main.zig", 1),
        makeBrainEntry(.import_decl, "handleAuth", "src/server.zig", 3),
    };

    var ref_map = try RefMap.build(alloc, &entries);
    defer ref_map.deinit();

    const refs = ref_map.findReferences("handleAuth").?;
    try std.testing.expectEqual(@as(usize, 2), refs.len);

    // Both main.zig and server.zig should be in the results
    var found_main = false;
    var found_server = false;
    for (refs) |ref| {
        if (std.mem.eql(u8, ref.file_path, "src/main.zig")) found_main = true;
        if (std.mem.eql(u8, ref.file_path, "src/server.zig")) found_server = true;
    }
    try std.testing.expect(found_main);
    try std.testing.expect(found_server);

    // No references to processPayment
    try std.testing.expect(ref_map.findReferences("processPayment") == null);
}

test "dependentsOf returns downstream dependents" {
    const alloc = std.testing.allocator;

    const entries = [_]BrainEntry{
        makeBrainEntry(.type_def, "Config", "src/config.zig", 1),
        makeBrainEntry(.import_decl, "Config", "src/server.zig", 2),
        makeBrainEntry(.import_decl, "Config", "src/worker.zig", 5),
    };

    var ref_map = try RefMap.build(alloc, &entries);
    defer ref_map.deinit();

    const deps = ref_map.dependentsOf("Config");
    try std.testing.expectEqual(@as(usize, 2), deps.len);

    // No dependents for unknown symbol
    const none = ref_map.dependentsOf("Unknown");
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "dependenciesOf returns what a file imports" {
    const alloc = std.testing.allocator;

    const entries = [_]BrainEntry{
        makeBrainEntry(.function, "handleAuth", "src/auth.zig", 10),
        makeBrainEntry(.type_def, "User", "src/models.zig", 5),
        makeBrainEntry(.function, "log", "src/logger.zig", 1),
        makeBrainEntry(.import_decl, "handleAuth", "src/main.zig", 1),
        makeBrainEntry(.import_decl, "User", "src/main.zig", 2),
        makeBrainEntry(.import_decl, "log", "src/auth.zig", 3),
    };

    var ref_map = try RefMap.build(alloc, &entries);
    defer ref_map.deinit();

    const main_deps = ref_map.dependenciesOf("src/main.zig");
    defer alloc.free(main_deps);
    try std.testing.expectEqual(@as(usize, 2), main_deps.len);

    // Check that handleAuth and User are both listed
    var found_auth = false;
    var found_user = false;
    for (main_deps) |dep| {
        if (std.mem.eql(u8, dep, "handleAuth")) found_auth = true;
        if (std.mem.eql(u8, dep, "User")) found_user = true;
    }
    try std.testing.expect(found_auth);
    try std.testing.expect(found_user);

    // auth.zig imports log
    const auth_deps = ref_map.dependenciesOf("src/auth.zig");
    defer alloc.free(auth_deps);
    try std.testing.expectEqual(@as(usize, 1), auth_deps.len);
    try std.testing.expectEqualStrings("log", auth_deps[0]);

    // File with no imports
    const no_deps = ref_map.dependenciesOf("src/models.zig");
    defer alloc.free(no_deps);
    try std.testing.expectEqual(@as(usize, 0), no_deps.len);
}

test "resolve file-based imports (e.g. zig @import)" {
    const alloc = std.testing.allocator;

    // Zig-style: @import("auth.zig") extracts name "auth.zig"
    // Definition is in auth.zig with a type named "auth" (unlikely) or
    // we need to match by module name derivation
    const entries = [_]BrainEntry{
        makeBrainEntry(.type_def, "auth", "src/auth.zig", 1),
        makeBrainEntry(.import_decl, "auth.zig", "src/main.zig", 1),
    };

    var ref_map = try RefMap.build(alloc, &entries);
    defer ref_map.deinit();

    // "auth.zig" should resolve to "auth" via module name derivation
    const refs = ref_map.findReferences("auth");
    try std.testing.expect(refs != null);
    try std.testing.expectEqual(@as(usize, 1), refs.?.len);
    try std.testing.expectEqualStrings("src/main.zig", refs.?[0].file_path);
}

test "resolve path-based imports" {
    const alloc = std.testing.allocator;

    const entries = [_]BrainEntry{
        makeBrainEntry(.function, "helpers", "src/utils/helpers.zig", 1),
        makeBrainEntry(.import_decl, "./utils/helpers", "src/main.zig", 2),
    };

    var ref_map = try RefMap.build(alloc, &entries);
    defer ref_map.deinit();

    const refs = ref_map.findReferences("helpers");
    try std.testing.expect(refs != null);
    try std.testing.expectEqual(@as(usize, 1), refs.?.len);
}

test "multiple definitions with same name" {
    const alloc = std.testing.allocator;

    const entries = [_]BrainEntry{
        makeBrainEntry(.function, "init", "src/server.zig", 10),
        makeBrainEntry(.function, "init", "src/client.zig", 20),
        makeBrainEntry(.import_decl, "init", "src/main.zig", 1),
    };

    var ref_map = try RefMap.build(alloc, &entries);
    defer ref_map.deinit();

    // Both definitions should be found
    const defs = ref_map.findDefinition("init").?;
    try std.testing.expectEqual(@as(usize, 2), defs.len);

    // Reference should exist
    const refs = ref_map.findReferences("init").?;
    try std.testing.expectEqual(@as(usize, 1), refs.len);
}

test "empty entries produce empty ref map" {
    const alloc = std.testing.allocator;

    const entries = [_]BrainEntry{};

    var ref_map = try RefMap.build(alloc, &entries);
    defer ref_map.deinit();

    try std.testing.expect(ref_map.findDefinition("anything") == null);
    try std.testing.expect(ref_map.findReferences("anything") == null);
    try std.testing.expectEqual(@as(usize, 0), ref_map.dependentsOf("anything").len);

    const deps = ref_map.dependenciesOf("any_file");
    defer alloc.free(deps);
    try std.testing.expectEqual(@as(usize, 0), deps.len);
}

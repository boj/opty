const std = @import("std");
const parser = @import("parser.zig");
const brain_mod = @import("brain.zig");
const refs_mod = @import("refs.zig");
const BrainEntry = brain_mod.BrainEntry;
const RefMap = refs_mod.RefMap;
const Allocator = std.mem.Allocator;

pub const ImpactEntry = struct {
    name: []const u8,
    file_path: []const u8,
    line_number: u32,
    kind: parser.CodeUnitKind,
    depth: u16,
    confidence: f64,
};

pub const ImpactResult = struct {
    source_symbol: []const u8,
    entries: []ImpactEntry,
    total_affected: usize,
    max_depth_reached: u16,
};

/// Analyze the blast radius of changing a symbol.
/// max_depth controls how many hops to traverse (1 = direct dependents only).
/// Caller owns the returned entries slice and must free each entry's name and file_path.
pub fn analyzeImpact(
    alloc: Allocator,
    ref_map: *const RefMap,
    symbol_name: []const u8,
    max_depth: u16,
) !ImpactResult {
    var result_entries: std.ArrayList(ImpactEntry) = .empty;
    errdefer {
        for (result_entries.items) |e| {
            alloc.free(e.name);
            alloc.free(e.file_path);
        }
        result_entries.deinit(alloc);
    }

    // Track seen symbols to avoid duplicates and cycles.
    // Key = "name\x00file_path" to distinguish same-name symbols in different files.
    var seen = std.StringHashMap(void).init(alloc);
    defer {
        var it = seen.iterator();
        while (it.next()) |kv| alloc.free(kv.key_ptr.*);
        seen.deinit();
    }

    // Verify the source symbol exists
    const source_defs = ref_map.findDefinition(symbol_name) orelse {
        return .{
            .source_symbol = symbol_name,
            .entries = try result_entries.toOwnedSlice(alloc),
            .total_affected = 0,
            .max_depth_reached = 0,
        };
    };

    // Add the source symbol itself at depth 0
    for (source_defs) |def| {
        const key = try makeKey(alloc, def.name, def.file_path);
        const gop = try seen.getOrPut(key);
        if (gop.found_existing) {
            alloc.free(key);
            continue;
        }
        try result_entries.append(alloc, .{
            .name = try alloc.dupe(u8, def.name),
            .file_path = try alloc.dupe(u8, def.file_path),
            .line_number = def.line_number,
            .kind = def.kind,
            .depth = 0,
            .confidence = 1.0,
        });
    }

    // BFS: current frontier of symbol names to expand
    var current_frontier: std.ArrayList([]const u8) = .empty;
    defer current_frontier.deinit(alloc);
    try current_frontier.append(alloc, symbol_name);

    var max_depth_reached: u16 = 0;

    var depth: u16 = 1;
    while (depth <= max_depth) : (depth += 1) {
        var next_frontier: std.ArrayList([]const u8) = .empty;
        defer next_frontier.deinit(alloc);

        const confidence = 1.0 / @as(f64, @floatFromInt(@as(u32, 1) + @as(u32, depth)));

        for (current_frontier.items) |frontier_name| {
            const ref_locs = ref_map.findReferences(frontier_name) orelse continue;

            for (ref_locs) |ref_loc| {
                // For each importing file, find all definitions in that file
                // that could be affected (the importing code unit itself)
                const importing_defs = findDefsInFile(ref_map, ref_loc.file_path);
                for (importing_defs) |def| {
                    const key = try makeKey(alloc, def.name, def.file_path);
                    const gop = try seen.getOrPut(key);
                    if (gop.found_existing) {
                        alloc.free(key);
                        continue;
                    }

                    try result_entries.append(alloc, .{
                        .name = try alloc.dupe(u8, def.name),
                        .file_path = try alloc.dupe(u8, def.file_path),
                        .line_number = def.line_number,
                        .kind = def.kind,
                        .depth = depth,
                        .confidence = confidence,
                    });

                    // Add this definition name to next frontier for further traversal
                    try next_frontier.append(alloc, def.name);
                    max_depth_reached = depth;
                }
            }
        }

        current_frontier.clearRetainingCapacity();
        try current_frontier.appendSlice(alloc, next_frontier.items);

        if (next_frontier.items.len == 0) break;
    }

    const total = result_entries.items.len;
    return .{
        .source_symbol = symbol_name,
        .entries = try result_entries.toOwnedSlice(alloc),
        .total_affected = total,
        .max_depth_reached = max_depth_reached,
    };
}

fn makeKey(alloc: Allocator, name: []const u8, file_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}\x00{s}", .{ name, file_path });
}

/// Find all definitions in a given file by iterating the ref_map's definitions.
fn findDefsInFile(ref_map: *const RefMap, file_path: []const u8) []const refs_mod.DefLocation {
    // We need to search across all definition names for ones in this file.
    // Since RefMap stores definitions by name, we iterate all entries.
    var it = ref_map.definitions.iterator();
    while (it.next()) |kv| {
        for (kv.value_ptr.items) |def| {
            if (std.mem.eql(u8, def.file_path, file_path)) {
                return kv.value_ptr.items;
            }
        }
    }
    return &.{};
}

/// Format impact results as TOON output. Caller owns returned slice.
pub fn formatImpact(alloc: Allocator, result: ImpactResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    // Count entries per depth
    var max_d: u16 = 0;
    for (result.entries) |e| {
        if (e.depth > max_d) max_d = e.depth;
    }

    try buf.print(alloc, "impact{{source:\"{s}\",affected:{d},max_depth:{d}}}\n", .{
        result.source_symbol,
        result.entries.len,
        result.max_depth_reached,
    });

    var d: u16 = 0;
    while (d <= max_d) : (d += 1) {
        var count: usize = 0;
        for (result.entries) |e| {
            if (e.depth == d) count += 1;
        }
        if (count == 0) continue;

        try buf.print(alloc, "depth_{d}[{d}]{{name,kind,file,line,confidence}}:\n", .{ d, count });
        for (result.entries) |e| {
            if (e.depth != d) continue;
            const kind_str = switch (e.kind) {
                .function => "fn",
                .type_def => "type",
                .import_decl => "import",
            };
            try buf.print(alloc, "{s},{s},{s},{d},{d:.3}\n", .{
                e.name,
                kind_str,
                e.file_path,
                e.line_number,
                e.confidence,
            });
        }
    }

    return buf.toOwnedSlice(alloc);
}

// -- tests --

fn makeBrainEntry(kind: parser.CodeUnitKind, name: []const u8, file_path: []const u8, line_number: u32) BrainEntry {
    return .{
        .unit = .{
            .kind = kind,
            .name = name,
            .signature = "",
            .file_path = file_path,
            .line_number = line_number,
            .module_name = "",
        },
        .vector = .{},
    };
}

test "analyzeImpact finds direct dependents" {
    const alloc = std.testing.allocator;

    const entries = [_]BrainEntry{
        makeBrainEntry(.function, "handleAuth", "src/auth.zig", 10),
        makeBrainEntry(.function, "loginUser", "src/login.zig", 15),
        makeBrainEntry(.import_decl, "handleAuth", "src/login.zig", 1),
    };

    var ref_map = try RefMap.build(alloc, &entries);
    defer ref_map.deinit();

    const result = try analyzeImpact(alloc, &ref_map, "handleAuth", 1);
    defer {
        for (result.entries) |e| {
            alloc.free(e.name);
            alloc.free(e.file_path);
        }
        alloc.free(result.entries);
    }

    // depth 0: handleAuth itself, depth 1: loginUser (in file that imports handleAuth)
    try std.testing.expect(result.entries.len >= 2);

    // Check source is at depth 0
    var found_source = false;
    var found_dependent = false;
    for (result.entries) |e| {
        if (std.mem.eql(u8, e.name, "handleAuth") and e.depth == 0) {
            found_source = true;
            try std.testing.expectEqual(@as(f64, 1.0), e.confidence);
        }
        if (std.mem.eql(u8, e.name, "loginUser") and e.depth == 1) {
            found_dependent = true;
            try std.testing.expectEqual(@as(f64, 0.5), e.confidence);
        }
    }
    try std.testing.expect(found_source);
    try std.testing.expect(found_dependent);
}

test "analyzeImpact confidence decreases with depth" {
    const alloc = std.testing.allocator;

    // Chain: handleAuth -> loginUser -> appMain
    const entries = [_]BrainEntry{
        makeBrainEntry(.function, "handleAuth", "src/auth.zig", 10),
        makeBrainEntry(.function, "loginUser", "src/login.zig", 15),
        makeBrainEntry(.import_decl, "handleAuth", "src/login.zig", 1),
        makeBrainEntry(.function, "appMain", "src/main.zig", 20),
        makeBrainEntry(.import_decl, "loginUser", "src/main.zig", 2),
    };

    var ref_map = try RefMap.build(alloc, &entries);
    defer ref_map.deinit();

    const result = try analyzeImpact(alloc, &ref_map, "handleAuth", 3);
    defer {
        for (result.entries) |e| {
            alloc.free(e.name);
            alloc.free(e.file_path);
        }
        alloc.free(result.entries);
    }

    for (result.entries) |e| {
        const expected_confidence = 1.0 / @as(f64, @floatFromInt(@as(u32, 1) + @as(u32, e.depth)));
        try std.testing.expectEqual(expected_confidence, e.confidence);
    }
}

test "analyzeImpact handles circular references" {
    const alloc = std.testing.allocator;

    // Circular: A imports B, B imports A
    const entries = [_]BrainEntry{
        makeBrainEntry(.function, "funcA", "src/a.zig", 10),
        makeBrainEntry(.function, "funcB", "src/b.zig", 20),
        makeBrainEntry(.import_decl, "funcB", "src/a.zig", 1),
        makeBrainEntry(.import_decl, "funcA", "src/b.zig", 1),
    };

    var ref_map = try RefMap.build(alloc, &entries);
    defer ref_map.deinit();

    // Should not infinite loop, even with high max_depth
    const result = try analyzeImpact(alloc, &ref_map, "funcA", 10);
    defer {
        for (result.entries) |e| {
            alloc.free(e.name);
            alloc.free(e.file_path);
        }
        alloc.free(result.entries);
    }

    // Should find both symbols exactly once each
    var found_a = false;
    var found_b = false;
    for (result.entries) |e| {
        if (std.mem.eql(u8, e.name, "funcA")) {
            try std.testing.expect(!found_a);
            found_a = true;
        }
        if (std.mem.eql(u8, e.name, "funcB")) {
            try std.testing.expect(!found_b);
            found_b = true;
        }
    }
    try std.testing.expect(found_a);
    try std.testing.expect(found_b);
}

test "analyzeImpact max_depth=1 only returns direct dependents" {
    const alloc = std.testing.allocator;

    // Chain: A -> B -> C
    const entries = [_]BrainEntry{
        makeBrainEntry(.function, "funcA", "src/a.zig", 10),
        makeBrainEntry(.function, "funcB", "src/b.zig", 20),
        makeBrainEntry(.import_decl, "funcA", "src/b.zig", 1),
        makeBrainEntry(.function, "funcC", "src/c.zig", 30),
        makeBrainEntry(.import_decl, "funcB", "src/c.zig", 1),
    };

    var ref_map = try RefMap.build(alloc, &entries);
    defer ref_map.deinit();

    const result = try analyzeImpact(alloc, &ref_map, "funcA", 1);
    defer {
        for (result.entries) |e| {
            alloc.free(e.name);
            alloc.free(e.file_path);
        }
        alloc.free(result.entries);
    }

    // Should only have funcA (depth 0) and funcB (depth 1), not funcC
    for (result.entries) |e| {
        try std.testing.expect(!std.mem.eql(u8, e.name, "funcC"));
        try std.testing.expect(e.depth <= 1);
    }
}

test "analyzeImpact symbol not found returns empty" {
    const alloc = std.testing.allocator;

    const entries = [_]BrainEntry{
        makeBrainEntry(.function, "handleAuth", "src/auth.zig", 10),
    };

    var ref_map = try RefMap.build(alloc, &entries);
    defer ref_map.deinit();

    const result = try analyzeImpact(alloc, &ref_map, "nonExistent", 3);
    defer alloc.free(result.entries);

    try std.testing.expectEqual(@as(usize, 0), result.entries.len);
    try std.testing.expectEqual(@as(usize, 0), result.total_affected);
}

test "formatImpact produces valid TOON output" {
    const alloc = std.testing.allocator;

    const entries_arr = [_]ImpactEntry{
        .{ .name = "handleAuth", .kind = .function, .file_path = "src/auth.zig", .line_number = 42, .depth = 0, .confidence = 1.0 },
        .{ .name = "loginUser", .kind = .function, .file_path = "src/login.zig", .line_number = 15, .depth = 1, .confidence = 0.5 },
        .{ .name = "UserConfig", .kind = .type_def, .file_path = "src/config.zig", .line_number = 10, .depth = 1, .confidence = 0.5 },
    };

    const result = ImpactResult{
        .source_symbol = "handleAuth",
        .entries = @constCast(&entries_arr),
        .total_affected = 3,
        .max_depth_reached = 1,
    };

    const output = try formatImpact(alloc, result);
    defer alloc.free(output);

    // Verify header
    try std.testing.expect(std.mem.startsWith(u8, output, "impact{source:\"handleAuth\",affected:3,max_depth:1}\n"));

    // Verify depth sections exist
    try std.testing.expect(std.mem.indexOf(u8, output, "depth_0[1]{name,kind,file,line,confidence}:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "depth_1[2]{name,kind,file,line,confidence}:") != null);

    // Verify entries
    try std.testing.expect(std.mem.indexOf(u8, output, "handleAuth,fn,src/auth.zig,42,1.000") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "loginUser,fn,src/login.zig,15,0.500") != null);
}

test "formatImpact handles empty result" {
    const alloc = std.testing.allocator;

    const result = ImpactResult{
        .source_symbol = "missing",
        .entries = &.{},
        .total_affected = 0,
        .max_depth_reached = 0,
    };

    const output = try formatImpact(alloc, result);
    defer alloc.free(output);

    try std.testing.expectEqualStrings("impact{source:\"missing\",affected:0,max_depth:0}\n", output);
}

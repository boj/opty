const std = @import("std");
const parser = @import("parser.zig");
const brain_mod = @import("brain.zig");
const BrainEntry = brain_mod.BrainEntry;
const Allocator = std.mem.Allocator;

pub const ChangeType = enum {
    modified,
    added,
    deleted,

    pub fn label(self: ChangeType) []const u8 {
        return switch (self) {
            .modified => "modified",
            .added => "added",
            .deleted => "deleted",
        };
    }
};

pub const ChangedSymbol = struct {
    name: []const u8,
    kind: parser.CodeUnitKind,
    file_path: []const u8,
    line_number: u32,
    change_type: ChangeType,
};

pub const DiffHunk = struct {
    file_path: []const u8,
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
};

/// Detect changed symbols by comparing git diff against indexed code units.
/// `diff_target` can be "HEAD", "HEAD~1", a commit SHA, or "" for unstaged changes.
/// Caller owns returned slice and must free each symbol's name and file_path.
pub fn detectChanges(
    alloc: Allocator,
    root_dir: []const u8,
    entries: []const BrainEntry,
    diff_target: []const u8,
) ![]ChangedSymbol {
    const diff_output = try runGitDiff(alloc, root_dir, diff_target);
    defer alloc.free(diff_output);

    const hunks = try parseDiffOutput(alloc, diff_output);
    defer {
        for (hunks) |h| alloc.free(h.file_path);
        alloc.free(hunks);
    }

    return mapHunksToSymbols(alloc, hunks, entries);
}

fn runGitDiff(alloc: Allocator, root_dir: []const u8, diff_target: []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);

    try argv.appendSlice(alloc, &.{ "git", "-C", root_dir, "diff", "--unified=0" });
    if (diff_target.len > 0) {
        try argv.append(alloc, diff_target);
    }

    var child = std.process.Child.init(argv.items, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = child.stdout.?.read(&buf) catch break;
        if (n == 0) break;
        try output.appendSlice(alloc, buf[0..n]);
    }

    _ = try child.wait();
    return output.toOwnedSlice(alloc);
}

/// Parse unified diff output into hunks. Pure function.
/// Caller owns returned slice and must free each hunk's file_path.
pub fn parseDiffOutput(alloc: Allocator, diff_output: []const u8) ![]DiffHunk {
    var hunks: std.ArrayList(DiffHunk) = .empty;
    errdefer {
        for (hunks.items) |h| alloc.free(h.file_path);
        hunks.deinit(alloc);
    }

    var current_file: ?[]const u8 = null;

    var line_iter = std.mem.splitScalar(u8, diff_output, '\n');
    while (line_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "+++ b/")) {
            // Free previous current_file if we duped it
            if (current_file) |f| alloc.free(f);
            current_file = try alloc.dupe(u8, line[6..]);
        } else if (std.mem.startsWith(u8, line, "@@ ")) {
            const file_path = current_file orelse continue;
            const hunk = parseHunkHeader(line) orelse continue;
            try hunks.append(alloc, .{
                .file_path = try alloc.dupe(u8, file_path),
                .old_start = hunk.old_start,
                .old_count = hunk.old_count,
                .new_start = hunk.new_start,
                .new_count = hunk.new_count,
            });
        }
    }

    if (current_file) |f| alloc.free(f);

    return hunks.toOwnedSlice(alloc);
}

const HunkRange = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
};

/// Parse "@@ -old_start,old_count +new_start,new_count @@" header.
fn parseHunkHeader(line: []const u8) ?HunkRange {
    // Find the range part between @@ markers
    if (!std.mem.startsWith(u8, line, "@@ ")) return null;
    const rest = line[3..];
    const end = std.mem.indexOf(u8, rest, " @@") orelse return null;
    const range_str = rest[0..end];

    // Split into old and new parts: "-old_start,old_count +new_start,new_count"
    const space = std.mem.indexOf(u8, range_str, " ") orelse return null;
    const old_part = range_str[0..space]; // "-old_start,old_count"
    const new_part = range_str[space + 1 ..]; // "+new_start,new_count"

    if (old_part.len < 2 or old_part[0] != '-') return null;
    if (new_part.len < 2 or new_part[0] != '+') return null;

    const old_range = parseRange(old_part[1..]);
    const new_range = parseRange(new_part[1..]);

    return .{
        .old_start = old_range.start,
        .old_count = old_range.count,
        .new_start = new_range.start,
        .new_count = new_range.count,
    };
}

const Range = struct { start: u32, count: u32 };

/// Parse "start,count" or just "start" (count defaults to 1).
fn parseRange(s: []const u8) Range {
    if (std.mem.indexOf(u8, s, ",")) |comma| {
        const start = std.fmt.parseInt(u32, s[0..comma], 10) catch return .{ .start = 0, .count = 0 };
        const count = std.fmt.parseInt(u32, s[comma + 1 ..], 10) catch return .{ .start = 0, .count = 0 };
        return .{ .start = start, .count = count };
    }
    const start = std.fmt.parseInt(u32, s, 10) catch return .{ .start = 0, .count = 0 };
    return .{ .start = start, .count = 1 };
}

/// Given hunks and code unit entries, find which symbols are affected. Pure function.
/// Caller owns returned slice and must free each symbol's name and file_path.
pub fn mapHunksToSymbols(
    alloc: Allocator,
    hunks: []const DiffHunk,
    entries: []const BrainEntry,
) ![]ChangedSymbol {
    var symbols: std.ArrayList(ChangedSymbol) = .empty;
    errdefer {
        for (symbols.items) |s| {
            alloc.free(s.name);
            alloc.free(s.file_path);
        }
        symbols.deinit(alloc);
    }

    // Track which entries we've already matched to avoid duplicates
    var seen = std.AutoHashMap(usize, void).init(alloc);
    defer seen.deinit();

    for (hunks) |hunk| {
        for (entries, 0..) |entry, entry_idx| {
            if (seen.contains(entry_idx)) continue;
            if (!std.mem.eql(u8, entry.unit.file_path, hunk.file_path)) continue;

            const change_type = classifyChange(hunk, entry.unit.line_number);
            if (change_type) |ct| {
                try seen.put(entry_idx, {});
                try symbols.append(alloc, .{
                    .name = try alloc.dupe(u8, entry.unit.name),
                    .kind = entry.unit.kind,
                    .file_path = try alloc.dupe(u8, entry.unit.file_path),
                    .line_number = entry.unit.line_number,
                    .change_type = ct,
                });
            }
        }
    }

    return symbols.toOwnedSlice(alloc);
}

/// Classify a change based on hunk ranges and symbol line number.
/// Uses new-side ranges: if the symbol's line falls within the new range, it's modified.
/// If old_count > 0 and new_count == 0, lines were deleted.
/// If old_count == 0 and new_count > 0, lines were added.
fn classifyChange(hunk: DiffHunk, line_number: u32) ?ChangeType {
    // Check if the symbol's line falls within the new-side range of the hunk
    if (hunk.new_count > 0) {
        const new_end = hunk.new_start + hunk.new_count - 1;
        if (line_number >= hunk.new_start and line_number <= new_end) {
            if (hunk.old_count == 0) return .added;
            return .modified;
        }
    }

    // Check if the symbol's line falls within the old-side range
    if (hunk.old_count > 0) {
        const old_end = hunk.old_start + hunk.old_count - 1;
        if (line_number >= hunk.old_start and line_number <= old_end) {
            if (hunk.new_count == 0) return .deleted;
            return .modified;
        }
    }

    return null;
}

/// Format changed symbols as TOON output. Caller owns returned slice.
pub fn formatChanges(alloc: Allocator, changes: []const ChangedSymbol) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    try buf.print(alloc, "changes[{d}]{{name,kind,file,line,change}}:\n", .{changes.len});
    for (changes) |c| {
        const kind_str = switch (c.kind) {
            .function => "fn",
            .type_def => "type",
            .import_decl => "import",
        };
        try buf.print(alloc, "{s},{s},{s},{d},{s}\n", .{
            c.name,
            kind_str,
            c.file_path,
            c.line_number,
            c.change_type.label(),
        });
    }

    return buf.toOwnedSlice(alloc);
}

// -- tests --

test "parseDiffOutput parses unified diff into hunks" {
    const alloc = std.testing.allocator;
    const diff =
        \\--- a/src/auth.zig
        \\+++ b/src/auth.zig
        \\@@ -10,3 +10,5 @@ pub fn handleAuth
        \\ context line
        \\--- a/src/config.zig
        \\+++ b/src/config.zig
        \\@@ -1,0 +1,8 @@
        \\+new content
        \\
    ;

    const hunks = try parseDiffOutput(alloc, diff);
    defer {
        for (hunks) |h| alloc.free(h.file_path);
        alloc.free(hunks);
    }

    try std.testing.expectEqual(@as(usize, 2), hunks.len);

    // First hunk: src/auth.zig
    try std.testing.expectEqualStrings("src/auth.zig", hunks[0].file_path);
    try std.testing.expectEqual(@as(u32, 10), hunks[0].old_start);
    try std.testing.expectEqual(@as(u32, 3), hunks[0].old_count);
    try std.testing.expectEqual(@as(u32, 10), hunks[0].new_start);
    try std.testing.expectEqual(@as(u32, 5), hunks[0].new_count);

    // Second hunk: src/config.zig (pure addition)
    try std.testing.expectEqualStrings("src/config.zig", hunks[1].file_path);
    try std.testing.expectEqual(@as(u32, 1), hunks[1].old_start);
    try std.testing.expectEqual(@as(u32, 0), hunks[1].old_count);
    try std.testing.expectEqual(@as(u32, 1), hunks[1].new_start);
    try std.testing.expectEqual(@as(u32, 8), hunks[1].new_count);
}

test "parseDiffOutput handles single-line hunk without count" {
    const alloc = std.testing.allocator;
    const diff =
        \\--- a/src/main.zig
        \\+++ b/src/main.zig
        \\@@ -5 +5 @@ fn main
        \\
    ;

    const hunks = try parseDiffOutput(alloc, diff);
    defer {
        for (hunks) |h| alloc.free(h.file_path);
        alloc.free(hunks);
    }

    try std.testing.expectEqual(@as(usize, 1), hunks.len);
    try std.testing.expectEqual(@as(u32, 5), hunks[0].old_start);
    try std.testing.expectEqual(@as(u32, 1), hunks[0].old_count);
    try std.testing.expectEqual(@as(u32, 5), hunks[0].new_start);
    try std.testing.expectEqual(@as(u32, 1), hunks[0].new_count);
}

test "parseDiffOutput handles multiple hunks in same file" {
    const alloc = std.testing.allocator;
    const diff =
        \\--- a/src/server.zig
        \\+++ b/src/server.zig
        \\@@ -5,2 +5,3 @@ fn init
        \\@@ -20,4 +21,4 @@ fn handle
        \\
    ;

    const hunks = try parseDiffOutput(alloc, diff);
    defer {
        for (hunks) |h| alloc.free(h.file_path);
        alloc.free(hunks);
    }

    try std.testing.expectEqual(@as(usize, 2), hunks.len);
    try std.testing.expectEqualStrings("src/server.zig", hunks[0].file_path);
    try std.testing.expectEqualStrings("src/server.zig", hunks[1].file_path);
    try std.testing.expectEqual(@as(u32, 5), hunks[0].old_start);
    try std.testing.expectEqual(@as(u32, 20), hunks[1].old_start);
}

test "parseDiffOutput handles empty input" {
    const alloc = std.testing.allocator;
    const hunks = try parseDiffOutput(alloc, "");
    defer alloc.free(hunks);
    try std.testing.expectEqual(@as(usize, 0), hunks.len);
}

test "mapHunksToSymbols finds affected symbols" {
    const alloc = std.testing.allocator;

    // Mock entries (we only need the unit fields, vector is unused)
    const hdc = @import("hdc.zig");
    const zero_vec: hdc.HyperVector = .{ .bits = .{0} ** hdc.WORDS };

    const entries = [_]BrainEntry{
        .{ .unit = .{
            .kind = .function,
            .name = "handleAuth",
            .signature = "pub fn handleAuth(req: Request) !Response",
            .file_path = "src/auth.zig",
            .line_number = 10,
            .module_name = "auth",
        }, .vector = zero_vec },
        .{ .unit = .{
            .kind = .function,
            .name = "validateToken",
            .signature = "fn validateToken(token: []const u8) bool",
            .file_path = "src/auth.zig",
            .line_number = 30,
            .module_name = "auth",
        }, .vector = zero_vec },
        .{ .unit = .{
            .kind = .type_def,
            .name = "Config",
            .signature = "pub const Config = struct",
            .file_path = "src/config.zig",
            .line_number = 5,
            .module_name = "config",
        }, .vector = zero_vec },
    };

    const hunks = [_]DiffHunk{
        .{
            .file_path = "src/auth.zig",
            .old_start = 10,
            .old_count = 3,
            .new_start = 10,
            .new_count = 5,
        },
    };

    const symbols = try mapHunksToSymbols(alloc, &hunks, &entries);
    defer {
        for (symbols) |s| {
            alloc.free(s.name);
            alloc.free(s.file_path);
        }
        alloc.free(symbols);
    }

    // Only handleAuth (line 10) is in range [10, 14], not validateToken (line 30) or Config
    try std.testing.expectEqual(@as(usize, 1), symbols.len);
    try std.testing.expectEqualStrings("handleAuth", symbols[0].name);
    try std.testing.expectEqual(ChangeType.modified, symbols[0].change_type);
}

test "mapHunksToSymbols detects added symbols" {
    const alloc = std.testing.allocator;
    const hdc = @import("hdc.zig");
    const zero_vec: hdc.HyperVector = .{ .bits = .{0} ** hdc.WORDS };

    const entries = [_]BrainEntry{
        .{ .unit = .{
            .kind = .function,
            .name = "newFunction",
            .signature = "pub fn newFunction() void",
            .file_path = "src/new.zig",
            .line_number = 3,
            .module_name = "new",
        }, .vector = zero_vec },
    };

    // Pure addition: old_count=0, new lines 1-10
    const hunks = [_]DiffHunk{
        .{
            .file_path = "src/new.zig",
            .old_start = 0,
            .old_count = 0,
            .new_start = 1,
            .new_count = 10,
        },
    };

    const symbols = try mapHunksToSymbols(alloc, &hunks, &entries);
    defer {
        for (symbols) |s| {
            alloc.free(s.name);
            alloc.free(s.file_path);
        }
        alloc.free(symbols);
    }

    try std.testing.expectEqual(@as(usize, 1), symbols.len);
    try std.testing.expectEqual(ChangeType.added, symbols[0].change_type);
}

test "mapHunksToSymbols detects deleted symbols" {
    const alloc = std.testing.allocator;
    const hdc = @import("hdc.zig");
    const zero_vec: hdc.HyperVector = .{ .bits = .{0} ** hdc.WORDS };

    const entries = [_]BrainEntry{
        .{ .unit = .{
            .kind = .function,
            .name = "oldFunction",
            .signature = "fn oldFunction() void",
            .file_path = "src/old.zig",
            .line_number = 5,
            .module_name = "old",
        }, .vector = zero_vec },
    };

    // Pure deletion: new_count=0, old lines 1-10
    const hunks = [_]DiffHunk{
        .{
            .file_path = "src/old.zig",
            .old_start = 1,
            .old_count = 10,
            .new_start = 1,
            .new_count = 0,
        },
    };

    const symbols = try mapHunksToSymbols(alloc, &hunks, &entries);
    defer {
        for (symbols) |s| {
            alloc.free(s.name);
            alloc.free(s.file_path);
        }
        alloc.free(symbols);
    }

    try std.testing.expectEqual(@as(usize, 1), symbols.len);
    try std.testing.expectEqual(ChangeType.deleted, symbols[0].change_type);
}

test "mapHunksToSymbols exact line boundary" {
    const alloc = std.testing.allocator;
    const hdc = @import("hdc.zig");
    const zero_vec: hdc.HyperVector = .{ .bits = .{0} ** hdc.WORDS };

    const entries = [_]BrainEntry{
        .{ .unit = .{
            .kind = .function,
            .name = "atBoundary",
            .signature = "fn atBoundary() void",
            .file_path = "src/edge.zig",
            .line_number = 15,
            .module_name = "edge",
        }, .vector = zero_vec },
        .{ .unit = .{
            .kind = .function,
            .name = "justOutside",
            .signature = "fn justOutside() void",
            .file_path = "src/edge.zig",
            .line_number = 16,
            .module_name = "edge",
        }, .vector = zero_vec },
    };

    // Hunk covers exactly line 15 (start=15, count=1)
    const hunks = [_]DiffHunk{
        .{
            .file_path = "src/edge.zig",
            .old_start = 15,
            .old_count = 1,
            .new_start = 15,
            .new_count = 1,
        },
    };

    const symbols = try mapHunksToSymbols(alloc, &hunks, &entries);
    defer {
        for (symbols) |s| {
            alloc.free(s.name);
            alloc.free(s.file_path);
        }
        alloc.free(symbols);
    }

    // Only atBoundary (line 15) should match, not justOutside (line 16)
    try std.testing.expectEqual(@as(usize, 1), symbols.len);
    try std.testing.expectEqualStrings("atBoundary", symbols[0].name);
}

test "mapHunksToSymbols hunk between two symbols matches neither" {
    const alloc = std.testing.allocator;
    const hdc = @import("hdc.zig");
    const zero_vec: hdc.HyperVector = .{ .bits = .{0} ** hdc.WORDS };

    const entries = [_]BrainEntry{
        .{ .unit = .{
            .kind = .function,
            .name = "funcA",
            .signature = "fn funcA() void",
            .file_path = "src/gap.zig",
            .line_number = 5,
            .module_name = "gap",
        }, .vector = zero_vec },
        .{ .unit = .{
            .kind = .function,
            .name = "funcB",
            .signature = "fn funcB() void",
            .file_path = "src/gap.zig",
            .line_number = 20,
            .module_name = "gap",
        }, .vector = zero_vec },
    };

    // Hunk covers lines 10-14, between the two symbols
    const hunks = [_]DiffHunk{
        .{
            .file_path = "src/gap.zig",
            .old_start = 10,
            .old_count = 5,
            .new_start = 10,
            .new_count = 5,
        },
    };

    const symbols = try mapHunksToSymbols(alloc, &hunks, &entries);
    defer {
        for (symbols) |s| {
            alloc.free(s.name);
            alloc.free(s.file_path);
        }
        alloc.free(symbols);
    }

    // Neither symbol's line falls within [10, 14]
    try std.testing.expectEqual(@as(usize, 0), symbols.len);
}

test "mapHunksToSymbols no duplicate when multiple hunks match same symbol" {
    const alloc = std.testing.allocator;
    const hdc = @import("hdc.zig");
    const zero_vec: hdc.HyperVector = .{ .bits = .{0} ** hdc.WORDS };

    const entries = [_]BrainEntry{
        .{ .unit = .{
            .kind = .function,
            .name = "bigFunc",
            .signature = "fn bigFunc() void",
            .file_path = "src/big.zig",
            .line_number = 10,
            .module_name = "big",
        }, .vector = zero_vec },
    };

    // Two hunks both covering line 10
    const hunks = [_]DiffHunk{
        .{ .file_path = "src/big.zig", .old_start = 8, .old_count = 5, .new_start = 8, .new_count = 5 },
        .{ .file_path = "src/big.zig", .old_start = 10, .old_count = 2, .new_start = 10, .new_count = 2 },
    };

    const symbols = try mapHunksToSymbols(alloc, &hunks, &entries);
    defer {
        for (symbols) |s| {
            alloc.free(s.name);
            alloc.free(s.file_path);
        }
        alloc.free(symbols);
    }

    // Should appear only once despite two overlapping hunks
    try std.testing.expectEqual(@as(usize, 1), symbols.len);
}

test "formatChanges produces valid TOON output" {
    const alloc = std.testing.allocator;

    const changes = [_]ChangedSymbol{
        .{ .name = "handleAuth", .kind = .function, .file_path = "src/auth.zig", .line_number = 42, .change_type = .modified },
        .{ .name = "UserConfig", .kind = .type_def, .file_path = "src/config.zig", .line_number = 10, .change_type = .added },
    };

    const output = try formatChanges(alloc, &changes);
    defer alloc.free(output);

    const expected =
        \\changes[2]{name,kind,file,line,change}:
        \\handleAuth,fn,src/auth.zig,42,modified
        \\UserConfig,type,src/config.zig,10,added
        \\
    ;

    try std.testing.expectEqualStrings(expected, output);
}

test "formatChanges handles empty input" {
    const alloc = std.testing.allocator;
    const changes = [_]ChangedSymbol{};
    const output = try formatChanges(alloc, &changes);
    defer alloc.free(output);

    try std.testing.expectEqualStrings("changes[0]{name,kind,file,line,change}:\n", output);
}

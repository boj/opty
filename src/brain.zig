const std = @import("std");
const hdc = @import("hdc.zig");
const parser = @import("parser.zig");
const encoder = @import("encoder.zig");
const HyperVector = hdc.HyperVector;
const CodeUnit = parser.CodeUnit;
const Allocator = std.mem.Allocator;

pub const BrainEntry = struct {
    unit: CodeUnit,
    vector: HyperVector,
};

pub const QueryResult = struct {
    entry: *const BrainEntry,
    similarity: f64,
};

pub const Brain = struct {
    entries: std.ArrayList(BrainEntry) = .empty,
    allocator: Allocator,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: Allocator) Brain {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Brain) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.unit.name);
            self.allocator.free(entry.unit.signature);
            self.allocator.free(entry.unit.file_path);
            self.allocator.free(entry.unit.module_name);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn removeFile(self: *Brain, file_path: []const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (std.mem.eql(u8, self.entries.items[i].unit.file_path, file_path)) {
                const removed = self.entries.orderedRemove(i);
                self.allocator.free(removed.unit.name);
                self.allocator.free(removed.unit.signature);
                self.allocator.free(removed.unit.file_path);
                self.allocator.free(removed.unit.module_name);
            } else {
                i += 1;
            }
        }
    }

    pub fn indexFile(self: *Brain, file_path: []const u8, source: []const u8) !void {
        const lang = parser.Language.fromExtension(file_path);
        if (!lang.isSupported()) return;

        self.removeFile(file_path);

        const units = try parser.parseSource(self.allocator, source, file_path, lang);
        defer self.allocator.free(units);

        for (units) |unit| {
            const vec = try encoder.encodeUnit(self.allocator, unit);
            try self.entries.append(self.allocator, .{ .unit = unit, .vector = vec });
        }
    }

    pub fn query(self: *Brain, alloc: Allocator, query_vec: HyperVector, top_k: usize) ![]QueryResult {
        var results: std.ArrayList(QueryResult) = .empty;

        for (self.entries.items) |*entry| {
            const sim = entry.vector.similarity(query_vec);
            if (sim > 0.0) {
                try results.append(alloc, .{ .entry = entry, .similarity = sim });
            }
        }

        const items = try results.toOwnedSlice(alloc);

        std.mem.sort(QueryResult, items, {}, struct {
            fn lessThan(_: void, a: QueryResult, b: QueryResult) bool {
                return b.similarity < a.similarity;
            }
        }.lessThan);

        const limit = @min(top_k, items.len);
        if (limit < items.len) {
            const trimmed = try alloc.alloc(QueryResult, limit);
            @memcpy(trimmed, items[0..limit]);
            alloc.free(items);
            return trimmed;
        }
        return items;
    }

    pub fn unitCount(self: *Brain) usize {
        return self.entries.items.len;
    }

    pub fn fileCount(self: *Brain) usize {
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();
        for (self.entries.items) |entry| {
            seen.put(entry.unit.file_path, {}) catch {};
        }
        return seen.count();
    }
};

// -- tests --

test "brain index and query" {
    const alloc = std.testing.allocator;
    var brain = Brain.init(alloc);
    defer brain.deinit();

    const source = "pub fn handleAuth(req: Request) !Response {\n}\npub fn processPayment(amount: u64) !Receipt {\n}\n";
    try brain.indexFile("auth.zig", source);
    try std.testing.expectEqual(@as(usize, 2), brain.unitCount());

    const qvec = try encoder.encodeQuery(alloc, "auth handle request");
    const results = try brain.query(alloc, qvec, 5);
    defer alloc.free(results);

    try std.testing.expect(results.len > 0);
    // Both should be returned; auth function should rank first due to name overlap
    try std.testing.expectEqualStrings("handleAuth", results[0].entry.unit.name);
}

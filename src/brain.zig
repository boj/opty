const std = @import("std");
const hdc = @import("hdc.zig");
const parser = @import("parser.zig");
const encoder = @import("encoder.zig");
const bm25_mod = @import("bm25.zig");
const refs_mod = @import("refs.zig");
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
    bm25: bm25_mod.BM25Index,
    ref_map: ?refs_mod.RefMap = null,
    refs_dirty: bool = true,

    pub fn init(allocator: Allocator) Brain {
        return .{
            .allocator = allocator,
            .bm25 = bm25_mod.BM25Index.init(allocator),
        };
    }

    pub fn deinit(self: *Brain) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.unit.name);
            self.allocator.free(entry.unit.signature);
            self.allocator.free(entry.unit.file_path);
            self.allocator.free(entry.unit.module_name);
        }
        self.entries.deinit(self.allocator);
        self.bm25.deinit();
        if (self.ref_map) |*rm| rm.deinit();
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
        self.refs_dirty = true;
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
        self.refs_dirty = true;
    }

    /// Rebuild the BM25 index from current entries.
    pub fn rebuildBM25(self: *Brain) !void {
        self.bm25.clear();
        for (self.entries.items, 0..) |entry, i| {
            const text = try buildDocText(self.allocator, entry.unit);
            defer self.allocator.free(text);
            try self.bm25.addDocument(i, text);
        }
    }

    /// Get or rebuild the RefMap (lazy, rebuilt when entries change).
    pub fn getRefMap(self: *Brain) !*refs_mod.RefMap {
        if (self.refs_dirty or self.ref_map == null) {
            if (self.ref_map) |*rm| rm.deinit();
            self.ref_map = try refs_mod.RefMap.build(self.allocator, self.entries.items);
            self.refs_dirty = false;
        }
        return &self.ref_map.?;
    }

    /// Hybrid query: combines HDC similarity with BM25 text search via RRF.
    pub fn hybridQuery(self: *Brain, alloc: Allocator, query_text: []const u8, query_vec: HyperVector, top_k: usize) ![]QueryResult {
        // Get HDC results
        const hdc_results = try self.query(alloc, query_vec, top_k * 2);
        defer alloc.free(hdc_results);

        // Rebuild BM25 if needed and search
        self.rebuildBM25() catch {};
        const bm25_results = self.bm25.search(alloc, query_text, top_k * 2) catch
            return self.query(alloc, query_vec, top_k);
        defer alloc.free(bm25_results);

        // Convert to RRF input format
        var hdc_input = try alloc.alloc(bm25_mod.HdcResult, hdc_results.len);
        defer alloc.free(hdc_input);
        for (hdc_results, 0..) |r, i| {
            // Find the index of this entry in self.entries
            const idx = (@intFromPtr(r.entry) - @intFromPtr(self.entries.items.ptr)) / @sizeOf(BrainEntry);
            hdc_input[i] = .{ .doc_id = idx, .similarity = r.similarity };
        }

        const hybrid = bm25_mod.reciprocalRankFusion(alloc, bm25_results, hdc_input, 60.0, top_k) catch
            return self.query(alloc, query_vec, top_k);
        defer alloc.free(hybrid);

        // Convert back to QueryResult
        var results = try alloc.alloc(QueryResult, hybrid.len);
        for (hybrid, 0..) |h, i| {
            if (h.doc_id < self.entries.items.len) {
                results[i] = .{
                    .entry = &self.entries.items[h.doc_id],
                    .similarity = h.rrf_score,
                };
            }
        }
        return results;
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

/// Build a text document for BM25 from a CodeUnit's name, module, and signature tokens.
fn buildDocText(alloc: Allocator, unit: CodeUnit) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, unit.name);
    try buf.append(alloc, ' ');
    try buf.appendSlice(alloc, unit.module_name);
    try buf.append(alloc, ' ');
    try buf.appendSlice(alloc, unit.signature);
    return buf.toOwnedSlice(alloc);
}

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

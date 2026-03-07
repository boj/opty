const std = @import("std");
const parser = @import("parser.zig");
const Allocator = std.mem.Allocator;

/// Per-document term frequencies.
const DocTerms = struct {
    doc_id: usize,
    terms: std.StringHashMap(u32),
    total_terms: u32,

    fn deinit(self: *DocTerms, alloc: Allocator) void {
        var it = self.terms.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
        }
        self.terms.deinit();
    }
};

pub const BM25Result = struct {
    doc_id: usize,
    score: f64,
};

pub const HdcResult = struct {
    doc_id: usize,
    similarity: f64,
};

pub const HybridResult = struct {
    doc_id: usize,
    rrf_score: f64,
    bm25_rank: ?usize,
    hdc_rank: ?usize,
};

/// BM25 text search index using the Okapi BM25 scoring formula.
pub const BM25Index = struct {
    doc_terms: std.ArrayList(DocTerms),
    df: std.StringHashMap(u32),
    doc_count: u32,
    avg_dl: f64,
    total_dl: u64,
    allocator: Allocator,

    const k1: f64 = 1.2;
    const b: f64 = 0.75;

    pub fn init(alloc: Allocator) BM25Index {
        return .{
            .doc_terms = .empty,
            .df = std.StringHashMap(u32).init(alloc),
            .doc_count = 0,
            .avg_dl = 0.0,
            .total_dl = 0,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *BM25Index) void {
        for (self.doc_terms.items) |*dt| {
            dt.deinit(self.allocator);
        }
        self.doc_terms.deinit(self.allocator);
        var it = self.df.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.df.deinit();
    }

    pub fn clear(self: *BM25Index) void {
        for (self.doc_terms.items) |*dt| {
            dt.deinit(self.allocator);
        }
        self.doc_terms.clearRetainingCapacity();
        var it = self.df.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.df.clearRetainingCapacity();
        self.doc_count = 0;
        self.avg_dl = 0.0;
        self.total_dl = 0;
    }

    /// Add a document to the index. `text` is tokenized using whitespace/punctuation
    /// splitting and camelCase/snake_case splitting via splitIdentifier, then lowercased.
    pub fn addDocument(self: *BM25Index, doc_id: usize, text: []const u8) !void {
        var terms = std.StringHashMap(u32).init(self.allocator);
        var total_terms: u32 = 0;

        // Track which terms are new for this document (for df updates).
        var seen_terms = std.StringHashMap(void).init(self.allocator);
        defer seen_terms.deinit();

        // Tokenize: split on whitespace and punctuation.
        var tok_iter = std.mem.tokenizeAny(u8, text, " \t\n\r,(){}[]<>:;=&*|!?@#$%^~`'\"\\/.-_");
        while (tok_iter.next()) |raw_token| {
            if (raw_token.len < 1) continue;
            try self.addTerm(&terms, &seen_terms, &total_terms, raw_token);
        }

        // Also split identifiers from the original text for camelCase/snake_case.
        var ident_iter = std.mem.tokenizeAny(u8, text, " \t\n\r,(){}[]<>:;=&*|!?@#$%^~`'\"\\/");
        while (ident_iter.next()) |token| {
            const sub_tokens = parser.splitIdentifier(self.allocator, token) catch continue;
            defer self.allocator.free(sub_tokens);
            for (sub_tokens) |sub| {
                if (sub.len < 1) continue;
                try self.addTerm(&terms, &seen_terms, &total_terms, sub);
            }
        }

        try self.doc_terms.append(self.allocator, .{
            .doc_id = doc_id,
            .terms = terms,
            .total_terms = total_terms,
        });

        self.doc_count += 1;
        self.total_dl += total_terms;
        self.avg_dl = @as(f64, @floatFromInt(self.total_dl)) / @as(f64, @floatFromInt(self.doc_count));
    }

    fn addTerm(
        self: *BM25Index,
        terms: *std.StringHashMap(u32),
        seen_terms: *std.StringHashMap(void),
        total_terms: *u32,
        raw_token: []const u8,
    ) !void {
        var lower_buf: [512]u8 = undefined;
        const lower = toLower(raw_token, &lower_buf);
        if (lower.len == 0) return;

        // Update per-document term frequency.
        if (terms.getPtr(lower)) |count| {
            count.* += 1;
        } else {
            const key = try self.allocator.dupe(u8, lower);
            try terms.put(key, 1);
        }
        total_terms.* += 1;

        // Update global document frequency (once per term per document).
        if (!seen_terms.contains(lower)) {
            if (self.df.getPtr(lower)) |count| {
                count.* += 1;
            } else {
                const df_key = try self.allocator.dupe(u8, lower);
                try self.df.put(df_key, 1);
            }
            try seen_terms.put(lower, {});
        }
    }

    /// Search the index for documents matching `query_text`. Returns up to `top_k` results
    /// sorted by descending BM25 score.
    pub fn search(self: *BM25Index, alloc: Allocator, query_text: []const u8, top_k: usize) ![]BM25Result {
        if (self.doc_count == 0) return try alloc.alloc(BM25Result, 0);

        // Tokenize query the same way as documents.
        var query_terms: std.ArrayList([]const u8) = .empty;
        defer {
            for (query_terms.items) |t| alloc.free(t);
            query_terms.deinit(alloc);
        }

        var tok_iter = std.mem.tokenizeAny(u8, query_text, " \t\n\r,(){}[]<>:;=&*|!?@#$%^~`'\"\\/.-_");
        while (tok_iter.next()) |raw_token| {
            if (raw_token.len < 1) continue;
            var lower_buf: [512]u8 = undefined;
            const lower = toLower(raw_token, &lower_buf);
            if (lower.len > 0) try query_terms.append(alloc, try alloc.dupe(u8, lower));
        }

        // Also add camelCase/snake_case splits from query.
        var ident_iter = std.mem.tokenizeAny(u8, query_text, " \t\n\r,(){}[]<>:;=&*|!?@#$%^~`'\"\\/");
        while (ident_iter.next()) |token| {
            const sub_tokens = parser.splitIdentifier(alloc, token) catch continue;
            defer alloc.free(sub_tokens);
            for (sub_tokens) |sub| {
                if (sub.len < 1) continue;
                var lower_buf: [512]u8 = undefined;
                const lower = toLower(sub, &lower_buf);
                if (lower.len > 0) try query_terms.append(alloc, try alloc.dupe(u8, lower));
            }
        }

        if (query_terms.items.len == 0) return try alloc.alloc(BM25Result, 0);

        // Score each document.
        var results: std.ArrayList(BM25Result) = .empty;
        defer results.deinit(alloc);

        for (self.doc_terms.items) |*dt| {
            var score: f64 = 0.0;
            const dl: f64 = @floatFromInt(dt.total_terms);

            for (query_terms.items) |qt| {
                const tf_raw = dt.terms.get(qt) orelse continue;
                const tf: f64 = @floatFromInt(tf_raw);
                const n_raw = self.df.get(qt) orelse continue;
                const n: f64 = @floatFromInt(n_raw);
                const big_n: f64 = @floatFromInt(self.doc_count);

                // IDF = ln((N - n + 0.5) / (n + 0.5) + 1)
                const idf = @log((big_n - n + 0.5) / (n + 0.5) + 1.0);
                // BM25 term score
                const numerator = tf * (k1 + 1.0);
                const denominator = tf + k1 * (1.0 - b + b * dl / self.avg_dl);
                score += idf * numerator / denominator;
            }

            if (score > 0.0) {
                try results.append(alloc, .{ .doc_id = dt.doc_id, .score = score });
            }
        }

        const items = try results.toOwnedSlice(alloc);

        std.mem.sort(BM25Result, items, {}, struct {
            fn lessThan(_: void, a: BM25Result, bb: BM25Result) bool {
                return bb.score < a.score;
            }
        }.lessThan);

        const limit = @min(top_k, items.len);
        if (limit < items.len) {
            const trimmed = try alloc.alloc(BM25Result, limit);
            @memcpy(trimmed, items[0..limit]);
            alloc.free(items);
            return trimmed;
        }
        return items;
    }
};

/// Combine BM25 results and HDC results using Reciprocal Rank Fusion.
/// k is the RRF constant (typically 60).
pub fn reciprocalRankFusion(
    alloc: Allocator,
    bm25_results: []const BM25Result,
    hdc_results: []const HdcResult,
    k: f64,
    top_k: usize,
) ![]HybridResult {
    // Build a map of doc_id -> rrf_score, bm25_rank, hdc_rank.
    var score_map = std.AutoHashMap(usize, HybridResult).init(alloc);
    defer score_map.deinit();

    // Add BM25 contributions.
    for (bm25_results, 0..) |result, rank| {
        const rrf_contrib = 1.0 / (k + @as(f64, @floatFromInt(rank + 1)));
        const gop = try score_map.getOrPut(result.doc_id);
        if (gop.found_existing) {
            gop.value_ptr.rrf_score += rrf_contrib;
            gop.value_ptr.bm25_rank = rank + 1;
        } else {
            gop.value_ptr.* = .{
                .doc_id = result.doc_id,
                .rrf_score = rrf_contrib,
                .bm25_rank = rank + 1,
                .hdc_rank = null,
            };
        }
    }

    // Add HDC contributions.
    for (hdc_results, 0..) |result, rank| {
        const rrf_contrib = 1.0 / (k + @as(f64, @floatFromInt(rank + 1)));
        const gop = try score_map.getOrPut(result.doc_id);
        if (gop.found_existing) {
            gop.value_ptr.rrf_score += rrf_contrib;
            gop.value_ptr.hdc_rank = rank + 1;
        } else {
            gop.value_ptr.* = .{
                .doc_id = result.doc_id,
                .rrf_score = rrf_contrib,
                .bm25_rank = null,
                .hdc_rank = rank + 1,
            };
        }
    }

    // Collect results.
    var results: std.ArrayList(HybridResult) = .empty;
    defer results.deinit(alloc);

    var it = score_map.iterator();
    while (it.next()) |entry| {
        try results.append(alloc, entry.value_ptr.*);
    }

    const items = try results.toOwnedSlice(alloc);

    std.mem.sort(HybridResult, items, {}, struct {
        fn lessThan(_: void, a: HybridResult, bb: HybridResult) bool {
            return bb.rrf_score < a.rrf_score;
        }
    }.lessThan);

    const limit = @min(top_k, items.len);
    if (limit < items.len) {
        const trimmed = try alloc.alloc(HybridResult, limit);
        @memcpy(trimmed, items[0..limit]);
        alloc.free(items);
        return trimmed;
    }
    return items;
}

fn toLower(s: []const u8, buf: *[512]u8) []const u8 {
    const len = @min(s.len, 512);
    for (0..len) |i| {
        buf[i] = std.ascii.toLower(s[i]);
    }
    return buf[0..len];
}

// -- tests --

test "index and search exact term" {
    const alloc = std.testing.allocator;
    var index = BM25Index.init(alloc);
    defer index.deinit();

    try index.addDocument(0, "handleAuth request authentication");
    try index.addDocument(1, "processPayment amount billing");
    try index.addDocument(2, "renderDashboard view template");

    const results = try index.search(alloc, "authentication", 3);
    defer alloc.free(results);

    try std.testing.expect(results.len > 0);
    try std.testing.expectEqual(@as(usize, 0), results[0].doc_id);
}

test "bm25 exact matches score higher than partial" {
    const alloc = std.testing.allocator;
    var index = BM25Index.init(alloc);
    defer index.deinit();

    try index.addDocument(0, "database connection pool handler");
    try index.addDocument(1, "database migration script runner database backup");
    try index.addDocument(2, "user interface component render");

    const results = try index.search(alloc, "database", 3);
    defer alloc.free(results);

    try std.testing.expect(results.len >= 2);
    // Doc 1 has "database" twice, should score higher.
    try std.testing.expectEqual(@as(usize, 1), results[0].doc_id);
    try std.testing.expectEqual(@as(usize, 0), results[1].doc_id);
}

test "rrf combines two ranked lists" {
    const alloc = std.testing.allocator;

    const bm25 = [_]BM25Result{
        .{ .doc_id = 0, .score = 10.0 },
        .{ .doc_id = 1, .score = 5.0 },
        .{ .doc_id = 2, .score = 1.0 },
    };
    const hdc = [_]HdcResult{
        .{ .doc_id = 1, .similarity = 0.9 },
        .{ .doc_id = 2, .similarity = 0.7 },
        .{ .doc_id = 3, .similarity = 0.5 },
    };

    const results = try reciprocalRankFusion(alloc, &bm25, &hdc, 60.0, 10);
    defer alloc.free(results);

    try std.testing.expect(results.len == 4);

    // Doc 1 appears in both lists (rank 2 in BM25, rank 1 in HDC) -> highest RRF.
    // RRF(1) = 1/(60+2) + 1/(60+1) = 1/62 + 1/61
    // Doc 0 is rank 1 in BM25 only -> 1/(60+1) = 1/61
    // Doc 1's combined score should be the highest.
    try std.testing.expectEqual(@as(usize, 1), results[0].doc_id);

    // Verify ranks are recorded.
    try std.testing.expectEqual(@as(?usize, 2), results[0].bm25_rank);
    try std.testing.expectEqual(@as(?usize, 1), results[0].hdc_rank);
}

test "empty query returns empty results" {
    const alloc = std.testing.allocator;
    var index = BM25Index.init(alloc);
    defer index.deinit();

    try index.addDocument(0, "some document text");

    const results = try index.search(alloc, "", 5);
    defer alloc.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "multiple matching terms score higher" {
    const alloc = std.testing.allocator;
    var index = BM25Index.init(alloc);
    defer index.deinit();

    try index.addDocument(0, "auth handler request");
    try index.addDocument(1, "auth handler request validation error response");
    try index.addDocument(2, "render template view");

    const results = try index.search(alloc, "auth handler request", 3);
    defer alloc.free(results);

    try std.testing.expect(results.len >= 2);
    // Both doc 0 and 1 match all three terms. Doc 0 is shorter, so BM25
    // should give it a higher score (shorter documents get a boost with b=0.75).
    try std.testing.expectEqual(@as(usize, 0), results[0].doc_id);
    try std.testing.expectEqual(@as(usize, 1), results[1].doc_id);
}

test "camelCase splitting works in search" {
    const alloc = std.testing.allocator;
    var index = BM25Index.init(alloc);
    defer index.deinit();

    try index.addDocument(0, "handleAuthError");
    try index.addDocument(1, "processPayment");
    try index.addDocument(2, "renderView");

    const results = try index.search(alloc, "auth error", 3);
    defer alloc.free(results);

    try std.testing.expect(results.len > 0);
    try std.testing.expectEqual(@as(usize, 0), results[0].doc_id);
}

test "clear resets index" {
    const alloc = std.testing.allocator;
    var index = BM25Index.init(alloc);
    defer index.deinit();

    try index.addDocument(0, "some text");
    try std.testing.expectEqual(@as(u32, 1), index.doc_count);

    index.clear();
    try std.testing.expectEqual(@as(u32, 0), index.doc_count);

    const results = try index.search(alloc, "text", 5);
    defer alloc.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

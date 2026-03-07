const std = @import("std");
const hdc = @import("hdc.zig");
const parser = @import("parser.zig");
const encoder = @import("encoder.zig");
const brain_mod = @import("brain.zig");
const HyperVector = hdc.HyperVector;
const Allocator = std.mem.Allocator;

pub const ClusterMember = struct {
    entry_index: usize,
    name: []const u8,
    kind: parser.CodeUnitKind,
    file_path: []const u8,
    line_number: u32,
    distance_to_centroid: f64,
};

pub const Cluster = struct {
    id: u32,
    label: []const u8,
    members: []ClusterMember,
    centroid: HyperVector,
};

pub const ClusterResult = struct {
    clusters: []Cluster,
    unclustered_count: usize,
};

/// Free all memory owned by a ClusterResult.
pub fn freeResult(alloc: Allocator, result: ClusterResult) void {
    for (result.clusters) |cluster| {
        alloc.free(cluster.label);
        alloc.free(cluster.members);
    }
    alloc.free(result.clusters);
}

/// Cluster code units by HDC vector similarity using connected components.
/// threshold: minimum similarity for two units to be connected (0.0-1.0, suggest 0.15)
/// min_cluster_size: minimum members for a valid cluster (suggest 2)
pub fn clusterUnits(
    alloc: Allocator,
    entries: []const brain_mod.BrainEntry,
    threshold: f64,
    min_cluster_size: usize,
) !ClusterResult {
    const n = entries.len;
    if (n == 0) return .{ .clusters = try alloc.alloc(Cluster, 0), .unclustered_count = 0 };

    // Build adjacency list via pairwise similarity
    var adj = try alloc.alloc(std.ArrayList(usize), n);
    defer {
        for (adj) |*list| list.deinit(alloc);
        alloc.free(adj);
    }
    for (adj) |*list| list.* = .empty;

    for (0..n) |i| {
        for (i + 1..n) |j| {
            const sim = entries[i].vector.similarity(entries[j].vector);
            if (sim >= threshold) {
                try adj[i].append(alloc, j);
                try adj[j].append(alloc, i);
            }
        }
    }

    // Find connected components via BFS
    var component = try alloc.alloc(i32, n);
    defer alloc.free(component);
    @memset(component, -1);

    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(alloc);

    var comp_id: i32 = 0;
    for (0..n) |start| {
        if (component[start] != -1) continue;
        // BFS from start
        queue.clearRetainingCapacity();
        try queue.append(alloc, start);
        component[start] = comp_id;

        var head: usize = 0;
        while (head < queue.items.len) {
            const cur = queue.items[head];
            head += 1;
            for (adj[cur].items) |neighbor| {
                if (component[neighbor] == -1) {
                    component[neighbor] = comp_id;
                    try queue.append(alloc, neighbor);
                }
            }
        }
        comp_id += 1;
    }

    // Group entries by component
    const num_components: usize = @intCast(comp_id);
    var comp_members = try alloc.alloc(std.ArrayList(usize), num_components);
    defer {
        for (comp_members) |*list| list.deinit(alloc);
        alloc.free(comp_members);
    }
    for (comp_members) |*list| list.* = .empty;

    for (0..n) |i| {
        const c: usize = @intCast(component[i]);
        try comp_members[c].append(alloc, i);
    }

    // Build clusters from components that meet min_cluster_size
    var clusters: std.ArrayList(Cluster) = .empty;
    errdefer {
        for (clusters.items) |cluster| {
            alloc.free(cluster.label);
            alloc.free(cluster.members);
        }
        clusters.deinit(alloc);
    }

    var unclustered_count: usize = 0;

    for (comp_members) |comp| {
        if (comp.items.len < min_cluster_size) {
            unclustered_count += comp.items.len;
            continue;
        }

        // Compute centroid by bundling all member vectors
        var vecs = try alloc.alloc(HyperVector, comp.items.len);
        defer alloc.free(vecs);
        for (comp.items, 0..) |idx, vi| {
            vecs[vi] = entries[idx].vector;
        }
        const centroid = hdc.bundle(vecs);

        // Build members list with distance to centroid
        var members = try alloc.alloc(ClusterMember, comp.items.len);
        for (comp.items, 0..) |idx, mi| {
            members[mi] = .{
                .entry_index = idx,
                .name = entries[idx].unit.name,
                .kind = entries[idx].unit.kind,
                .file_path = entries[idx].unit.file_path,
                .line_number = entries[idx].unit.line_number,
                .distance_to_centroid = 1.0 - centroid.similarity(entries[idx].vector),
            };
        }

        // Sort members by distance to centroid (closest first)
        std.mem.sort(ClusterMember, members, {}, struct {
            fn lessThan(_: void, a: ClusterMember, b: ClusterMember) bool {
                return a.distance_to_centroid < b.distance_to_centroid;
            }
        }.lessThan);

        // Generate label from most common sub-tokens
        const label = try generateLabel(alloc, entries, comp.items);

        const cluster_id: u32 = @intCast(clusters.items.len);
        try clusters.append(alloc, .{
            .id = cluster_id,
            .label = label,
            .members = members,
            .centroid = centroid,
        });
    }

    return .{
        .clusters = try clusters.toOwnedSlice(alloc),
        .unclustered_count = unclustered_count,
    };
}

/// Generate a cluster label from the top 2-3 most common sub-tokens across member names.
fn generateLabel(alloc: Allocator, entries: []const brain_mod.BrainEntry, member_indices: []const usize) ![]const u8 {
    var freq = std.StringHashMap(usize).init(alloc);
    defer freq.deinit();

    // Collect sub-tokens from all member names
    for (member_indices) |idx| {
        const parts = parser.splitIdentifier(alloc, entries[idx].unit.name) catch continue;
        defer alloc.free(parts);
        for (parts) |part| {
            var lower_buf: [256]u8 = undefined;
            const lower = toLower(part, &lower_buf);
            const key = freq.getKey(lower) orelse try alloc.dupe(u8, lower);
            const entry = try freq.getOrPut(key);
            if (entry.found_existing) {
                entry.value_ptr.* += 1;
            } else {
                entry.value_ptr.* = 1;
            }
        }
    }

    // Sort by frequency descending, pick top 3
    const Token = struct { name: []const u8, count: usize };
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(alloc);

    var it = freq.iterator();
    while (it.next()) |entry| {
        try tokens.append(alloc, .{ .name = entry.key_ptr.*, .count = entry.value_ptr.* });
    }

    std.mem.sort(Token, tokens.items, {}, struct {
        fn lessThan(_: void, a: Token, b: Token) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    const top_n = @min(3, tokens.items.len);
    var label_buf: std.ArrayList(u8) = .empty;
    defer label_buf.deinit(alloc);

    for (0..top_n) |i| {
        if (i > 0) try label_buf.append(alloc, '-');
        try label_buf.appendSlice(alloc, tokens.items[i].name);
    }

    // Free the duped keys
    for (tokens.items) |tok| {
        // Check if this key is in the top_n; if not, free it; if yes, it'll be freed when label is freed
        // Actually, all keys were duped so we need to free them all. The label uses a separate copy.
        _ = tok;
    }
    const label = try alloc.dupe(u8, label_buf.items);

    // Free all frequency map keys
    var kit = freq.keyIterator();
    while (kit.next()) |key_ptr| {
        alloc.free(key_ptr.*);
    }

    if (label.len == 0) {
        alloc.free(label);
        return try alloc.dupe(u8, "unnamed");
    }
    return label;
}

fn toLower(s: []const u8, buf: *[256]u8) []const u8 {
    const len = @min(s.len, 256);
    for (0..len) |i| {
        buf[i] = std.ascii.toLower(s[i]);
    }
    return buf[0..len];
}

/// Format clusters as TOON. Caller owns returned slice.
pub fn formatClusters(alloc: Allocator, result: ClusterResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    // Summary header
    try buf.print(alloc, "clusters[{d}]{{id,label,size}}:\n", .{result.clusters.len});
    for (result.clusters) |cluster| {
        try buf.print(alloc, "{d},{s},{d}\n", .{ cluster.id, cluster.label, cluster.members.len });
    }

    // Detail sections per cluster
    for (result.clusters) |cluster| {
        try buf.print(alloc, "\ncluster_{d}[{d}]{{name,kind,file,line}}:\n", .{ cluster.id, cluster.members.len });
        for (cluster.members) |member| {
            const kind_str = switch (member.kind) {
                .function => "fn",
                .type_def => "type",
                .import_decl => "import",
            };
            try buf.print(alloc, "{s},{s},{s},{d}\n", .{
                member.name,
                kind_str,
                member.file_path,
                member.line_number,
            });
        }
    }

    return buf.toOwnedSlice(alloc);
}

// -- tests --

fn makeTestEntry(alloc: Allocator, name: []const u8, signature: []const u8, file_path: []const u8, kind: parser.CodeUnitKind) !brain_mod.BrainEntry {
    const unit = parser.CodeUnit{
        .kind = kind,
        .name = name,
        .signature = signature,
        .file_path = file_path,
        .line_number = 1,
        .module_name = "test",
    };
    const vec = try encoder.encodeUnit(alloc, unit);
    return .{ .unit = unit, .vector = vec };
}

test "cluster related units together" {
    const alloc = std.testing.allocator;

    // Create 3 auth-related and 3 db-related entries with very distinct vocabularies
    var entries = [_]brain_mod.BrainEntry{
        try makeTestEntry(alloc, "handleAuth", "pub fn handleAuth(req: AuthRequest) !AuthResponse", "src/auth.zig", .function),
        try makeTestEntry(alloc, "validateAuth", "pub fn validateAuth(token: AuthToken) !AuthResult", "src/auth.zig", .function),
        try makeTestEntry(alloc, "AuthError", "pub const AuthError = enum { invalid_auth, expired_auth }", "src/auth.zig", .type_def),
        try makeTestEntry(alloc, "queryDatabase", "pub fn queryDatabase(sql: DatabaseQuery) !DatabaseResult", "src/database.zig", .function),
        try makeTestEntry(alloc, "connectDatabase", "pub fn connectDatabase(url: DatabaseUrl) !DatabaseConnection", "src/database.zig", .function),
        try makeTestEntry(alloc, "DatabasePool", "pub const DatabasePool = struct { connections: []DatabaseConnection, database_size: usize }", "src/database.zig", .type_def),
    };

    // Use a moderate threshold — within-group similarity should be higher than between-group
    const result = try clusterUnits(alloc, &entries, 0.15, 2);
    defer freeResult(alloc, result);

    // Should produce clusters (at least 1, ideally 2)
    try std.testing.expect(result.clusters.len >= 1);

    // Verify each cluster has at least min_cluster_size members
    for (result.clusters) |cluster| {
        try std.testing.expect(cluster.members.len >= 2);
        try std.testing.expect(cluster.label.len > 0);
        try std.testing.expect(!cluster.centroid.isZero());
    }

    // Total members across all clusters + unclustered should equal total entries
    var total_clustered: usize = 0;
    for (result.clusters) |cluster| {
        total_clustered += cluster.members.len;
    }
    try std.testing.expectEqual(@as(usize, 6), total_clustered + result.unclustered_count);
}

test "threshold 1.0 produces no valid clusters" {
    const alloc = std.testing.allocator;

    var entries = [_]brain_mod.BrainEntry{
        try makeTestEntry(alloc, "handleAuth", "pub fn handleAuth(req: Request) !Response", "src/auth.zig", .function),
        try makeTestEntry(alloc, "queryDb", "pub fn queryDb(sql: []const u8) !Result", "src/db.zig", .function),
        try makeTestEntry(alloc, "parseConfig", "pub fn parseConfig(path: []const u8) !Config", "src/config.zig", .function),
    };

    // Threshold of 1.0 means only identical vectors connect
    const result = try clusterUnits(alloc, &entries, 1.0, 2);
    defer freeResult(alloc, result);

    try std.testing.expectEqual(@as(usize, 0), result.clusters.len);
    try std.testing.expectEqual(@as(usize, 3), result.unclustered_count);
}

test "threshold 0.0 puts everything in one cluster" {
    const alloc = std.testing.allocator;

    var entries = [_]brain_mod.BrainEntry{
        try makeTestEntry(alloc, "handleAuth", "pub fn handleAuth(req: Request) !Response", "src/auth.zig", .function),
        try makeTestEntry(alloc, "queryDb", "pub fn queryDb(sql: []const u8) !Result", "src/db.zig", .function),
        try makeTestEntry(alloc, "parseConfig", "pub fn parseConfig(path: []const u8) !Config", "src/config.zig", .function),
    };

    // Threshold of 0.0 connects everything (similarity >= 0.0 is always true for non-inverse vectors)
    const result = try clusterUnits(alloc, &entries, 0.0, 2);
    defer freeResult(alloc, result);

    // Everything should be in a single cluster
    try std.testing.expectEqual(@as(usize, 1), result.clusters.len);
    try std.testing.expectEqual(@as(usize, 3), result.clusters[0].members.len);
    try std.testing.expectEqual(@as(usize, 0), result.unclustered_count);
}

test "label generation picks common sub-tokens" {
    const alloc = std.testing.allocator;

    var entries = [_]brain_mod.BrainEntry{
        try makeTestEntry(alloc, "handleAuth", "pub fn handleAuth(req: Request) !Response", "src/auth.zig", .function),
        try makeTestEntry(alloc, "validateAuth", "pub fn validateAuth(token: Token) !bool", "src/auth.zig", .function),
        try makeTestEntry(alloc, "refreshAuth", "pub fn refreshAuth(session: Session) !Token", "src/auth.zig", .function),
    };

    // Use threshold 0.0 to force all into one cluster
    const result = try clusterUnits(alloc, &entries, 0.0, 2);
    defer freeResult(alloc, result);

    try std.testing.expectEqual(@as(usize, 1), result.clusters.len);
    // "auth" should appear in the label since it's common to all three names
    try std.testing.expect(std.mem.indexOf(u8, result.clusters[0].label, "auth") != null);
}

test "formatClusters produces valid TOON" {
    const alloc = std.testing.allocator;

    var entries = [_]brain_mod.BrainEntry{
        try makeTestEntry(alloc, "handleAuth", "pub fn handleAuth(req: Request) !Response", "src/auth.zig", .function),
        try makeTestEntry(alloc, "validateAuth", "pub fn validateAuth(token: Token) !bool", "src/auth.zig", .function),
        try makeTestEntry(alloc, "refreshAuth", "pub fn refreshAuth(session: Session) !Token", "src/auth.zig", .function),
    };

    const result = try clusterUnits(alloc, &entries, 0.0, 2);
    defer freeResult(alloc, result);

    const output = try formatClusters(alloc, result);
    defer alloc.free(output);

    // Should start with clusters header
    try std.testing.expect(std.mem.startsWith(u8, output, "clusters["));
    // Should contain cluster detail sections
    try std.testing.expect(std.mem.indexOf(u8, output, "cluster_0[") != null);
    // Should contain member info
    try std.testing.expect(std.mem.indexOf(u8, output, "handleAuth") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "fn") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "src/auth.zig") != null);
}

test "empty entries produces empty result" {
    const alloc = std.testing.allocator;
    const entries: []const brain_mod.BrainEntry = &.{};
    const result = try clusterUnits(alloc, entries, 0.15, 2);
    defer freeResult(alloc, result);

    try std.testing.expectEqual(@as(usize, 0), result.clusters.len);
    try std.testing.expectEqual(@as(usize, 0), result.unclustered_count);
}

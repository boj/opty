const std = @import("std");
const httpz = @import("httpz");
const brain_mod = @import("brain.zig");
const encoder = @import("encoder.zig");
const parser = @import("parser.zig");
const toon = @import("toon.zig");
const ignore = @import("ignore.zig");
const mcp = @import("mcp.zig");
const Brain = brain_mod.Brain;
const Allocator = std.mem.Allocator;

const DEFAULT_PORT: u16 = 7390;
const WATCH_INTERVAL_NS: u64 = 500 * std.time.ns_per_ms;

const HttpServer = httpz.Server(*DaemonState);

pub const DaemonState = struct {
    brain: Brain,
    root_dir: []const u8,
    allocator: Allocator,
    file_mtimes: std.StringHashMap(i128),
    running: bool = true,
    port: u16 = DEFAULT_PORT,
    http_server: ?*anyopaque = null,

    pub fn init(allocator: Allocator, root_dir: []const u8) DaemonState {
        return .{
            .brain = Brain.init(allocator),
            .root_dir = root_dir,
            .allocator = allocator,
            .file_mtimes = std.StringHashMap(i128).init(allocator),
        };
    }

    pub fn deinit(self: *DaemonState) void {
        var it = self.file_mtimes.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.file_mtimes.deinit();
        self.brain.deinit();
    }
};

pub fn run(allocator: Allocator, root_dir: []const u8, port: u16) !void {
    var state = DaemonState.init(allocator, root_dir);
    defer state.deinit();
    state.port = port;

    const stderr = std.fs.File.stderr();
    var msg_buf: [256]u8 = undefined;

    var msg = try std.fmt.bufPrint(&msg_buf, "opty daemon starting on http://127.0.0.1:{d}\n", .{port});
    _ = try stderr.write(msg);
    msg = try std.fmt.bufPrint(&msg_buf, "indexing {s}...\n", .{root_dir});
    _ = try stderr.write(msg);

    try scanAndIndex(&state);

    msg = try std.fmt.bufPrint(&msg_buf, "indexed {d} code units across {d} files\n", .{
        state.brain.unitCount(),
        state.brain.fileCount(),
    });
    _ = try stderr.write(msg);

    const watch_thread = try std.Thread.spawn(.{}, watchLoop, .{&state});
    defer watch_thread.join();

    var server = try HttpServer.init(allocator, .{
        .address = .{ .addr = .initIp4(.{ 127, 0, 0, 1 }, port) },
        .thread_pool = .{ .count = 4 },
        .request = .{ .max_body_size = 65536 },
    }, &state);
    defer server.deinit();
    state.http_server = @ptrCast(&server);

    var router = try server.router(.{});
    router.post("/query", handleQueryRoute, .{});
    router.get("/status", handleStatusRoute, .{});
    router.post("/reindex", handleReindexRoute, .{});
    router.post("/shutdown", handleShutdownRoute, .{});
    router.post("/mcp", handleMcpRoute, .{});

    try server.listen();
}

// --- HTTP Route Handlers ---

fn handleQueryRoute(state: *DaemonState, req: *httpz.Request, res: *httpz.Response) !void {
    const json_body = req.body() orelse {
        res.status = 400;
        res.body = "Missing request body";
        return;
    };

    const parsed = std.json.parseFromSlice(std.json.Value, state.allocator, json_body, .{}) catch {
        res.status = 400;
        res.body = "Invalid JSON";
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    const query_text = jStr(root, "query") orelse {
        res.status = 400;
        res.body = "Missing 'query' field";
        return;
    };

    state.brain.mutex.lock();
    defer state.brain.mutex.unlock();

    const query_vec = try encoder.encodeQuery(state.allocator, query_text);
    const results = try state.brain.query(state.allocator, query_vec, 20);
    defer state.allocator.free(results);

    if (results.len == 0) {
        res.body = "# no matching code units found\n";
        return;
    }

    const output = try toon.formatResults(state.allocator, results, .signatures);
    defer state.allocator.free(output);
    res.body = try std.fmt.allocPrint(res.arena, "{s}", .{output});
}

fn handleStatusRoute(state: *DaemonState, _: *httpz.Request, res: *httpz.Response) !void {
    state.brain.mutex.lock();
    defer state.brain.mutex.unlock();
    res.body = try std.fmt.allocPrint(res.arena, "OK watching {s}: {d} units, {d} files, {d} bytes memory\n", .{
        state.root_dir,
        state.brain.unitCount(),
        state.brain.fileCount(),
        state.brain.entries.items.len * @sizeOf(brain_mod.BrainEntry),
    });
}

fn handleReindexRoute(state: *DaemonState, _: *httpz.Request, res: *httpz.Response) !void {
    state.brain.mutex.lock();
    defer state.brain.mutex.unlock();
    scanAndIndex(state) catch {};
    res.body = try std.fmt.allocPrint(res.arena, "OK reindexed: {d} units, {d} files\n", .{
        state.brain.unitCount(),
        state.brain.fileCount(),
    });
}

fn handleShutdownRoute(state: *DaemonState, _: *httpz.Request, res: *httpz.Response) !void {
    state.running = false;
    res.body = "OK shutting down\n";
    if (state.http_server) |server_ptr| {
        const server: *HttpServer = @ptrCast(@alignCast(server_ptr));
        server.stop();
    }
}

fn handleMcpRoute(state: *DaemonState, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        res.status = 400;
        res.body = "Missing request body";
        return;
    };

    res.content_type = .JSON;
    const response = mcp.handleHttpRequest(state.allocator, body, &state.brain, &state.file_mtimes, state.root_dir) catch {
        res.status = 500;
        res.body = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}";
        return;
    };

    if (response) |resp| {
        defer state.allocator.free(resp);
        res.body = try std.fmt.allocPrint(res.arena, "{s}", .{resp});
    } else {
        res.status = 204;
    }
}

// --- JSON helper ---

fn jStr(val: std.json.Value, key: []const u8) ?[]const u8 {
    if (val != .object) return null;
    const v = val.object.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

// --- Watch loop ---

fn watchLoop(state: *DaemonState) void {
    while (state.running) {
        std.Thread.sleep(WATCH_INTERVAL_NS);
        state.brain.mutex.lock();
        defer state.brain.mutex.unlock();
        scanAndIndex(state) catch |err| {
            std.log.err("watch scan error: {}", .{err});
        };
    }
}

// --- File scanning ---

fn scanAndIndex(state: *DaemonState) !void {
    var dir = std.fs.cwd().openDir(state.root_dir, .{ .iterate = true }) catch |err| {
        std.log.err("cannot open {s}: {}", .{ state.root_dir, err });
        return;
    };
    defer dir.close();

    var filter = ignore.IgnoreFilter.init(state.allocator, state.root_dir);
    defer filter.deinit();

    var walker = try dir.walk(state.allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (filter.shouldIgnore(entry.path)) continue;

        const lang = parser.Language.fromExtension(entry.path);
        if (!lang.isSupported()) continue;

        const full_path = try std.fs.path.join(state.allocator, &.{ state.root_dir, entry.path });
        defer state.allocator.free(full_path);

        const stat = dir.statFile(entry.path) catch continue;
        const mtime = stat.mtime;

        if (state.file_mtimes.get(full_path)) |prev_mtime| {
            if (prev_mtime == mtime) continue;
        }

        const source = dir.readFileAlloc(state.allocator, entry.path, 10 * 1024 * 1024) catch continue;
        defer state.allocator.free(source);

        state.brain.indexFile(full_path, source) catch |err| {
            std.log.err("index error {s}: {}", .{ full_path, err });
            continue;
        };

        const owned_path = try state.allocator.dupe(u8, full_path);
        const result = try state.file_mtimes.getOrPut(owned_path);
        if (result.found_existing) {
            state.allocator.free(owned_path);
        }
        result.value_ptr.* = mtime;
    }
}

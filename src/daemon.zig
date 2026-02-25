const std = @import("std");
const brain_mod = @import("brain.zig");
const encoder = @import("encoder.zig");
const parser = @import("parser.zig");
const toon = @import("toon.zig");
const Brain = brain_mod.Brain;
const Allocator = std.mem.Allocator;

const DEFAULT_PORT: u16 = 7390;
const WATCH_INTERVAL_NS: u64 = 500 * std.time.ns_per_ms;
const MAX_REQUEST_SIZE: usize = 8192;

pub const DaemonState = struct {
    brain: Brain,
    root_dir: []const u8,
    allocator: Allocator,
    file_mtimes: std.StringHashMap(i128),
    running: bool = true,
    port: u16 = DEFAULT_PORT,

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

    var msg = try std.fmt.bufPrint(&msg_buf, "opty daemon starting on 127.0.0.1:{d}\n", .{port});
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

    try serveLoop(&state);
}

fn serveLoop(state: *DaemonState) !void {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, state.port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    while (state.running) {
        const conn = server.accept() catch |err| {
            if (err == error.WouldBlock) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        defer conn.stream.close();
        handleClient(state, conn.stream) catch |err| {
            std.log.err("client error: {}", .{err});
        };
    }
}

fn handleClient(state: *DaemonState, stream: std.net.Stream) !void {
    var buf: [MAX_REQUEST_SIZE]u8 = undefined;
    const n = stream.read(&buf) catch return;
    if (n == 0) return;

    const request = std.mem.trim(u8, buf[0..n], " \t\r\n");

    if (std.mem.startsWith(u8, request, "QUERY ")) {
        const payload = request[6..];
        // Strip CWD prefix if tab-separated (sent by global-aware clients)
        const query_text = if (std.mem.indexOfScalar(u8, payload, '\t')) |tab_pos|
            payload[tab_pos + 1 ..]
        else
            payload;
        try handleQuery(state, stream, query_text);
    } else if (std.mem.startsWith(u8, request, "STATUS")) {
        try handleStatus(state, stream);
    } else if (std.mem.startsWith(u8, request, "REINDEX")) {
        state.brain.mutex.lock();
        defer state.brain.mutex.unlock();
        try scanAndIndex(state);
        var resp_buf: [256]u8 = undefined;
        const resp = try std.fmt.bufPrint(&resp_buf, "OK reindexed: {d} units, {d} files\n", .{
            state.brain.unitCount(),
            state.brain.fileCount(),
        });
        try stream.writeAll(resp);
    } else if (std.mem.startsWith(u8, request, "SHUTDOWN")) {
        state.running = false;
        try stream.writeAll("OK shutting down\n");
    } else {
        try stream.writeAll("ERR unknown command\n");
    }
}

fn handleQuery(state: *DaemonState, stream: std.net.Stream, query_text: []const u8) !void {
    state.brain.mutex.lock();
    defer state.brain.mutex.unlock();

    const query_vec = try encoder.encodeQuery(state.allocator, query_text);
    const results = try state.brain.query(state.allocator, query_vec, 20);
    defer state.allocator.free(results);

    if (results.len == 0) {
        try stream.writeAll("# no matching code units found\n");
        return;
    }

    const output = try toon.formatResults(state.allocator, results, .signatures);
    defer state.allocator.free(output);
    try stream.writeAll(output);
}

fn handleStatus(state: *DaemonState, stream: std.net.Stream) !void {
    state.brain.mutex.lock();
    defer state.brain.mutex.unlock();
    var resp_buf: [512]u8 = undefined;
    const resp = try std.fmt.bufPrint(&resp_buf, "OK watching {s}: {d} units, {d} files, {d} bytes memory\n", .{
        state.root_dir,
        state.brain.unitCount(),
        state.brain.fileCount(),
        state.brain.entries.items.len * @sizeOf(brain_mod.BrainEntry),
    });
    try stream.writeAll(resp);
}

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

fn scanAndIndex(state: *DaemonState) !void {
    var dir = std.fs.cwd().openDir(state.root_dir, .{ .iterate = true }) catch |err| {
        std.log.err("cannot open {s}: {}", .{ state.root_dir, err });
        return;
    };
    defer dir.close();

    var walker = try dir.walk(state.allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

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

const std = @import("std");
const brain_mod = @import("brain.zig");
const encoder = @import("encoder.zig");
const parser = @import("parser.zig");
const toon = @import("toon.zig");
const Brain = brain_mod.Brain;
const Allocator = std.mem.Allocator;

const WATCH_INTERVAL_NS: u64 = 2 * std.time.ns_per_s;
const MAX_REQUEST_SIZE: usize = 8192;

const PROJECT_MARKERS = [_][]const u8{
    ".git",
    "build.zig",
    "Cargo.toml",
    "package.json",
    "go.mod",
    "pyproject.toml",
    "Makefile",
    "CMakeLists.txt",
    ".sln",
    "Gemfile",
    "pom.xml",
    "build.gradle",
};

pub const ProjectState = struct {
    brain: Brain,
    file_mtimes: std.StringHashMap(i128),
    root_dir: []const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, root_dir: []const u8) !ProjectState {
        return .{
            .brain = Brain.init(allocator),
            .file_mtimes = std.StringHashMap(i128).init(allocator),
            .root_dir = try allocator.dupe(u8, root_dir),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ProjectState) void {
        var it = self.file_mtimes.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.file_mtimes.deinit();
        self.brain.deinit();
        self.allocator.free(self.root_dir);
    }
};

pub const GlobalState = struct {
    projects: std.StringHashMap(*ProjectState),
    allocator: Allocator,
    running: bool = true,
    port: u16,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: Allocator, port: u16) GlobalState {
        return .{
            .projects = std.StringHashMap(*ProjectState).init(allocator),
            .allocator = allocator,
            .port = port,
        };
    }

    pub fn deinit(self: *GlobalState) void {
        var it = self.projects.iterator();
        while (it.next()) |entry| {
            var project = entry.value_ptr.*;
            project.deinit();
            self.allocator.destroy(project);
            self.allocator.free(entry.key_ptr.*);
        }
        self.projects.deinit();
    }

    /// Get existing project or auto-load by detecting root from CWD.
    pub fn getOrCreateProject(self: *GlobalState, cwd: []const u8) !*ProjectState {
        const root = try detectProjectRoot(self.allocator, cwd);
        defer self.allocator.free(root);

        if (self.projects.get(root)) |project| return project;

        const project = try self.allocator.create(ProjectState);
        project.* = try ProjectState.init(self.allocator, root);

        const stderr = std.fs.File.stderr();
        var msg_buf: [512]u8 = undefined;
        var msg = std.fmt.bufPrint(&msg_buf, "auto-loading project: {s}\n", .{root}) catch "";
        stderr.writeAll(msg) catch {};

        scanAndIndex(self.allocator, &project.brain, &project.file_mtimes, project.root_dir) catch |err| {
            std.log.err("index error for {s}: {}", .{ root, err });
        };

        msg = std.fmt.bufPrint(&msg_buf, "  indexed {d} units across {d} files\n", .{
            project.brain.unitCount(), project.brain.fileCount(),
        }) catch "";
        stderr.writeAll(msg) catch {};

        const owned_key = try self.allocator.dupe(u8, root);
        try self.projects.put(owned_key, project);
        return project;
    }
};

pub fn run(allocator: Allocator, port: u16) !void {
    var state = GlobalState.init(allocator, port);
    defer state.deinit();

    const stderr = std.fs.File.stderr();
    var msg_buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "opty global daemon on 127.0.0.1:{d} (auto-loading projects)\n", .{port});
    try stderr.writeAll(msg);

    const watch_thread = try std.Thread.spawn(.{}, watchLoop, .{&state});
    defer watch_thread.join();

    try serveLoop(&state);
}

fn serveLoop(state: *GlobalState) !void {
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

fn handleClient(state: *GlobalState, stream: std.net.Stream) !void {
    var buf: [MAX_REQUEST_SIZE]u8 = undefined;
    const n = stream.read(&buf) catch return;
    if (n == 0) return;
    const request = std.mem.trim(u8, buf[0..n], " \t\r\n");

    if (std.mem.startsWith(u8, request, "QUERY ")) {
        const payload = request[6..];
        if (std.mem.indexOfScalar(u8, payload, '\t')) |tab_pos| {
            const cwd = payload[0..tab_pos];
            const query_text = payload[tab_pos + 1 ..];
            try handleQuery(state, stream, cwd, query_text);
        } else {
            try stream.writeAll("ERR: QUERY requires CWD\\ttext format\n");
        }
    } else if (std.mem.startsWith(u8, request, "STATUS")) {
        if (request.len > 7) {
            const cwd = std.mem.trim(u8, request[6..], " ");
            try handleProjectStatus(state, stream, cwd);
        } else {
            try handleGlobalStatus(state, stream);
        }
    } else if (std.mem.startsWith(u8, request, "REINDEX")) {
        if (request.len > 8) {
            const cwd = std.mem.trim(u8, request[7..], " ");
            try handleReindex(state, stream, cwd);
        } else {
            try handleReindexAll(state, stream);
        }
    } else if (std.mem.eql(u8, request, "SHUTDOWN")) {
        state.running = false;
        try stream.writeAll("OK shutting down\n");
    } else {
        try stream.writeAll("ERR unknown command\n");
    }
}

fn handleQuery(state: *GlobalState, stream: std.net.Stream, cwd: []const u8, query_text: []const u8) !void {
    state.mutex.lock();
    defer state.mutex.unlock();

    const project = try state.getOrCreateProject(cwd);
    const query_vec = try encoder.encodeQuery(state.allocator, query_text);
    const results = try project.brain.query(state.allocator, query_vec, 20);
    defer state.allocator.free(results);

    if (results.len == 0) {
        try stream.writeAll("# no matching code units found\n");
        return;
    }

    const output = try toon.formatResults(state.allocator, results, .signatures);
    defer state.allocator.free(output);
    try stream.writeAll(output);
}

fn handleGlobalStatus(state: *GlobalState, stream: std.net.Stream) !void {
    state.mutex.lock();
    defer state.mutex.unlock();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(state.allocator);

    try buf.print(state.allocator, "opty global: {d} projects loaded\n", .{state.projects.count()});
    var it = state.projects.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr.*;
        try buf.print(state.allocator, "  {s}: {d} units, {d} files\n", .{
            p.root_dir, p.brain.unitCount(), p.brain.fileCount(),
        });
    }
    try stream.writeAll(buf.items);
}

fn handleProjectStatus(state: *GlobalState, stream: std.net.Stream, cwd: []const u8) !void {
    state.mutex.lock();
    defer state.mutex.unlock();

    const root = detectProjectRoot(state.allocator, cwd) catch {
        try stream.writeAll("ERR: cannot detect project root\n");
        return;
    };
    defer state.allocator.free(root);

    if (state.projects.get(root)) |project| {
        var resp_buf: [512]u8 = undefined;
        const resp = try std.fmt.bufPrint(&resp_buf, "OK {s}: {d} units, {d} files\n", .{
            project.root_dir, project.brain.unitCount(), project.brain.fileCount(),
        });
        try stream.writeAll(resp);
    } else {
        try stream.writeAll("OK project not yet loaded (will auto-load on first query)\n");
    }
}

fn handleReindex(state: *GlobalState, stream: std.net.Stream, cwd: []const u8) !void {
    state.mutex.lock();
    defer state.mutex.unlock();

    const project = state.getOrCreateProject(cwd) catch {
        try stream.writeAll("ERR: cannot load project\n");
        return;
    };

    // Clear mtimes to force full rescan
    var mtime_it = project.file_mtimes.iterator();
    while (mtime_it.next()) |entry| state.allocator.free(entry.key_ptr.*);
    project.file_mtimes.clearAndFree();

    for (project.brain.entries.items) |entry| {
        state.allocator.free(entry.unit.name);
        state.allocator.free(entry.unit.signature);
        state.allocator.free(entry.unit.file_path);
        state.allocator.free(entry.unit.module_name);
    }
    project.brain.entries.clearRetainingCapacity();

    scanAndIndex(state.allocator, &project.brain, &project.file_mtimes, project.root_dir) catch {};

    var resp_buf: [256]u8 = undefined;
    const resp = try std.fmt.bufPrint(&resp_buf, "OK reindexed {s}: {d} units, {d} files\n", .{
        project.root_dir, project.brain.unitCount(), project.brain.fileCount(),
    });
    try stream.writeAll(resp);
}

fn handleReindexAll(state: *GlobalState, stream: std.net.Stream) !void {
    state.mutex.lock();
    defer state.mutex.unlock();

    var it = state.projects.iterator();
    while (it.next()) |entry| {
        const project = entry.value_ptr.*;
        scanAndIndex(state.allocator, &project.brain, &project.file_mtimes, project.root_dir) catch {};
    }

    var resp_buf: [256]u8 = undefined;
    const resp = try std.fmt.bufPrint(&resp_buf, "OK reindexed {d} projects\n", .{state.projects.count()});
    try stream.writeAll(resp);
}

fn watchLoop(state: *GlobalState) void {
    while (state.running) {
        std.Thread.sleep(WATCH_INTERVAL_NS);
        state.mutex.lock();
        defer state.mutex.unlock();

        var it = state.projects.iterator();
        while (it.next()) |entry| {
            const project = entry.value_ptr.*;
            scanAndIndex(state.allocator, &project.brain, &project.file_mtimes, project.root_dir) catch |err| {
                std.log.err("watch error for {s}: {}", .{ project.root_dir, err });
            };
        }
    }
}

// --- Project root detection ---

fn hasMarker(dir: std.fs.Dir, name: []const u8) bool {
    _ = dir.statFile(name) catch {
        var sub = dir.openDir(name, .{}) catch return false;
        sub.close();
        return true;
    };
    return true;
}

/// Walk up from CWD to find the nearest directory containing a project marker.
pub fn detectProjectRoot(alloc: Allocator, cwd: []const u8) ![]const u8 {
    var current: []const u8 = cwd;
    while (true) {
        var dir = std.fs.cwd().openDir(current, .{}) catch break;
        defer dir.close();
        for (PROJECT_MARKERS) |marker| {
            if (hasMarker(dir, marker)) return try alloc.dupe(u8, current);
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }
    return try alloc.dupe(u8, cwd);
}

// --- File scanning ---

fn scanAndIndex(alloc: Allocator, brain: *Brain, file_mtimes: *std.StringHashMap(i128), root_dir: []const u8) !void {
    var dir = std.fs.cwd().openDir(root_dir, .{ .iterate = true }) catch |err| {
        std.log.err("cannot open {s}: {}", .{ root_dir, err });
        return;
    };
    defer dir.close();

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const lang = parser.Language.fromExtension(entry.path);
        if (!lang.isSupported()) continue;

        const full_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root_dir, entry.path });
        defer alloc.free(full_path);

        const stat = dir.statFile(entry.path) catch continue;
        const mtime = stat.mtime;

        if (file_mtimes.get(full_path)) |prev_mtime| {
            if (prev_mtime == mtime) continue;
        }

        const source = dir.readFileAlloc(alloc, entry.path, 10 * 1024 * 1024) catch continue;
        defer alloc.free(source);

        brain.indexFile(full_path, source) catch |err| {
            std.log.err("index error {s}: {}", .{ full_path, err });
            continue;
        };

        const owned_path = try alloc.dupe(u8, full_path);
        const result = try file_mtimes.getOrPut(owned_path);
        if (result.found_existing) alloc.free(owned_path);
        result.value_ptr.* = mtime;
    }
}

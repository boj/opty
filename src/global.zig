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

const WATCH_INTERVAL_NS: u64 = 2 * std.time.ns_per_s;

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

const HttpServer = httpz.Server(*GlobalState);

pub const GlobalState = struct {
    projects: std.StringHashMap(*ProjectState),
    allocator: Allocator,
    running: bool = true,
    port: u16,
    mutex: std.Thread.Mutex = .{},
    http_server: ?*anyopaque = null,

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
    const msg = try std.fmt.bufPrint(&msg_buf, "opty global daemon on http://127.0.0.1:{d} (auto-loading projects)\n", .{port});
    try stderr.writeAll(msg);

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

fn handleQueryRoute(state: *GlobalState, req: *httpz.Request, res: *httpz.Response) !void {
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
    const cwd = jStr(root, "cwd") orelse {
        res.status = 400;
        res.body = "Missing 'cwd' field";
        return;
    };
    const query_text = jStr(root, "query") orelse {
        res.status = 400;
        res.body = "Missing 'query' field";
        return;
    };

    state.mutex.lock();
    defer state.mutex.unlock();

    const project = state.getOrCreateProject(cwd) catch {
        res.status = 500;
        res.body = "ERR: cannot load project";
        return;
    };
    const query_vec = try encoder.encodeQuery(state.allocator, query_text);
    const results = try project.brain.query(state.allocator, query_vec, 20);
    defer state.allocator.free(results);

    if (results.len == 0) {
        res.body = "# no matching code units found\n";
        return;
    }

    const output = try toon.formatResults(state.allocator, results, .signatures);
    defer state.allocator.free(output);
    res.body = try std.fmt.allocPrint(res.arena, "{s}", .{output});
}

fn handleStatusRoute(state: *GlobalState, req: *httpz.Request, res: *httpz.Response) !void {
    // Check for ?cwd= query parameter
    const qs = try req.query();
    const cwd = qs.get("cwd");

    state.mutex.lock();
    defer state.mutex.unlock();

    if (cwd) |c| {
        // Project-specific status
        const root = detectProjectRoot(state.allocator, c) catch {
            res.status = 500;
            res.body = "ERR: cannot detect project root";
            return;
        };
        defer state.allocator.free(root);

        if (state.projects.get(root)) |project| {
            res.body = try std.fmt.allocPrint(res.arena, "OK {s}: {d} units, {d} files\n", .{
                project.root_dir, project.brain.unitCount(), project.brain.fileCount(),
            });
        } else {
            res.body = "OK project not yet loaded (will auto-load on first query)\n";
        }
    } else {
        // Global status
        var buf: std.ArrayList(u8) = .empty;
        try buf.print(res.arena, "opty global: {d} projects loaded\n", .{state.projects.count()});
        var it = state.projects.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr.*;
            try buf.print(res.arena, "  {s}: {d} units, {d} files\n", .{
                p.root_dir, p.brain.unitCount(), p.brain.fileCount(),
            });
        }
        res.body = buf.items;
    }
}

fn handleReindexRoute(state: *GlobalState, req: *httpz.Request, res: *httpz.Response) !void {
    const json_body = req.body();

    state.mutex.lock();
    defer state.mutex.unlock();

    if (json_body) |body| {
        const parsed = std.json.parseFromSlice(std.json.Value, state.allocator, body, .{}) catch {
            // No valid JSON body — reindex all
            return reindexAll(state, res);
        };
        defer parsed.deinit();

        if (jStr(parsed.value, "cwd")) |cwd| {
            const project = state.getOrCreateProject(cwd) catch {
                res.status = 500;
                res.body = "ERR: cannot load project";
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

            res.body = try std.fmt.allocPrint(res.arena, "OK reindexed {s}: {d} units, {d} files\n", .{
                project.root_dir, project.brain.unitCount(), project.brain.fileCount(),
            });
            return;
        }
    }

    return reindexAll(state, res);
}

fn reindexAll(state: *GlobalState, res: *httpz.Response) !void {
    var it = state.projects.iterator();
    while (it.next()) |entry| {
        const project = entry.value_ptr.*;
        scanAndIndex(state.allocator, &project.brain, &project.file_mtimes, project.root_dir) catch {};
    }

    res.body = try std.fmt.allocPrint(res.arena, "OK reindexed {d} projects\n", .{state.projects.count()});
}

fn handleShutdownRoute(state: *GlobalState, _: *httpz.Request, res: *httpz.Response) !void {
    state.running = false;
    res.body = "OK shutting down\n";
    if (state.http_server) |server_ptr| {
        const server: *HttpServer = @ptrCast(@alignCast(server_ptr));
        server.stop();
    }
}

fn handleMcpRoute(state: *GlobalState, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        res.status = 400;
        res.body = "Missing request body";
        return;
    };

    res.content_type = .JSON;

    // Try to extract cwd from tools/call arguments for project routing
    const maybe_cwd = mcp.extractCwdFromRequest(state.allocator, body);
    defer if (maybe_cwd) |c| state.allocator.free(c);

    state.mutex.lock();
    defer state.mutex.unlock();

    if (maybe_cwd) |cwd| {
        // Route to specific project
        const project = state.getOrCreateProject(cwd) catch {
            res.status = 500;
            res.body = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Cannot load project\"}}";
            return;
        };
        const response = mcp.handleHttpRequest(state.allocator, body, &project.brain, &project.file_mtimes, project.root_dir) catch {
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
    } else {
        // Non-tool-call methods (initialize, tools/list, ping, etc.) don't need project context.
        // Use a temporary empty brain for dispatch.
        var dummy_brain = brain_mod.Brain.init(state.allocator);
        defer dummy_brain.deinit();
        var dummy_mtimes = std.StringHashMap(i128).init(state.allocator);
        defer dummy_mtimes.deinit();

        const response = mcp.handleHttpRequest(state.allocator, body, &dummy_brain, &dummy_mtimes, ".") catch {
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
}

// --- JSON helper ---

fn jStr(val: std.json.Value, key: []const u8) ?[]const u8 {
    if (val != .object) return null;
    const v = val.object.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

// --- Watch loop ---

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

    var filter = ignore.IgnoreFilter.init(alloc, root_dir);
    defer filter.deinit();

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (filter.shouldIgnore(entry.path)) continue;
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

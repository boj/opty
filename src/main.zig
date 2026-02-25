const std = @import("std");
const daemon = @import("daemon.zig");
const global = @import("global.zig");
const mcp = @import("mcp.zig");
const encoder = @import("encoder.zig");
const brain_mod = @import("brain.zig");
const toon = @import("toon.zig");
const parser = @import("parser.zig");
const posix = std.posix;

const DEFAULT_PORT: u16 = 7390;
const VERSION = "0.1.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd = args[1];
    const port = parsePort(args);

    if (std.mem.eql(u8, cmd, "daemon") or std.mem.eql(u8, cmd, "start")) {
        const root = if (args.len > 2 and !std.mem.startsWith(u8, args[2], "-")) args[2] else ".";
        try daemon.run(alloc, root, port);
    } else if (std.mem.eql(u8, cmd, "global")) {
        try global.run(alloc, port);
    } else if (std.mem.eql(u8, cmd, "query")) {
        if (args.len < 3) {
            std.debug.print("usage: opty query <text>\n", .{});
            return;
        }
        const query_text = try joinArgs(alloc, args[2..]);
        defer alloc.free(query_text);
        try sendCommand(alloc, port, query_text, "QUERY ");
    } else if (std.mem.eql(u8, cmd, "status")) {
        try sendCommand(alloc, port, "", "STATUS");
    } else if (std.mem.eql(u8, cmd, "stop")) {
        try sendCommand(alloc, port, "", "SHUTDOWN");
    } else if (std.mem.eql(u8, cmd, "reindex")) {
        try sendCommand(alloc, port, "", "REINDEX");
    } else if (std.mem.eql(u8, cmd, "mcp")) {
        const root = if (args.len > 2 and !std.mem.startsWith(u8, args[2], "-")) args[2] else ".";
        try mcp.run(alloc, root);
    } else if (std.mem.eql(u8, cmd, "mcp-client")) {
        const root = if (args.len > 2 and !std.mem.startsWith(u8, args[2], "-")) args[2] else getCwd();
        try mcp.runClient(alloc, root, port);
    } else if (std.mem.eql(u8, cmd, "oneshot")) {
        if (args.len < 3) {
            std.debug.print("usage: opty oneshot <query> [--dir <path>]\n", .{});
            return;
        }
        const query_text = try joinArgs(alloc, args[2..]);
        defer alloc.free(query_text);
        const root = parseDir(args) orelse ".";
        try oneshotQuery(alloc, root, query_text);
    } else if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        std.debug.print("opty {s}\n", .{VERSION});
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help")) {
        printUsage();
    } else {
        std.debug.print("unknown command: {s}\n", .{cmd});
        printUsage();
    }
}

fn printUsage() void {
    const usage =
        \\opty - HDC-powered codebase context optimizer for LLMs
        \\
        \\USAGE:
        \\  opty daemon [dir] [--port N]    Start single-project daemon
        \\  opty global        [--port N]   Start global multi-project daemon
        \\  opty query <text>  [--port N]   Query the running daemon
        \\  opty status        [--port N]   Show daemon status
        \\  opty reindex       [--port N]   Force re-index
        \\  opty stop          [--port N]   Stop the daemon
        \\  opty mcp [dir]                  MCP server (stdio, standalone)
        \\  opty mcp-client [dir] [--port N] MCP server backed by global daemon
        \\  opty oneshot <query> [--dir D]  One-shot query (no daemon)
        \\  opty version                    Show version
        \\
        \\The daemon indexes your codebase using Hyperdimensional Computing
        \\and produces minimal TOON-format context for LLM API calls.
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn sendCommand(alloc: std.mem.Allocator, port: u16, payload: []const u8, prefix: []const u8) !void {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);

    const stream = std.net.tcpConnectToAddress(addr) catch {
        std.debug.print("error: cannot connect to daemon on port {d}. Is it running?\n", .{port});
        return;
    };
    defer stream.close();

    // Build command with CWD for global daemon routing
    const cwd = getCwd();
    const msg = if (std.mem.eql(u8, prefix, "QUERY "))
        try std.fmt.allocPrint(alloc, "QUERY {s}\t{s}\n", .{ cwd, payload })
    else if (std.mem.eql(u8, prefix, "SHUTDOWN"))
        try std.fmt.allocPrint(alloc, "SHUTDOWN\n", .{})
    else
        try std.fmt.allocPrint(alloc, "{s} {s}\n", .{ prefix, cwd });
    defer alloc.free(msg);
    try stream.writeAll(msg);

    // Read response
    const stdout = std.fs.File.stdout();
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = stream.read(&buf) catch break;
        if (n == 0) break;
        try stdout.writeAll(buf[0..n]);
    }
}

fn oneshotQuery(alloc: std.mem.Allocator, root: []const u8, query_text: []const u8) !void {
    var brain = brain_mod.Brain.init(alloc);
    defer brain.deinit();

    // Walk and index
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();

    var walk = try dir.walk(alloc);
    defer walk.deinit();

    var file_count: usize = 0;
    while (try walk.next()) |entry| {
        if (entry.kind != .file) continue;
        const lang = parser.Language.fromExtension(entry.path);
        if (!lang.isSupported()) continue;

        const full_path = try std.fs.path.join(alloc, &.{ root, entry.path });
        defer alloc.free(full_path);

        const source = dir.readFileAlloc(alloc, entry.path, 10 * 1024 * 1024) catch continue;
        defer alloc.free(source);

        try brain.indexFile(full_path, source);
        file_count += 1;
    }

    std.debug.print("# indexed {d} units across {d} files\n", .{ brain.unitCount(), file_count });

    const query_vec = try encoder.encodeQuery(alloc, query_text);
    const results = try brain.query(alloc, query_vec, 20);
    defer alloc.free(results);

    const stdout = std.fs.File.stdout();
    if (results.len == 0) {
        try stdout.writeAll("# no matching code units found\n");
    } else {
        const output = try toon.formatResults(alloc, results, .signatures);
        defer alloc.free(output);
        try stdout.writeAll(output);
    }
}

fn joinArgs(alloc: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    var total: usize = 0;
    for (args, 0..) |arg, i| {
        if (std.mem.startsWith(u8, arg, "--")) break;
        total += arg.len;
        if (i > 0) total += 1;
    }
    const buf = try alloc.alloc(u8, total);
    var pos: usize = 0;
    for (args, 0..) |arg, i| {
        if (std.mem.startsWith(u8, arg, "--")) break;
        if (i > 0) {
            buf[pos] = ' ';
            pos += 1;
        }
        @memcpy(buf[pos .. pos + arg.len], arg);
        pos += arg.len;
    }
    return buf[0..pos];
}

fn parsePort(args: []const []const u8) u16 {
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--port") and i + 1 < args.len) {
            return std.fmt.parseInt(u16, args[i + 1], 10) catch DEFAULT_PORT;
        }
    }
    return DEFAULT_PORT;
}

fn parseDir(args: []const []const u8) ?[]const u8 {
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--dir") and i + 1 < args.len) {
            return args[i + 1];
        }
    }
    return null;
}

var global_cwd_buf: [4096]u8 = undefined;

fn getCwd() []const u8 {
    return std.posix.getcwd(&global_cwd_buf) catch ".";
}

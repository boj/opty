const std = @import("std");
const brain_mod = @import("brain.zig");
const encoder = @import("encoder.zig");
const parser = @import("parser.zig");
const toon = @import("toon.zig");
const ignore = @import("ignore.zig");
const Allocator = std.mem.Allocator;

const VERSION = "0.1.0";
const PROTOCOL_VERSION = "2024-11-05";

/// Run the MCP server over stdio (JSON-RPC 2.0 with Content-Length framing).
/// Indexes the codebase on startup and serves tool calls for semantic search.
pub fn run(alloc: Allocator, root_dir: []const u8) !void {
    var brain = brain_mod.Brain.init(alloc);
    defer brain.deinit();

    var file_mtimes = std.StringHashMap(i128).init(alloc);
    defer {
        var it = file_mtimes.iterator();
        while (it.next()) |entry| alloc.free(entry.key_ptr.*);
        file_mtimes.deinit();
    }

    const stderr = std.fs.File.stderr();
    try stderr.writeAll("opty MCP server starting...\n");
    try scanAndIndex(alloc, &brain, &file_mtimes, root_dir);

    var msg_buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "indexed {d} units across {d} files\n", .{
        brain.unitCount(), brain.fileCount(),
    });
    try stderr.writeAll(msg);

    while (true) {
        const body = readMessage(alloc) catch break;
        defer alloc.free(body);
        const response = handleMessage(alloc, body, &brain, &file_mtimes, root_dir) catch continue;
        if (response) |resp| {
            defer alloc.free(resp);
            writeMessage(resp) catch break;
        }
    }
}

// --- Transport (Content-Length framed stdio) ---

fn readMessage(alloc: Allocator) ![]u8 {
    const stdin = std.fs.File.stdin();
    var header_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var initial_retries: usize = 0;

    while (pos < header_buf.len) {
        var byte: [1]u8 = undefined;
        const n = try stdin.read(&byte);
        if (n == 0) {
            // On some platforms (WSL), stdin pipe may not be ready yet.
            // Retry a few times with a short sleep before giving up.
            if (pos == 0 and initial_retries < 50) {
                initial_retries += 1;
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            }
            return error.EndOfStream;
        }
        header_buf[pos] = byte[0];
        pos += 1;
        if (pos >= 4 and
            header_buf[pos - 4] == '\r' and header_buf[pos - 3] == '\n' and
            header_buf[pos - 2] == '\r' and header_buf[pos - 1] == '\n')
        {
            break;
        }
    }

    var content_length: ?usize = null;
    var iter = std.mem.splitSequence(u8, header_buf[0..pos], "\r\n");
    while (iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "Content-Length: ")) {
            content_length = std.fmt.parseInt(usize, line["Content-Length: ".len..], 10) catch null;
        }
    }
    const len = content_length orelse return error.InvalidHeader;

    const body = try alloc.alloc(u8, len);
    errdefer alloc.free(body);
    var total: usize = 0;
    while (total < len) {
        const n = try stdin.read(body[total..]);
        if (n == 0) return error.EndOfStream;
        total += n;
    }
    return body;
}

fn writeMessage(body: []const u8) !void {
    const stdout = std.fs.File.stdout();
    var hdr: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&hdr, "Content-Length: {d}\r\n\r\n", .{body.len});
    try stdout.writeAll(header);
    try stdout.writeAll(body);
}

// --- Public HTTP handler ---

/// Handle an MCP JSON-RPC request over HTTP. Returns the response body (caller
/// must free), or null for notifications that need no response.
pub fn handleHttpRequest(
    alloc: Allocator,
    body: []const u8,
    brain: *brain_mod.Brain,
    file_mtimes: *std.StringHashMap(i128),
    root_dir: []const u8,
) !?[]u8 {
    return handleMessage(alloc, body, brain, file_mtimes, root_dir);
}

/// Extract the "cwd" field from a tools/call MCP request's arguments.
/// Used by the global daemon to route to the correct project.
pub fn extractCwdFromRequest(alloc: Allocator, body: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    const method = jStr(root, "method") orelse return null;
    if (!eql(method, "tools/call")) return null;

    const params = jObj(root, "params") orelse return null;
    const args = jObj(params, "arguments") orelse return null;
    const cwd = jStr(args, "cwd") orelse return null;

    return alloc.dupe(u8, cwd) catch null;
}

// --- JSON-RPC dispatch ---

fn handleMessage(
    alloc: Allocator,
    body: []const u8,
    brain: *brain_mod.Brain,
    file_mtimes: *std.StringHashMap(i128),
    root_dir: []const u8,
) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        return try rpcError(alloc, null, -32700, "Parse error");
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return try rpcError(alloc, null, -32600, "Invalid request");

    const id = root.object.get("id");
    const method = jStr(root, "method") orelse
        return try rpcError(alloc, id, -32600, "Missing method");

    if (eql(method, "initialize")) {
        return try rpcResult(alloc, id,
            "{\"protocolVersion\":\"" ++ PROTOCOL_VERSION ++ "\"," ++
                "\"capabilities\":{\"tools\":{}}," ++
                "\"serverInfo\":{\"name\":\"opty\",\"version\":\"" ++ VERSION ++ "\"}}");
    } else if (eql(method, "notifications/initialized") or eql(method, "initialized")) {
        return null;
    } else if (eql(method, "notifications/cancelled")) {
        return null;
    } else if (eql(method, "ping")) {
        return try rpcResult(alloc, id, "{}");
    } else if (eql(method, "tools/list")) {
        return try handleToolsList(alloc, id);
    } else if (eql(method, "tools/call")) {
        return try handleToolsCall(alloc, id, root, brain, file_mtimes, root_dir);
    } else if (eql(method, "resources/list")) {
        return try rpcResult(alloc, id, "{\"resources\":[]}");
    } else if (eql(method, "prompts/list")) {
        return try rpcResult(alloc, id, "{\"prompts\":[]}");
    } else {
        return try rpcError(alloc, id, -32601, "Method not found");
    }
}

fn handleToolsList(alloc: Allocator, id: ?std.json.Value) ![]u8 {
    return try rpcResult(alloc, id,
        "{\"tools\":[" ++
            "{\"name\":\"opty_query\"," ++
            "\"description\":\"Semantic code search using Hyperdimensional Computing. " ++
            "Finds functions, types, and imports matching a natural language query. " ++
            "Returns TOON-format results (token-optimized). Use to locate relevant code before reading files.\"," ++
            "\"inputSchema\":{\"type\":\"object\",\"properties\":{" ++
            "\"query\":{\"type\":\"string\",\"description\":\"Natural language query (e.g. 'error handling functions', 'database types')\"}," ++
            "\"top_k\":{\"type\":\"number\",\"description\":\"Max results (default 20)\"}," ++
            "\"cwd\":{\"type\":\"string\",\"description\":\"Project working directory for routing (used by global daemon)\"}}," ++
            "\"required\":[\"query\"]}}," ++
            "{\"name\":\"opty_status\"," ++
            "\"description\":\"Get opty index statistics: file count, code unit count, memory usage, watched directory.\"," ++
            "\"inputSchema\":{\"type\":\"object\",\"properties\":{" ++
            "\"cwd\":{\"type\":\"string\",\"description\":\"Project working directory for routing (used by global daemon)\"}}}}," ++
            "{\"name\":\"opty_reindex\"," ++
            "\"description\":\"Force full re-scan and re-index of the codebase. Use after major file changes or stale results.\"," ++
            "\"inputSchema\":{\"type\":\"object\",\"properties\":{" ++
            "\"cwd\":{\"type\":\"string\",\"description\":\"Project working directory for routing (used by global daemon)\"}}}}," ++
            "{\"name\":\"opty_ast\"," ++
            "\"description\":\"Return the full depth-aware AST of the project or a single file. " ++
            "Extracts functions, types, imports, fields, variables and enum variants with nesting depth and line numbers. " ++
            "Omit 'file' to get the entire project AST.\"," ++
            "\"inputSchema\":{\"type\":\"object\",\"properties\":{" ++
            "\"file\":{\"type\":\"string\",\"description\":\"Relative file path (e.g. 'src/main.zig'). Omit for full project AST.\"}," ++
            "\"cwd\":{\"type\":\"string\",\"description\":\"Project working directory for routing (used by global daemon)\"}}}}" ++
            "]}");
}

fn handleToolsCall(
    alloc: Allocator,
    id: ?std.json.Value,
    root: std.json.Value,
    brain: *brain_mod.Brain,
    file_mtimes: *std.StringHashMap(i128),
    root_dir: []const u8,
) ![]u8 {
    const params = jObj(root, "params") orelse
        return try rpcError(alloc, id, -32602, "Missing params");
    const name = jStr(params, "name") orelse
        return try rpcError(alloc, id, -32602, "Missing tool name");
    const args = jObj(params, "arguments");

    if (eql(name, "opty_query")) {
        return try toolQuery(alloc, id, args, brain);
    } else if (eql(name, "opty_status")) {
        return try toolStatus(alloc, id, brain, root_dir);
    } else if (eql(name, "opty_reindex")) {
        return try toolReindex(alloc, id, brain, file_mtimes, root_dir);
    } else if (eql(name, "opty_ast")) {
        return try toolAst(alloc, id, args, root_dir);
    } else {
        return try callError(alloc, id, "Unknown tool");
    }
}

// --- Tool implementations ---

fn toolQuery(alloc: Allocator, id: ?std.json.Value, args: ?std.json.Value, brain: *brain_mod.Brain) ![]u8 {
    const query_text: []const u8 = blk: {
        if (args) |a| {
            if (jStr(a, "query")) |q| break :blk q;
        }
        break :blk "";
    };
    if (query_text.len == 0) return try callError(alloc, id, "Missing required argument: query");

    const top_k: usize = blk: {
        if (args) |a| {
            if (jInt(a, "top_k")) |k| {
                if (k > 0) break :blk @intCast(k);
            }
        }
        break :blk 20;
    };

    brain.mutex.lock();
    defer brain.mutex.unlock();

    const query_vec = try encoder.encodeQuery(alloc, query_text);
    const results = try brain.query(alloc, query_vec, top_k);
    defer alloc.free(results);

    if (results.len == 0) return try callText(alloc, id, "No matching code units found.");

    const output = try toon.formatResults(alloc, results, .signatures);
    defer alloc.free(output);
    return try callText(alloc, id, output);
}

fn toolStatus(alloc: Allocator, id: ?std.json.Value, brain: *brain_mod.Brain, root_dir: []const u8) ![]u8 {
    brain.mutex.lock();
    defer brain.mutex.unlock();
    var buf: [512]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "opty index: {d} code units, {d} files in {s}\nmemory: {d} bytes", .{
        brain.unitCount(), brain.fileCount(), root_dir,
        brain.entries.items.len * @sizeOf(brain_mod.BrainEntry),
    });
    return try callText(alloc, id, text);
}

fn toolReindex(
    alloc: Allocator,
    id: ?std.json.Value,
    brain: *brain_mod.Brain,
    file_mtimes: *std.StringHashMap(i128),
    root_dir: []const u8,
) ![]u8 {
    brain.mutex.lock();
    defer brain.mutex.unlock();

    // Clear file mtimes
    var it = file_mtimes.iterator();
    while (it.next()) |entry| alloc.free(entry.key_ptr.*);
    file_mtimes.clearAndFree();

    // Clear brain entries
    for (brain.entries.items) |entry| {
        alloc.free(entry.unit.name);
        alloc.free(entry.unit.signature);
        alloc.free(entry.unit.file_path);
        alloc.free(entry.unit.module_name);
    }
    brain.entries.clearRetainingCapacity();

    try scanAndIndex(alloc, brain, file_mtimes, root_dir);

    var buf: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "Reindexed: {d} code units across {d} files", .{
        brain.unitCount(), brain.fileCount(),
    });
    return try callText(alloc, id, text);
}

fn toolAst(alloc: Allocator, id: ?std.json.Value, args: ?std.json.Value, root_dir: []const u8) ![]u8 {
    const file_path: ?[]const u8 = blk: {
        if (args) |a| {
            if (jStr(a, "file")) |f| break :blk f;
        }
        break :blk null;
    };

    if (file_path) |fp| {
        return try astSingleFile(alloc, id, fp, root_dir);
    } else {
        return try astProject(alloc, id, root_dir);
    }
}

fn astSingleFile(alloc: Allocator, id: ?std.json.Value, file_path: []const u8, root_dir: []const u8) ![]u8 {
    const lang = parser.Language.fromExtension(file_path);
    if (!lang.isSupported()) return try callError(alloc, id, "Unsupported file type");

    const full_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root_dir, file_path });
    defer alloc.free(full_path);

    const source = std.fs.cwd().readFileAlloc(alloc, full_path, 10 * 1024 * 1024) catch {
        return try callError(alloc, id, "Cannot read file");
    };
    defer alloc.free(source);

    const nodes = try parser.parseAst(alloc, source, lang);
    defer {
        for (nodes) |n| {
            alloc.free(n.name);
            alloc.free(n.signature);
        }
        alloc.free(nodes);
    }

    if (nodes.len == 0) return try callText(alloc, id, "No code units found in file.");

    var buf: std.ArrayList(u8) = .empty;
    try toon.formatFileAst(alloc, &buf, nodes, file_path, lang);
    const output = try buf.toOwnedSlice(alloc);
    defer alloc.free(output);
    return try callText(alloc, id, output);
}

fn astProject(alloc: Allocator, id: ?std.json.Value, root_dir: []const u8) ![]u8 {
    var dir = std.fs.cwd().openDir(root_dir, .{ .iterate = true }) catch {
        return try callError(alloc, id, "Cannot open project directory");
    };
    defer dir.close();

    var filter = ignore.IgnoreFilter.init(alloc, root_dir);
    defer filter.deinit();

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var file_buf: std.ArrayList(u8) = .empty;
    defer file_buf.deinit(alloc);
    var total_nodes: usize = 0;
    var file_count: usize = 0;

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (filter.shouldIgnore(entry.path)) continue;
        const lang = parser.Language.fromExtension(entry.path);
        if (!lang.isSupported()) continue;

        const source = dir.readFileAlloc(alloc, entry.path, 10 * 1024 * 1024) catch continue;
        defer alloc.free(source);

        const nodes = parser.parseAst(alloc, source, lang) catch continue;
        defer {
            for (nodes) |n| {
                alloc.free(n.name);
                alloc.free(n.signature);
            }
            alloc.free(nodes);
        }

        try toon.formatFileAst(alloc, &file_buf, nodes, entry.path, lang);
        total_nodes += nodes.len;
        file_count += 1;
    }

    if (file_count == 0) return try callText(alloc, id, "No supported source files found.");

    var buf: std.ArrayList(u8) = .empty;
    try buf.print(alloc, "ast{{root:\"{s}\",files:{d},nodes:{d}}}\n", .{ root_dir, file_count, total_nodes });
    try buf.appendSlice(alloc, file_buf.items);
    const output = try buf.toOwnedSlice(alloc);
    defer alloc.free(output);
    return try callText(alloc, id, output);
}

fn rpcResult(alloc: Allocator, id: ?std.json.Value, result: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try fmtId(&buf, alloc, id);
    try buf.appendSlice(alloc, ",\"result\":");
    try buf.appendSlice(alloc, result);
    try buf.append(alloc, '}');
    return buf.toOwnedSlice(alloc);
}

fn rpcError(alloc: Allocator, id: ?std.json.Value, code: i32, message: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try fmtId(&buf, alloc, id);
    try buf.print(alloc, ",\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ code, message });
    return buf.toOwnedSlice(alloc);
}

fn callText(alloc: Allocator, id: ?std.json.Value, text: []const u8) ![]u8 {
    const escaped = try jsonEscape(alloc, text);
    defer alloc.free(escaped);
    var inner: std.ArrayList(u8) = .empty;
    try inner.appendSlice(alloc, "{\"content\":[{\"type\":\"text\",\"text\":\"");
    try inner.appendSlice(alloc, escaped);
    try inner.appendSlice(alloc, "\"}]}");
    const result = try inner.toOwnedSlice(alloc);
    defer alloc.free(result);
    return try rpcResult(alloc, id, result);
}

fn callError(alloc: Allocator, id: ?std.json.Value, message: []const u8) ![]u8 {
    const escaped = try jsonEscape(alloc, message);
    defer alloc.free(escaped);
    var inner: std.ArrayList(u8) = .empty;
    try inner.appendSlice(alloc, "{\"content\":[{\"type\":\"text\",\"text\":\"");
    try inner.appendSlice(alloc, escaped);
    try inner.appendSlice(alloc, "\"}],\"isError\":true}");
    const result = try inner.toOwnedSlice(alloc);
    defer alloc.free(result);
    return try rpcResult(alloc, id, result);
}

// --- JSON helpers ---

fn fmtId(buf: *std.ArrayList(u8), alloc: Allocator, id: ?std.json.Value) !void {
    if (id) |v| {
        switch (v) {
            .integer => |i| try buf.print(alloc, "{d}", .{i}),
            .string => |s| {
                try buf.append(alloc, '"');
                try buf.appendSlice(alloc, s);
                try buf.append(alloc, '"');
            },
            else => try buf.appendSlice(alloc, "null"),
        }
    } else {
        try buf.appendSlice(alloc, "null");
    }
}

fn jStr(val: std.json.Value, key: []const u8) ?[]const u8 {
    if (val != .object) return null;
    const v = val.object.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn jObj(val: std.json.Value, key: []const u8) ?std.json.Value {
    if (val != .object) return null;
    const v = val.object.get(key) orelse return null;
    if (v != .object) return null;
    return v;
}

fn jInt(val: std.json.Value, key: []const u8) ?i64 {
    if (val != .object) return null;
    const v = val.object.get(key) orelse return null;
    if (v != .integer) return null;
    return v.integer;
}

fn jsonEscape(alloc: Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    try buf.print(alloc, "\\u{x:0>4}", .{@as(u16, c)});
                } else {
                    try buf.append(alloc, c);
                }
            },
        }
    }
    return buf.toOwnedSlice(alloc);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// --- File scanning (used by standalone MCP mode) ---

fn scanAndIndex(
    alloc: Allocator,
    brain: *brain_mod.Brain,
    file_mtimes: *std.StringHashMap(i128),
    root_dir: []const u8,
) !void {
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

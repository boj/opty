const std = @import("std");
const brain_mod = @import("brain.zig");
const QueryResult = brain_mod.QueryResult;
const Allocator = std.mem.Allocator;

pub const DetailLevel = enum {
    signatures,
    full,
};

/// Format query results as TOON. Caller owns returned slice.
pub fn formatResults(alloc: Allocator, results: []const QueryResult, detail_level: DetailLevel) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    switch (detail_level) {
        .signatures => try formatSignatures(alloc, &buf, results),
        .full => try formatFull(alloc, &buf, results),
    }
    return buf.toOwnedSlice(alloc);
}

fn formatSignatures(alloc: Allocator, buf: *std.ArrayList(u8), results: []const QueryResult) !void {
    var fn_count: usize = 0;
    var type_count: usize = 0;
    var import_count: usize = 0;
    for (results) |r| {
        switch (r.entry.unit.kind) {
            .function => fn_count += 1,
            .type_def => type_count += 1,
            .import_decl => import_count += 1,
        }
    }

    if (fn_count > 0) {
        try buf.print(alloc, "functions[{d}]{{name,signature,file,line}}:\n", .{fn_count});
        for (results) |r| {
            if (r.entry.unit.kind != .function) continue;
            try buf.print(alloc, "{s},{s},{s},{d}\n", .{
                r.entry.unit.name,
                r.entry.unit.signature,
                r.entry.unit.file_path,
                r.entry.unit.line_number,
            });
        }
    }

    if (type_count > 0) {
        try buf.print(alloc, "types[{d}]{{name,signature,file,line}}:\n", .{type_count});
        for (results) |r| {
            if (r.entry.unit.kind != .type_def) continue;
            try buf.print(alloc, "{s},{s},{s},{d}\n", .{
                r.entry.unit.name,
                r.entry.unit.signature,
                r.entry.unit.file_path,
                r.entry.unit.line_number,
            });
        }
    }

    if (import_count > 0) {
        try buf.print(alloc, "imports[{d}]{{name,signature,file,line}}:\n", .{import_count});
        for (results) |r| {
            if (r.entry.unit.kind != .import_decl) continue;
            try buf.print(alloc, "{s},{s},{s},{d}\n", .{
                r.entry.unit.name,
                r.entry.unit.signature,
                r.entry.unit.file_path,
                r.entry.unit.line_number,
            });
        }
    }
}

fn formatFull(alloc: Allocator, buf: *std.ArrayList(u8), results: []const QueryResult) !void {
    try buf.print(alloc, "results[{d}]{{kind,name,signature,file,line,similarity}}:\n", .{results.len});
    for (results) |r| {
        const kind_str = switch (r.entry.unit.kind) {
            .function => "fn",
            .type_def => "type",
            .import_decl => "import",
        };
        try buf.print(alloc, "{s},{s},{s},{s},{d},{d:.3}\n", .{
            kind_str,
            r.entry.unit.name,
            r.entry.unit.signature,
            r.entry.unit.file_path,
            r.entry.unit.line_number,
            r.similarity,
        });
    }
}

pub fn estimateTokens(buf: []const u8) usize {
    return (buf.len + 3) / 4;
}

const std = @import("std");
const hdc = @import("hdc.zig");
const parser = @import("parser.zig");
const HyperVector = hdc.HyperVector;
const Allocator = std.mem.Allocator;

const roles = hdc.Roles{};
const atoms = hdc.AtomMap{};

/// Encode a CodeUnit into a HyperVector capturing its semantic identity.
pub fn encodeUnit(alloc: Allocator, unit: parser.CodeUnit) !HyperVector {
    var components: std.ArrayList(HyperVector) = .empty;
    defer components.deinit(alloc);

    // Encode kind
    const kind_str = switch (unit.kind) {
        .function => "function",
        .type_def => "type",
        .import_decl => "import",
    };
    try components.append(alloc, roles.kind().bind(atoms.get(kind_str)));

    // Encode name (full + sub-tokens for camelCase/snake_case)
    try components.append(alloc, roles.name().bind(atoms.get(unit.name)));
    const sub_tokens = try parser.splitIdentifier(alloc, unit.name);
    defer alloc.free(sub_tokens);
    for (sub_tokens) |tok| {
        var lower_buf: [256]u8 = undefined;
        const lower = toLower(tok, &lower_buf);
        try components.append(alloc, roles.name().bind(atoms.get(lower)));
    }

    // Encode module/file context
    try components.append(alloc, roles.module_role().bind(atoms.get(unit.module_name)));

    // Encode file path segments
    const path_parts = try parser.splitIdentifier(alloc, unit.file_path);
    defer alloc.free(path_parts);
    for (path_parts) |part| {
        var lower_buf: [256]u8 = undefined;
        const lower = toLower(part, &lower_buf);
        try components.append(alloc, roles.file_role().bind(atoms.get(lower)));
    }

    // Encode signature tokens (captures param types, return types, etc.)
    var sig_iter = std.mem.tokenizeAny(u8, unit.signature, " \t,(){}[]<>:;=&*|!?@#$%^~`'\"\\/");
    while (sig_iter.next()) |token| {
        if (token.len < 2) continue; // skip noise
        var lower_buf: [256]u8 = undefined;
        const lower = toLower(token, &lower_buf);
        try components.append(alloc, atoms.get(lower));
    }

    return hdc.bundle(components.items);
}

/// Encode a natural language query into a HyperVector for similarity search.
pub fn encodeQuery(alloc: Allocator, query_text: []const u8) !HyperVector {
    var components: std.ArrayList(HyperVector) = .empty;
    defer components.deinit(alloc);

    var tok_iter = std.mem.tokenizeAny(u8, query_text, " \t,(){}[]<>:;=&*|!?@#$%^~`'\"\\/");
    while (tok_iter.next()) |token| {
        if (token.len < 2) continue;
        var lower_buf: [256]u8 = undefined;
        const lower = toLower(token, &lower_buf);

        // Add raw atom
        try components.append(alloc, atoms.get(lower));

        // Structural hints: if token matches a kind keyword, bind with role
        if (std.mem.eql(u8, lower, "function") or std.mem.eql(u8, lower, "fn") or std.mem.eql(u8, lower, "def") or std.mem.eql(u8, lower, "func")) {
            try components.append(alloc, roles.kind().bind(atoms.get("function")));
        } else if (std.mem.eql(u8, lower, "type") or std.mem.eql(u8, lower, "struct") or std.mem.eql(u8, lower, "class") or std.mem.eql(u8, lower, "interface") or std.mem.eql(u8, lower, "enum")) {
            try components.append(alloc, roles.kind().bind(atoms.get("type")));
        } else if (std.mem.eql(u8, lower, "import") or std.mem.eql(u8, lower, "require") or std.mem.eql(u8, lower, "use")) {
            try components.append(alloc, roles.kind().bind(atoms.get("import")));
        } else {
            // General term — bind with name and module roles to boost matches
            try components.append(alloc, roles.name().bind(atoms.get(lower)));
            try components.append(alloc, roles.module_role().bind(atoms.get(lower)));
        }
    }

    if (components.items.len == 0) return HyperVector{};
    return hdc.bundle(components.items);
}

fn toLower(s: []const u8, buf: *[256]u8) []const u8 {
    const len = @min(s.len, 256);
    for (0..len) |i| {
        buf[i] = std.ascii.toLower(s[i]);
    }
    return buf[0..len];
}

// -- tests --

test "encode and query similarity" {
    const alloc = std.testing.allocator;
    const unit = parser.CodeUnit{
        .kind = .function,
        .name = "handleAuthError",
        .signature = "pub fn handleAuthError(req: Request) !AuthError",
        .file_path = "src/auth.zig",
        .line_number = 42,
        .module_name = "auth",
    };

    const unit_vec = try encodeUnit(alloc, unit);
    const query_vec = try encodeQuery(alloc, "auth error handling function");

    // The query should be meaningfully similar to the code unit
    const sim = unit_vec.similarity(query_vec);
    try std.testing.expect(sim > 0.0);
}

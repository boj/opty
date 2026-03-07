pub const hdc = @import("hdc.zig");
pub const parser = @import("parser.zig");
pub const encoder = @import("encoder.zig");
pub const brain = @import("brain.zig");
pub const toon = @import("toon.zig");
pub const daemon = @import("daemon.zig");
pub const mcp = @import("mcp.zig");
pub const global = @import("global.zig");
pub const ignore = @import("ignore.zig");
pub const treesitter = @import("treesitter.zig");
pub const refs = @import("refs.zig");
pub const bm25 = @import("bm25.zig");
pub const changes = @import("changes.zig");
pub const impact = @import("impact.zig");
pub const context = @import("context.zig");
pub const cluster = @import("cluster.zig");

test {
    _ = hdc;
    _ = parser;
    _ = encoder;
    _ = brain;
    _ = mcp;
    _ = ignore;
    _ = treesitter;
    _ = refs;
    _ = bm25;
    _ = changes;
    _ = impact;
    _ = context;
    _ = cluster;
}

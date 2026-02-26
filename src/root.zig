pub const hdc = @import("hdc.zig");
pub const parser = @import("parser.zig");
pub const encoder = @import("encoder.zig");
pub const brain = @import("brain.zig");
pub const toon = @import("toon.zig");
pub const daemon = @import("daemon.zig");
pub const mcp = @import("mcp.zig");
pub const global = @import("global.zig");
pub const ignore = @import("ignore.zig");

test {
    _ = hdc;
    _ = parser;
    _ = encoder;
    _ = brain;
    _ = mcp;
    _ = ignore;
}

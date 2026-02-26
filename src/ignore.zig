const std = @import("std");
const Allocator = std.mem.Allocator;

/// Ignore patterns loaded from .gitignore and built-in defaults.
pub const IgnoreFilter = struct {
    patterns: std.ArrayList(Pattern),
    alloc: Allocator,

    const Pattern = struct {
        text: []const u8,
        is_dir_only: bool,
        is_negation: bool,
    };

    // Directories always skipped (no config needed)
    const builtin_dirs = [_][]const u8{
        ".git",
        ".hg",
        ".svn",
        "node_modules",
        "__pycache__",
        ".zig-cache",
        "zig-cache",
        "zig-out",
        ".build",
        "build",
        "dist",
        "target",
        ".next",
        ".nuxt",
        ".output",
        ".cache",
        ".venv",
        "venv",
        ".tox",
        "vendor",
        ".gradle",
        ".idea",
        ".vs",
        ".vscode",
    };

    pub fn init(alloc: Allocator, root_dir: []const u8) IgnoreFilter {
        var self = IgnoreFilter{
            .patterns = .empty,
            .alloc = alloc,
        };

        // Load .gitignore if present
        const gitignore_path = std.fmt.allocPrint(alloc, "{s}/.gitignore", .{root_dir}) catch return self;
        defer alloc.free(gitignore_path);

        const content = std.fs.cwd().readFileAlloc(alloc, gitignore_path, 1024 * 1024) catch return self;
        defer alloc.free(content);

        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |raw_line| {
            const line = std.mem.trimRight(u8, raw_line, &[_]u8{ '\r', ' ', '\t' });
            if (line.len == 0 or line[0] == '#') continue;

            var text = line;
            var is_negation = false;
            if (text[0] == '!') {
                is_negation = true;
                text = text[1..];
            }

            // Strip leading slash (root-relative, treat same as prefix)
            if (text.len > 0 and text[0] == '/') {
                text = text[1..];
            }

            var is_dir_only = false;
            if (text.len > 0 and text[text.len - 1] == '/') {
                is_dir_only = true;
                text = text[0 .. text.len - 1];
            }

            if (text.len == 0) continue;

            const owned = alloc.dupe(u8, text) catch continue;
            self.patterns.append(alloc, .{
                .text = owned,
                .is_dir_only = is_dir_only,
                .is_negation = is_negation,
            }) catch {
                alloc.free(owned);
                continue;
            };
        }

        return self;
    }

    pub fn deinit(self: *IgnoreFilter) void {
        for (self.patterns.items) |p| {
            self.alloc.free(p.text);
        }
        self.patterns.deinit(self.alloc);
    }

    /// Returns true if the given path should be ignored.
    /// `path` is relative to the project root (e.g. "src/main.zig" or "node_modules").
    pub fn shouldIgnore(self: *const IgnoreFilter, path: []const u8) bool {
        // Check built-in directory ignores against each path component
        var comp_iter = std.mem.splitScalar(u8, path, '/');
        while (comp_iter.next()) |component| {
            if (component.len == 0) continue;
            for (builtin_dirs) |dir| {
                if (std.mem.eql(u8, component, dir)) return true;
            }
        }

        // Check .gitignore patterns
        var ignored = false;
        for (self.patterns.items) |p| {
            if (matchPattern(p.text, path)) {
                ignored = !p.is_negation;
            }
        }
        return ignored;
    }

    /// Simple glob matching: supports * (any chars within segment) and ** (any path segments).
    fn matchPattern(pattern: []const u8, path: []const u8) bool {
        // If pattern has no slash, match against basename only
        if (std.mem.indexOfScalar(u8, pattern, '/') == null) {
            const basename = blk: {
                if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
                    break :blk path[idx + 1 ..];
                }
                break :blk path;
            };
            return globMatch(pattern, basename);
        }

        // Pattern with path separators — match against full path
        return globMatch(pattern, path);
    }

    fn globMatch(pattern: []const u8, text: []const u8) bool {
        return globMatchPublic(pattern, text);
    }
};

/// Glob matching exposed for use outside IgnoreFilter (e.g. file filtering).
pub fn globMatchPublic(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: usize = 0;

    while (ti < text.len) {
        if (pi < pattern.len) {
            // Handle **
            if (pi + 1 < pattern.len and pattern[pi] == '*' and pattern[pi + 1] == '*') {
                pi += 2;
                if (pi < pattern.len and pattern[pi] == '/') pi += 1;
                star_pi = pi;
                star_ti = ti;
                continue;
            }
            // Handle *
            if (pattern[pi] == '*') {
                star_pi = pi + 1;
                star_ti = ti;
                pi += 1;
                continue;
            }
            // Handle ? or exact match
            if (pattern[pi] == '?' or pattern[pi] == text[ti]) {
                pi += 1;
                ti += 1;
                continue;
            }
        }

        // Backtrack to last star
        if (star_pi) |sp| {
            pi = sp;
            star_ti += 1;
            ti = star_ti;
            continue;
        }

        return false;
    }

    // Skip trailing stars in pattern
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

test "builtin ignores" {
    const alloc = std.testing.allocator;
    var f = IgnoreFilter.init(alloc, "/nonexistent");
    defer f.deinit();

    try std.testing.expect(f.shouldIgnore("node_modules/foo.js"));
    try std.testing.expect(f.shouldIgnore(".git/config"));
    try std.testing.expect(f.shouldIgnore("zig-out/bin/opty"));
    try std.testing.expect(f.shouldIgnore("src/.zig-cache/foo"));
    try std.testing.expect(!f.shouldIgnore("src/main.zig"));
    try std.testing.expect(!f.shouldIgnore("README.md"));
}

test "glob matching" {
    try std.testing.expect(globMatchPublic("*.o", "foo.o"));
    try std.testing.expect(!globMatchPublic("*.o", "foo.c"));
    try std.testing.expect(globMatchPublic("build", "build"));
    try std.testing.expect(!globMatchPublic("build", "rebuild"));
    try std.testing.expect(globMatchPublic("src/*.zig", "src/main.zig"));
    try std.testing.expect(!globMatchPublic("src/*.zig", "test/main.zig"));
    try std.testing.expect(globMatchPublic("src/**/*.zig", "src/sub/deep/file.zig"));
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;

pub fn parse(allocator: Allocator, content: []const u8, config: *Config) !void {
    _ = allocator;
    _ = content;
    _ = config;

    // TODO: Implement a TOML parser only with the necessary functionality.
    // No need to support the full TOML spec.
}

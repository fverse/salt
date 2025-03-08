const std = @import("std");
const Allocator = std.mem.Allocator;
const toml = @import("parser/toml.zig");

pub const BranchMapping = struct {
    superProject_branch: []const u8,
    submodule_branch: []const u8,
};

pub const Submodule = struct {
    name: []const u8,
    url: []const u8,
    path: []const u8,
    default_branch: []const u8,
    branch_mappings: std.ArrayList(BranchMapping),

    pub fn deinit(self: *Submodule) void {
        self.branch_mappings.deinit();
    }
};

pub const Config = struct {
    allocator: Allocator,
    submodules: std.ArrayList(Submodule),

    // Initializes a new Config
    pub fn init(allocator: Allocator) !Config {
        return Config{
            .allocator = allocator,
            .submodules = std.ArrayList(Submodule).init(allocator),
        };
    }

    pub fn deinit(self: *Config) void {
        for (self.submodules.items) |*submodule| {
            submodule.deinit();
        }
        self.submodules.deinit();
    }

    pub fn loadFromFile(allocator: Allocator, filepath: []const u8) !Config {
        var config = try Config.init(allocator);
        errdefer config.deinit();

        const file_content = try std.fs.cwd().readFileAlloc(allocator, filepath, 1024 * 1024);
        defer allocator.free(file_content);

        try toml.parse(allocator, file_content, &config);
        return config;
    }
};

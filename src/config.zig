const std = @import("std");
const writer = @import("./config/writer.zig");
const Writer = writer.Writer;
const Parser = @import("./parser/salt.zig").Parser;

/// Represents a single submodule configuration
pub const Submodule = struct {
    /// Name/identifier of the submodule
    name: []const u8,
    /// Local path where the submodule is located
    path: []const u8,
    /// Remote repository URL
    url: []const u8,
    /// Default branch to use
    default_branch: []const u8,
    /// Branch mappings
    branches: std.hash_map.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) Submodule {
        return .{
            .name = "",
            .path = "",
            .url = "",
            .default_branch = "",
            .branches = std.hash_map.StringHashMap([]const u8).init(allocator),
        };
    }

    /// Add a branch mapping
    pub fn addBranchMapping(self: *Submodule, repoBranch: []const u8, submoduleBranch: []const u8) !void {
        try self.branches.put(repoBranch, submoduleBranch);
    }

    /// Get branch for a specific environment
    pub fn getBranch(self: *const Submodule, env: []const u8) ?[]const u8 {
        return self.branches.get(env);
    }

    /// Get branch for environment or fall back to default
    pub fn getBranchOrDefault(self: *const Submodule, env: []const u8) []const u8 {
        return self.branches.get(env) orelse self.default_branch;
    }

    pub fn deinit(self: *Submodule) void {
        self.branches.deinit();
    }

    pub fn setName(self: *Submodule, name: []const u8) !void {
        self.name = name;
    }

    pub fn setPath(self: *Submodule, path: []const u8) !void {
        self.path = path;
    }

    pub fn setUrl(self: *Submodule, url: []const u8) !void {
        self.url = url;
    }

    pub fn setDefaultBranch(self: *Submodule, default_branch: []const u8) !void {
        self.default_branch = default_branch;
    }

    pub fn addToSaltfile(self: *Submodule, allocator: std.mem.Allocator) !void {
        const content = try writer.readFileContent(allocator);
        defer allocator.free(content);

        var parser = Parser.init(allocator);
        defer parser.deinit();

        var conf = try parser.parseContent(content);
        defer conf.deinit();

        try conf.submodules.append(self.*);

        var w = Writer.init(allocator);
        try w.writeFile(&conf, "salt.conf");
    }
};

/// Main configuration structure holding all submodules
pub const SubmoduleConfig = struct {
    submodules: std.ArrayList(Submodule),
    allocator: std.mem.Allocator,

    /// Initialize a new SubmoduleConfig
    pub fn init(allocator: std.mem.Allocator) SubmoduleConfig {
        return .{
            .submodules = std.ArrayList(Submodule).init(allocator),
            .allocator = allocator,
        };
    }

    /// Add a submodule to the configuration
    pub fn addSubmodule(self: *SubmoduleConfig, submodule: Submodule) !void {
        try self.submodules.append(submodule);
    }

    /// Find a submodule by name
    pub fn findByName(self: *const SubmoduleConfig, name: []const u8) ?*Submodule {
        for (self.submodules.items) |*submodule| {
            if (std.mem.eql(u8, submodule.name, name)) {
                return submodule;
            }
        }
        return null;
    }

    /// Find a submodule by path
    pub fn findByPath(self: *const SubmoduleConfig, path: []const u8) ?*Submodule {
        for (self.submodules.items) |*submodule| {
            if (std.mem.eql(u8, submodule.path, path)) {
                return submodule;
            }
        }
        return null;
    }

    /// Get all available environments across all submodules
    pub fn getAllEnvironments(self: *const SubmoduleConfig, allocator: std.mem.Allocator) ![][]const u8 {
        var env_set = std.hash_map.StringHashMap(void).init(allocator);
        defer env_set.deinit();

        // Collect all unique environment names
        for (self.submodules.items) |submodule| {
            var iter = submodule.branches.iterator();
            while (iter.next()) |entry| {
                try env_set.put(entry.key_ptr.*, {});
            }
        }

        var envs = try allocator.alloc([]const u8, env_set.count());
        var i: usize = 0;
        var iter = env_set.iterator();
        while (iter.next()) |entry| : (i += 1) {
            envs[i] = entry.key_ptr.*;
        }

        return envs;
    }

    pub fn deinit(self: *SubmoduleConfig) void {
        for (self.submodules.items) |*submodule| {
            submodule.deinit();
        }
        self.submodules.deinit();
    }
};

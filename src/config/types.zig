const std = @import("std");
const Allocator = std.mem.Allocator;

/// Type alias for branch mappings (parent_branch -> submodule_branch)
pub const BranchMappings = std.StringHashMap([]const u8);

pub const Submodule = struct {
    /// Name/identifier of the submodule
    name: []const u8,
    /// Local path where the submodule is located
    path: []const u8,
    /// Remote repository URL
    url: []const u8,
    /// Default branch to use
    default_branch: []const u8,
    /// Use shallow clone (default: true)
    shallow: bool,
    /// Branch mappings (parent_branch -> submodule_branch)
    branch_mappings: BranchMappings,
    /// Allocator used for this submodule's memory
    allocator: Allocator,

    pub fn init(allocator: Allocator) Submodule {
        return .{
            .name = "",
            .path = "",
            .url = "",
            .default_branch = "",
            .shallow = true,
            .branch_mappings = BranchMappings.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Submodule) void {
        self.branch_mappings.deinit();
    }

    /// Add a branch mapping (parent_branch -> submodule_branch)
    pub fn addBranchMapping(self: *Submodule, parent_branch: []const u8, submodule_branch: []const u8) !void {
        try self.branch_mappings.put(parent_branch, submodule_branch);
    }

    /// Get the submodule branch for a given parent branch
    /// Returns null if no mapping exists
    pub fn getBranchFor(self: *const Submodule, parent_branch: []const u8) ?[]const u8 {
        return self.branch_mappings.get(parent_branch);
    }

    /// Get the submodule branch for a given parent branch, or fall back to default
    pub fn getBranchOrDefault(self: *const Submodule, parent_branch: []const u8) []const u8 {
        return self.branch_mappings.get(parent_branch) orelse self.default_branch;
    }

    /// Legacy compatibility methods
    pub fn getBranch(self: *const Submodule, env: []const u8) ?[]const u8 {
        return self.getBranchFor(env);
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
};

pub const SubmoduleConfig = struct {
    submodules: std.ArrayList(Submodule),
    allocator: Allocator,

    pub fn init(allocator: Allocator) SubmoduleConfig {
        return .{
            .submodules = std.ArrayList(Submodule).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SubmoduleConfig) void {
        for (self.submodules.items) |*submodule| {
            submodule.deinit();
        }
        self.submodules.deinit();
    }

    /// Add a submodule to the configuration
    pub fn addSubmodule(self: *SubmoduleConfig, submodule: Submodule) !void {
        // Check for duplicate names
        if (self.findByName(submodule.name)) |_| {
            return error.DuplicateSubmodule;
        }
        try self.submodules.append(submodule);
    }

    /// Remove a submodule by name
    /// Returns true if the submodule was found and removed, false otherwise
    pub fn removeSubmodule(self: *SubmoduleConfig, name: []const u8) !bool {
        for (self.submodules.items, 0..) |*submodule, i| {
            if (std.mem.eql(u8, submodule.name, name)) {
                submodule.deinit();
                _ = self.submodules.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Find a submodule by name
    /// Returns a pointer to the submodule if found, null otherwise
    pub fn findByName(self: *const SubmoduleConfig, name: []const u8) ?*Submodule {
        for (self.submodules.items) |*submodule| {
            if (std.mem.eql(u8, submodule.name, name)) {
                return submodule;
            }
        }
        return null;
    }

    /// Find a submodule by path
    /// Returns a pointer to the submodule if found, null otherwise
    pub fn findByPath(self: *const SubmoduleConfig, path: []const u8) ?*Submodule {
        for (self.submodules.items) |*submodule| {
            if (std.mem.eql(u8, submodule.path, path)) {
                return submodule;
            }
        }
        return null;
    }

    /// Get the number of submodules in the configuration
    pub fn count(self: *const SubmoduleConfig) usize {
        return self.submodules.items.len;
    }
};

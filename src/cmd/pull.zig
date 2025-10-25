const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const git = @import("../git.zig");
const process = @import("../utils/process.zig");

const PullError = error{
    SubprojectNotFound,
    BranchCheckoutFailed,
    PullFailed,
};

/// Pull changes from a subproject
pub fn pull(allocator: Allocator, args: []const []const u8) !void {
    const config_path = "zigdep.toml";
    const stdout = std.io.getStdOut().writer();

    // Load config
    var config = try Config.loadFromFile(allocator, config_path);
    defer config.deinit();

    // Get current branch in superproject
    const super_branch = try git.getCurrentBranch(allocator, ".");
    defer allocator.free(super_branch);

    try stdout.print("Current superproject branch: {s}\n", .{super_branch});

    if (args.len == 0) {
        // Pull from all subprojects
        for (config.subprojects.items) |subproject| {
            try stdout.print("\nPulling from subproject: {s}\n", .{subproject.name});
            pullFromSubproject(allocator, &config, subproject.name, super_branch) catch |err| {
                try stdout.print("Error pulling from {s}: {any}\n", .{ subproject.name, err });
            };
        }
    } else {
        // Pull from specific subproject
        const subproject_name = args[0];
        try stdout.print("\nPulling from subproject: {s}\n", .{subproject_name});
        try pullFromSubproject(allocator, &config, subproject_name, super_branch);
    }
}

/// Pull changes from a specific subproject
fn pullFromSubproject(allocator: Allocator, config: *const Config, subproject_name: []const u8, super_branch: []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    // Find subproject in config
    const subproject = config.getSubprojectByName(subproject_name) orelse
        return PullError.SubprojectNotFound;

    // Find corresponding branch in subproject
    const sub_branch = config.getSubprojectBranchMapping(subproject_name, super_branch) orelse
        subproject.default_branch;

    try stdout.print("Mapped to subproject branch: {s}\n", .{sub_branch});

    // Current working directory for later restoration
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    // Change to subproject directory
    try std.os.chdir(subproject.path);
    defer std.os.chdir(cwd) catch {};

    // Checkout the correct branch
    var result = try process.run(allocator, &[_][]const u8{ "git", "checkout", sub_branch });

    if (result.exit_code != 0) {
        try stdout.print("Failed to checkout branch {s}: {s}\n", .{ sub_branch, result.stderr });
        allocator.free(result);

        // Try to create branch if it doesn't exist
        try stdout.print("Attempting to create branch {s}...\n", .{sub_branch});
        result = try process.run(allocator, &[_][]const u8{ "git", "checkout", "-b", sub_branch });

        if (result.exit_code != 0) {
            try stdout.print("Failed to create branch {s}: {s}\n", .{ sub_branch, result.stderr });
            allocator.free(result);
            return PullError.BranchCheckoutFailed;
        }
    }
    allocator.free(result);

    // Pull from remote
    try stdout.print("Pulling changes from origin/{s}...\n", .{sub_branch});
    result = try process.run(allocator, &[_][]const u8{ "git", "pull", "origin", sub_branch });

    if (result.exit_code != 0) {
        try stdout.print("Pull failed: {s}\n", .{result.stderr});
        allocator.free(result);
        return PullError.PullFailed;
    }
    allocator.free(result);

    // Return to original directory
    try std.os.chdir(cwd);

    // Update superproject tracking
    try stdout.print("Updating superproject tracking...\n", .{});
    _ = try process.run(allocator, &[_][]const u8{ "git", "add", subproject.path });

    try stdout.print("Successfully pulled changes for {s} from branch {s}\n", .{ subproject_name, sub_branch });
}

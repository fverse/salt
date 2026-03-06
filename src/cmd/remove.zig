const std = @import("std");
const Allocator = std.mem.Allocator;
const config_parser = @import("../config/parser.zig");
const config_types = @import("../config/types.zig");
const config_writer = @import("../config/writer.zig");
const state_mod = @import("../core/state.zig");
const git = @import("../git/operations.zig");
const fs = @import("../utils/fs.zig");

const RemoveOptions = struct {
    delete_files: bool = false,
    force: bool = false,
};

/// Removes a submodule from the project
pub fn execute(allocator: Allocator, args: *std.process.ArgIterator) !void {
    var options = RemoveOptions{};
    var submodule_name: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--delete-files")) {
            options.delete_files = true;
        } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // First non-flag argument is the submodule name
            if (submodule_name == null) {
                submodule_name = arg;
            }
        }
    }

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    // Validate that submodule name was provided
    const name = submodule_name orelse {
        try stderr.writeAll("Error: Please provide a submodule name\n");
        try stderr.writeAll("Usage: salt remove <submodule-name> [options]\n");
        try stderr.writeAll("Run 'salt remove --help' for more information\n");
        return error.MissingArgument;
    };

    // Load Saltfile
    var parser = config_parser.Parser.init(allocator);
    defer parser.deinit();

    var config = parser.parseFile("Saltfile") catch |err| {
        try stderr.print("Error: Failed to load Saltfile: {}\n", .{err});
        if (err == error.FileNotFound) {
            try stderr.writeAll("Run 'salt init' to create a configuration file\n");
        }
        return err;
    };
    defer config.deinit();

    // Validate submodule exists
    const submodule = config.findByName(name) orelse {
        try stderr.print("Error: Submodule '{s}' not found in Saltfile\n", .{name});
        try stderr.writeAll("Run 'salt status' to see configured submodules\n");
        return error.SubmoduleNotFound;
    };

    try stdout.print("Removing submodule '{s}'...\n", .{name});

    // Save the path before removal frees it
    const submodule_path = try allocator.dupe(u8, submodule.path);
    defer allocator.free(submodule_path);

    // Perform safety checks if deleting files
    if (options.delete_files) {
        try performSafetyChecks(allocator, submodule, options, stderr);
    }

    // Perform the removal
    try removeSubmodule(allocator, &config, submodule, name, options, stdout, stderr);

    // Report success
    if (options.delete_files) {
        try stdout.print("\n✓ Removed submodule '{s}' and deleted files\n", .{name});
    } else {
        try stdout.print("\n✓ Removed submodule '{s}' (files preserved at {s})\n", .{ name, submodule_path });
    }
}

/// Perform safety checks before removing a submodule
fn performSafetyChecks(
    allocator: Allocator,
    submodule: *const config_types.Submodule,
    options: RemoveOptions,
    stderr: anytype,
) !void {
    // Check if path exists
    if (!fs.pathExists(submodule.path)) {
        // Path doesn't exist, nothing to check
        return;
    }

    // Check for uncommitted changes in parent path
    var status_result = try git.executeGitCommand(allocator, &[_][]const u8{
        "git",
        "status",
        "--porcelain",
        submodule.path,
    });
    defer status_result.deinit(allocator);

    if (status_result.exit_code == 0 and status_result.stdout.len > 0) {
        // There are uncommitted changes
        if (!options.force) {
            try stderr.print("Error: '{s}' has uncommitted changes:\n", .{submodule.name});
            try stderr.print("{s}\n", .{status_result.stdout});
            try stderr.writeAll("Use --force to delete anyway, or commit/stash changes first\n");
            return error.UncommittedChanges;
        } else {
            try stderr.print("Warning: Deleting '{s}' with uncommitted changes (--force)\n", .{submodule.name});
        }
    }
}

/// Remove a submodule from the project
fn removeSubmodule(
    allocator: Allocator,
    config: *config_types.SubmoduleConfig,
    submodule: *const config_types.Submodule,
    name: []const u8,
    options: RemoveOptions,
    stdout: anytype,
    stderr: anytype,
) !void {
    // 1. Delete working directory if --delete-files flag is set
    if (options.delete_files and fs.pathExists(submodule.path)) {
        try stdout.print("  Deleting working directory: {s}\n", .{submodule.path});

        std.fs.cwd().deleteTree(submodule.path) catch |err| {
            try stderr.print("  Warning: Failed to delete directory '{s}': {}\n", .{ submodule.path, err });
            // Continue anyway
        };

        // Unstage from parent Git using git rm --cached
        try stdout.print("  Unstaging from parent Git...\n", .{});

        var rm_result = try git.executeGitCommand(allocator, &[_][]const u8{
            "git",
            "rm",
            "-r",
            "--cached",
            submodule.path,
        });
        defer rm_result.deinit(allocator);

        if (rm_result.exit_code != 0) {
            // Not a fatal error - files might not be tracked
            try stderr.print("  Warning: Failed to unstage files: {s}\n", .{rm_result.stderr});
        }
    }

    // 2. Remove hidden source repo from .salt/repos/<name>
    const source_path = try std.fmt.allocPrint(
        allocator,
        ".salt/repos/{s}",
        .{name},
    );
    defer allocator.free(source_path);

    if (fs.pathExists(source_path)) {
        try stdout.print("  Removing hidden repository: {s}\n", .{source_path});

        std.fs.cwd().deleteTree(source_path) catch |err| {
            try stderr.print("  Warning: Failed to delete hidden repo '{s}': {}\n", .{ source_path, err });
            // Continue anyway
        };
    }

    // 3. Remove submodule entry from Saltfile
    try stdout.print("  Updating Saltfile...\n", .{});

    const removed = try config.removeSubmodule(name);
    if (!removed) {
        // This shouldn't happen since we validated earlier, but handle it
        try stderr.print("  Warning: Submodule '{s}' not found in config\n", .{name});
    }

    // Write updated configuration
    var writer = config_writer.Writer.init(allocator);
    try writer.writeFile(config, "Saltfile");

    // 4. Remove submodule from state.json
    try stdout.print("  Updating state tracking...\n", .{});

    if (state_mod.SyncState.load(allocator)) |sync_state_val| {
        var sync_state = sync_state_val;
        defer sync_state.deinit();
        state_mod.removeSubmoduleState(&sync_state, allocator, name) catch |err| {
            try stderr.print("  Warning: Failed to update state tracking: {}\n", .{err});
        };
    } else |err| {
        try stderr.print("  Warning: Failed to load state: {}\n", .{err});
    }
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\salt remove - Remove a submodule
        \\
        \\USAGE:
        \\    salt remove <submodule-name> [options]
        \\
        \\DESCRIPTION:
        \\    Remove a submodule from the project cleanly. This removes the
        \\    submodule entry from Saltfile, the hidden repository from
        \\    .salt/repos/, and optionally deletes the working directory.
        \\
        \\ARGUMENTS:
        \\    <submodule-name>    Name of the submodule to remove (required)
        \\
        \\OPTIONS:
        \\    --delete-files      Delete the submodule working directory
        \\                        (default: preserve files)
        \\    --force, -f         Force deletion even with uncommitted changes
        \\                        (only applies with --delete-files)
        \\    --help, -h          Display this help message
        \\
        \\EXAMPLES:
        \\    # Remove submodule but keep files
        \\    salt remove xyz
        \\
        \\    # Remove submodule and delete files
        \\    salt remove xyz --delete-files
        \\
        \\    # Force delete even with uncommitted changes
        \\    salt remove xyz --delete-files --force
        \\
        \\NOTES:
        \\    - Without --delete-files, only the configuration is updated
        \\    - The working directory files remain as regular files
        \\    - With --delete-files, uncommitted changes require --force
        \\    - The hidden repository in .salt/repos/ is always removed
        \\
    );
}

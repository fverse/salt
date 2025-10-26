const std = @import("std");
const Allocator = std.mem.Allocator;
const config_parser = @import("../config/parser.zig");
const config_types = @import("../config/types.zig");
const state_mod = @import("../core/state.zig");
const git = @import("../git/operations.zig");
const fs = @import("../utils/fs.zig");

const PullOptions = struct {
    parallel: bool = false,
    ci_mode: bool = false,
    quiet: bool = false,
};

pub fn execute(allocator: Allocator, args: *std.process.ArgIterator) !void {
    var options = PullOptions{};
    var submodule_name: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--parallel")) {
            options.parallel = true;
        } else if (std.mem.eql(u8, arg, "--ci")) {
            options.ci_mode = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            options.quiet = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (submodule_name == null) {
                submodule_name = arg;
            }
        }
    }

    var parser = config_parser.Parser.init(allocator);
    defer parser.deinit();

    var config = parser.parseFile("salt.conf") catch |err| {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Error: Failed to load salt.conf: {}\n", .{err});
        if (options.ci_mode) {
            std.process.exit(2);
        }
        return err;
    };
    defer config.deinit();

    var sync_state = try state_mod.SyncState.load(allocator);
    defer sync_state.deinit();

    var success_count: usize = 0;
    var skipped_count: usize = 0;
    var failed_count: usize = 0;

    // Pull submodules
    if (submodule_name) |name| {
        const submodule = config.findByName(name) orelse {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error: Submodule '{s}' not found\n", .{name});
            if (options.ci_mode) {
                std.process.exit(2);
            }
            return error.SubmoduleNotFound;
        };

        pullSubmodule(allocator, submodule, &sync_state, options) catch |err| {
            if (err == error.UncommittedChanges or err == error.MergeConflict) {
                skipped_count += 1;
            } else {
                failed_count += 1;
                if (options.ci_mode) {
                    std.process.exit(3);
                }
            }
        };
        if (failed_count == 0 and skipped_count == 0) {
            success_count += 1;
        }
    } else {
        for (config.submodules.items) |*submodule| {
            pullSubmodule(allocator, submodule, &sync_state, options) catch |err| {
                if (err == error.UncommittedChanges or err == error.MergeConflict) {
                    skipped_count += 1;
                } else {
                    failed_count += 1;
                    if (options.ci_mode) {
                        std.process.exit(3);
                    }
                }
                continue;
            };
            success_count += 1;
        }
    }

    if (!options.quiet) {
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll("\n");
        try stdout.print("  Pulled: {} submodule(s)\n", .{success_count});
        if (skipped_count > 0) {
            try stdout.print("  Skipped: {} submodule(s)\n", .{skipped_count});
        }
        if (failed_count > 0) {
            try stdout.print("  Failed: {} submodule(s)\n", .{failed_count});
        }
    }
}

fn pullSubmodule(
    allocator: Allocator,
    submodule: *const config_types.Submodule,
    sync_state: *state_mod.SyncState,
    options: PullOptions,
) !void {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    if (!options.quiet) {
        try stdout.print("\nPulling '{s}'...\n", .{submodule.name});
    }

    const source_path = try std.fmt.allocPrint(allocator, ".salt/repos/{s}", .{submodule.name});
    defer allocator.free(source_path);

    if (!fs.pathExists(source_path)) {
        try stderr.print("  Error: Source repository not found\n", .{});
        return error.SourceRepoNotFound;
    }

    const current_branch = try git.getCurrentBranch(allocator, source_path);
    defer allocator.free(current_branch);

    if (!options.quiet) {
        try stdout.print("  Current branch: {s}\n", .{current_branch});
    }

    var status_result = try git.executeGitCommand(allocator, &[_][]const u8{ "git", "-C", source_path, "status", "--porcelain" });
    defer status_result.deinit(allocator);

    if (status_result.stdout.len > 0) {
        try stderr.print("  ⚠ Skipping: Uncommitted changes\n", .{});
        return error.UncommittedChanges;
    }

    if (!options.quiet) {
        try stdout.print("  Pulling from origin/{s}...\n", .{current_branch});
    }

    git.pull(allocator, source_path, "origin", current_branch) catch |err| {
        if (err == error.MergeConflict) {
            try stderr.print("  ⚠ Merge conflict detected\n", .{});
            return err;
        }
        try stderr.print("  Error: Pull failed\n", .{});
        return err;
    };

    if (!options.quiet) {
        try stdout.print("  Copying files...\n", .{});
    }

    try fs.copyDirectory(allocator, source_path, submodule.path, .{ .exclude_git = true });

    try state_mod.updateAfterSync(sync_state, allocator, submodule.name, submodule.path, source_path, current_branch);

    if (!options.quiet) {
        try stdout.print("  ✓ Successfully pulled '{s}'\n", .{submodule.name});
    }
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\salt pull - Pull latest changes on current branches
        \\
        \\USAGE:
        \\    salt pull [submodule-name] [options]
        \\
        \\DESCRIPTION:
        \\    Pull the latest changes for submodules on their current branches.
        \\
        \\OPTIONS:
        \\    --parallel          Pull submodules in parallel (not yet implemented)
        \\    --ci                Fail fast on any error
        \\    --quiet, -q         Suppress non-error output
        \\    --help, -h          Display this help message
        \\
        \\EXAMPLES:
        \\    salt pull
        \\    salt pull submodulename
        \\
    );
}

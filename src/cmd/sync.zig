const std = @import("std");
const Allocator = std.mem.Allocator;
const config_parser = @import("../config/parser.zig");
const config_types = @import("../config/types.zig");
const state_mod = @import("../core/state.zig");
const mapper = @import("../core/mapper.zig");
const git = @import("../git/operations.zig");
const fs = @import("../utils/fs.zig");

pub const SyncOptions = struct {
    ci_mode: bool = false,
    quiet: bool = false,
    force: bool = false,
};

/// Syncs submodules to the branch mapped to the current parent branch
pub fn execute(allocator: Allocator, args: *std.process.ArgIterator) !void {
    // Parse command arguments
    var options = SyncOptions{};
    var submodule_name: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ci")) {
            options.ci_mode = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            options.quiet = true;
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

    // Get current parent branch
    const parent_branch = try git.getCurrentBranch(allocator, ".");
    defer allocator.free(parent_branch);

    if (!options.quiet) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("Current parent branch: {s}\n", .{parent_branch});
    }

    // Load salt.conf
    var parser = config_parser.Parser.init(allocator);
    defer parser.deinit();

    var config = parser.parseFile("salt.conf") catch |err| {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Error: Failed to load salt.conf: {}\n", .{err});
        if (options.ci_mode) {
            std.process.exit(2); // Config error
        }
        return err;
    };
    defer config.deinit();

    // Load state.json
    var sync_state = try state_mod.SyncState.load(allocator);
    defer sync_state.deinit();

    // Track results
    var success_count: usize = 0;
    const skipped_count: usize = 0;
    var failed_count: usize = 0;
    var errors = std.ArrayList([]const u8).init(allocator);
    defer {
        for (errors.items) |err_msg| {
            allocator.free(err_msg);
        }
        errors.deinit();
    }

    // Sync submodules
    if (submodule_name) |name| {
        // Sync single submodule
        const submodule = config.findByName(name) orelse {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error: Submodule '{s}' not found in salt.conf\n", .{name});
            if (options.ci_mode) {
                std.process.exit(2); // Config error
            }
            return error.SubmoduleNotFound;
        };

        syncSubmodule(
            allocator,
            submodule,
            parent_branch,
            &sync_state,
            options,
        ) catch |err| {
            failed_count += 1;
            const err_msg = try std.fmt.allocPrint(
                allocator,
                "Failed to sync '{s}': {}",
                .{ name, err },
            );
            try errors.append(err_msg);

            if (options.ci_mode) {
                const stderr = std.io.getStdErr().writer();
                try stderr.print("Error: {s}\n", .{err_msg});
                std.process.exit(3); // Git error
            }
        };
        if (failed_count == 0) {
            success_count += 1;
        }
    } else {
        // Sync all submodules
        for (config.submodules.items) |*submodule| {
            syncSubmodule(
                allocator,
                submodule,
                parent_branch,
                &sync_state,
                options,
            ) catch |err| {
                failed_count += 1;
                const err_msg = try std.fmt.allocPrint(
                    allocator,
                    "Failed to sync '{s}': {}",
                    .{ submodule.name, err },
                );
                try errors.append(err_msg);

                if (options.ci_mode) {
                    const stderr = std.io.getStdErr().writer();
                    try stderr.print("Error: {s}\n", .{err_msg});
                    std.process.exit(3); // Git error
                }
                continue;
            };
            success_count += 1;
        }
    }

    if (!options.quiet) {
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll("\n");
        try stdout.print("  Synced: {} submodule(s)\n", .{success_count});
        if (skipped_count > 0) {
            try stdout.print("  Skipped: {} submodule(s)\n", .{skipped_count});
        }
        if (failed_count > 0) {
            try stdout.print("  Failed: {} submodule(s)\n", .{failed_count});
        }
    }

    if (errors.items.len > 0) {
        const stderr = std.io.getStdErr().writer();
        try stderr.writeAll("\nErrors:\n");
        for (errors.items) |err_msg| {
            try stderr.print("  - {s}\n", .{err_msg});
        }
        if (options.ci_mode) {
            std.process.exit(3); // Git error
        }
    }
}

/// Sync a single submodule
pub fn syncSubmodule(
    allocator: Allocator,
    submodule: *const config_types.Submodule,
    parent_branch: []const u8,
    sync_state: *state_mod.SyncState,
    options: SyncOptions,
) !void {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    if (!options.quiet) {
        try stdout.print("\nSyncing '{s}'...\n", .{submodule.name});
    }

    // Determine target branch from mapping
    const target_branch = mapper.getBranchMapping(submodule, parent_branch);

    if (!options.quiet) {
        try stdout.print("  Target branch: {s}\n", .{target_branch});
    }

    // Build source repo path
    const source_path = try std.fmt.allocPrint(
        allocator,
        ".salt/repos/{s}",
        .{submodule.name},
    );
    defer allocator.free(source_path);

    // Check if source repo exists
    if (!fs.pathExists(source_path)) {
        try stderr.print("  Error: Source repository not found at {s}\n", .{source_path});
        try stderr.print("  Run 'salt add' to initialize this submodule\n", .{});
        return error.SourceRepoNotFound;
    }

    // Check for uncommitted changes in parent path
    if (!options.force) {
        var status_result = try git.executeGitCommand(allocator, &[_][]const u8{
            "git",
            "status",
            "--porcelain",
            submodule.path,
        });
        defer status_result.deinit(allocator);

        if (status_result.stdout.len > 0) {
            try stderr.print("  ⚠ Skipping: Uncommitted changes in {s}\n", .{submodule.path});
            try stderr.print("  Use --force to sync anyway\n", .{});
            return error.UncommittedChanges;
        }
    }

    // Fetch latest changes from remote
    if (!options.quiet) {
        try stdout.print("  Fetching from remote...\n", .{});
    }

    var fetch_result = try git.executeGitCommand(allocator, &[_][]const u8{
        "git",
        "-C",
        source_path,
        "fetch",
        "origin",
    });
    defer fetch_result.deinit(allocator);

    if (fetch_result.exit_code != 0) {
        try stderr.print("  Warning: Failed to fetch from remote: {s}\n", .{fetch_result.stderr});
        // Continue anyway - we'll use what we have locally
    }

    // Checkout target branch
    if (!options.quiet) {
        try stdout.print("  Checking out branch {s}...\n", .{target_branch});
    }

    try git.checkout(allocator, source_path, target_branch);

    // Pull latest changes
    if (!options.quiet) {
        try stdout.print("  Pulling latest changes...\n", .{});
    }

    git.pull(allocator, source_path, "origin", target_branch) catch |err| {
        if (err == error.MergeConflict) {
            try stderr.print("  Error: Merge conflict detected in hidden repo\n", .{});
            try stderr.print("  Resolve conflicts in {s} and try again\n", .{source_path});
            return err;
        }
        // For other errors, log but continue
        try stderr.print("  Warning: Pull failed: {}\n", .{err});
    };

    // Copy files from source to parent path
    if (!options.quiet) {
        try stdout.print("  Copying files to {s}...\n", .{submodule.path});
    }

    try fs.copyDirectory(allocator, source_path, submodule.path, .{ .exclude_git = true });

    // Update state tracking
    try state_mod.updateAfterSync(
        sync_state,
        allocator,
        submodule.name,
        submodule.path,
        source_path,
        target_branch,
    );

    if (!options.quiet) {
        try stdout.print("  ✓ Successfully synced '{s}' to branch {s}\n", .{ submodule.name, target_branch });
    }
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\salt sync - Switch submodules to mapped branches
        \\
        \\USAGE:
        \\    salt sync [submodule-name] [options]
        \\
        \\DESCRIPTION:
        \\    Sync submodules to the branch mapped to the current parent branch.
        \\    This is used when you switch branches in the parent repository.
        \\
        \\ARGUMENTS:
        \\    [submodule-name]    Optional: Sync only the specified submodule
        \\                        If omitted, syncs all submodules
        \\
        \\OPTIONS:
        \\    --ci                Fail fast on any error (for CI/CD)
        \\    --quiet, -q         Suppress non-error output
        \\    --force, -f         Force sync even with uncommitted changes
        \\    --help, -h          Display this help message
        \\
        \\EXAMPLES:
        \\    # Sync all submodules to match current branch
        \\    salt sync
        \\
        \\    # Sync only the 'xyz' submodule
        \\    salt sync xyz
        \\
        \\    # Sync in CI mode (fail fast)
        \\    salt sync --ci
        \\
        \\    # Force sync even with uncommitted changes
        \\    salt sync --force
        \\
    );
}

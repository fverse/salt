const std = @import("std");
const Allocator = std.mem.Allocator;
const config_parser = @import("../config/parser.zig");
const config_types = @import("../config/types.zig");
const state = @import("../core/state.zig");
const mapper = @import("../core/mapper.zig");
const git = @import("../git/operations.zig");
const fs = @import("../utils/fs.zig");
const hash = @import("../utils/hash.zig");

const PushOptions = struct {
    force: bool = false,
    auto_sync: bool = false,
    ci_mode: bool = false,
    quiet: bool = false,
};

/// Pushes changes from submodules to their remotes
pub fn execute(allocator: Allocator, args: *std.process.ArgIterator) !void {
    var options = PushOptions{};
    var submodule_name: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "--auto-sync")) {
            options.auto_sync = true;
        } else if (std.mem.eql(u8, arg, "--ci")) {
            options.ci_mode = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            options.quiet = true;
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
    var sync_state = try state.SyncState.load(allocator);
    defer sync_state.deinit();

    // Get current parent branch
    const parent_branch = try git.getCurrentBranch(allocator, ".");
    defer allocator.free(parent_branch);

    if (!options.quiet) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("Current parent branch: {s}\n", .{parent_branch});
    }

    var success_count: usize = 0;
    var skipped_count: usize = 0;
    var failed_count: usize = 0;
    var errors = std.ArrayList([]const u8).init(allocator);
    defer {
        for (errors.items) |err_msg| {
            allocator.free(err_msg);
        }
        errors.deinit();
    }

    // Push submodules
    if (submodule_name) |name| {
        // Push single submodule
        const submodule = config.findByName(name) orelse {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error: Submodule '{s}' not found in salt.conf\n", .{name});
            if (options.ci_mode) {
                std.process.exit(2); // Config error
            }
            return error.SubmoduleNotFound;
        };

        pushSubmodule(
            allocator,
            submodule,
            parent_branch,
            &sync_state,
            options,
        ) catch |err| {
            if (err == error.NoChanges or err == error.BranchMismatch) {
                skipped_count += 1;
            } else {
                failed_count += 1;
                const err_msg = try std.fmt.allocPrint(
                    allocator,
                    "Failed to push '{s}': {}",
                    .{ name, err },
                );
                try errors.append(err_msg);

                if (options.ci_mode) {
                    const stderr = std.io.getStdErr().writer();
                    try stderr.print("Error: {s}\n", .{err_msg});
                    std.process.exit(3); // Git error
                }
            }
        };
        if (failed_count == 0 and skipped_count == 0) {
            success_count += 1;
        }
    } else {
        // Push all submodules
        for (config.submodules.items) |*submodule| {
            pushSubmodule(
                allocator,
                submodule,
                parent_branch,
                &sync_state,
                options,
            ) catch |err| {
                if (err == error.NoChanges or err == error.BranchMismatch) {
                    skipped_count += 1;
                } else {
                    failed_count += 1;
                    const err_msg = try std.fmt.allocPrint(
                        allocator,
                        "Failed to push '{s}': {}",
                        .{ submodule.name, err },
                    );
                    try errors.append(err_msg);

                    if (options.ci_mode) {
                        const stderr = std.io.getStdErr().writer();
                        try stderr.print("Error: {s}\n", .{err_msg});
                        std.process.exit(3); // Git error
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
        try stdout.print("  Pushed: {} submodule(s)\n", .{success_count});
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

fn pushSubmodule(
    allocator: Allocator,
    submodule: *const config_types.Submodule,
    parent_branch: []const u8,
    sync_state: *state.SyncState,
    options: PushOptions,
) !void {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    if (!options.quiet) {
        try stdout.print("\nPushing '{s}'...\n", .{submodule.name});
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

    // Get submodule state
    const submodule_state = sync_state.submodules.get(submodule.name) orelse {
        try stderr.print("  Error: No state found for submodule '{s}'\n", .{submodule.name});
        try stderr.print("  Run 'salt sync' to initialize state\n", .{});
        return error.NoState;
    };

    // Detect branch mismatch (STALE status)
    const expected_branch = mapper.getBranchMapping(submodule, parent_branch);
    const branch_mismatch = !std.mem.eql(u8, submodule_state.source_branch, expected_branch);

    if (branch_mismatch and !options.force) {
        try stderr.print("  ⚠ Branch mismatch detected:\n", .{});
        try stderr.print("    Current: {s}\n", .{submodule_state.source_branch});
        try stderr.print("    Expected: {s}\n", .{expected_branch});
        try stderr.print("    Files may be from wrong branch (STALE)\n", .{});

        if (options.auto_sync) {
            try stderr.print("  Running auto-sync...\n", .{});
            // Import sync module to run sync
            const sync_cmd = @import("sync.zig");
            const sync_options = sync_cmd.SyncOptions{
                .ci_mode = options.ci_mode,
                .quiet = true,
                .force = false,
            };
            // Sync this specific submodule
            try sync_cmd.syncSubmodule(
                allocator,
                submodule,
                parent_branch,
                sync_state,
                sync_options,
            );

            if (!options.quiet) {
                try stdout.print("  ✓ Auto-sync completed\n", .{});
            }
        } else {
            try stderr.print("  Use --auto-sync to sync before push, or --force to push anyway\n", .{});
            try stderr.print("  Recommended: salt sync {s}\n", .{submodule.name});
            return error.BranchMismatch;
        }
    }

    // Hash parent directory to detect changes
    const current_hash = try hash.hashDirectory(allocator, submodule.path);
    defer allocator.free(current_hash);

    // Compare with last push hash
    if (std.mem.eql(u8, current_hash, submodule_state.parent_files_hash)) {
        if (!options.quiet) {
            try stdout.print("  No changes to push\n", .{});
        }
        return error.NoChanges;
    }

    if (!options.quiet) {
        try stdout.print("  Changes detected, preparing to push...\n", .{});
    }

    // Copy changed files to hidden source repo
    if (!options.quiet) {
        try stdout.print("  Copying files to source repo...\n", .{});
    }

    try fs.copyDirectory(allocator, submodule.path, source_path, .{ .exclude_git = true });

    // Get current branch in source repo
    const current_branch = try git.getCurrentBranch(allocator, source_path);
    defer allocator.free(current_branch);

    if (!options.quiet) {
        try stdout.print("  Current branch in source: {s}\n", .{current_branch});
    }

    // Stage changes in source repo
    if (!options.quiet) {
        try stdout.print("  Staging changes...\n", .{});
    }

    var add_result = try git.executeGitCommand(allocator, &[_][]const u8{
        "git",
        "-C",
        source_path,
        "add",
        ".",
    });
    defer add_result.deinit(allocator);

    if (add_result.exit_code != 0) {
        try stderr.print("  Error: Failed to stage changes: {s}\n", .{add_result.stderr});
        return error.StageFailed;
    }

    // Check if there are actually changes to commit
    var status_result = try git.executeGitCommand(allocator, &[_][]const u8{
        "git",
        "-C",
        source_path,
        "status",
        "--porcelain",
    });
    defer status_result.deinit(allocator);

    if (status_result.stdout.len == 0) {
        if (!options.quiet) {
            try stdout.print("  No changes to commit (files identical)\n", .{});
        }
        return error.NoChanges;
    }

    // Commit changes in source repo
    if (!options.quiet) {
        try stdout.print("  Committing changes...\n", .{});
    }

    const commit_msg = try std.fmt.allocPrint(
        allocator,
        "Update from parent repo (branch: {s})",
        .{parent_branch},
    );
    defer allocator.free(commit_msg);

    var commit_result = try git.executeGitCommand(allocator, &[_][]const u8{
        "git",
        "-C",
        source_path,
        "commit",
        "-m",
        commit_msg,
    });
    defer commit_result.deinit(allocator);

    if (commit_result.exit_code != 0) {
        try stderr.print("  Error: Failed to commit changes: {s}\n", .{commit_result.stderr});
        return error.CommitFailed;
    }

    // Push to remote
    if (!options.quiet) {
        try stdout.print("  Pushing to origin/{s}...\n", .{current_branch});
    }

    git.push(allocator, source_path, "origin", current_branch) catch |err| {
        if (err == error.PushFailed) {
            try stderr.print("  Error: Push failed\n", .{});
            try stderr.print("  This may be due to:\n", .{});
            try stderr.print("    - No upstream branch configured\n", .{});
            try stderr.print("    - Push rejected (non-fast-forward)\n", .{});
            try stderr.print("    - Network issues or authentication failure\n", .{});
            try stderr.print("  Try:\n", .{});
            try stderr.print("    - salt pull {s}  (to pull latest changes)\n", .{submodule.name});
            try stderr.print("    - git -C {s} push --set-upstream origin {s}\n", .{ source_path, current_branch });
            return err;
        }
        return err;
    };

    // Update state tracking
    try state.updateAfterPush(
        sync_state,
        allocator,
        submodule.name,
        submodule.path,
        source_path,
    );

    if (!options.quiet) {
        try stdout.print("  ✓ Successfully pushed '{s}' to {s}\n", .{ submodule.name, current_branch });
    }
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\salt push - Push changes to submodule remotes
        \\
        \\USAGE:
        \\    salt push [submodule-name] [options]
        \\
        \\DESCRIPTION:
        \\    Push changes from submodules to their remote repositories.
        \\    Detects changes in parent directory and commits/pushes to source repo.
        \\
        \\ARGUMENTS:
        \\    [submodule-name]    Optional: Push only the specified submodule
        \\                        If omitted, pushes all submodules with changes
        \\
        \\OPTIONS:
        \\    --force, -f         Force push even with branch mismatch
        \\    --auto-sync         Automatically sync before push if branch mismatch
        \\    --ci                Fail fast on any error (for CI/CD)
        \\    --quiet, -q         Suppress non-error output
        \\    --help, -h          Display this help message
        \\
        \\EXAMPLES:
        \\    # Push all submodules with changes
        \\    salt push
        \\
        \\    # Push only the 'xyz' submodule
        \\    salt push xyz
        \\
        \\    # Auto-sync before push if needed
        \\    salt push --auto-sync
        \\
        \\    # Force push even with branch mismatch
        \\    salt push --force
        \\
    );
}

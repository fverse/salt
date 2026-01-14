const std = @import("std");
const Allocator = std.mem.Allocator;
const config_parser = @import("../config/parser.zig");
const config_types = @import("../config/types.zig");
const state_mod = @import("../core/state.zig");
const git = @import("../git/operations.zig");
const fs = @import("../utils/fs.zig");

pub const ResolveOptions = struct {
    quiet: bool = false,
    force: bool = false,
};

/// Resolves all submodule dependencies by cloning/updating them
pub fn execute(allocator: Allocator, args: *std.process.ArgIterator) !void {
    var options = ResolveOptions{};
    var submodule_name: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            options.quiet = true;
        } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (submodule_name == null) {
                submodule_name = arg;
            }
        }
    }

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    // Load salt.conf
    var parser = config_parser.Parser.init(allocator);
    defer parser.deinit();

    var config = parser.parseFile("salt.conf") catch |err| {
        try stderr.print("Error: Failed to load salt.conf: {}\n", .{err});
        try stderr.writeAll("Run 'salt init' to create a salt.conf file\n");
        return err;
    };
    defer config.deinit();

    if (config.submodules.items.len == 0) {
        try stdout.writeAll("No submodules defined in salt.conf\n");
        return;
    }

    // Ensure .salt/repos directory exists
    std.fs.cwd().makePath(".salt/repos") catch |err| {
        if (err != error.PathAlreadyExists) {
            try stderr.print("Error: Failed to create .salt/repos directory: {}\n", .{err});
            return err;
        }
    };

    // Load state
    var sync_state = try state_mod.SyncState.load(allocator);
    defer sync_state.deinit();

    // Track results
    var resolved_count: usize = 0;
    var updated_count: usize = 0;
    var skipped_count: usize = 0;
    var failed_count: usize = 0;
    var nested_deps = std.ArrayList([]const u8).init(allocator);
    defer nested_deps.deinit();

    if (submodule_name) |name| {
        // Resolve single submodule
        const submodule = config.findByName(name) orelse {
            try stderr.print("Error: Submodule '{s}' not found in salt.conf\n", .{name});
            return error.SubmoduleNotFound;
        };

        const result = resolveSubmodule(
            allocator,
            submodule,
            &sync_state,
            options,
            &nested_deps,
        ) catch |err| {
            failed_count += 1;
            try stderr.print("✗ Failed to resolve '{s}': {}\n", .{ name, err });
            return err;
        };

        switch (result) {
            .resolved => resolved_count += 1,
            .updated => updated_count += 1,
            .skipped => skipped_count += 1,
        }
    } else {
        // Resolve all submodules
        for (config.submodules.items) |*submodule| {
            const result = resolveSubmodule(
                allocator,
                submodule,
                &sync_state,
                options,
                &nested_deps,
            ) catch |err| {
                failed_count += 1;
                try stderr.print("✗ Failed to resolve '{s}': {}\n", .{ submodule.name, err });
                continue;
            };

            switch (result) {
                .resolved => resolved_count += 1,
                .updated => updated_count += 1,
                .skipped => skipped_count += 1,
            }
        }
    }

    // Print summary
    if (!options.quiet) {
        try stdout.writeAll("\n");
        if (resolved_count > 0) {
            try stdout.print("  Resolved: {} submodule(s)\n", .{resolved_count});
        }
        if (updated_count > 0) {
            try stdout.print("  Updated: {} submodule(s)\n", .{updated_count});
        }
        if (skipped_count > 0) {
            try stdout.print("  Skipped: {} submodule(s)\n", .{skipped_count});
        }
        if (failed_count > 0) {
            try stdout.print("  Failed: {} submodule(s)\n", .{failed_count});
        }

        // Notify about nested dependencies
        if (nested_deps.items.len > 0) {
            try stdout.writeAll("\n⚠ Nested salt dependencies detected:\n");
            for (nested_deps.items) |dep_path| {
                try stdout.print("  → {s}/salt.conf\n", .{dep_path});
            }
            try stdout.writeAll("  Run 'salt resolve' inside those directories to resolve them.\n");
        }
    }
}

const ResolveResult = enum {
    resolved, // Freshly cloned
    updated, // Existing, verified/updated
    skipped, // Already up to date
};

/// Resolve a single submodule
fn resolveSubmodule(
    allocator: Allocator,
    submodule: *const config_types.Submodule,
    sync_state: *state_mod.SyncState,
    options: ResolveOptions,
    nested_deps: *std.ArrayList([]const u8),
) !ResolveResult {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    if (!options.quiet) {
        try stdout.print("\nResolving '{s}'...\n", .{submodule.name});
    }

    const source_path = try std.fmt.allocPrint(
        allocator,
        ".salt/repos/{s}",
        .{submodule.name},
    );
    defer allocator.free(source_path);

    const target_branch = submodule.default_branch;
    var result: ResolveResult = undefined;

    // Check if source repo exists
    if (fs.pathExists(source_path)) {
        // Verify/update existing repo
        if (!options.quiet) {
            try stdout.print("  Source repo exists, verifying...\n", .{});
        }

        // Fetch latest
        if (!options.quiet) {
            try stdout.print("  Fetching from remote...\n", .{});
        }

        var fetch_result = try git.executeGitCommand(allocator, &[_][]const u8{
            "git", "-C", source_path, "fetch", "origin",
        });
        defer fetch_result.deinit(allocator);

        if (fetch_result.exit_code != 0) {
            try stderr.print("  Warning: Failed to fetch: {s}\n", .{fetch_result.stderr});
        }

        // Checkout correct branch
        if (!options.quiet) {
            try stdout.print("  Checking out branch {s}...\n", .{target_branch});
        }

        try git.checkout(allocator, source_path, target_branch);

        // Pull latest
        git.pull(allocator, source_path, "origin", target_branch) catch |err| {
            if (err == error.MergeConflict) {
                try stderr.print("  Error: Merge conflict in {s}\n", .{source_path});
                return err;
            }
            try stderr.print("  Warning: Pull failed: {}\n", .{err});
        };

        result = .updated;
    } else {
        // Clone fresh
        if (!options.quiet) {
            try stdout.print("  Cloning from {s}...\n", .{submodule.url});
            try stdout.print("  Branch: {s}\n", .{target_branch});
        }

        if (submodule.shallow) {
            try cloneRepositoryShallow(allocator, submodule.url, source_path, target_branch);
        } else {
            try git.cloneRepository(allocator, submodule.url, source_path, target_branch);
        }

        result = .resolved;
    }

    // Check if target path exists
    const target_exists = fs.pathExists(submodule.path);

    if (target_exists and !options.force) {
        // Verify existing files match source
        if (!options.quiet) {
            try stdout.print("  Target path exists, syncing files...\n", .{});
        }
    }

    // Copy files to target path
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

    // Check for nested salt.conf
    const nested_salt_conf = try std.fmt.allocPrint(
        allocator,
        "{s}/salt.conf",
        .{submodule.path},
    );
    defer allocator.free(nested_salt_conf);

    if (fs.pathExists(nested_salt_conf)) {
        const path_copy = try allocator.dupe(u8, submodule.path);
        try nested_deps.append(path_copy);
    }

    if (!options.quiet) {
        const action = if (result == .resolved) "Resolved" else "Updated";
        try stdout.print("  ✓ {s} '{s}' on branch {s}\n", .{ action, submodule.name, target_branch });
    }

    return result;
}

/// Clone a repository with shallow clone
fn cloneRepositoryShallow(allocator: Allocator, url: []const u8, dest_dir: []const u8, branch: []const u8) !void {
    const argv = [_][]const u8{
        "git", "clone", "--depth", "1", "--branch", branch, "--single-branch", url, dest_dir,
    };

    var process = std.process.Child.init(&argv, allocator);
    process.stdin_behavior = .Ignore;
    process.stdout_behavior = .Inherit;
    process.stderr_behavior = .Inherit;

    try process.spawn();
    const term = try process.wait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                return error.GitCloneFailed;
            }
        },
        else => {
            return error.GitCloneFailed;
        },
    }
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\salt resolve - Download and setup all submodule dependencies
        \\
        \\USAGE:
        \\    salt resolve [submodule-name] [options]
        \\
        \\DESCRIPTION:
        \\    Resolves all submodule dependencies defined in salt.conf.
        \\    Use this after cloning a repository that uses salt submodules.
        \\
        \\    For each submodule:
        \\    - If not present: clones the repository to .salt/repos/<name>
        \\    - If present: verifies and updates to the default branch
        \\    - Copies files to the target path (excluding .git)
        \\    - Detects nested salt.conf files and notifies about them
        \\
        \\ARGUMENTS:
        \\    [submodule-name]    Optional: Resolve only the specified submodule
        \\                        If omitted, resolves all submodules
        \\
        \\OPTIONS:
        \\    --quiet, -q         Suppress non-error output
        \\    --force, -f         Force overwrite existing files
        \\    --help, -h          Display this help message
        \\
        \\EXAMPLES:
        \\    # Resolve all submodules after cloning
        \\    salt resolve
        \\
        \\    # Resolve only a specific submodule
        \\    salt resolve hello-world
        \\
        \\    # Force resolve (overwrite existing)
        \\    salt resolve --force
        \\
    );
}

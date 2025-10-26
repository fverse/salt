const std = @import("std");
const Allocator = std.mem.Allocator;
const config_parser = @import("../config/parser.zig");
const config_types = @import("../config/types.zig");
const state_mod = @import("../core/state.zig");
const git = @import("../git/operations.zig");
const mapper = @import("../core/mapper.zig");
const hash = @import("../utils/hash.zig");
const output = @import("../utils/output.zig");

const SubmoduleConfig = config_types.SubmoduleConfig;
const Submodule = config_types.Submodule;
const SyncState = state_mod.SyncState;
const SyncStatus = state_mod.SyncStatus;

pub const SubmoduleStatus = struct {
    name: []const u8,
    path: []const u8,
    current_branch: []const u8,
    expected_branch: []const u8,
    status: SyncStatus,
    modified_files: usize,
    ahead: usize,
    behind: usize,
    exists: bool,

    pub fn deinit(self: *SubmoduleStatus, allocator: Allocator) void {
        allocator.free(self.current_branch);
        allocator.free(self.expected_branch);
    }
};

pub fn execute(allocator: Allocator, iter: *std.process.ArgIterator) !void {
    var verbose = false;
    var json_output = false;

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            return;
        } else {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Unknown flag: {s}\n", .{arg});
            try printHelp();
            return error.InvalidArgument;
        }
    }

    // Load configuration
    var parser = config_parser.Parser.init(allocator);
    defer parser.deinit();

    var config = parser.parseFile("salt.conf") catch |err| {
        const stderr = std.io.getStdErr().writer();
        if (err == error.FileNotFound) {
            try stderr.writeAll("Error: salt.conf not found. Run 'salt init' to create it.\n");
        } else {
            try stderr.print("Error loading configuration: {}\n", .{err});
        }
        return err;
    };
    defer config.deinit();

    // Load state
    var sync_state = try SyncState.load(allocator);
    defer sync_state.deinit();

    // Get current parent branch
    const parent_branch = try git.getCurrentBranch(allocator, ".");
    defer allocator.free(parent_branch);

    // Collect status for all submodules
    var statuses = std.ArrayList(SubmoduleStatus).init(allocator);
    defer {
        for (statuses.items) |*status| {
            status.deinit(allocator);
        }
        statuses.deinit();
    }

    for (config.submodules.items) |*submodule| {
        const status = try collectSubmoduleStatus(
            allocator,
            submodule,
            &sync_state,
            parent_branch,
            verbose,
        );
        try statuses.append(status);
    }

    // Output results
    if (json_output) {
        try outputJson(allocator, statuses.items, parent_branch);
    } else {
        try outputTable(allocator, statuses.items, parent_branch, verbose);
    }
}

fn collectSubmoduleStatus(
    allocator: Allocator,
    submodule: *const Submodule,
    sync_state: *const SyncState,
    parent_branch: []const u8,
    verbose: bool,
) !SubmoduleStatus {
    const exists = blk: {
        std.fs.cwd().access(submodule.path, .{}) catch |err| {
            if (err == error.FileNotFound) break :blk false;
            return err;
        };
        break :blk true;
    };

    if (!exists) {
        return SubmoduleStatus{
            .name = submodule.name,
            .path = submodule.path,
            .current_branch = try allocator.dupe(u8, "-"),
            .expected_branch = try allocator.dupe(u8, "-"),
            .status = .behind, // Missing is treated as behind
            .modified_files = 0,
            .ahead = 0,
            .behind = 0,
            .exists = false,
        };
    }

    // Get expected branch from mapping
    const expected_branch = mapper.getBranchMapping(submodule, parent_branch);
    const expected_branch_copy = try allocator.dupe(u8, expected_branch);

    // Get current branch from hidden repo
    const source_path = try std.fmt.allocPrint(
        allocator,
        ".salt/repos/{s}",
        .{submodule.name},
    );
    defer allocator.free(source_path);

    const current_branch = git.getCurrentBranch(allocator, source_path) catch |err| blk: {
        if (err == error.FileNotFound) {
            break :blk try allocator.dupe(u8, "unknown");
        }
        return err;
    };

    // Get submodule state
    const submodule_state = sync_state.submodules.get(submodule.name);

    // Detect sync status
    const status = if (submodule_state) |state|
        try state_mod.detectSyncStatus(allocator, submodule, &state, parent_branch)
    else
        SyncStatus.behind; // No state means never synced

    // Count modified files in parent directory
    const modified_files = if (verbose)
        try countModifiedFiles(allocator, submodule.path)
    else
        0;

    // Count ahead/behind commits
    var ahead: usize = 0;
    var behind: usize = 0;

    if (verbose and submodule_state != null) {
        const counts = try getAheadBehindCounts(allocator, source_path, expected_branch);
        ahead = counts.ahead;
        behind = counts.behind;
    }

    return SubmoduleStatus{
        .name = submodule.name,
        .path = submodule.path,
        .current_branch = current_branch,
        .expected_branch = expected_branch_copy,
        .status = status,
        .modified_files = modified_files,
        .ahead = ahead,
        .behind = behind,
        .exists = true,
    };
}

/// Count modified files in a directory
fn countModifiedFiles(allocator: Allocator, path: []const u8) !usize {
    const result = try git.executeGitCommand(allocator, &[_][]const u8{
        "git",
        "status",
        "--porcelain",
        path,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.exit_code != 0) {
        return 0;
    }

    // Count non-empty lines
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) {
            count += 1;
        }
    }

    return count;
}

/// Get ahead/behind commit counts
fn getAheadBehindCounts(
    allocator: Allocator,
    repo_path: []const u8,
    branch: []const u8,
) !struct { ahead: usize, behind: usize } {
    // Fetch latest from remote
    _ = git.executeGitCommand(allocator, &[_][]const u8{
        "git",
        "-C",
        repo_path,
        "fetch",
        "origin",
        branch,
    }) catch {
        return .{ .ahead = 0, .behind = 0 };
    };

    // Get ahead/behind counts
    const rev_spec = try std.fmt.allocPrint(allocator, "{s}...origin/{s}", .{ branch, branch });
    defer allocator.free(rev_spec);

    const result = try git.executeGitCommand(allocator, &[_][]const u8{
        "git",
        "-C",
        repo_path,
        "rev-list",
        "--left-right",
        "--count",
        rev_spec,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.exit_code != 0) {
        return .{ .ahead = 0, .behind = 0 };
    }

    // Parse output: "ahead\tbehind\n"
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, result.stdout, "\n\t "), '\t');
    const ahead_str = parts.next() orelse "0";
    const behind_str = parts.next() orelse "0";

    const ahead = std.fmt.parseInt(usize, ahead_str, 10) catch 0;
    const behind = std.fmt.parseInt(usize, behind_str, 10) catch 0;

    return .{ .ahead = ahead, .behind = behind };
}

fn outputTable(
    allocator: Allocator,
    statuses: []const SubmoduleStatus,
    parent_branch: []const u8,
    verbose: bool,
) !void {
    const stdout = std.io.getStdOut().writer();

    if (statuses.len == 0) {
        try stdout.writeAll("No submodules configured.\n");
        return;
    }

    try stdout.writeAll("\n");
    try output.printColor(stdout, .bold, "Parent branch: ");
    try output.printColor(stdout, .cyan, parent_branch);
    try stdout.writeAll("\n\n");

    // Print table header
    try stdout.writeAll("Submodules:\n");
    try stdout.writeAll("┌");
    try stdout.writeAll("─────────────");
    try stdout.writeAll("┬");
    try stdout.writeAll("──────────");
    try stdout.writeAll("┬");
    try stdout.writeAll("──────────");
    try stdout.writeAll("┬");
    try stdout.writeAll("─────────────");
    try stdout.writeAll("┬");
    try stdout.writeAll("──────────────");
    try stdout.writeAll("┬");
    try stdout.writeAll("─────────────");
    try stdout.writeAll("┐\n");

    try stdout.writeAll("│ Name        │ Branch   │ Status   │ Parent      │ Source Repo  │ Action      │\n");

    try stdout.writeAll("├");
    try stdout.writeAll("─────────────");
    try stdout.writeAll("┼");
    try stdout.writeAll("──────────");
    try stdout.writeAll("┼");
    try stdout.writeAll("──────────");
    try stdout.writeAll("┼");
    try stdout.writeAll("─────────────");
    try stdout.writeAll("┼");
    try stdout.writeAll("──────────────");
    try stdout.writeAll("┼");
    try stdout.writeAll("─────────────");
    try stdout.writeAll("┤\n");

    // Print each submodule
    var suggestions = std.ArrayList([]const u8).init(allocator);
    defer {
        for (suggestions.items) |suggestion| {
            allocator.free(suggestion);
        }
        suggestions.deinit();
    }

    for (statuses) |status| {
        try printStatusRow(stdout, &status, &suggestions, allocator);
    }

    // Print table footer
    try stdout.writeAll("└");
    try stdout.writeAll("─────────────");
    try stdout.writeAll("┴");
    try stdout.writeAll("──────────");
    try stdout.writeAll("┴");
    try stdout.writeAll("──────────");
    try stdout.writeAll("┴");
    try stdout.writeAll("─────────────");
    try stdout.writeAll("┴");
    try stdout.writeAll("──────────────");
    try stdout.writeAll("┴");
    try stdout.writeAll("─────────────");
    try stdout.writeAll("┘\n");

    // Print suggestions with colors
    if (suggestions.items.len > 0) {
        try stdout.writeAll("\n");
        for (suggestions.items) |suggestion| {
            // Parse and colorize the suggestion
            if (std.mem.startsWith(u8, suggestion, "✗")) {
                try output.printColor(stdout, .red, "✗");
                try stdout.print("{s}\n", .{suggestion[3..]});
            } else if (std.mem.startsWith(u8, suggestion, "⚠")) {
                try output.printColor(stdout, .yellow, "⚠");
                try stdout.print("{s}\n", .{suggestion[3..]});
            } else {
                try stdout.print("{s}\n", .{suggestion});
            }
        }
    }

    // Print verbose details if requested
    if (verbose) {
        try stdout.writeAll("\n");
        try output.printColor(stdout, .bold, "Detailed Information:");
        try stdout.writeAll("\n");

        for (statuses) |status| {
            if (!status.exists) continue;

            try stdout.writeAll("\n");
            try output.printColor(stdout, .cyan, status.name);
            try stdout.writeAll(":\n");

            try stdout.print("  Path: {s}\n", .{status.path});

            try stdout.writeAll("  Current branch: ");
            try output.printColor(stdout, .green, status.current_branch);
            try stdout.writeAll("\n");

            try stdout.writeAll("  Expected branch: ");
            try output.printColor(stdout, .green, status.expected_branch);
            try stdout.writeAll("\n");

            try stdout.writeAll("  Status: ");
            const status_color: output.Color = switch (status.status) {
                .synced => .green,
                .diverged => .red,
                else => .yellow,
            };
            try output.printColor(stdout, status_color, @tagName(status.status));
            try stdout.writeAll("\n");

            if (status.modified_files > 0) {
                try stdout.writeAll("  Modified files: ");
                try output.printColorf(stdout, .yellow, "{}", .{status.modified_files});
                try stdout.writeAll("\n");
            }

            if (status.ahead > 0 or status.behind > 0) {
                try stdout.writeAll("  Ahead: ");
                try output.printColorf(stdout, .cyan, "{}", .{status.ahead});
                try stdout.writeAll(" | Behind: ");
                try output.printColorf(stdout, .cyan, "{}", .{status.behind});
                try stdout.writeAll("\n");
            }
        }
    }
}

/// Print a single status row
fn printStatusRow(
    writer: anytype,
    status: *const SubmoduleStatus,
    suggestions: *std.ArrayList([]const u8),
    allocator: Allocator,
) !void {
    // Truncate name if too long
    var name_buf: [11]u8 = undefined;
    const name_display = if (status.name.len > 11)
        try std.fmt.bufPrint(&name_buf, "{s}...", .{status.name[0..8]})
    else
        status.name;

    // Truncate branch if too long
    var branch_buf: [8]u8 = undefined;
    const branch_display = if (status.current_branch.len > 8)
        try std.fmt.bufPrint(&branch_buf, "{s}...", .{status.current_branch[0..5]})
    else
        status.current_branch;

    // Status symbol and color - create colored string
    const status_str = switch (status.status) {
        .synced => try output.coloredCell(allocator, .green, "✓ SYNCED"),
        .dirty => try output.coloredCell(allocator, .yellow, "⚠ DIRTY"),
        .behind => try output.coloredCell(allocator, .yellow, "⚠ BEHIND"),
        .ahead => try output.coloredCell(allocator, .yellow, "⚠ AHEAD"),
        .diverged => try output.coloredCell(allocator, .red, "✗ DIVERG"),
        .stale => try output.coloredCell(allocator, .yellow, "⚠ STALE"),
    };
    defer allocator.free(status_str);

    // Parent state
    const parent_state = if (!status.exists)
        "Missing"
    else if (status.modified_files > 0)
        try std.fmt.allocPrint(allocator, "{} modified", .{status.modified_files})
    else
        "Clean";
    defer if (status.exists and status.modified_files > 0) allocator.free(parent_state);

    // Source repo state
    const source_state = if (!status.exists)
        "-"
    else if (status.ahead > 0 and status.behind > 0)
        try std.fmt.allocPrint(allocator, "{}↑ {}↓", .{ status.ahead, status.behind })
    else if (status.ahead > 0)
        try std.fmt.allocPrint(allocator, "{} ahead", .{status.ahead})
    else if (status.behind > 0)
        try std.fmt.allocPrint(allocator, "{} behind", .{status.behind})
    else
        "Up to date";
    defer if (status.exists and (status.ahead > 0 or status.behind > 0)) allocator.free(source_state);

    // Action
    const action = switch (status.status) {
        .synced => "-",
        .dirty => "Need push",
        .behind => "Need pull",
        .ahead => "Pushed",
        .diverged => "Need sync",
        .stale => "Need sync",
    };

    // Print row
    try writer.print("│ {s: <11} │ {s: <8} │ {s: <8} │ {s: <11} │ {s: <12} │ {s: <11} │\n", .{
        name_display,
        branch_display,
        status_str,
        parent_state,
        source_state,
        action,
    });

    // Add suggestion
    const suggestion = try createSuggestion(allocator, status);
    if (suggestion) |sug| {
        try suggestions.append(sug);
    }
}

/// Create actionable suggestion for a submodule status
fn createSuggestion(allocator: Allocator, status: *const SubmoduleStatus) !?[]const u8 {
    return switch (status.status) {
        .synced => null,
        .dirty => try std.fmt.allocPrint(
            allocator,
            "⚠ {s}: You have uncommitted changes that need to be pushed\n  → Run: salt push {s}",
            .{ status.name, status.name },
        ),
        .behind => if (!status.exists)
            try std.fmt.allocPrint(
                allocator,
                "✗ {s}: Submodule directory doesn't exist\n  → Run: salt sync {s}",
                .{ status.name, status.name },
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "⚠ {s}: Source repo has new commits\n  → Run: salt pull {s}",
                .{ status.name, status.name },
            ),
        .ahead => null,
        .diverged => try std.fmt.allocPrint(
            allocator,
            "⚠ {s}: Both parent and source have changes\n  → Run: salt pull {s} then salt push {s}",
            .{ status.name, status.name, status.name },
        ),
        .stale => try std.fmt.allocPrint(
            allocator,
            "⚠ {s}: Files are from '{s}' branch but should be from '{s}'\n  This usually happens after merging branches.\n  → Run: salt sync {s}",
            .{ status.name, status.current_branch, status.expected_branch, status.name },
        ),
    };
}

fn outputJson(
    allocator: Allocator,
    statuses: []const SubmoduleStatus,
    parent_branch: []const u8,
) !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.writeAll("{\n");
    try stdout.print("  \"version\": \"1.0\",\n", .{});
    try stdout.print("  \"parent_branch\": \"{s}\",\n", .{parent_branch});
    try stdout.writeAll("  \"submodules\": [\n");

    for (statuses, 0..) |status, i| {
        if (i > 0) {
            try stdout.writeAll(",\n");
        }

        try stdout.writeAll("    {\n");
        try stdout.print("      \"name\": \"{s}\",\n", .{status.name});
        try stdout.print("      \"path\": \"{s}\",\n", .{status.path});
        try stdout.print("      \"current_branch\": \"{s}\",\n", .{status.current_branch});
        try stdout.print("      \"expected_branch\": \"{s}\",\n", .{status.expected_branch});
        try stdout.print("      \"status\": \"{s}\",\n", .{@tagName(status.status)});
        try stdout.print("      \"modified_files\": {},\n", .{status.modified_files});
        try stdout.print("      \"ahead\": {},\n", .{status.ahead});
        try stdout.print("      \"behind\": {},\n", .{status.behind});
        try stdout.print("      \"exists\": {}\n", .{status.exists});
        try stdout.writeAll("    }");
    }

    try stdout.writeAll("\n  ]\n");
    try stdout.writeAll("}\n");

    _ = allocator;
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\salt status - Show submodule status
        \\
        \\USAGE:
        \\    salt status [options]
        \\
        \\DESCRIPTION:
        \\    Display the current status of all configured submodules, including
        \\    their branches, sync status, and any pending changes.
        \\
        \\OPTIONS:
        \\    --verbose       Show detailed information including commit counts
        \\    --json          Output in JSON format for CI/CD consumption
        \\    -h, --help      Display this help message
        \\
        \\EXAMPLES:
        \\    # Show status of all submodules
        \\    salt status
        \\
        \\    # Show detailed status with commit counts
        \\    salt status --verbose
        \\
        \\    # Output status as JSON
        \\    salt status --json
        \\
    );
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const process = @import("../utils/process.zig");

pub const GitError = error{
    CommandFailed,
    RepositoryNotFound,
    BranchNotFound,
    RemoteNotFound,
    MergeConflict,
    CloneFailed,
    CheckoutFailed,
    PullFailed,
    PushFailed,
    Timeout,
    InvalidArguments,
};

pub const GitCommandResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,

    pub fn deinit(self: *GitCommandResult, allocator: Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const GitCommandOptions = struct {
    timeout_ms: ?u64 = null,
    capture_output: bool = true,
};

/// Clone a repository to a specified path
pub fn cloneRepository(allocator: Allocator, url: []const u8, path: []const u8, branch: []const u8) !void {
    const argv = [_][]const u8{ "git", "clone", "--branch", branch, url, path };
    var result = try executeGitCommandWithOptions(allocator, &argv, .{
        .timeout_ms = 300000, // 5 minutea
    });
    defer result.deinit(allocator);

    if (result.exit_code != 0) {
        std.debug.print("Failed to clone repository: {s}\n", .{result.stderr});
        return GitError.CloneFailed;
    }
}

/// Checkout a branch in a repository
pub fn checkout(allocator: Allocator, repo_path: []const u8, branch: []const u8) !void {
    const argv = [_][]const u8{ "git", "-C", repo_path, "checkout", branch };
    var result = try executeGitCommand(allocator, &argv);
    defer result.deinit(allocator);

    if (result.exit_code != 0) {
        // Try to create branch if it doesn't exist
        const create_argv = [_][]const u8{ "git", "-C", repo_path, "checkout", "-b", branch };
        var create_result = try executeGitCommand(allocator, &create_argv);
        defer create_result.deinit(allocator);

        if (create_result.exit_code != 0) {
            std.debug.print("Failed to checkout branch: {s}\n", .{create_result.stderr});
            return GitError.CheckoutFailed;
        }
    }
}

/// Pull changes from remote
pub fn pull(allocator: Allocator, repo_path: []const u8, remote: []const u8, branch: []const u8) !void {
    const argv = [_][]const u8{ "git", "-C", repo_path, "pull", remote, branch };
    var result = try executeGitCommandWithOptions(allocator, &argv, .{
        .timeout_ms = 120000, // 2 minute timeout for pulling
    });
    defer result.deinit(allocator);

    if (result.exit_code != 0) {
        // Check for specific error conditions
        if (std.mem.indexOf(u8, result.stderr, "merge conflict") != null or
            std.mem.indexOf(u8, result.stderr, "CONFLICT") != null)
        {
            return GitError.MergeConflict;
        }
        std.debug.print("Failed to pull from remote: {s}\n", .{result.stderr});
        return GitError.PullFailed;
    }
}

/// Push changes to remote
pub fn push(allocator: Allocator, repo_path: []const u8, remote: []const u8, branch: []const u8) !void {
    const argv = [_][]const u8{ "git", "-C", repo_path, "push", remote, branch };
    var result = try executeGitCommandWithOptions(allocator, &argv, .{
        .timeout_ms = 120000, // 2 minute timeout for pushing
    });
    defer result.deinit(allocator);

    if (result.exit_code != 0) {
        // Provide more detailed error messages based on stderr content
        if (std.mem.indexOf(u8, result.stderr, "no upstream") != null or
            std.mem.indexOf(u8, result.stderr, "has no upstream branch") != null)
        {
            std.debug.print("No upstream branch configured. Use: git push --set-upstream {s} {s}\n", .{ remote, branch });
        } else if (std.mem.indexOf(u8, result.stderr, "non-fast-forward") != null or
            std.mem.indexOf(u8, result.stderr, "rejected") != null)
        {
            std.debug.print("Push rejected (non-fast-forward). Pull changes first or use --force\n", .{});
        } else {
            std.debug.print("Failed to push to remote: {s}\n", .{result.stderr});
        }
        return GitError.PushFailed;
    }
}

/// Get the current branch name
pub fn getCurrentBranch(allocator: Allocator, repo_path: []const u8) ![]const u8 {
    const argv = [_][]const u8{ "git", "-C", repo_path, "rev-parse", "--abbrev-ref", "HEAD" };
    var result = try executeGitCommand(allocator, &argv);
    defer result.deinit(allocator);

    if (result.exit_code != 0) {
        std.debug.print("Failed to get current branch: {s}\n", .{result.stderr});
        return GitError.BranchNotFound;
    }

    // Trim trailing newline and whitespace
    const branch = std.mem.trim(u8, result.stdout, " \n\r\t");
    if (branch.len == 0) {
        return GitError.BranchNotFound;
    }

    return try allocator.dupe(u8, branch);
}

/// Get the current commit hash
pub fn getCurrentCommit(allocator: Allocator, repo_path: []const u8) ![]const u8 {
    const argv = [_][]const u8{ "git", "-C", repo_path, "rev-parse", "HEAD" };
    var result = try executeGitCommand(allocator, &argv);
    defer result.deinit(allocator);

    if (result.exit_code != 0) {
        std.debug.print("Failed to get current commit: {s}\n", .{result.stderr});
        return GitError.CommandFailed;
    }

    // Trim trailing newline and whitespace
    const commit = std.mem.trim(u8, result.stdout, " \n\r\t");
    if (commit.len == 0) {
        return GitError.CommandFailed;
    }

    return try allocator.dupe(u8, commit);
}

/// Execute a git command with arguments and return the result
pub fn executeGitCommand(allocator: Allocator, argv: []const []const u8) !GitCommandResult {
    return executeGitCommandWithOptions(allocator, argv, .{});
}

/// Execute a git command with options and return the result
pub fn executeGitCommandWithOptions(
    allocator: Allocator,
    argv: []const []const u8,
    options: GitCommandOptions,
) !GitCommandResult {
    if (argv.len == 0 or !std.mem.eql(u8, argv[0], "git")) {
        return GitError.InvalidArguments;
    }

    const result = try process.runWithOptions(allocator, argv, .{
        .timeout_ms = options.timeout_ms,
    });

    return GitCommandResult{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = result.exit_code,
    };
}

/// Execute a git command and check for success
pub fn executeGitCommandChecked(allocator: Allocator, argv: []const []const u8) !void {
    var result = try executeGitCommand(allocator, argv);
    defer result.deinit(allocator);

    if (result.exit_code != 0) {
        std.debug.print("Git command failed: {s}\n", .{result.stderr});
        return GitError.CommandFailed;
    }
}

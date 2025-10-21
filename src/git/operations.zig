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
};

/// Clone a repository to a specified path
pub fn cloneRepository(allocator: Allocator, url: []const u8, path: []const u8, branch: []const u8) !void {
    const argv = [_][]const u8{ "git", "clone", "--branch", branch, url, path };
    const result = try process.run(allocator, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.exit_code != 0) {
        std.debug.print("Failed to clone repository: {s}\n", .{result.stderr});
        return GitError.CloneFailed;
    }
}

/// Checkout a branch in a repository
pub fn checkout(allocator: Allocator, repo_path: []const u8, branch: []const u8) !void {
    const argv = [_][]const u8{ "git", "-C", repo_path, "checkout", branch };
    const result = try process.run(allocator, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.exit_code != 0) {
        // Try to create branch if it doesn't exist
        const create_argv = [_][]const u8{ "git", "-C", repo_path, "checkout", "-b", branch };
        const create_result = try process.run(allocator, &create_argv);
        defer allocator.free(create_result.stdout);
        defer allocator.free(create_result.stderr);

        if (create_result.exit_code != 0) {
            std.debug.print("Failed to checkout branch: {s}\n", .{create_result.stderr});
            return GitError.CheckoutFailed;
        }
    }
}

/// Pull changes from remote
pub fn pull(allocator: Allocator, repo_path: []const u8, remote: []const u8, branch: []const u8) !void {
    const argv = [_][]const u8{ "git", "-C", repo_path, "pull", remote, branch };
    const result = try process.run(allocator, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.exit_code != 0) {
        if (std.mem.indexOf(u8, result.stderr, "merge conflict") != null) {
            return GitError.MergeConflict;
        }
        std.debug.print("Failed to pull from remote: {s}\n", .{result.stderr});
        return GitError.PullFailed;
    }
}

/// Push changes to remote
pub fn push(allocator: Allocator, repo_path: []const u8, remote: []const u8, branch: []const u8) !void {
    const argv = [_][]const u8{ "git", "-C", repo_path, "push", remote, branch };
    const result = try process.run(allocator, &argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.exit_code != 0) {
        std.debug.print("Failed to push to remote: {s}\n", .{result.stderr});
        return GitError.PushFailed;
    }
}

/// Get the current branch name
pub fn getCurrentBranch(allocator: Allocator, repo_path: []const u8) ![]const u8 {
    const argv = [_][]const u8{ "git", "-C", repo_path, "rev-parse", "--abbrev-ref", "HEAD" };
    const result = try process.run(allocator, &argv);
    defer allocator.free(result.stderr);

    if (result.exit_code != 0) {
        allocator.free(result.stdout);
        std.debug.print("Failed to get current branch: {s}\n", .{result.stderr});
        return GitError.CommandFailed;
    }

    // Trim trailing newline
    const branch = std.mem.trimRight(u8, result.stdout, "\n");
    const branch_copy = try allocator.dupe(u8, branch);
    allocator.free(result.stdout);
    return branch_copy;
}

/// Get the current commit hash
pub fn getCurrentCommit(allocator: Allocator, repo_path: []const u8) ![]const u8 {
    const argv = [_][]const u8{ "git", "-C", repo_path, "rev-parse", "HEAD" };
    const result = try process.run(allocator, &argv);
    defer allocator.free(result.stderr);

    if (result.exit_code != 0) {
        allocator.free(result.stdout);
        std.debug.print("Failed to get current commit: {s}\n", .{result.stderr});
        return GitError.CommandFailed;
    }

    // Trim trailing newline
    const commit = std.mem.trimRight(u8, result.stdout, "\n");
    const commit_copy = try allocator.dupe(u8, commit);
    allocator.free(result.stdout);
    return commit_copy;
}

/// Execute a git command with arguments
pub fn executeGitCommand(allocator: Allocator, argv: []const []const u8) !void {
    const result = try process.run(allocator, argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.exit_code != 0) {
        std.debug.print("Git command failed: {s}\n", .{result.stderr});
        return GitError.CommandFailed;
    }
}

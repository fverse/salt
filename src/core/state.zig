const std = @import("std");
const Allocator = std.mem.Allocator;
const mapper = @import("mapper.zig");
const hash = @import("../utils/hash.zig");
const git = @import("../git/operations.zig");

/// Sync status enum representing the state of a submodule
pub const SyncStatus = enum {
    /// synced: Everything up to date
    synced,
    // Parent has uncommitted changes
    dirty,
    // behind: Source repo has new commits
    behind,
    /// diverged: Both have changes
    diverged,
    // Parent pushed but source not updated
    ahead,
    // Files from wrong source branch (after merge)
    stale,
};

/// State information for a single submodule, stored in <submodule_path>/saltstate.json
pub const SubmoduleState = struct {
    commit: []const u8,
    parent_hash: []const u8,
    branch: []const u8,
    synced: []const u8,

    pub fn deinit(self: *SubmoduleState, allocator: Allocator) void {
        allocator.free(self.commit);
        allocator.free(self.parent_hash);
        allocator.free(self.branch);
        allocator.free(self.synced);
    }
};

/// Load state from <submodule_path>/saltstate.json
pub fn loadSubmoduleState(allocator: Allocator, submodule_path: []const u8) !?SubmoduleState {
    const state_path = try std.fmt.allocPrint(allocator, "{s}/saltstate.json", .{submodule_path});
    defer allocator.free(state_path);

    const file = std.fs.cwd().openFile(state_path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    return try parseStateJson(allocator, content);
}

/// Save state to <submodule_path>/saltstate.json
pub fn saveSubmoduleState(allocator: Allocator, submodule_path: []const u8, state: *const SubmoduleState) !void {
    const state_path = try std.fmt.allocPrint(allocator, "{s}/saltstate.json", .{submodule_path});
    defer allocator.free(state_path);

    const temp_path = try std.fmt.allocPrint(allocator, "{s}/saltstate.json.tmp", .{submodule_path});
    defer allocator.free(temp_path);

    const file = try std.fs.cwd().createFile(temp_path, .{});
    defer file.close();

    const writer = file.writer();
    try writeStateJson(writer, state);

    try std.fs.cwd().rename(temp_path, state_path);
}

fn writeStateJson(writer: anytype, state: *const SubmoduleState) !void {
    try writer.writeAll("{\n");
    try writer.print("  \"commit\": \"{s}\",\n", .{state.commit});
    try writer.print("  \"parent_hash\": \"{s}\",\n", .{state.parent_hash});
    try writer.print("  \"branch\": \"{s}\",\n", .{state.branch});
    try writer.print("  \"synced\": \"{s}\"\n", .{state.synced});
    try writer.writeAll("}\n");
}

/// Parse a per-submodule saltstate.json
fn parseStateJson(allocator: Allocator, content: []const u8) !SubmoduleState {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        content,
        .{},
    );
    defer parsed.deinit();

    const obj = parsed.value.object;

    const commit = try allocator.dupe(u8, obj.get("commit").?.string);
    errdefer allocator.free(commit);

    const parent_hash = try allocator.dupe(u8, obj.get("parent_hash").?.string);
    errdefer allocator.free(parent_hash);

    const branch = try allocator.dupe(u8, obj.get("branch").?.string);
    errdefer allocator.free(branch);

    const synced = try allocator.dupe(u8, obj.get("synced").?.string);
    errdefer allocator.free(synced);

    return SubmoduleState{
        .commit = commit,
        .parent_hash = parent_hash,
        .branch = branch,
        .synced = synced,
    };
}

/// Get current timestamp in ISO 8601 format
pub fn getCurrentTimestamp(allocator: Allocator) ![]const u8 {
    const timestamp = std.time.timestamp();
    const epoch_seconds = @as(u64, @intCast(timestamp));

    const seconds_per_day = 86400;
    const seconds_per_hour = 3600;
    const seconds_per_minute = 60;

    const days_since_epoch = epoch_seconds / seconds_per_day;
    const remaining_seconds = epoch_seconds % seconds_per_day;

    const hours = remaining_seconds / seconds_per_hour;
    const minutes = (remaining_seconds % seconds_per_hour) / seconds_per_minute;
    const seconds = remaining_seconds % seconds_per_minute;

    const year = 1970 + (days_since_epoch / 365);
    const day_of_year = days_since_epoch % 365;
    const month = (day_of_year / 30) + 1;
    const day = (day_of_year % 30) + 1;

    return try std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{ year, month, day, hours, minutes, seconds },
    );
}

/// Detect the sync status of a submodule
pub fn detectSyncStatus(
    allocator: Allocator,
    submodule: anytype,
    state: *const SubmoduleState,
    parent_branch: []const u8,
) !SyncStatus {
    // 1. Check for branch mismatch (STALE status)
    const expected_branch = mapper.getBranchMapping(submodule, parent_branch);
    if (!std.mem.eql(u8, state.branch, expected_branch)) {
        return .stale;
    }

    // 2. Check if parent files changed (DIRTY status)
    const current_hash = try hash.hashDirectory(allocator, submodule.path);
    defer allocator.free(current_hash);

    const parent_changed = !std.mem.eql(u8, current_hash, state.parent_hash);

    // 3. Check if source repo has new commits (BEHIND status)
    const source_path = try std.fmt.allocPrint(
        allocator,
        ".salt/repos/{s}",
        .{submodule.name},
    );
    defer allocator.free(source_path);

    const current_commit = try git.getCurrentCommit(allocator, source_path);
    defer allocator.free(current_commit);

    const source_changed = !std.mem.eql(u8, current_commit, state.commit);

    // 4. Determine appropriate SyncStatus
    if (parent_changed and source_changed) {
        return .diverged;
    } else if (parent_changed) {
        return .dirty;
    } else if (source_changed) {
        return .behind;
    } else {
        return .synced;
    }
}

/// Update state after a sync operation
pub fn updateAfterSync(
    allocator: Allocator,
    submodule_path: []const u8,
    source_repo_path: []const u8,
    source_branch: []const u8,
) !void {
    const commit = try git.getCurrentCommit(allocator, source_repo_path);
    defer allocator.free(commit);

    const files_hash = try hash.hashDirectory(allocator, submodule_path);
    defer allocator.free(files_hash);

    const timestamp = try getCurrentTimestamp(allocator);
    defer allocator.free(timestamp);

    const state = SubmoduleState{
        .commit = commit,
        .parent_hash = files_hash,
        .branch = @constCast(source_branch),
        .synced = timestamp,
    };

    try saveSubmoduleState(allocator, submodule_path, &state);
}

/// Update state after a push operation
pub fn updateAfterPush(
    allocator: Allocator,
    submodule_path: []const u8,
    source_repo_path: []const u8,
) !void {
    const commit = try git.getCurrentCommit(allocator, source_repo_path);
    defer allocator.free(commit);

    const files_hash = try hash.hashDirectory(allocator, submodule_path);
    defer allocator.free(files_hash);

    // Load existing state to preserve branch
    const existing = try loadSubmoduleState(allocator, submodule_path);
    if (existing) |ex| {
        var ex_mut = ex;
        defer ex_mut.deinit(allocator);

        const timestamp = try getCurrentTimestamp(allocator);
        defer allocator.free(timestamp);

        const state = SubmoduleState{
            .commit = commit,
            .parent_hash = files_hash,
            .branch = ex.branch,
            .synced = timestamp,
        };

        try saveSubmoduleState(allocator, submodule_path, &state);
    } else {
        return error.NoState;
    }
}

/// Initialize state for a newly added submodule
pub fn initializeSubmoduleState(
    allocator: Allocator,
    submodule_path: []const u8,
    source_repo_path: []const u8,
    source_branch: []const u8,
) !void {
    const commit = try git.getCurrentCommit(allocator, source_repo_path);
    defer allocator.free(commit);

    const files_hash = try hash.hashDirectory(allocator, submodule_path);
    defer allocator.free(files_hash);

    const timestamp = try getCurrentTimestamp(allocator);
    defer allocator.free(timestamp);

    const state = SubmoduleState{
        .commit = commit,
        .parent_hash = files_hash,
        .branch = @constCast(source_branch),
        .synced = timestamp,
    };

    try saveSubmoduleState(allocator, submodule_path, &state);
}

/// Remove state file for a submodule
pub fn removeSubmoduleState(allocator: Allocator, submodule_path: []const u8) !void {
    const state_path = try std.fmt.allocPrint(allocator, "{s}/saltstate.json", .{submodule_path});
    defer allocator.free(state_path);

    std.fs.cwd().deleteFile(state_path) catch |err| {
        if (err != error.FileNotFound) return err;
    };
}

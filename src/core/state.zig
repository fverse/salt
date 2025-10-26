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

/// State information for a single submodule
pub const SubmoduleState = struct {
    last_sync_commit: []const u8,
    last_push_commit: []const u8,
    parent_files_hash: []const u8,
    source_branch: []const u8,
    last_sync_time: []const u8,
    last_push_time: ?[]const u8,

    pub fn deinit(self: *SubmoduleState, allocator: Allocator) void {
        allocator.free(self.last_sync_commit);
        allocator.free(self.last_push_commit);
        allocator.free(self.parent_files_hash);
        allocator.free(self.source_branch);
        allocator.free(self.last_sync_time);
        if (self.last_push_time) |time| {
            allocator.free(time);
        }
    }
};

pub const SyncState = struct {
    version: []const u8,
    submodules: std.StringHashMap(SubmoduleState),
    allocator: Allocator,

    pub fn init(allocator: Allocator) SyncState {
        return SyncState{
            .version = "1.0",
            .submodules = std.StringHashMap(SubmoduleState).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SyncState) void {
        var iter = self.submodules.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.submodules.deinit();
    }

    /// Load state from .salt/state.json
    pub fn load(allocator: Allocator) !SyncState {
        const file = std.fs.cwd().openFile(".salt/state.json", .{}) catch |err| {
            if (err == error.FileNotFound) {
                // Initialize empty state if file doesn't exist
                return SyncState.init(allocator);
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
        defer allocator.free(content);

        return try parseStateJson(allocator, content);
    }

    /// Save state to .salt/state.json
    pub fn save(self: *const SyncState, allocator: Allocator) !void {
        // Ensure .salt directory exists
        std.fs.cwd().makePath(".salt") catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Create temp file for atomic write
        const temp_path = ".salt/state.json.tmp";
        const file = try std.fs.cwd().createFile(temp_path, .{});
        defer file.close();

        const writer = file.writer();
        try self.writeJson(writer, allocator);

        try std.fs.cwd().rename(temp_path, ".salt/state.json");
    }

    fn writeJson(self: *const SyncState, writer: anytype, allocator: Allocator) !void {
        try writer.writeAll("{\n");
        try writer.print("  \"version\": \"{s}\",\n", .{self.version});
        try writer.writeAll("  \"submodules\": {\n");

        var iter = self.submodules.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) {
                try writer.writeAll(",\n");
            }
            first = false;

            const name = entry.key_ptr.*;
            const state = entry.value_ptr.*;

            try writer.print("    \"{s}\": {{\n", .{name});
            try writer.print("      \"last_sync_commit\": \"{s}\",\n", .{state.last_sync_commit});
            try writer.print("      \"last_push_commit\": \"{s}\",\n", .{state.last_push_commit});
            try writer.print("      \"parent_files_hash\": \"{s}\",\n", .{state.parent_files_hash});
            try writer.print("      \"source_branch\": \"{s}\",\n", .{state.source_branch});
            try writer.print("      \"last_sync_time\": \"{s}\"", .{state.last_sync_time});

            if (state.last_push_time) |push_time| {
                try writer.print(",\n      \"last_push_time\": \"{s}\"\n", .{push_time});
            } else {
                try writer.writeAll("\n");
            }

            try writer.writeAll("    }");
        }

        try writer.writeAll("\n  }\n");
        try writer.writeAll("}\n");
        _ = allocator;
    }
};

/// Parse JSON state file
fn parseStateJson(allocator: Allocator, content: []const u8) !SyncState {
    var state = SyncState.init(allocator);
    errdefer state.deinit();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        content,
        .{},
    );
    defer parsed.deinit();

    const root = parsed.value.object;

    if (root.get("version")) |version_value| {
        // Version is already a constant, no need to allocate
        _ = version_value;
    }

    // Parse submodules
    if (root.get("submodules")) |submodules_value| {
        const submodules_obj = submodules_value.object;
        var iter = submodules_obj.iterator();

        while (iter.next()) |entry| {
            const name = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(name);

            const submodule_obj = entry.value_ptr.object;

            const last_sync_commit = try allocator.dupe(
                u8,
                submodule_obj.get("last_sync_commit").?.string,
            );
            errdefer allocator.free(last_sync_commit);

            const last_push_commit = try allocator.dupe(
                u8,
                submodule_obj.get("last_push_commit").?.string,
            );
            errdefer allocator.free(last_push_commit);

            const parent_files_hash = try allocator.dupe(
                u8,
                submodule_obj.get("parent_files_hash").?.string,
            );
            errdefer allocator.free(parent_files_hash);

            const source_branch = try allocator.dupe(
                u8,
                submodule_obj.get("source_branch").?.string,
            );
            errdefer allocator.free(source_branch);

            const last_sync_time = try allocator.dupe(
                u8,
                submodule_obj.get("last_sync_time").?.string,
            );
            errdefer allocator.free(last_sync_time);

            const last_push_time = if (submodule_obj.get("last_push_time")) |push_time_value|
                try allocator.dupe(u8, push_time_value.string)
            else
                null;
            errdefer if (last_push_time) |time| allocator.free(time);

            const submodule_state = SubmoduleState{
                .last_sync_commit = last_sync_commit,
                .last_push_commit = last_push_commit,
                .parent_files_hash = parent_files_hash,
                .source_branch = source_branch,
                .last_sync_time = last_sync_time,
                .last_push_time = last_push_time,
            };

            try state.submodules.put(name, submodule_state);
        }
    }

    return state;
}

/// Get current timestamp in ISO 8601 format
pub fn getCurrentTimestamp(allocator: Allocator) ![]const u8 {
    const timestamp = std.time.timestamp();
    const epoch_seconds = @as(u64, @intCast(timestamp));

    // Convert to ISO 8601 format: YYYY-MM-DDTHH:MM:SSZ
    // For simplicity, we'll use a basic format
    const seconds_per_day = 86400;
    const seconds_per_hour = 3600;
    const seconds_per_minute = 60;

    // Calculate days since epoch (1970-01-01)
    const days_since_epoch = epoch_seconds / seconds_per_day;
    const remaining_seconds = epoch_seconds % seconds_per_day;

    // Calculate time components
    const hours = remaining_seconds / seconds_per_hour;
    const minutes = (remaining_seconds % seconds_per_hour) / seconds_per_minute;
    const seconds = remaining_seconds % seconds_per_minute;

    // Calculate date components (simplified - doesn't account for leap years perfectly)
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
    if (!std.mem.eql(u8, state.source_branch, expected_branch)) {
        return .stale;
    }

    // 2. Check if parent files changed (DIRTY status)
    const current_hash = try hash.hashDirectory(allocator, submodule.path);
    defer allocator.free(current_hash);

    const parent_changed = !std.mem.eql(u8, current_hash, state.parent_files_hash);

    // 3. Check if source repo has new commits (BEHIND status)
    const source_path = try std.fmt.allocPrint(
        allocator,
        ".salt/repos/{s}",
        .{submodule.name},
    );
    defer allocator.free(source_path);

    const current_commit = try git.getCurrentCommit(allocator, source_path);
    defer allocator.free(current_commit);

    const source_changed = !std.mem.eql(u8, current_commit, state.last_sync_commit);

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
/// This updates the last_sync_commit, parent_files_hash, source_branch, and last_sync_time
pub fn updateAfterSync(
    state: *SyncState,
    allocator: Allocator,
    submodule_name: []const u8,
    submodule_path: []const u8,
    source_repo_path: []const u8,
    source_branch: []const u8,
) !void {

    // Get current commit from source repo
    const commit = try git.getCurrentCommit(allocator, source_repo_path);
    errdefer allocator.free(commit);

    // Hash parent directory
    const files_hash = try hash.hashDirectory(allocator, submodule_path);
    errdefer allocator.free(files_hash);

    // Get current timestamp
    const timestamp = try getCurrentTimestamp(allocator);
    errdefer allocator.free(timestamp);

    // Duplicate source branch
    const branch = try allocator.dupe(u8, source_branch);
    errdefer allocator.free(branch);

    // Get or create submodule state
    if (state.submodules.getPtr(submodule_name)) |submodule_state| {
        // Free old values
        allocator.free(submodule_state.last_sync_commit);
        allocator.free(submodule_state.parent_files_hash);
        allocator.free(submodule_state.source_branch);
        allocator.free(submodule_state.last_sync_time);

        // Update with new values
        submodule_state.last_sync_commit = commit;
        submodule_state.parent_files_hash = files_hash;
        submodule_state.source_branch = branch;
        submodule_state.last_sync_time = timestamp;
    } else {
        // Create new state entry
        const new_state = SubmoduleState{
            .last_sync_commit = commit,
            .last_push_commit = try allocator.dupe(u8, commit), // Initialize with same commit
            .parent_files_hash = files_hash,
            .source_branch = branch,
            .last_sync_time = timestamp,
            .last_push_time = null,
        };

        const name_copy = try allocator.dupe(u8, submodule_name);
        try state.submodules.put(name_copy, new_state);
    }

    try state.save(allocator);
}

/// Update state after a push operation
/// This updates the last_push_commit, parent_files_hash, and last_push_time
pub fn updateAfterPush(
    state: *SyncState,
    allocator: Allocator,
    submodule_name: []const u8,
    submodule_path: []const u8,
    source_repo_path: []const u8,
) !void {
    // Get current commit from source repo
    const commit = try git.getCurrentCommit(allocator, source_repo_path);
    errdefer allocator.free(commit);

    // Hash parent directory
    const files_hash = try hash.hashDirectory(allocator, submodule_path);
    errdefer allocator.free(files_hash);

    // Get current timestamp
    const timestamp = try getCurrentTimestamp(allocator);
    errdefer allocator.free(timestamp);

    // Update existing submodule state
    if (state.submodules.getPtr(submodule_name)) |submodule_state| {
        // Free old values
        allocator.free(submodule_state.last_push_commit);
        allocator.free(submodule_state.parent_files_hash);
        if (submodule_state.last_push_time) |old_time| {
            allocator.free(old_time);
        }

        // Update with new values
        submodule_state.last_push_commit = commit;
        submodule_state.parent_files_hash = files_hash;
        submodule_state.last_push_time = timestamp;
    } else {
        // State should exist before push, but handle gracefully
        return error.NoState;
    }

    // Save state atomically
    try state.save(allocator);
}

/// Initialize state for a newly added submodule
pub fn initializeSubmoduleState(
    state: *SyncState,
    allocator: Allocator,
    submodule_name: []const u8,
    submodule_path: []const u8,
    source_repo_path: []const u8,
    source_branch: []const u8,
) !void {
    // Get current commit from source repo
    const commit = try git.getCurrentCommit(allocator, source_repo_path);
    errdefer allocator.free(commit);

    // Hash parent directory
    const files_hash = try hash.hashDirectory(allocator, submodule_path);
    errdefer allocator.free(files_hash);

    // Get current timestamp
    const timestamp = try getCurrentTimestamp(allocator);
    errdefer allocator.free(timestamp);

    // Duplicate source branch
    const branch = try allocator.dupe(u8, source_branch);
    errdefer allocator.free(branch);

    // Create new state entry
    const new_state = SubmoduleState{
        .last_sync_commit = try allocator.dupe(u8, commit),
        .last_push_commit = commit,
        .parent_files_hash = files_hash,
        .source_branch = branch,
        .last_sync_time = timestamp,
        .last_push_time = null,
    };

    const name_copy = try allocator.dupe(u8, submodule_name);
    try state.submodules.put(name_copy, new_state);

    // Save state atomically
    try state.save(allocator);
}

/// Remove a submodule from state tracking
pub fn removeSubmoduleState(
    state: *SyncState,
    allocator: Allocator,
    submodule_name: []const u8,
) !void {
    if (state.submodules.fetchRemove(submodule_name)) |kv| {
        allocator.free(kv.key);
        var submodule_state = kv.value;
        submodule_state.deinit(allocator);
    }

    // Save state atomically
    try state.save(allocator);
}

test "SyncState init and deinit" {
    const allocator = std.testing.allocator;
    var state = SyncState.init(allocator);
    defer state.deinit();

    try std.testing.expectEqual(@as(usize, 0), state.submodules.count());
    try std.testing.expectEqualStrings("1.0", state.version);
}

test "getCurrentTimestamp returns valid format" {
    const allocator = std.testing.allocator;
    const timestamp = try getCurrentTimestamp(allocator);
    defer allocator.free(timestamp);

    // Should be in format YYYY-MM-DDTHH:MM:SSZ
    try std.testing.expect(timestamp.len >= 20);
    try std.testing.expect(std.mem.indexOf(u8, timestamp, "T") != null);
    try std.testing.expect(std.mem.endsWith(u8, timestamp, "Z"));
}

test "SyncState JSON serialization" {
    const allocator = std.testing.allocator;
    var state = SyncState.init(allocator);
    defer state.deinit();

    // Add a test submodule state
    const name = try allocator.dupe(u8, "test-submodule");
    const submodule_state = SubmoduleState{
        .last_sync_commit = try allocator.dupe(u8, "abc123def456"),
        .last_push_commit = try allocator.dupe(u8, "abc123def456"),
        .parent_files_hash = try allocator.dupe(u8, "789xyz"),
        .source_branch = try allocator.dupe(u8, "main"),
        .last_sync_time = try allocator.dupe(u8, "2025-10-26T10:30:00Z"),
        .last_push_time = null,
    };

    try state.submodules.put(name, submodule_state);

    // Serialize to string
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try state.writeJson(buffer.writer(), allocator);

    const json = buffer.items;

    // Verify JSON contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\": \"1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"test-submodule\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"last_sync_commit\": \"abc123def456\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"source_branch\": \"main\"") != null);
}

test "parseStateJson parses valid JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "version": "1.0",
        \\  "submodules": {
        \\    "proto": {
        \\      "last_sync_commit": "abc123",
        \\      "last_push_commit": "abc123",
        \\      "parent_files_hash": "hash123",
        \\      "source_branch": "main",
        \\      "last_sync_time": "2025-10-26T10:30:00Z"
        \\    }
        \\  }
        \\}
    ;

    var state = try parseStateJson(allocator, json);
    defer state.deinit();

    try std.testing.expectEqual(@as(usize, 1), state.submodules.count());

    const proto_state = state.submodules.get("proto").?;
    try std.testing.expectEqualStrings("abc123", proto_state.last_sync_commit);
    try std.testing.expectEqualStrings("main", proto_state.source_branch);
    try std.testing.expect(proto_state.last_push_time == null);
}

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ProcessResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
};

pub const ProcessError = error{
    Timeout,
    SpawnFailed,
    ReadFailed,
};

pub const RunOptions = struct {
    timeout_ms: ?u64 = null,
    max_output_size: usize = 10 * 1024 * 1024, // 10MB default
};

/// Execute a command and return the result
pub fn run(allocator: Allocator, argv: []const []const u8) !ProcessResult {
    return runWithOptions(allocator, argv, .{});
}

/// Execute a command with options and return the result
pub fn runWithOptions(allocator: Allocator, argv: []const []const u8, options: RunOptions) !ProcessResult {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = child.stdout.?.readToEndAlloc(allocator, options.max_output_size) catch |err| {
        _ = child.kill() catch {};
        return err;
    };
    errdefer allocator.free(stdout);

    const stderr = child.stderr.?.readToEndAlloc(allocator, options.max_output_size) catch |err| {
        allocator.free(stdout);
        _ = child.kill() catch {};
        return err;
    };
    errdefer allocator.free(stderr);

    // Wait for process with optional timeout
    const term = if (options.timeout_ms) |timeout| blk: {
        // TODO: Zig's std.process.Child doesn't have built-in timeout,
        // so we just wait normally. Need to consider using a timer thread.
        _ = timeout;
        break :blk try child.wait();
    } else try child.wait();

    const exit_code: u8 = switch (term) {
        .Exited => |code| @intCast(code),
        .Signal => 128,
        .Stopped => 129,
        .Unknown => 130,
    };

    return ProcessResult{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = exit_code,
    };
}

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ProcessResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
};

/// Execute a command and return the result
pub fn run(allocator: Allocator, argv: []const []const u8) !ProcessResult {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    errdefer allocator.free(stdout);

    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    errdefer allocator.free(stderr);

    const term = try child.wait();

    const exit_code: u8 = switch (term) {
        .Exited => |code| @intCast(code),
        else => 1,
    };

    return ProcessResult{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = exit_code,
    };
}

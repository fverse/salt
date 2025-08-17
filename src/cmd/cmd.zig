const std = @import("std");
const clap = @import("clap");

const Commands = enum {
    help,
    init,
    add,
};

pub const main_parsers = .{
    .command = clap.parsers.enumeration(Commands),
};

pub const main_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<command>
    \\
);

pub const MainArgs = clap.ResultEx(clap.Help, &main_params, main_parsers);

pub fn printUsage() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\Usage: salt <command> <options>
        \\
        \\Commands:
        \\  init <path>    Initializes an empty salt project. 
        \\  add <url>      Adds a submodule to the project.
        \\  help           Display this help and exit.
        \\  pull           Pull changes from a submodule.
        \\  push           Push changes to a submodule.
        \\  status         Display the status of submodules.
        \\  mirror         Mirror a submodule.
        \\
    );
}

pub fn parseCommandArgs(comptime T: type, allocator: std.mem.Allocator, iter: *std.process.ArgIterator, params: anytype) !MainArgs {
    var diag = clap.Diagnostic{};
    const res = clap.parseEx(T, params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    return res;
}

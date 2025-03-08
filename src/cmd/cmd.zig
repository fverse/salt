const std = @import("std");
const clap = @import("clap");

const Commands = enum {
    help,
    init,
    // TODO: add,
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
        \\
    );
}

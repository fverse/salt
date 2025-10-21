const std = @import("std");
const clap = @import("clap");

pub const Command = enum {
    help,
    add,
    sync,
    status,
    push,
    remove,
};

pub const main_parsers = .{
    .command = clap.parsers.enumeration(Command),
};

pub const main_params = clap.parseParamsComptime(
    \\-h, --help     Display this help and exit.
    \\-v, --version  Display version information.
    \\-q, --quiet    Suppress non-error output.
    \\--verbose      Show detailed output.
    \\<command>
    \\
);

pub const MainArgs = clap.ResultEx(clap.Help, &main_params, main_parsers);

pub fn printUsage() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\Usage: salt <command> [options]
        \\
        \\Commands:
        \\  add <url> [path]    Add a submodule to the project
        \\  sync [name]         Sync submodules to correct branch
        \\  status              Display status of all submodules
        \\  push [name]         Push changes to submodule remotes
        \\  remove <name>       Remove a submodule
        \\  help                Display this help and exit
        \\
        \\Global Options:
        \\  -h, --help          Display this help and exit
        \\  -v, --version       Display version information
        \\  -q, --quiet         Suppress non-error output
        \\  --verbose           Show detailed output
        \\
        \\For more information on a specific command, run:
        \\  salt <command> --help
        \\
    );
}

pub fn printVersion() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("salt version 0.1.0\n");
}

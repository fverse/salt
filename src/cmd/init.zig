const std = @import("std");
const Allocator = std.mem.Allocator;
const clap = @import("clap");

pub fn execute(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                Display this help and exit.
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try printHelp();
        return;
    }

    // Check if salt.conf already exists
    if (std.fs.cwd().access("salt.conf", .{})) |_| {
        const stderr = std.io.getStdErr().writer();
        try stderr.writeAll("Error: salt.conf already exists\n");
        return error.ConfigExists;
    } else |_| {}

    // Create empty config with header
    const content =
        \\# salt.conf - Submodule configuration
        \\# 
        \\# Add submodules with: salt add <url> [path]
        \\# 
        \\# Example:
        \\# [submodule "repo"]
        \\#   path = repo
        \\#   url = https://github.com/org/repo.git
        \\#   default_branch = main
        \\#   shallow = true
        \\#   branches = {
        \\#     main -> main
        \\#     staging -> staging
        \\#   }
        \\
    ;

    try std.fs.cwd().writeFile(.{ .sub_path = "salt.conf", .data = content });

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("✓ Initialized salt.conf\n");
    try stdout.writeAll("  Add submodules with: salt add <url> [path]\n");
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\salt init - Initialize a new salt configuration
        \\
        \\Usage: salt init [options]
        \\
        \\Description:
        \\  Creates an empty salt.conf file in the repository root to prepare
        \\  for adding submodules. This command is optional since 'salt add'
        \\  will create salt.conf if it doesn't exist.
        \\
        \\Options:
        \\  -h, --help           Display this help and exit
        \\
        \\Examples:
        \\  salt init
        \\  salt add https://github.com/org/repo.git
        \\
    );
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const clap = @import("clap");
const cmd = @import("./cmd.zig");

pub fn init(allocator: std.mem.Allocator, iter: *std.process.ArgIterator, main_args: cmd.MainArgs) !void {
    _ = main_args;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                Display this help and exit.
        \\-p, --path <str>          Path to initialize (default: current directory).
        \\
    );

    // Print deprecation warning and exit
    const stderr = std.io.getStdErr().writer();
    try stderr.writeAll("The 'salt init' command is deprecated and will be removed in a future version.\n");
    try stderr.writeAll("Please use 'salt submodule add <repo-url>' instead.\n");
    try stderr.writeAll("For more information, run: salt submodule add --help\n");
    std.process.exit(0);

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    // const path = res.positionals[0] orelse return error.MissingArg;
    if (res.args.help != 0) {
        try printInitCmdHelp();
        return;
    }

    const stdout = std.io.getStdOut().writer();

    var config_path: ?[]const u8 = null;
    defer if (config_path) |path| allocator.free(path);

    var config_path_value: []const u8 = "salt.conf";

    // Check if config file exists
    if (res.args.path) |path| {
        // Check if directory exists, if not create i
        std.fs.cwd().makeDir(path) catch |err| {
            if (err != error.PathAlreadyExists) {
                std.debug.print("Error creating directory: {}\n", .{err});
                return err;
            }
        };

        config_path = try std.fs.path.join(allocator, &[_][]const u8{ path, "salt.conf" });
        config_path_value = config_path.?;
    }

    try stdout.print("Initialized an empty salt config file: {s}\n", .{config_path_value});
    try stdout.writeAll("To add a submodule, please run 'salt add <repo-url>'\n");
}

fn printInitCmdHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\salt init - Initialize a new salt submodule config (DEPRECATED)
        \\
        \\Usage: salt init <options>
        \\
        \\Description:
        \\  This command will create a salt.conf that holds the submodule config.
        \\
        \\Options:
        \\  -h, --help           Display this help and exit.
        \\  -p, --path <str>     Path to initialize (default: current directory).
        \\                       The directory will be created if it doesn't exist.
    );
}

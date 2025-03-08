const std = @import("std");
const Allocator = std.mem.Allocator;
const clap = @import("clap");
const MainArgs = @import("./cmd.zig").MainArgs;
const Config = @import("../config.zig").Config;
const Submodule = @import("../config.zig").Submodule;
const BranchMapping = @import("../config.zig").BranchMapping;

pub fn init(allocator: std.mem.Allocator, iter: *std.process.ArgIterator, main_args: MainArgs) !void {
    _ = main_args;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help           Display this help and exit.
        \\-p, --path <str>          Path to initialize (default: current directory).
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

    // const path = res.positionals[0] orelse return error.MissingArg;
    if (res.args.help != 0) {
        try printInitHelp();
        return;
    }

    const stdout = std.io.getStdOut().writer();

    var config_path: ?[]const u8 = null;
    defer if (config_path) |path| allocator.free(path);

    var config_path_value: []const u8 = "salt.toml";

    // Check if config file exists
    if (res.args.path) |path| {
        // Check if directory exists, if not create i
        std.fs.cwd().makeDir(path) catch |err| {
            if (err != error.PathAlreadyExists) {
                std.debug.print("Error creating directory: {}\n", .{err});
                return err;
            }
        };

        config_path = try std.fs.path.join(allocator, &[_][]const u8{ path, "salt.toml" });
        config_path_value = config_path.?;
    }

    var config: Config = undefined;

    if (std.fs.cwd().access(config_path_value, .{})) |_| {
        // Config file exists
        config = try Config.loadFromFile(allocator, config_path_value);
    } else |_| {
        // Create new config
        config = try Config.init(allocator);

        const file = try std.fs.cwd().createFile(config_path_value, .{});
        defer file.close();
    }
    defer config.deinit();

    try stdout.print("Initialized an empty salt config file: {s}\n", .{config_path_value});
    try stdout.writeAll("To add a submodule, please run 'salt add <repo-url>'\n");
}

fn printInitHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\salt init - Initialize a new salt submodule config
        \\
        \\Usage: salt init <options>
        \\
        \\Description:
        \\  This command will create a salt.toml file that holds the submodule config.
        \\
        \\Options:
        \\  -h, --help           Display this help and exit.
        \\  -p, --path <str>     Path to initialize (default: current directory).
        \\                       The directory will be created if it doesn't exist.
    );
}

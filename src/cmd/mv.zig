const std = @import("std");
const clap = @import("clap");
const Config = @import("../config/parser.zig");
const Writer = @import("../config/writer.zig").Writer;
const State = @import("../core/state.zig");

pub fn execute(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help               Display the help and exit.
        \\<str>                   Name of the submodule that wanted to rename
        \\<str>                   New name for the submodule 
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

    const path = res.positionals[0] orelse {
        try std.io.getStdErr().writer().print("Error: Please specify the submodule name", .{});
        return;
    };

    const new_path = res.positionals[1] orelse {
        const std_err = std.io.getStdErr().writer();
        try std_err.print("Error: Please specify the new name", .{});
        return;
    };

    // get path name from config
    var parser = Config.Parser.init(allocator);
    defer parser.deinit();

    var config = parser.parseFile("Saltfile") catch |err| {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Error: Failed to load Saltfile: {}\n", .{err});
        return err;
    };
    defer config.deinit();

    const submodule = config.findByName(path) orelse {
        try std.io.getStdErr().writer().print("Error: submodule {s} not found", .{path});
        return;
    };

    defer config.deinit();

    // Rename
    std.fs.cwd().rename(path, new_path) catch |err| {
        const std_err = std.io.getStdErr().writer();
        try std_err.print("Error: Failed to rename the submodule {}\n", .{err});
    };

    // Update the submodule path
    submodule.path = new_path;
    submodule.name = new_path;
    var writer = Writer.init(allocator);
    writer.writeFile(&config, "Saltfile") catch |err| {
        const std_err = std.io.getStdErr().writer();
        try std_err.print("Error: Failed to update path {}\n", .{err});
    };

    // Update state.json
    var sync_state = State.SyncState.load(allocator) catch |err| {
        const std_err = std.io.getStdErr().writer();
        try std_err.print("Warning: Failed to load state.json {}\n", .{err});
        return;
    };
    defer sync_state.deinit();

    State.renameSubmoduleState(&sync_state, allocator, path, new_path) catch |err| {
        if (err != error.NoState) {
            const std_err = std.io.getStdErr().writer();
            try std_err.print("Warning: Failed to update state.json {}\n", .{err});
        }
    };
}

fn printHelp() !void {
    try std.io.getStdOut().writer().writeAll(
        \\ salt mv - Rename a submodule
        \\
        \\Usage: salt mv <submodule name> 
    );
}

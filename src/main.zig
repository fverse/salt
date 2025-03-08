const std = @import("std");
const clap = @import("clap");
const Config = @import("config.zig").Config;
const cmd = @import("cmd/cmd.zig");
const init = @import("cmd/init.zig").init;

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_state.allocator();
    defer _ = gpa_state.deinit();

    var iter = try std.process.ArgIterator.initWithAllocator(gpa);
    defer iter.deinit();

    _ = iter.next();

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &cmd.main_params, cmd.main_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
        .terminating_positional = 0,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        try cmd.printUsage();

    const command = res.positionals[0] orelse {
        try cmd.printUsage();
        return;
    };

    switch (command) {
        .help => try cmd.printUsage(),
        .init => try init(gpa, &iter, res),
    }
}

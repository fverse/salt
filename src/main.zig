const std = @import("std");
const clap = @import("clap");
const cmd = @import("cmd/cmd.zig");
const init_cmd = @import("cmd/init.zig");
const add_cmd = @import("cmd/add.zig");
const sync_cmd = @import("cmd/sync.zig");
const pull_cmd = @import("cmd/pull.zig");
const push_cmd = @import("cmd/push.zig");
const status_cmd = @import("cmd/status.zig");
const remove_cmd = @import("cmd/remove.zig");

/// Global flags that can be passed to all commands
pub const GlobalFlags = struct {
    quiet: bool = false,
    verbose: bool = false,
};

pub var global_flags: GlobalFlags = .{};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_state.allocator();
    defer _ = gpa_state.deinit();

    var iter = try std.process.ArgIterator.initWithAllocator(gpa);
    defer iter.deinit();

    _ = iter.next(); // Skip program name

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &cmd.main_params, cmd.main_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
        .terminating_positional = 0,
    }) catch |err| {
        // Check if it's an invalid command error
        if (err == error.InvalidArgument or err == error.NameNotPartOfEnum) {
            // Try to get the invalid command for suggestions
            var temp_iter = try std.process.ArgIterator.initWithAllocator(gpa);
            defer temp_iter.deinit();
            _ = temp_iter.next(); // Skip program name

            // Skip global flags
            while (temp_iter.next()) |arg| {
                if (!std.mem.startsWith(u8, arg, "-")) {
                    try cmd.suggestCommand(arg);
                    return err;
                }
            }
        }
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try cmd.printUsage();
        return;
    }

    if (res.args.version != 0) {
        try cmd.printVersion();
        return;
    }

    // Set global flags
    global_flags.quiet = res.args.quiet != 0;
    global_flags.verbose = res.args.verbose != 0;

    const command = res.positionals[0] orelse {
        try cmd.printUsage();
        return;
    };

    switch (command) {
        .help => try cmd.printUsage(),
        .init => try init_cmd.execute(gpa, &iter),
        .add => try add_cmd.execute(gpa, &iter),
        .sync => try sync_cmd.execute(gpa, &iter),
        .pull => try pull_cmd.execute(gpa, &iter),
        .push => try push_cmd.execute(gpa, &iter),
        .status => try status_cmd.execute(gpa, &iter),
        .remove => try remove_cmd.execute(gpa, &iter),
    }
}

test {
    _ = @import("core/mapper.zig");
}

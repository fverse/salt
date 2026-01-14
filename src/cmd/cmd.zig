const std = @import("std");
const clap = @import("clap");

pub const Command = enum {
    help,
    init,
    add,
    resolve,
    sync,
    pull,
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
        \\Salt - A branch-aware Git submodule alternative
        \\
        \\Usage: salt <command> [options]
        \\
        \\Commands:
        \\  init                Initialize salt.conf in repository
        \\  add <url> [path]    Add a submodule to the project
        \\  resolve [name]      Download and setup all dependencies
        \\  sync [name]         Sync submodules to correct branch based on parent branch
        \\  pull [name]         Pull latest changes on current branches
        \\  status              Display status of all submodules
        \\  push [name]         Push changes to submodule remotes
        \\  remove <name>       Remove a submodule from the project
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
    try stdout.writeAll("A branch-aware Git submodule alternative\n");
    try stdout.writeAll("https://github.com/fverse/salt\n");
}

/// Calculate Levenshtein distance between two strings
fn levenshteinDistance(s1: []const u8, s2: []const u8) usize {
    const len1 = s1.len;
    const len2 = s2.len;

    if (len1 == 0) return len2;
    if (len2 == 0) return len1;

    var prev_row: [256]usize = undefined;
    var curr_row: [256]usize = undefined;

    // Initialize first row
    for (0..len2 + 1) |i| {
        prev_row[i] = i;
    }

    for (0..len1) |i| {
        curr_row[0] = i + 1;

        for (0..len2) |j| {
            const cost: usize = if (s1[i] == s2[j]) 0 else 1;
            const deletion = prev_row[j + 1] + 1;
            const insertion = curr_row[j] + 1;
            const substitution = prev_row[j] + cost;

            curr_row[j + 1] = @min(@min(deletion, insertion), substitution);
        }

        // Swap rows
        const temp = prev_row;
        prev_row = curr_row;
        curr_row = temp;
    }

    return prev_row[len2];
}

/// Suggest similar commands for typos
pub fn suggestCommand(invalid_cmd: []const u8) !void {
    const commands = [_][]const u8{
        "init",
        "add",
        "resolve",
        "sync",
        "pull",
        "status",
        "push",
        "remove",
        "help",
    };

    const stderr = std.io.getStdErr().writer();
    try stderr.print("Unknown command: '{s}'\n\n", .{invalid_cmd});

    // Find closest match
    var min_distance: usize = std.math.maxInt(usize);
    var best_match: ?[]const u8 = null;

    for (commands) |cmd| {
        const distance = levenshteinDistance(invalid_cmd, cmd);
        if (distance < min_distance) {
            min_distance = distance;
            best_match = cmd;
        }
    }

    // Suggest if distance is reasonable (less than half the command length)
    if (best_match) |match| {
        if (min_distance <= invalid_cmd.len / 2 + 1) {
            try stderr.print("Did you mean '{s}'?\n\n", .{match});
        }
    }

    try stderr.writeAll("Run 'salt --help' to see available commands.\n");
}

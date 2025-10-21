const std = @import("std");
const Allocator = std.mem.Allocator;
const clap = @import("clap");
const Submodule = @import("../config/types.zig").Submodule;
const utils = @import("../config/utils.zig");

fn extractRepoName(url: []const u8) []const u8 {
    var working_url = url;

    if (std.mem.endsWith(u8, working_url, ".git")) {
        working_url = working_url[0 .. working_url.len - 4];
    }

    var last_separator: usize = 0;
    for (working_url, 0..) |char, i| {
        if (char == '/' or char == ':') {
            last_separator = i;
        }
    }

    if (last_separator > 0 and last_separator < working_url.len - 1) {
        return working_url[last_separator + 1 ..];
    }

    return working_url;
}

pub fn execute(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                Display this help and exit.
        \\<str>                     Repository URL.
        \\<str>                     Name of the folder where the repo will be cloned (default: repo name)
        \\-b, --branch              Clone a specific branch instead of default
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

    const stdout = std.io.getStdOut().writer();

    const url = res.positionals[0] orelse {
        try stdout.writeAll("Please provide a repository URL\n");
        return;
    };

    const dir = res.positionals[1] orelse extractRepoName(url);

    try stdout.print("Adding submodule: {s}\n", .{url});

    try cloneGitRepository(allocator, url, dir);

    try utils.createSaltFile();

    var submodule = Submodule.init(allocator);
    try submodule.setName(dir);
    try submodule.setPath(dir);
    try submodule.setUrl(url);
    try submodule.setDefaultBranch("main");
    try submodule.addToSaltfile(allocator);

    // TODO: may be auto commit the changes after adding the submodule
    // better consider a config option for this
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\salt add - Add a new submodule
        \\
        \\Usage: salt add [options] <repository-url> [folder-name] 
        \\
        \\Description:
        \\  Adds a new submodule to the parent repository.
        \\
        \\Arguments:
        \\  <repository-url>         URL of the git repository to add.
        \\  [folder-name]            Name of the folder to clone into (default: repo name).
        \\
        \\Options:
        \\  -h, --help               Display this help and exit.
        \\  -b, --branch             Clone a specific branch instead of default.
        \\
    );
}

pub fn cloneGitRepository(allocator: std.mem.Allocator, url: []const u8, dest_dir: []const u8) !void {
    const stdout_writer = std.io.getStdOut().writer();

    const argv = [_][]const u8{
        "git",
        "clone",
        "--progress",
        "--depth",
        "1",
        url,
        dest_dir,
    };

    try stdout_writer.print("Cloning repository {s} into {s}...\n", .{ url, dest_dir });

    var process = std.process.Child.init(argv[0..], allocator);
    process.stdin_behavior = .Ignore;
    process.stdout_behavior = .Inherit;
    process.stderr_behavior = .Inherit;

    try process.spawn();

    const term = try process.wait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                try stdout_writer.print("Git clone failed with exit code {}\n", .{code});
                // return error.GitCloneFailed;
                std.process.exit(0);
            }
            try stdout_writer.print("Submodule added: {s}\n", .{dest_dir});
        },
        else => {
            try stdout_writer.print("Git clone terminated abnormally\n", .{});
            return error.GitCloneFailed;
        },
    }
}

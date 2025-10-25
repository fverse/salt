const std = @import("std");
const Allocator = std.mem.Allocator;
const clap = @import("clap");
const Submodule = @import("../config/types.zig").Submodule;
const SubmoduleConfig = @import("../config/types.zig").SubmoduleConfig;
const Parser = @import("../config/parser.zig").Parser;
const Writer = @import("../config/writer.zig").Writer;
const utils = @import("../config/utils.zig");
const git = @import("../git/operations.zig");
const fs = @import("../utils/fs.zig");
const state = @import("../core/state.zig");

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
        \\-b, --branch <str>        Clone a specific branch instead of default (default: main)
        \\-n, --name <str>          Custom submodule name (default: derived from URL)
        \\--shallow                 Use shallow clone (default: true)
        \\--no-shallow              Use full clone for complete history
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
    const stderr = std.io.getStdErr().writer();

    const url = res.positionals[0] orelse {
        try stderr.writeAll("Error: Please provide a repository URL\n");
        return error.MissingArgument;
    };

    // Determine path (where files will be copied in parent repo)
    const path = res.positionals[1] orelse extractRepoName(url);

    // Determine name (identifier for the submodule)
    const name = res.args.name orelse extractRepoName(url);

    // Determine branch
    const branch = res.args.branch orelse "main";

    // Determine shallow flag (default: true, unless --no-shallow is specified)
    const shallow = res.args.@"no-shallow" == 0;

    try stdout.print("Adding submodule '{s}' from {s}\n", .{ name, url });
    try stdout.print("  Branch: {s}\n", .{branch});
    try stdout.print("  Path: {s}\n", .{path});
    try stdout.print("  Shallow: {}\n", .{shallow});

    // Check if path already exists
    if (fs.pathExists(path)) {
        try stderr.print("Error: Path '{s}' already exists\n", .{path});
        return error.PathAlreadyExists;
    }

    // Create .salt/repos directory structure
    try std.fs.cwd().makePath(".salt/repos");

    // Build hidden repo path
    const source_path = try std.fmt.allocPrint(allocator, ".salt/repos/{s}", .{name});
    defer allocator.free(source_path);

    // Check if hidden repo already exists
    if (fs.pathExists(source_path)) {
        try stderr.print("Error: Submodule '{s}' already exists in .salt/repos/\n", .{name});
        return error.SubmoduleAlreadyExists;
    }

    // Clone repository to hidden location
    try stdout.print("\nCloning repository to {s}...\n", .{source_path});
    if (shallow) {
        try cloneRepositoryShallow(allocator, url, source_path, branch);
    } else {
        try git.cloneRepository(allocator, url, source_path, branch);
    }

    // Copy files from hidden repo to target path (excluding .git)
    try stdout.print("Copying files to {s}...\n", .{path});
    try fs.copyDirectory(allocator, source_path, path, .{ .exclude_git = true });

    // Add files to parent's Git
    try stdout.print("Adding files to parent repository...\n", .{});
    if (std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "add", path },
    })) |result| {
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term.Exited != 0) {
            try stderr.print("Warning: Failed to add files to git (exit code {})\n", .{result.term.Exited});
        }
    } else |err| {
        try stderr.print("Warning: Failed to add files to git: {}\n", .{err});
        // Continue anyway - user might not be in a git repo
    }

    // Ensure salt.conf exists
    try utils.createSaltFile();

    // Load existing configuration
    var parser = Parser.init(allocator);
    defer parser.deinit();

    var config = parser.parseFile("salt.conf") catch |err| blk: {
        if (err == error.FileNotFound) {
            break :blk SubmoduleConfig.init(allocator);
        } else {
            return err;
        }
    };
    defer config.deinit();

    // Create new submodule
    var submodule = Submodule.init(allocator);
    try submodule.setName(name);
    try submodule.setPath(path);
    try submodule.setUrl(url);
    try submodule.setDefaultBranch(branch);
    submodule.shallow = shallow;

    // Add to configuration
    try config.addSubmodule(submodule);

    // Write updated configuration
    var writer = Writer.init(allocator);
    try writer.writeFile(&config, "salt.conf");

    // Initialize state tracking
    try stdout.print("Initializing state tracking...\n", .{});
    var sync_state = try state.SyncState.load(allocator);
    defer sync_state.deinit();

    try state.initializeSubmoduleState(
        &sync_state,
        allocator,
        name,
        path,
        source_path,
        branch,
    );

    try stdout.print("\n✓ Added submodule '{s}' at {s}\n", .{ name, path });
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\salt add - Add a new submodule
        \\
        \\Usage: salt add [options] <repository-url> [path]
        \\
        \\Description:
        \\  Clone a repository and add it as a submodule. The repository
        \\  will be cloned to .salt/repos/<name> and files copied to the
        \\  specified path in your working directory.
        \\
        \\Arguments:
        \\  <repository-url>         URL of the git repository to add.
        \\  [path]                   Path where files will be copied (default: repo name).
        \\
        \\Options:
        \\  -h, --help               Display this help and exit.
        \\  -b, --branch <branch>    Initial branch to checkout (default: main).
        \\  -n, --name <name>        Custom submodule name (default: derived from URL).
        \\  --shallow                Use shallow clone (default: true).
        \\  --no-shallow             Use full clone for complete history.
        \\
    );
}

/// Clone a repository with shallow clone (--depth=1)
fn cloneRepositoryShallow(allocator: Allocator, url: []const u8, dest_dir: []const u8, branch: []const u8) !void {
    const argv = [_][]const u8{
        "git",
        "clone",
        "--depth",
        "1",
        "--branch",
        branch,
        "--single-branch",
        url,
        dest_dir,
    };

    var process = std.process.Child.init(&argv, allocator);
    process.stdin_behavior = .Ignore;
    process.stdout_behavior = .Inherit;
    process.stderr_behavior = .Inherit;

    try process.spawn();
    const term = try process.wait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                return error.GitCloneFailed;
            }
        },
        else => {
            return error.GitCloneFailed;
        },
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Options for directory copying operations
pub const CopyOptions = struct {
    /// Exclude .git directories from copying
    exclude_git: bool = true,
    /// Follow symlinks (copy target) or skip them
    follow_symlinks: bool = false,
};

/// Check if a path exists
pub fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Copy a directory recursively from source to destination
/// Excludes .git directories by default
pub fn copyDirectory(
    allocator: Allocator,
    source_path: []const u8,
    dest_path: []const u8,
    options: CopyOptions,
) !void {
    // Open source directory
    var source_dir = std.fs.cwd().openDir(source_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Error: Failed to open source directory '{s}': {}\n", .{ source_path, err });
        return err;
    };
    defer source_dir.close();

    // Create destination directory if it doesn't exist
    std.fs.cwd().makePath(dest_path) catch |err| {
        std.debug.print("Error: Failed to create destination directory '{s}': {}\n", .{ dest_path, err });
        return err;
    };

    // Iterate through source directory
    var iter = source_dir.iterate();
    while (try iter.next()) |entry| {
        // Skip .git directories if exclude_git is true
        if (options.exclude_git and std.mem.eql(u8, entry.name, ".git")) {
            continue;
        }

        // Build full paths
        const source_entry_path = try std.fs.path.join(allocator, &[_][]const u8{ source_path, entry.name });
        defer allocator.free(source_entry_path);

        const dest_entry_path = try std.fs.path.join(allocator, &[_][]const u8{ dest_path, entry.name });
        defer allocator.free(dest_entry_path);

        switch (entry.kind) {
            .directory => {
                // Recursively copy subdirectory
                try copyDirectory(allocator, source_entry_path, dest_entry_path, options);
            },
            .file => {
                // Copy file with permissions
                try copyFile(source_entry_path, dest_entry_path);
            },
            .sym_link => {
                if (options.follow_symlinks) {
                    // Follow symlink and copy target
                    var buffer: [std.fs.max_path_bytes]u8 = undefined;
                    const real_path = try std.fs.cwd().readLink(source_entry_path, &buffer);
                    const real_path_owned = try allocator.dupe(u8, real_path);
                    defer allocator.free(real_path_owned);

                    // Check if target is a file or directory
                    const stat = try std.fs.cwd().statFile(real_path_owned);
                    if (stat.kind == .directory) {
                        try copyDirectory(allocator, real_path_owned, dest_entry_path, options);
                    } else {
                        try copyFile(real_path_owned, dest_entry_path);
                    }
                }
                // Otherwise skip symlinks
            },
            else => {
                // Skip other types (block devices, character devices, etc.)
            },
        }
    }
}

/// Copy a single file from source to destination, preserving permissions
fn copyFile(source_path: []const u8, dest_path: []const u8) !void {
    // Open source file
    const source_file = try std.fs.cwd().openFile(source_path, .{});
    defer source_file.close();

    // Get source file permissions
    const stat = try source_file.stat();

    // Create destination file
    const dest_file = try std.fs.cwd().createFile(dest_path, .{
        .truncate = true,
        .mode = stat.mode,
    });
    defer dest_file.close();

    // Copy contents
    const buffer_size = 4096;
    var buffer: [buffer_size]u8 = undefined;

    while (true) {
        const bytes_read = try source_file.read(&buffer);
        if (bytes_read == 0) break;

        try dest_file.writeAll(buffer[0..bytes_read]);
    }
}

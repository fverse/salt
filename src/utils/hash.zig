const std = @import("std");
const Allocator = std.mem.Allocator;

/// Entry for sorting file paths deterministically
const FileEntry = struct {
    path: []const u8,
    is_dir: bool,
};

/// Compare function for sorting file entries
fn compareFileEntries(_: void, a: FileEntry, b: FileEntry) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

/// Hash a directory recursively using SHA-256
/// Returns a hex-encoded hash string
pub fn hashDirectory(allocator: Allocator, dir_path: []const u8) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    // Collect all file paths
    var file_list = std.ArrayList(FileEntry).init(allocator);
    defer {
        for (file_list.items) |entry| {
            allocator.free(entry.path);
        }
        file_list.deinit();
    }

    try collectFiles(allocator, dir_path, "", &file_list);

    // Sort files for deterministic hashing
    std.mem.sort(FileEntry, file_list.items, {}, compareFileEntries);

    // Hash each file path and contents
    for (file_list.items) |entry| {
        if (entry.is_dir) {
            // Hash directory path
            hasher.update(entry.path);
            hasher.update(&[_]u8{0}); // Separator
        } else {
            // Hash file path
            hasher.update(entry.path);
            hasher.update(&[_]u8{0}); // Separator

            // Hash file contents
            const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.path });
            defer allocator.free(full_path);

            try hashFile(&hasher, full_path);
        }
    }

    // Get final hash
    var hash_bytes: [32]u8 = undefined;
    hasher.final(&hash_bytes);

    // Convert to hex string
    return try hexEncode(allocator, &hash_bytes);
}

/// Recursively collect all file paths in a directory
fn collectFiles(
    allocator: Allocator,
    base_path: []const u8,
    relative_path: []const u8,
    file_list: *std.ArrayList(FileEntry),
) !void {
    const full_path = if (relative_path.len == 0)
        try allocator.dupe(u8, base_path)
    else
        try std.fs.path.join(allocator, &[_][]const u8{ base_path, relative_path });
    defer allocator.free(full_path);

    var dir = std.fs.cwd().openDir(full_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Warning: Failed to open directory '{s}': {}\n", .{ full_path, err });
        return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Skip .git directories
        if (std.mem.eql(u8, entry.name, ".git")) {
            continue;
        }

        const entry_relative_path = if (relative_path.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &[_][]const u8{ relative_path, entry.name });

        switch (entry.kind) {
            .directory => {
                // Add directory entry
                try file_list.append(.{
                    .path = entry_relative_path,
                    .is_dir = true,
                });

                // Recursively collect files in subdirectory
                try collectFiles(allocator, base_path, entry_relative_path, file_list);
            },
            .file => {
                // Add file entry
                try file_list.append(.{
                    .path = entry_relative_path,
                    .is_dir = false,
                });
            },
            .sym_link => {
                // Skip symlinks for now
                allocator.free(entry_relative_path);
            },
            else => {
                // Skip other types
                allocator.free(entry_relative_path);
            },
        }
    }
}

/// Hash a single file's contents
fn hashFile(hasher: *std.crypto.hash.sha2.Sha256, file_path: []const u8) !void {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const buffer_size = 4096;
    var buffer: [buffer_size]u8 = undefined;

    while (true) {
        const bytes_read = try file.read(&buffer);
        if (bytes_read == 0) break;

        hasher.update(buffer[0..bytes_read]);
    }
}

/// Convert bytes to hex-encoded string
fn hexEncode(allocator: Allocator, bytes: []const u8) ![]const u8 {
    const hex_chars = "0123456789abcdef";
    var result = try allocator.alloc(u8, bytes.len * 2);

    for (bytes, 0..) |byte, i| {
        result[i * 2] = hex_chars[byte >> 4];
        result[i * 2 + 1] = hex_chars[byte & 0x0F];
    }

    return result;
}

const std = @import("std");
const types = @import("./types.zig");
const SubmoduleConfig = types.SubmoduleConfig;
const Submodule = types.Submodule;
const Parser = @import("./parser.zig").Parser;

pub const Writer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{
            .allocator = allocator,
            // .format_options = .{},
        };
    }

    /// Write config to a file atomically using a temporary file
    pub fn writeFile(self: *Writer, config: *const SubmoduleConfig, file_path: []const u8) !void {
        // Create a temporary file with a unique name
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp.{d}", .{ file_path, std.time.milliTimestamp() });
        defer self.allocator.free(tmp_path);

        const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
        errdefer {
            tmp_file.close();
            std.fs.cwd().deleteFile(tmp_path) catch {};
        }

        try self.writeConfig(tmp_file.writer(), config);

        try tmp_file.sync();
        tmp_file.close();

        try std.fs.cwd().rename(tmp_path, file_path);
    }

    /// Write config to any writer (file, buffer, etc.)
    pub fn writeConfig(self: *Writer, writer: anytype, config: *const SubmoduleConfig) !void {
        // Write header
        try self.writeSaltfileHeader(writer);
        // Write each submodule
        for (config.submodules.items, 0..) |submodule, idx| {
            if (idx > 0) {
                try writer.writeAll("\n");
            }
            try self.writeSubmodule(writer, &submodule);
        }
    }

    pub fn writeSaltfileHeader(_: *Writer, writer: anytype) !void {
        try writer.writeAll("# salt.conf - Submodule configuration\n");
        // TODO: write parent repository information like
        try writer.writeAll("\n");
    }

    /// Write a single submodule entry
    fn writeSubmodule(self: *Writer, writer: anytype, submodule: *const Submodule) !void {
        // Write submodule header
        try writer.print("[submodule \"{s}\"]\n", .{submodule.name});

        const indent = try self.getIndentString();
        defer self.allocator.free(indent);

        try writer.print("{s}path = {s}\n", .{ indent, submodule.path });
        try writer.print("{s}url = {s}\n", .{ indent, submodule.url });
        try writer.print("{s}default_branch = {s}\n", .{ indent, submodule.default_branch });

        // Write branches block if any exist
        if (submodule.branch_mappings.count() > 0) {
            try writer.print("{s}branches = {{\n", .{indent});
            try self.writeBranches(writer, submodule, indent);
            try writer.print("{s}}}\n", .{indent});
        }
    }

    fn writeBranches(self: *Writer, writer: anytype, submodule: *const Submodule, indent: []const u8) !void {
        // Collect all branch mappings into a list for sorting
        var mappings = std.ArrayList(struct { key: []const u8, value: []const u8 }).init(self.allocator);
        defer mappings.deinit();

        var iter = submodule.branch_mappings.iterator();
        while (iter.next()) |entry| {
            try mappings.append(.{ .key = entry.key_ptr.*, .value = entry.value_ptr.* });
        }

        // Sort mappings by key for consistent output
        std.mem.sort(@TypeOf(mappings.items[0]), mappings.items, {}, struct {
            fn lessThan(_: void, a: @TypeOf(mappings.items[0]), b: @TypeOf(mappings.items[0])) bool {
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.lessThan);

        // Write sorted mappings
        for (mappings.items) |mapping| {
            try writer.print("{s}    {s} -> {s}\n", .{ indent, mapping.key, mapping.value });
        }
    }

    fn getIndentString(self: *Writer) ![]u8 {
        const indent = try self.allocator.alloc(u8, 2);
        @memset(indent, ' ');
        return indent;
    }

    /// Serialize config to a string
    pub fn toString(self: *Writer, config: *const SubmoduleConfig) ![]u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        errdefer buffer.deinit();

        try self.writeConfig(buffer.writer(), config);
        return try buffer.toOwnedSlice();
    }
};

pub fn readFileContent(allocator: std.mem.Allocator) ![]const u8 {
    const file = std.fs.cwd().openFile("salt.conf", .{}) catch |err| {
        if (err == error.FileNotFound) {
            // Return empty config if file doesn't exist
            // TODO: return SubmoduleConfig.init(allocator);
        }
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    return content;
}

pub fn loadSaltfile(
    allocator: std.mem.Allocator,
) !SubmoduleConfig {
    const content = try readFileContent(allocator);
    defer allocator.free(content);

    var parser = Parser.init(allocator);
    defer parser.deinit();

    return try parser.parseContent(content);
}

/// Convenience function to read, modify, and write back
pub fn updateSaltfile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    update_fn: fn (*SubmoduleConfig) anyerror!void,
) !void {
    var config = try loadSaltfile(allocator, file_path);
    defer config.deinit();

    // Apply updates
    try update_fn(&config);

    // Write back
    var writer = Writer.init(allocator);
    try writer.writeFile(&config, file_path);
}

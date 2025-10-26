const std = @import("std");
const main = @import("../main.zig");

/// ANSI color codes for terminal output
pub const Color = enum {
    reset,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bold,
    dim,

    pub fn code(self: Color) []const u8 {
        return switch (self) {
            .reset => "\x1b[0m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .magenta => "\x1b[35m",
            .cyan => "\x1b[36m",
            .white => "\x1b[37m",
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
        };
    }
};

/// Check if terminal supports colors
pub fn supportsColor() bool {
    // Check if stdout is a terminal
    if (!std.io.getStdOut().isTty()) return false;

    // Check TERM environment variable
    const term = std.posix.getenv("TERM") orelse return false;
    if (std.mem.eql(u8, term, "dumb")) return false;

    return true;
}

/// Print colored text to stdout
pub fn printColor(writer: anytype, color: Color, text: []const u8) !void {
    if (supportsColor()) {
        try writer.writeAll(color.code());
        try writer.writeAll(text);
        try writer.writeAll(Color.reset.code());
    } else {
        try writer.writeAll(text);
    }
}

/// Print colored formatted text to stdout
pub fn printColorf(writer: anytype, color: Color, comptime fmt: []const u8, args: anytype) !void {
    if (supportsColor()) {
        try writer.writeAll(color.code());
        try writer.print(fmt, args);
        try writer.writeAll(Color.reset.code());
    } else {
        try writer.print(fmt, args);
    }
}

/// Print success message (green checkmark)
pub fn printSuccess(comptime fmt: []const u8, args: anytype) !void {
    if (main.global_flags.quiet) return;

    const stdout = std.io.getStdOut().writer();
    try printColor(stdout, .green, "✓ ");
    try stdout.print(fmt, args);
    try stdout.writeAll("\n");
}

/// Print error message (red X)
pub fn printError(comptime fmt: []const u8, args: anytype) !void {
    const stderr = std.io.getStdErr().writer();
    try printColor(stderr, .red, "✗ ");
    try stderr.print(fmt, args);
    try stderr.writeAll("\n");
}

/// Print warning message (yellow warning sign)
pub fn printWarning(comptime fmt: []const u8, args: anytype) !void {
    if (main.global_flags.quiet) return;

    const stdout = std.io.getStdOut().writer();
    try printColor(stdout, .yellow, "⚠ ");
    try stdout.print(fmt, args);
    try stdout.writeAll("\n");
}

/// Print info message (only if not quiet)
pub fn printInfo(comptime fmt: []const u8, args: anytype) !void {
    if (main.global_flags.quiet) return;

    const stdout = std.io.getStdOut().writer();
    try stdout.print(fmt, args);
    try stdout.writeAll("\n");
}

/// Print verbose message (only if verbose flag is set)
pub fn printVerbose(comptime fmt: []const u8, args: anytype) !void {
    if (!main.global_flags.verbose) return;

    const stdout = std.io.getStdOut().writer();
    try printColor(stdout, .dim, "  ");
    try stdout.print(fmt, args);
    try stdout.writeAll("\n");
}

/// Table formatter for status display
pub const Table = struct {
    allocator: std.mem.Allocator,
    headers: []const []const u8,
    rows: std.ArrayList([]const []const u8),
    column_widths: []usize,

    pub fn init(allocator: std.mem.Allocator, headers: []const []const u8) !Table {
        var column_widths = try allocator.alloc(usize, headers.len);
        for (headers, 0..) |header, i| {
            column_widths[i] = header.len;
        }

        return Table{
            .allocator = allocator,
            .headers = headers,
            .rows = std.ArrayList([]const []const u8).init(allocator),
            .column_widths = column_widths,
        };
    }

    pub fn deinit(self: *Table) void {
        for (self.rows.items) |row| {
            self.allocator.free(row);
        }
        self.rows.deinit();
        self.allocator.free(self.column_widths);
    }

    pub fn addRow(self: *Table, row: []const []const u8) !void {
        if (row.len != self.headers.len) {
            return error.InvalidRowLength;
        }

        // Update column widths
        for (row, 0..) |cell, i| {
            // Strip ANSI codes for width calculation
            const display_width = stripAnsiLength(cell);
            if (display_width > self.column_widths[i]) {
                self.column_widths[i] = display_width;
            }
        }

        // Duplicate row data
        const row_copy = try self.allocator.alloc([]const u8, row.len);
        for (row, 0..) |cell, i| {
            row_copy[i] = try self.allocator.dupe(u8, cell);
        }

        try self.rows.append(row_copy);
    }

    pub fn print(self: *const Table, writer: anytype) !void {
        // Print top border
        try self.printBorder(writer, "┌", "┬", "┐");

        // Print headers
        try writer.writeAll("│");
        for (self.headers, 0..) |header, i| {
            try writer.writeAll(" ");
            try printColor(writer, .bold, header);
            const padding = self.column_widths[i] - header.len;
            try writer.writeByteNTimes(' ', padding);
            try writer.writeAll(" │");
        }
        try writer.writeAll("\n");

        // Print header separator
        try self.printBorder(writer, "├", "┼", "┤");

        // Print rows
        for (self.rows.items) |row| {
            try writer.writeAll("│");
            for (row, 0..) |cell, i| {
                try writer.writeAll(" ");
                try writer.writeAll(cell);
                const display_width = stripAnsiLength(cell);
                const padding = self.column_widths[i] - display_width;
                try writer.writeByteNTimes(' ', padding);
                try writer.writeAll(" │");
            }
            try writer.writeAll("\n");
        }

        // Print bottom border
        try self.printBorder(writer, "└", "┴", "┘");
    }

    fn printBorder(self: *const Table, writer: anytype, left: []const u8, mid: []const u8, right: []const u8) !void {
        try writer.writeAll(left);
        for (self.column_widths, 0..) |width, i| {
            try writer.writeByteNTimes('─', width + 2);
            if (i < self.column_widths.len - 1) {
                try writer.writeAll(mid);
            }
        }
        try writer.writeAll(right);
        try writer.writeAll("\n");
    }

    fn stripAnsiLength(text: []const u8) usize {
        var length: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '\x1b' and i + 1 < text.len and text[i + 1] == '[') {
                // Skip ANSI escape sequence
                i += 2;
                while (i < text.len and text[i] != 'm') : (i += 1) {}
                i += 1;
            } else {
                length += 1;
                i += 1;
            }
        }
        return length;
    }
};

/// Format a colored cell for table
pub fn coloredCell(allocator: std.mem.Allocator, color: Color, text: []const u8) ![]const u8 {
    if (!supportsColor()) {
        return try allocator.dupe(u8, text);
    }

    return try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        color.code(),
        text,
        Color.reset.code(),
    });
}

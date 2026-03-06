const std = @import("std");

// Create an empty Saltfile if it doesn't exist
pub fn createSaltFile() !void {
    std.fs.cwd().access("Saltfile", .{}) catch |err| {
        if (err == error.FileNotFound) {
            const file = try std.fs.cwd().createFile("Saltfile", .{});
            defer file.close();
        } else {
            return err;
        }
    };
}

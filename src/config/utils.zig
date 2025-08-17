const std = @import("std");

// Create an empty salt.conf if it doesn't exist
pub fn createSaltFile() !void {
    std.fs.cwd().access("salt.conf", .{}) catch |err| {
        if (err == error.FileNotFound) {
            const file = try std.fs.cwd().createFile("salt.conf", .{});
            defer file.close();
        } else {
            return err;
        }
    };
}

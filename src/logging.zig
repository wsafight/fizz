/// File logging.
const std = @import("std");

/// Open log file and write prefix to it.
pub fn logToFile(path: []const u8, prefix: []const u8) !std.fs.File {
    const file = try openLogFile(path);
    if (prefix.len > 0) {
        try file.writeAll(prefix);
        try file.writeAll("\n");
    }
    return file;
}

/// Open log file, write prefix to a separate writer (e.g. stderr).
/// Returns the file handle for the caller to use as log backend.
pub fn logToFileWith(path: []const u8, prefix: []const u8, writer: anytype) !std.fs.File {
    const file = try openLogFile(path);
    if (prefix.len > 0) {
        try writer.writeAll(prefix);
        try writer.writeAll("\n");
    }
    return file;
}

fn openLogFile(path: []const u8) !std.fs.File {
    const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = false });
    try file.seekTo(try file.getEndPos());
    return file;
}

const testing = std.testing;

test "logging: logToFile creates file" {
    const name = "fizz-log-test.txt";
    const f = try logToFile(name, "prefix");
    f.close();
    defer std.fs.cwd().deleteFile(name) catch {};

    const stat = try std.fs.cwd().statFile(name);
    try testing.expect(stat.size > 0);
}

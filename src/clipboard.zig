/// Clipboard messages and requests.
const buffer = @import("buffer.zig");

pub const ClipboardSelection = enum(u8) {
    system = 'c',
    primary = 'p',
};

pub const ClipboardMsg = struct {
    buf: buffer.FixedBuffer(256) = .{},
    selection: ClipboardSelection = .system,

    pub fn fromSlice(s: []const u8, selection: ClipboardSelection) ClipboardMsg {
        return .{ .buf = buffer.FixedBuffer(256).fromSlice(s), .selection = selection };
    }

    pub fn slice(self: *const ClipboardMsg) []const u8 {
        return self.buf.slice();
    }
};

pub const SetClipboardMsg = ClipboardMsg;

pub const ReadClipboardMsg = struct {
    selection: ClipboardSelection = .system,
};

const testing = @import("std").testing;

test "ClipboardMsg: fromSlice" {
    const c = ClipboardMsg.fromSlice("abc", .primary);
    try testing.expectEqualStrings("abc", c.slice());
    try testing.expect(c.selection == .primary);
    try testing.expect(!c.buf.truncated);
}

test "ClipboardMsg: truncation flag" {
    var big: [600]u8 = undefined;
    @memset(big[0..], 'x');
    const c = ClipboardMsg.fromSlice(&big, .system);
    try testing.expect(c.buf.truncated);
    try testing.expectEqual(@as(u16, 256), c.buf.len);
}

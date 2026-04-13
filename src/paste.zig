/// Bracketed paste messages.
const buffer = @import("buffer.zig");

pub const PasteMsg = buffer.FixedBuffer(256);

pub const PasteStartMsg = struct {};
pub const PasteEndMsg = struct {};

const testing = @import("std").testing;

test "PasteMsg: fromSlice" {
    const p = PasteMsg.fromSlice("hello");
    try testing.expectEqualStrings("hello", p.slice());
    try testing.expect(!p.truncated);
}

test "PasteMsg: truncation flag" {
    var big: [600]u8 = undefined;
    @memset(big[0..], 'p');
    const p = PasteMsg.fromSlice(&big);
    try testing.expect(p.truncated);
    try testing.expectEqual(@as(u16, 256), p.len);
}

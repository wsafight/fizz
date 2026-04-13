/// Generic fixed-size buffer, eliminating repetitive patterns in RawMsg/PasteMsg/ClipboardMsg etc.
pub fn FixedBuffer(comptime N: usize) type {
    return struct {
        const Self = @This();

        data: [N]u8 = [_]u8{0} ** N,
        len: u16 = 0,
        truncated: bool = false,

        pub fn fromSlice(s: []const u8) Self {
            var out = Self{};
            const n: u16 = @intCast(@min(s.len, N));
            @memcpy(out.data[0..n], s[0..n]);
            out.len = n;
            out.truncated = s.len > N;
            return out;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.data[0..self.len];
        }
    };
}

const testing = @import("std").testing;

test "FixedBuffer: basic" {
    const Buf = FixedBuffer(8);
    const b = Buf.fromSlice("hello");
    try testing.expectEqualStrings("hello", b.slice());
    try testing.expect(!b.truncated);
}

test "FixedBuffer: truncation" {
    const Buf = FixedBuffer(4);
    const b = Buf.fromSlice("hello world");
    try testing.expectEqual(@as(u16, 4), b.len);
    try testing.expect(b.truncated);
    try testing.expectEqualStrings("hell", b.slice());
}

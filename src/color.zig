/// Color types and color messages.
const std = @import("std");

pub const RgbColor = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn toHex(self: RgbColor, buf: *[7]u8) []const u8 {
        _ = std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ self.r, self.g, self.b }) catch return "#000000";
        return buf[0..7];
    }

    pub fn isDark(self: RgbColor) bool {
        // Perceptual brightness approximation: 0.299R + 0.587G + 0.114B
        const luma = @as(u32, 299) * self.r + @as(u32, 587) * self.g + @as(u32, 114) * self.b;
        return luma < 128_000;
    }
};

pub fn ColorMsg(comptime tag: []const u8) type {
    _ = tag;
    return struct {
        color: RgbColor,

        pub fn isDark(self: @This()) bool {
            return self.color.isDark();
        }
    };
}

pub const ForegroundColorMsg = ColorMsg("foreground");
pub const BackgroundColorMsg = ColorMsg("background");
pub const CursorColorMsg = ColorMsg("cursor");

const testing = std.testing;

test "RgbColor: toHex" {
    const c = RgbColor{ .r = 0x12, .g = 0xAB, .b = 0xEF };
    var buf: [7]u8 = undefined;
    try testing.expectEqualStrings("#12ABEF", c.toHex(&buf));
}

test "RgbColor: dark detection" {
    try testing.expect((RgbColor{ .r = 10, .g = 10, .b = 10 }).isDark());
    try testing.expect(!(RgbColor{ .r = 240, .g = 240, .b = 240 }).isDark());
}

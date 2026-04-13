/// Cursor and position types.
const color = @import("color.zig");

pub const Position = struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const CursorShape = enum {
    block,
    underline,
    bar,
};

pub const Cursor = struct {
    position: Position = .{},
    color: ?color.RgbColor = null,
    shape: CursorShape = .block,
    blink: bool = true,

    pub fn init(x: i32, y: i32) Cursor {
        return .{ .position = .{ .x = x, .y = y } };
    }
};

pub const CursorPositionMsg = struct {
    x: i32,
    y: i32,
};

const testing = @import("std").testing;

test "Cursor: init with default style" {
    const c = Cursor.init(3, 5);
    try testing.expectEqual(@as(i32, 3), c.position.x);
    try testing.expectEqual(@as(i32, 5), c.position.y);
    try testing.expect(c.shape == .block);
    try testing.expect(c.blink);
}

/// Mouse types and SGR mouse sequence parsing.
const std = @import("std");
const key = @import("key.zig");

pub const MouseButton = enum {
    none,
    left,
    middle,
    right,
    wheel_up,
    wheel_down,
    wheel_left,
    wheel_right,
    backward,
    forward,
};

pub const Mouse = struct {
    x: i32,
    y: i32,
    button: MouseButton,
    modifiers: key.Modifiers = .{},

    pub fn format(self: Mouse, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (self.modifiers.ctrl) try writer.writeAll("ctrl+");
        if (self.modifiers.alt) try writer.writeAll("alt+");
        if (self.modifiers.shift) try writer.writeAll("shift+");
        try writer.print("{s}({d},{d})", .{ @tagName(self.button), self.x, self.y });
    }
};

pub const MouseEventKind = enum {
    click,
    release,
    wheel,
    motion,
};

pub const ParseResult = struct {
    kind: ?MouseEventKind,
    mouse: Mouse,
    consumed: usize,
};

const empty_mouse = Mouse{ .x = 0, .y = 0, .button = .none };

fn noMatch(consumed: usize) ParseResult {
    return .{ .kind = null, .mouse = empty_mouse, .consumed = consumed };
}

pub fn parseSgr(buf: []const u8) ParseResult {
    if (buf.len < 6) return noMatch(0);
    if (!std.mem.startsWith(u8, buf, "\x1B[<")) return noMatch(0);

    var idx: usize = 3;
    const cb = parseNum(buf, &idx) orelse return noMatch(idx);
    if (idx >= buf.len or buf[idx] != ';') return noMatch(idx);
    idx += 1;

    const cx = parseNum(buf, &idx) orelse return noMatch(idx);
    if (idx >= buf.len or buf[idx] != ';') return noMatch(idx);
    idx += 1;

    const cy = parseNum(buf, &idx) orelse return noMatch(idx);
    if (idx >= buf.len) return noMatch(0);

    const final = buf[idx];
    if (final != 'M' and final != 'm') return noMatch(idx + 1);

    const mods = key.Modifiers{
        .shift = (cb & 4) != 0,
        .alt = (cb & 8) != 0,
        .ctrl = (cb & 16) != 0,
    };

    const is_wheel = (cb & 64) != 0;
    const is_motion = (cb & 32) != 0;
    const base = cb & 0b11;

    var button: MouseButton = .none;
    var kind: MouseEventKind = .click;

    if (is_wheel) {
        kind = .wheel;
        button = switch (base) {
            0 => .wheel_up,
            1 => .wheel_down,
            2 => .wheel_left,
            3 => .wheel_right,
            else => .none,
        };
    } else if (is_motion) {
        kind = .motion;
        button = decodeButton(base);
    } else if (final == 'm') {
        kind = .release;
        button = decodeButton(base);
    } else {
        kind = .click;
        button = decodeButton(base);
    }

    return .{
        .kind = kind,
        .mouse = .{
            .x = @max(0, cx - 1),
            .y = @max(0, cy - 1),
            .button = button,
            .modifiers = mods,
        },
        .consumed = idx + 1,
    };
}

fn decodeButton(v: i32) MouseButton {
    return switch (v) {
        0 => .left,
        1 => .middle,
        2 => .right,
        else => .none,
    };
}

fn parseNum(buf: []const u8, idx: *usize) ?i32 {
    const v = key.parseDigits(buf, idx) orelse return null;
    return @intCast(@min(v, std.math.maxInt(i32)));
}

const testing = std.testing;

test "mouse: parse sgr click" {
    const r = parseSgr("\x1B[<0;12;7M");
    try testing.expect(r.kind != null);
    try testing.expect(r.kind.? == .click);
    try testing.expect(r.mouse.button == .left);
    try testing.expectEqual(@as(i32, 11), r.mouse.x);
    try testing.expectEqual(@as(i32, 6), r.mouse.y);
}

test "mouse: parse sgr wheel" {
    const r = parseSgr("\x1B[<65;3;2M");
    try testing.expect(r.kind.? == .wheel);
    try testing.expect(r.mouse.button == .wheel_down);
}

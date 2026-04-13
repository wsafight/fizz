/// Key types and escape sequence parsing (Phase 3)
const std = @import("std");

pub const KeyCode = enum {
    char,
    enter,
    tab,
    backspace,
    escape,
    space,
    delete,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    insert,
    begin,
    find,
    select,
    // Function keys
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    f25,
    f26,
    f27,
    f28,
    f29,
    f30,
    f31,
    f32,
    f33,
    f34,
    f35,
    f36,
    f37,
    f38,
    f39,
    f40,
    f41,
    f42,
    f43,
    f44,
    f45,
    f46,
    f47,
    f48,
    f49,
    f50,
    f51,
    f52,
    f53,
    f54,
    f55,
    f56,
    f57,
    f58,
    f59,
    f60,
    f61,
    f62,
    f63,
    // Keypad
    kp_enter,
    kp_equal,
    kp_multiply,
    kp_plus,
    kp_comma,
    kp_minus,
    kp_decimal,
    kp_divide,
    kp_0,
    kp_1,
    kp_2,
    kp_3,
    kp_4,
    kp_5,
    kp_6,
    kp_7,
    kp_8,
    kp_9,
    kp_separator,
    kp_up,
    kp_down,
    kp_left,
    kp_right,
    kp_page_up,
    kp_page_down,
    kp_home,
    kp_end,
    kp_insert,
    kp_delete,
    kp_begin,
    // Media
    media_play,
    media_pause,
    media_play_pause,
    media_reverse,
    media_stop,
    media_fast_forward,
    media_rewind,
    media_next,
    media_prev,
    media_record,
    // Volume
    lower_vol,
    raise_vol,
    mute,
    // Modifier keys as events
    left_shift,
    left_alt,
    left_ctrl,
    left_super,
    left_hyper,
    left_meta,
    right_shift,
    right_alt,
    right_ctrl,
    right_super,
    right_hyper,
    right_meta,
    // Lock keys
    caps_lock,
    scroll_lock,
    num_lock,
    print_screen,
    pause,
    menu,
};

pub const Modifiers = packed struct(u9) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
    hyper: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    scroll_lock: bool = false,
};

pub const KeyEvent = struct {
    code: KeyCode,
    char: u21 = 0,
    modifiers: Modifiers = .{},
    /// Printable character text (Kitty protocol associated text)
    text: [16]u8 = [_]u8{0} ** 16,
    text_len: u8 = 0,
    /// Shifted key code (Kitty protocol)
    shifted_code: u21 = 0,
    /// PC-101 layout base key code (Kitty protocol)
    base_code: u21 = 0,
    /// Whether this is a key repeat (Kitty protocol)
    is_repeat: bool = false,

    pub fn textSlice(self: *const KeyEvent) []const u8 {
        return self.text[0..self.text_len];
    }

    /// Format as human-readable key description (Go Key.String() equivalent).
    pub fn format(self: KeyEvent, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (self.modifiers.ctrl) try writer.writeAll("ctrl+");
        if (self.modifiers.alt) try writer.writeAll("alt+");
        if (self.modifiers.shift) try writer.writeAll("shift+");
        if (self.modifiers.super) try writer.writeAll("super+");
        if (self.modifiers.hyper) try writer.writeAll("hyper+");
        if (self.modifiers.meta) try writer.writeAll("meta+");

        if (self.code == .char and self.char > 0) {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(self.char, &buf) catch 0;
            if (len > 0) try writer.writeAll(buf[0..len]);
        } else {
            try writer.writeAll(@tagName(self.code));
        }
    }

    /// Return formatted key string (stack buffer).
    pub fn string(self: KeyEvent) [64]u8 {
        var buf: [64]u8 = [_]u8{0} ** 64;
        var stream = std.io.fixedBufferStream(&buf);
        self.format("", .{}, stream.writer()) catch {};
        return buf;
    }
};

pub const ParseResult = struct {
    key: ?KeyEvent,
    consumed: usize,
};

/// Parse a single key event from the input buffer.
/// is_esc_timeout: set to true if buf starts with ESC and no more data follows (poll timeout).
pub fn parseInput(buf: []const u8, is_esc_timeout: bool) ParseResult {
    if (buf.len == 0) return .{ .key = null, .consumed = 0 };

    const b = buf[0];

    // Starts with ESC
    if (b == 0x1B) {
        if (buf.len == 1) {
            if (is_esc_timeout) {
                return .{ .key = .{ .code = .escape }, .consumed = 1 };
            }
            // Need more data
            return .{ .key = null, .consumed = 0 };
        }
        return parseEscape(buf);
    }

    // Ctrl+A-Z (0x01-0x1A)
    if (b >= 0x01 and b <= 0x1A) {
        // Special mappings
        if (b == 0x09) return .{ .key = .{ .code = .tab }, .consumed = 1 };
        if (b == 0x0D) return .{ .key = .{ .code = .enter }, .consumed = 1 };
        return .{
            .key = .{
                .code = .char,
                .char = @as(u21, b) + 'a' - 1,
                .modifiers = .{ .ctrl = true },
            },
            .consumed = 1,
        };
    }

    // Backspace
    if (b == 0x7F) return .{ .key = .{ .code = .backspace }, .consumed = 1 };

    // Printable ASCII
    if (b >= 0x20 and b <= 0x7E) {
        if (b == ' ') return .{ .key = .{ .code = .space, .char = ' ' }, .consumed = 1 };
        return .{ .key = .{ .code = .char, .char = b }, .consumed = 1 };
    }

    // UTF-8 multi-byte
    if (b >= 0xC0) {
        const seq_len = utf8SeqLen(b) orelse return .{ .key = null, .consumed = 1 };
        if (buf.len < seq_len) return .{ .key = null, .consumed = 0 };
        const cp = std.unicode.utf8Decode(buf[0..seq_len]) catch
            return .{ .key = null, .consumed = seq_len };
        return .{ .key = .{ .code = .char, .char = cp }, .consumed = seq_len };
    }

    // Unknown byte, skip
    return .{ .key = null, .consumed = 1 };
}

fn utf8SeqLen(first: u8) ?usize {
    if (first & 0xE0 == 0xC0) return 2;
    if (first & 0xF0 == 0xE0) return 3;
    if (first & 0xF8 == 0xF0) return 4;
    return null;
}

fn parseEscape(buf: []const u8) ParseResult {
    // buf[0] == 0x1B, buf.len >= 2
    const second = buf[1];

    // CSI: ESC [
    if (second == '[') return parseCsi(buf);

    // SS3: ESC O
    if (second == 'O') return parseSs3(buf);

    // Alt+key
    if (second >= 0x20 and second <= 0x7E) {
        return .{
            .key = .{
                .code = .char,
                .char = second,
                .modifiers = .{ .alt = true },
            },
            .consumed = 2,
        };
    }

    // Alt+Ctrl
    if (second >= 0x01 and second <= 0x1A) {
        return .{
            .key = .{
                .code = .char,
                .char = @as(u21, second) + 'a' - 1,
                .modifiers = .{ .alt = true, .ctrl = true },
            },
            .consumed = 2,
        };
    }

    return .{ .key = .{ .code = .escape }, .consumed = 1 };
}

fn parseCsi(buf: []const u8) ParseResult {
    // buf[0..2] == ESC [, need at least 3 bytes
    if (buf.len < 3) return .{ .key = null, .consumed = 0 };

    const third = buf[2];

    // Simple CSI sequence (no parameters)
    switch (third) {
        'A' => return .{ .key = .{ .code = .up }, .consumed = 3 },
        'B' => return .{ .key = .{ .code = .down }, .consumed = 3 },
        'C' => return .{ .key = .{ .code = .right }, .consumed = 3 },
        'D' => return .{ .key = .{ .code = .left }, .consumed = 3 },
        'H' => return .{ .key = .{ .code = .home }, .consumed = 3 },
        'F' => return .{ .key = .{ .code = .end }, .consumed = 3 },
        else => {},
    }

    // Parameterized CSI: ESC [ <num> ~ or ESC [ <num> ; <num> ~
    // Find terminator
    var i: usize = 2;
    while (i < buf.len) : (i += 1) {
        const c = buf[i];
        if (c >= 0x40 and c <= 0x7E) {
            // Terminator
            const params = buf[2..i];
            return parseCsiParams(params, c, i + 1);
        }
    }

    // Incomplete sequence
    return .{ .key = null, .consumed = 0 };
}

fn parseCsiParams(params: []const u8, terminator: u8, total_len: usize) ParseResult {
    if (terminator == '~') {
        // ESC [ <n> ~ or ESC [ <n> ; <mod> ~
        const n = parseNum(params) orelse return .{ .key = null, .consumed = total_len };
        const code: ?KeyCode = switch (n) {
            1 => .home,
            2 => .insert,
            3 => .delete,
            4 => .end,
            5 => .page_up,
            6 => .page_down,
            7 => .home,
            8 => .end,
            15 => .f5,
            17 => .f6,
            18 => .f7,
            19 => .f8,
            20 => .f9,
            21 => .f10,
            23 => .f11,
            24 => .f12,
            else => null,
        };
        if (code) |c| {
            const mods = parseModParam(params);
            return .{ .key = .{ .code = c, .modifiers = mods }, .consumed = total_len };
        }
    }

    // Arrow keys with modifiers: ESC [ 1 ; <mod> <A-D>
    if ((terminator >= 'A' and terminator <= 'D') or terminator == 'H' or terminator == 'F') {
        const code: KeyCode = switch (terminator) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            else => unreachable,
        };
        const mods = parseModParam(params);
        return .{ .key = .{ .code = code, .modifiers = mods }, .consumed = total_len };
    }

    return .{ .key = null, .consumed = total_len };
}

fn parseSs3(buf: []const u8) ParseResult {
    if (buf.len < 3) return .{ .key = null, .consumed = 0 };
    const code: ?KeyCode = switch (buf[2]) {
        'P' => .f1,
        'Q' => .f2,
        'R' => .f3,
        'S' => .f4,
        'H' => .home,
        'F' => .end,
        else => null,
    };
    if (code) |c| return .{ .key = .{ .code = c }, .consumed = 3 };
    return .{ .key = null, .consumed = 3 };
}

/// Shared digit parser: advances idx past consecutive ASCII digits, returns parsed i64.
pub fn parseDigits(data: []const u8, idx: *usize) ?i64 {
    var value: i64 = 0;
    var found = false;
    while (idx.* < data.len) : (idx.* += 1) {
        const c = data[idx.*];
        if (c < '0' or c > '9') break;
        found = true;
        value = value *| 10 +| @as(i64, c - '0');
    }
    return if (found) value else null;
}

fn parseNum(s: []const u8) ?u16 {
    var idx: usize = 0;
    const v = parseDigits(s, &idx) orelse return null;
    return @intCast(@min(v, std.math.maxInt(u16)));
}

/// Decode xterm modifier bitmask (raw param value, 1-based) into Modifiers.
pub fn decodeModifiers(raw: u16) Modifiers {
    const v = raw -| 1;
    return .{
        .shift = v & 1 != 0,
        .alt = v & 2 != 0,
        .ctrl = v & 4 != 0,
        .super = v & 8 != 0,
        .hyper = v & 16 != 0,
        .meta = v & 32 != 0,
        .caps_lock = v & 64 != 0,
        .num_lock = v & 128 != 0,
        .scroll_lock = v & 256 != 0,
    };
}

fn parseModParam(params: []const u8) Modifiers {
    // Find modifier parameter after ';'
    var i: usize = 0;
    while (i < params.len) : (i += 1) {
        if (params[i] == ';') {
            const mod_n = parseNum(params[i + 1 ..]) orelse return .{};
            return decodeModifiers(mod_n);
        }
    }
    return .{};
}

// ── Unit tests ──────────────────────────────────────────────

const testing = std.testing;

test "key: printable ASCII" {
    const r = parseInput("a", false);
    try testing.expect(r.key != null);
    try testing.expect(r.key.?.code == .char);
    try testing.expectEqual(@as(u21, 'a'), r.key.?.char);
    try testing.expectEqual(@as(usize, 1), r.consumed);
}

test "key: space" {
    const r = parseInput(" ", false);
    try testing.expect(r.key.?.code == .space);
}

test "key: enter (CR)" {
    const r = parseInput("\r", false);
    try testing.expect(r.key.?.code == .enter);
}

test "key: tab" {
    const r = parseInput("\t", false);
    try testing.expect(r.key.?.code == .tab);
}

test "key: backspace (0x7F)" {
    const r = parseInput(&[_]u8{0x7F}, false);
    try testing.expect(r.key.?.code == .backspace);
}

test "key: Ctrl+C" {
    const r = parseInput(&[_]u8{0x03}, false);
    try testing.expect(r.key.?.code == .char);
    try testing.expectEqual(@as(u21, 'c'), r.key.?.char);
    try testing.expect(r.key.?.modifiers.ctrl);
}

test "key: Ctrl+A" {
    const r = parseInput(&[_]u8{0x01}, false);
    try testing.expect(r.key.?.code == .char);
    try testing.expectEqual(@as(u21, 'a'), r.key.?.char);
    try testing.expect(r.key.?.modifiers.ctrl);
}

test "key: ESC alone (timeout)" {
    const r = parseInput(&[_]u8{0x1B}, true);
    try testing.expect(r.key.?.code == .escape);
}

test "key: ESC alone (no timeout, need more data)" {
    const r = parseInput(&[_]u8{0x1B}, false);
    try testing.expect(r.key == null);
    try testing.expectEqual(@as(usize, 0), r.consumed);
}

test "key: arrow up (CSI A)" {
    const r = parseInput("\x1B[A", false);
    try testing.expect(r.key.?.code == .up);
    try testing.expectEqual(@as(usize, 3), r.consumed);
}

test "key: arrow down" {
    const r = parseInput("\x1B[B", false);
    try testing.expect(r.key.?.code == .down);
}

test "key: arrow right" {
    const r = parseInput("\x1B[C", false);
    try testing.expect(r.key.?.code == .right);
}

test "key: arrow left" {
    const r = parseInput("\x1B[D", false);
    try testing.expect(r.key.?.code == .left);
}

test "key: Home (CSI H)" {
    const r = parseInput("\x1B[H", false);
    try testing.expect(r.key.?.code == .home);
}

test "key: End (CSI F)" {
    const r = parseInput("\x1B[F", false);
    try testing.expect(r.key.?.code == .end);
}

test "key: Delete (CSI 3~)" {
    const r = parseInput("\x1B[3~", false);
    try testing.expect(r.key.?.code == .delete);
}

test "key: Page Up (CSI 5~)" {
    const r = parseInput("\x1B[5~", false);
    try testing.expect(r.key.?.code == .page_up);
}

test "key: Page Down (CSI 6~)" {
    const r = parseInput("\x1B[6~", false);
    try testing.expect(r.key.?.code == .page_down);
}

test "key: Insert (CSI 2~)" {
    const r = parseInput("\x1B[2~", false);
    try testing.expect(r.key.?.code == .insert);
}

test "key: F1 (SS3 P)" {
    const r = parseInput("\x1BOP", false);
    try testing.expect(r.key.?.code == .f1);
}

test "key: F2 (SS3 Q)" {
    const r = parseInput("\x1BOQ", false);
    try testing.expect(r.key.?.code == .f2);
}

test "key: F5 (CSI 15~)" {
    const r = parseInput("\x1B[15~", false);
    try testing.expect(r.key.?.code == .f5);
}

test "key: F12 (CSI 24~)" {
    const r = parseInput("\x1B[24~", false);
    try testing.expect(r.key.?.code == .f12);
}

test "key: Alt+a" {
    const r = parseInput("\x1Ba", false);
    try testing.expect(r.key.?.code == .char);
    try testing.expectEqual(@as(u21, 'a'), r.key.?.char);
    try testing.expect(r.key.?.modifiers.alt);
}

test "key: Alt+Ctrl+a" {
    const r = parseInput(&[_]u8{ 0x1B, 0x01 }, false);
    try testing.expect(r.key.?.code == .char);
    try testing.expectEqual(@as(u21, 'a'), r.key.?.char);
    try testing.expect(r.key.?.modifiers.alt);
    try testing.expect(r.key.?.modifiers.ctrl);
}

test "key: Shift+Up (CSI 1;2A)" {
    const r = parseInput("\x1B[1;2A", false);
    try testing.expect(r.key.?.code == .up);
    try testing.expect(r.key.?.modifiers.shift);
}

test "key: Ctrl+Right (CSI 1;5C)" {
    const r = parseInput("\x1B[1;5C", false);
    try testing.expect(r.key.?.code == .right);
    try testing.expect(r.key.?.modifiers.ctrl);
}

test "key: UTF-8 Chinese character" {
    const r = parseInput("你", false);
    try testing.expect(r.key.?.code == .char);
    try testing.expectEqual(@as(u21, 0x4F60), r.key.?.char);
    try testing.expectEqual(@as(usize, 3), r.consumed);
}

test "key: empty input" {
    const r = parseInput("", false);
    try testing.expect(r.key == null);
    try testing.expectEqual(@as(usize, 0), r.consumed);
}

test "key: Ctrl+Delete (CSI 3;5~)" {
    const r = parseInput("\x1B[3;5~", false);
    try testing.expect(r.key.?.code == .delete);
    try testing.expect(r.key.?.modifiers.ctrl);
}

test "key: Shift+F5 (CSI 15;2~)" {
    const r = parseInput("\x1B[15;2~", false);
    try testing.expect(r.key.?.code == .f5);
    try testing.expect(r.key.?.modifiers.shift);
}

test "key: Ctrl+Home (CSI 1;5H)" {
    const r = parseInput("\x1B[1;5H", false);
    try testing.expect(r.key.?.code == .home);
    try testing.expect(r.key.?.modifiers.ctrl);
}

test "key: Alt+End (CSI 1;3F)" {
    const r = parseInput("\x1B[1;3F", false);
    try testing.expect(r.key.?.code == .end);
    try testing.expect(r.key.?.modifiers.alt);
}

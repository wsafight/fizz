/// Message type definitions (Phase 5 full).
const std = @import("std");
const buffer = @import("buffer.zig");
const key_mod = @import("input/key.zig");
const mouse_mod = @import("input/mouse.zig");
const screen_mod = @import("screen.zig");
const focus_mod = @import("focus.zig");
const clipboard_mod = @import("clipboard.zig");
const paste_mod = @import("paste.zig");
const color_mod = @import("color.zig");
const cursor_mod = @import("cursor.zig");
const termcap_mod = @import("termcap.zig");
const keyboard_mod = @import("keyboard.zig");
const profile_mod = @import("profile.zig");
const environ_mod = @import("environ.zig");
const raw_mod = @import("raw.zig");
const exec_mod = @import("exec.zig");

pub const KeyEvent = key_mod.KeyEvent;
pub const KeyCode = key_mod.KeyCode;
pub const Modifiers = key_mod.Modifiers;
pub const Mouse = mouse_mod.Mouse;
pub const MouseButton = mouse_mod.MouseButton;
pub const MouseEventKind = mouse_mod.MouseEventKind;
pub const WindowSizeMsg = screen_mod.WindowSizeMsg;

pub const Msg = union(enum) {
    // Lifecycle
    startup,
    quit,
    suspend_msg,
    resume_msg,
    interrupt,

    // Events and general
    no_op,
    text: TextPayload,
    custom: CustomMsg,
    window_size: screen_mod.WindowSizeMsg,
    mode_report: screen_mod.ModeReportMsg,
    key_press: KeyEvent,
    key_release: KeyEvent,
    mouse_click: Mouse,
    mouse_release: Mouse,
    mouse_wheel: Mouse,
    mouse_motion: Mouse,
    focus: focus_mod.FocusMsg,
    blur: focus_mod.BlurMsg,

    // Clipboard/paste
    clipboard: clipboard_mod.ClipboardMsg,
    set_clipboard: clipboard_mod.SetClipboardMsg,
    read_clipboard: clipboard_mod.ReadClipboardMsg,
    paste: paste_mod.PasteMsg,
    paste_start: paste_mod.PasteStartMsg,
    paste_end: paste_mod.PasteEndMsg,

    // Color and cursor
    foreground_color: color_mod.ForegroundColorMsg,
    background_color: color_mod.BackgroundColorMsg,
    cursor_color: color_mod.CursorColorMsg,
    cursor_position: cursor_mod.CursorPositionMsg,

    // Terminal capabilities
    capability: termcap_mod.CapabilityMsg,
    terminal_version: termcap_mod.TerminalVersionMsg,
    keyboard_enhancements: keyboard_mod.KeyboardEnhancementsMsg,
    color_profile: profile_mod.ColorProfileMsg,
    env: *const environ_mod.EnvMsg,

    // Command/request internal messages
    request_window_size,
    clear_screen,
    request_background_color,
    request_foreground_color,
    request_cursor_color,
    request_cursor_position,
    request_capability: termcap_mod.RequestCapabilityMsg,
    request_terminal_version,
    run_exec,
    drain_window_size,
    drain_mouse_motion,
    raw: raw_mod.RawMsg,
    print_line: TextPayload,

    // External process
    exec_result: exec_mod.ExecResultMsg,

    // Compile-time size guard: alert if a new variant bloats the union beyond 512 bytes.
    comptime {
        if (@sizeOf(Msg) > 512) {
            @compileError("Msg union exceeds 512 bytes; consider using a pointer for the new variant");
        }
    }
};

/// Fixed-size text payload to avoid slice lifetime issues across threads.
/// Maximum capacity is 256 bytes. Data exceeding this limit will be truncated
/// and the `truncated` flag will be set to true.
pub const TextPayload = struct {
    buf: buffer.FixedBuffer(256) = .{},

    pub fn fromSlice(s: []const u8) TextPayload {
        const b = buffer.FixedBuffer(256).fromSlice(s);
        if (b.truncated) {
            std.log.warn("TextPayload truncated: {d} bytes exceeds 256 byte limit", .{s.len});
        }
        return .{ .buf = b };
    }

    pub fn slice(self: *const TextPayload) []const u8 {
        return self.buf.slice();
    }
};

/// Custom message bridge: name (32 bytes max) + data payload (128 bytes max).
/// Fields exceeding limits will be truncated with corresponding `*_truncated` flags set.
pub const CustomMsg = struct {
    name_buf: buffer.FixedBuffer(32) = .{},
    data_buf: buffer.FixedBuffer(128) = .{},

    pub fn fromSlices(name: []const u8, data: []const u8) CustomMsg {
        const nb = buffer.FixedBuffer(32).fromSlice(name);
        const db = buffer.FixedBuffer(128).fromSlice(data);
        if (nb.truncated) {
            std.log.warn("CustomMsg name truncated: {d} bytes exceeds 32 byte limit", .{name.len});
        }
        if (db.truncated) {
            std.log.warn("CustomMsg data truncated: {d} bytes exceeds 128 byte limit", .{data.len});
        }
        return .{ .name_buf = nb, .data_buf = db };
    }

    pub fn nameSlice(self: *const CustomMsg) []const u8 {
        return self.name_buf.slice();
    }

    pub fn dataSlice(self: *const CustomMsg) []const u8 {
        return self.data_buf.slice();
    }
};

const testing = @import("std").testing;

test "Msg: text payload" {
    const m: Msg = .{ .text = TextPayload.fromSlice("hello") };
    try testing.expect(m == .text);
    try testing.expectEqualStrings("hello", m.text.slice());
}

test "Msg: includes phase 5 variants" {
    const a: Msg = .{ .focus = .{} };
    const b: Msg = .{ .paste_start = .{} };
    const c: Msg = .request_terminal_version;
    const d: Msg = .run_exec;
    try testing.expect(a == .focus);
    try testing.expect(b == .paste_start);
    try testing.expect(c == .request_terminal_version);
    try testing.expect(d == .run_exec);
}

test "Msg: custom payload bridge" {
    const m: Msg = .{ .custom = CustomMsg.fromSlices("event", "payload") };
    try testing.expect(m == .custom);
    try testing.expectEqualStrings("event", m.custom.nameSlice());
    try testing.expectEqualStrings("payload", m.custom.dataSlice());
}

test "Msg: text payload truncation flag" {
    var big: [400]u8 = undefined;
    @memset(big[0..], 't');
    const p = TextPayload.fromSlice(&big);
    try testing.expect(p.buf.truncated);
    try testing.expectEqual(@as(u16, 256), p.buf.len);
}

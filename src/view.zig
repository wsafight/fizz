/// View struct (Phase 4).
const cursor_mod = @import("cursor.zig");
const color = @import("color.zig");
const cmd = @import("cmd.zig");
const mouse = @import("input/mouse.zig");
const keyboard = @import("keyboard.zig");

pub const MouseMode = enum {
    none,
    cell_motion,
    all_motion,
};

pub const ProgressBarState = enum {
    none,
    default,
    err,
    indeterminate,
    warning,
};

pub const ProgressBar = struct {
    state: ProgressBarState = .none,
    value: u8 = 0,

    pub fn init(state: ProgressBarState, value: u8) ProgressBar {
        return .{
            .state = state,
            .value = if (value > 100) 100 else value,
        };
    }
};

pub const View = struct {
    content: []const u8 = "",
    cursor: ?cursor_mod.Cursor = null,
    background_color: ?color.RgbColor = null,
    foreground_color: ?color.RgbColor = null,
    window_title: []const u8 = "",
    progress_bar: ?ProgressBar = null,
    alt_screen: bool = false,
    report_focus: bool = false,
    disable_bracketed_paste_mode: bool = false,
    mouse_mode: MouseMode = .none,
    keyboard_enhancements: keyboard.KeyboardEnhancements = .{},
    on_mouse: ?*const fn (kind: mouse.MouseEventKind, m: mouse.Mouse) ?cmd.Cmd = null,

    pub fn init(content: []const u8) View {
        return .{ .content = content };
    }

    pub fn setContent(self: *View, content: []const u8) void {
        self.content = content;
    }
};

const testing = @import("std").testing;

test "View: default and mutate" {
    var v = View.init("hello");
    try testing.expectEqualStrings("hello", v.content);
    v.alt_screen = true;
    v.mouse_mode = .all_motion;
    v.setContent("world");
    try testing.expectEqualStrings("world", v.content);
    try testing.expect(v.alt_screen);
    try testing.expect(v.mouse_mode == .all_motion);
}

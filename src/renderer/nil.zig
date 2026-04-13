/// Null renderer: preserves Program lifecycle semantics without frame rendering.
const std = @import("std");
const renderer_mod = @import("renderer.zig");
const view = @import("../view.zig");
const cmd = @import("../cmd.zig");
const profile = @import("../profile.zig");
const mouse = @import("../input/mouse.zig");

pub const NilRenderer = struct {
    out_file: std.fs.File,
    width: u16 = 0,
    height: u16 = 0,

    pub fn init(out_file: std.fs.File, width: u16, height: u16) NilRenderer {
        return .{ .out_file = out_file, .width = width, .height = height };
    }

    pub fn asRenderer(self: *NilRenderer) renderer_mod.Renderer {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    fn start(_: *anyopaque) void {}

    fn close(_: *anyopaque) !void {}

    fn render(_: *anyopaque, _: view.View) void {}

    fn flush(_: *anyopaque, _: bool) !void {}

    fn reset(_: *anyopaque) void {}

    fn insertAbove(ctx: *anyopaque, line: []const u8) !void {
        const self: *NilRenderer = @ptrCast(@alignCast(ctx));
        try self.out_file.writeAll(line);
        try self.out_file.writeAll("\n");
    }

    fn setSyncdUpdates(_: *anyopaque, _: bool) void {}

    fn setWidthMethod(_: *anyopaque, _: renderer_mod.WidthMethod) void {}

    fn resize(ctx: *anyopaque, width: u16, height: u16) void {
        const self: *NilRenderer = @ptrCast(@alignCast(ctx));
        self.width = width;
        self.height = height;
    }

    fn setColorProfile(_: *anyopaque, _: profile.ColorProfile) void {}

    fn clearScreen(_: *anyopaque) void {}

    fn writeString(ctx: *anyopaque, s: []const u8) !usize {
        const self: *NilRenderer = @ptrCast(@alignCast(ctx));
        try self.out_file.writeAll(s);
        return s.len;
    }

    fn onMouse(_: *anyopaque, _: mouse.MouseEventKind, _: mouse.Mouse) ?cmd.Cmd {
        return null;
    }

    const vtable = renderer_mod.VTable{
        .start = start,
        .close = close,
        .render = render,
        .flush = flush,
        .reset = reset,
        .insert_above = insertAbove,
        .set_syncd_updates = setSyncdUpdates,
        .set_width_method = setWidthMethod,
        .resize = resize,
        .set_color_profile = setColorProfile,
        .clear_screen = clearScreen,
        .write_string = writeString,
        .on_mouse = onMouse,
    };
};

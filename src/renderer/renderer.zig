/// Renderer interface.
const view = @import("../view.zig");
const cmd = @import("../cmd.zig");
const profile = @import("../profile.zig");
const mouse = @import("../input/mouse.zig");

pub const WidthMethod = enum {
    cell,
    grapheme,
};

pub const VTable = struct {
    start: *const fn (ctx: *anyopaque) void,
    close: *const fn (ctx: *anyopaque) anyerror!void,
    render: *const fn (ctx: *anyopaque, v: view.View) void,
    flush: *const fn (ctx: *anyopaque, closing: bool) anyerror!void,
    reset: *const fn (ctx: *anyopaque) void,
    insert_above: *const fn (ctx: *anyopaque, line: []const u8) anyerror!void,
    set_syncd_updates: *const fn (ctx: *anyopaque, enabled: bool) void,
    set_width_method: *const fn (ctx: *anyopaque, method: WidthMethod) void,
    resize: *const fn (ctx: *anyopaque, width: u16, height: u16) void,
    set_color_profile: *const fn (ctx: *anyopaque, cp: profile.ColorProfile) void,
    clear_screen: *const fn (ctx: *anyopaque) void,
    write_string: *const fn (ctx: *anyopaque, s: []const u8) anyerror!usize,
    on_mouse: *const fn (ctx: *anyopaque, kind: mouse.MouseEventKind, m: mouse.Mouse) ?cmd.Cmd,
};

pub const Renderer = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn start(self: Renderer) void {
        self.vtable.start(self.ctx);
    }

    pub fn close(self: Renderer) !void {
        try self.vtable.close(self.ctx);
    }

    pub fn render(self: Renderer, v: view.View) void {
        self.vtable.render(self.ctx, v);
    }

    pub fn flush(self: Renderer, closing: bool) !void {
        try self.vtable.flush(self.ctx, closing);
    }

    pub fn reset(self: Renderer) void {
        self.vtable.reset(self.ctx);
    }

    pub fn insertAbove(self: Renderer, line: []const u8) !void {
        try self.vtable.insert_above(self.ctx, line);
    }

    pub fn setSyncdUpdates(self: Renderer, enabled: bool) void {
        self.vtable.set_syncd_updates(self.ctx, enabled);
    }

    pub fn setWidthMethod(self: Renderer, method: WidthMethod) void {
        self.vtable.set_width_method(self.ctx, method);
    }

    pub fn resize(self: Renderer, width: u16, height: u16) void {
        self.vtable.resize(self.ctx, width, height);
    }

    pub fn setColorProfile(self: Renderer, cp: profile.ColorProfile) void {
        self.vtable.set_color_profile(self.ctx, cp);
    }

    pub fn clearScreen(self: Renderer) void {
        self.vtable.clear_screen(self.ctx);
    }

    pub fn writeString(self: Renderer, s: []const u8) !usize {
        return try self.vtable.write_string(self.ctx, s);
    }

    pub fn onMouse(self: Renderer, kind: mouse.MouseEventKind, m: mouse.Mouse) ?cmd.Cmd {
        return self.vtable.on_mouse(self.ctx, kind, m);
    }
};

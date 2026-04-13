/// TestProgram: headless test driver for fizz applications.
///
/// Allows injecting key/mouse/custom events, stepping the event loop,
/// and asserting the rendered view content — without a real terminal.
///
/// Usage:
///   var tp = TestProgram(MyModel).init(MyModel{});
///   defer tp.deinit();
///   tp.sendKey('q');
///   tp.step();
///   try testing.expectEqualStrings("goodbye", tp.viewContent());
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const msg_mod = @import("msg.zig");
const cmd_mod = @import("cmd.zig");
const model_mod = @import("model.zig");
const view_mod = @import("view.zig");
const key_mod = @import("input/key.zig");

const Msg = msg_mod.Msg;
const Cmd = cmd_mod.Cmd;

pub fn TestProgram(comptime ModelType: type) type {
    comptime {
        model_mod.validateModel(ModelType);
    }

    return struct {
        const Self = @This();

        model: ModelType,
        last_view: []const u8 = "",
        pending: [64]Msg = undefined,
        pending_len: usize = 0,
        arena: std.heap.ArenaAllocator,

        pub fn init(model: ModelType) Self {
            var self = Self{
                .model = model,
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            };
            const init_cmd = self.model.init();
            if (init_cmd) |c| self.execCmd(c);
            self.updateView();
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (comptime model_mod.hasDeinit(ModelType)) {
                self.model.deinit();
            }
            self.arena.deinit();
        }

        /// Inject a key press event.
        pub fn sendKey(self: *Self, char: u21) void {
            self.send(.{ .key_press = .{ .code = .char, .char = char } });
        }

        /// Inject a key press with modifiers.
        pub fn sendKeyMod(self: *Self, code: key_mod.KeyCode, char: u21, mods: key_mod.Modifiers) void {
            self.send(.{ .key_press = .{ .code = code, .char = char, .modifiers = mods } });
        }

        /// Inject a special key press (enter, escape, arrow, etc.).
        pub fn sendSpecialKey(self: *Self, code: key_mod.KeyCode) void {
            self.send(.{ .key_press = .{ .code = code } });
        }

        /// Inject any message.
        pub fn send(self: *Self, m: Msg) void {
            if (self.pending_len < self.pending.len) {
                self.pending[self.pending_len] = m;
                self.pending_len += 1;
            }
        }

        /// Process all pending messages through model.update, then re-render.
        /// Returns true if the program should continue, false if quit/interrupt was received.
        pub fn step(self: *Self) bool {
            var i: usize = 0;
            while (i < self.pending_len) : (i += 1) {
                const m = self.pending[i];
                const c = model_mod.callUpdate(ModelType, &self.model, m, self.arena.allocator());
                if (c) |cmd| {
                    if (cmd.isQuit()) return false;
                    self.execCmd(cmd);
                }
                switch (m) {
                    .quit => return false,
                    .interrupt => return false,
                    else => {},
                }
            }
            self.pending_len = 0;
            self.updateView();
            return true;
        }

        /// Get the current view content string.
        pub fn viewContent(self: *Self) []const u8 {
            return self.last_view;
        }

        /// Get a pointer to the model for direct inspection.
        pub fn getModel(self: *Self) *ModelType {
            return &self.model;
        }

        fn updateView(self: *Self) void {
            _ = self.arena.reset(.retain_capacity);
            const v = model_mod.viewOf(ModelType, &self.model, self.arena.allocator());
            self.last_view = v.content;
        }

        fn execCmd(self: *Self, c: Cmd) void {
            switch (c) {
                .simple => |f| self.send(f()),
                .msg => |m| self.send(m),
                .batch => |cmds| {
                    for (cmds) |sub| self.execCmd(sub);
                },
                .sequence => |cmds| {
                    for (cmds) |sub| self.execCmd(sub);
                },
                .tick, .every => {}, // timers don't fire in test mode
                .exec => {}, // exec not supported in test mode
                .throttle => |t| self.send(t.message),
                .debounce => |d| self.send(d.message),
            }
        }
    };
}

const testing = std.testing;

const SimpleModel = struct {
    count: i32 = 0,

    pub fn init(_: *SimpleModel) ?Cmd {
        return null;
    }

    pub fn update(self: *SimpleModel, m: Msg) ?Cmd {
        switch (m) {
            .key_press => |kp| {
                if (kp.char == 'q') return cmd_mod.quit_cmd;
                if (kp.char == '+') self.count += 1;
                if (kp.char == '-') self.count -= 1;
            },
            else => {},
        }
        return null;
    }

    pub fn view(self: *SimpleModel) []const u8 {
        _ = self;
        return "test";
    }
};

test "TestProgram: basic lifecycle" {
    var tp = TestProgram(SimpleModel).init(.{});
    defer tp.deinit();

    try testing.expectEqualStrings("test", tp.viewContent());
    tp.sendKey('+');
    _ = tp.step();
    try testing.expectEqual(@as(i32, 1), tp.getModel().count);
}

test "TestProgram: quit returns false" {
    var tp = TestProgram(SimpleModel).init(.{});
    defer tp.deinit();

    tp.sendKey('q');
    try testing.expect(!tp.step());
}

test "TestProgram: multiple events in one step" {
    var tp = TestProgram(SimpleModel).init(.{});
    defer tp.deinit();

    tp.sendKey('+');
    tp.sendKey('+');
    tp.sendKey('+');
    _ = tp.step();
    try testing.expectEqual(@as(i32, 3), tp.getModel().count);
}

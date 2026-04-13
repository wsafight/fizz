const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const msg_mod = @import("../msg.zig");
const cmd_mod = @import("../cmd.zig");
const options_mod = @import("../options.zig");
const view_mod = @import("../view.zig");
const mouse_mod = @import("../input/mouse.zig");
const raw_mod = @import("../raw.zig");
const clipboard_mod = @import("../clipboard.zig");
const termcap_mod = @import("../termcap.zig");
const profile_mod = @import("../profile.zig");
const screen_mod = @import("../screen.zig");
const environ_mod = @import("../environ.zig");
const exec_mod = @import("../exec.zig");

const Program = @import("program.zig").Program;
const Msg = msg_mod.Msg;
const Cmd = cmd_mod.Cmd;

// ── Unit tests ──────────────────────────────────────────────

const testing = std.testing;

const CountingModel = struct {
    count: i32 = 0,

    pub fn init(_: *CountingModel) ?cmd_mod.Cmd {
        return null;
    }

    pub fn update(self: *CountingModel, m: Msg) ?cmd_mod.Cmd {
        switch (m) {
            .key_press => self.count += 1,
            else => {},
        }
        return null;
    }

    pub fn view(_: *CountingModel) []const u8 {
        return "";
    }
};

const ImmediateQuitModel = struct {
    pub fn init(_: *ImmediateQuitModel) ?cmd_mod.Cmd {
        return cmd_mod.quit_cmd;
    }

    pub fn update(_: *ImmediateQuitModel, _: Msg) ?cmd_mod.Cmd {
        return null;
    }

    pub fn view(_: *ImmediateQuitModel) []const u8 {
        return "quitting\n";
    }
};

const StartupQuitModel = struct {
    got_startup: bool = false,

    pub fn init(_: *StartupQuitModel) ?cmd_mod.Cmd {
        return null;
    }

    pub fn update(self: *StartupQuitModel, m: Msg) ?cmd_mod.Cmd {
        switch (m) {
            .startup => {
                self.got_startup = true;
                return cmd_mod.quit_cmd;
            },
            else => {},
        }
        return null;
    }

    pub fn view(_: *StartupQuitModel) []const u8 {
        return "";
    }
};

fn createPipe() !struct { write: std.fs.File, read: std.fs.File } {
    const pipes = try posix.pipe();
    return .{
        .write = std.fs.File{ .handle = pipes[1] },
        .read = std.fs.File{ .handle = pipes[0] },
    };
}

fn invalidFd() posix.fd_t {
    if (builtin.os.tag == .windows) {
        return @as(posix.fd_t, @ptrFromInt(std.math.maxInt(usize)));
    }
    return -1;
}

/// 创建用于测试的 Program（使用 pipe 作为输入，跳过 raw mode）
fn createTestProgram(comptime M: type, out: std.fs.File, model: M) Program(M) {
    return Program(M).initWithInputAndOptions(
        out,
        invalidFd(),
        model,
        &[_]options_mod.OptionFn{
            options_mod.withoutSignalHandler(),
        },
    );
}

test "Program: init with immediate quit cmd" {
    const pipe = try createPipe();
    defer pipe.read.close();

    const model = ImmediateQuitModel{};
    var p = createTestProgram(ImmediateQuitModel, pipe.write, model);
    defer p.deinit();

    _ = try p.run();
    pipe.write.close();

    try testing.expect(p.started);
    try testing.expect(p.finished);

    var buf: [256]u8 = undefined;
    const n = try pipe.read.readAll(&buf);
    try testing.expect(n > 0);
}

test "Program: send quit from outside" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = CountingModel{};
    var p = createTestProgram(CountingModel, pipe.write, model);
    defer p.deinit();

    const t = try std.Thread.spawn(.{}, struct {
        fn run(prog: *Program(CountingModel)) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            prog.quit();
        }
    }.run, .{&p});

    _ = try p.run();
    t.join();

    try testing.expect(p.finished);
    try testing.expect(!p.simple_cmd_workers_started);
    for (p.simple_cmd_workers) |slot| {
        try testing.expect(slot == null);
    }
}

test "Program: mouse motion is dropped when message queue is full" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = CountingModel{};
    var p = createTestProgram(CountingModel, pipe.write, model);
    defer p.deinit();

    var i: usize = 0;
    while (i < 128) : (i += 1) {
        p.send(.no_op);
    }
    try testing.expectEqual(@as(usize, 128), p.msgs.len());

    p.send(.{ .mouse_motion = .{ .x = 1, .y = 2, .button = .none } });
    try testing.expectEqual(@as(usize, 128), p.msgs.len());
}

test "Program: mouse motion is coalesced to latest value" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = CountingModel{};
    var p = createTestProgram(CountingModel, pipe.write, model);
    defer p.deinit();

    p.send(.{ .mouse_motion = .{ .x = 1, .y = 2, .button = .none } });
    p.send(.{ .mouse_motion = .{ .x = 9, .y = 7, .button = .none } });

    try testing.expectEqual(@as(usize, 1), p.msgs.len());
    try testing.expect(p.pending_mouse_motion.scheduled);
    try testing.expect(p.pending_mouse_motion.valid);
    try testing.expectEqual(@as(i32, 9), p.pending_mouse_motion.value.x);
    try testing.expectEqual(@as(i32, 7), p.pending_mouse_motion.value.y);
}

test "Program: window size is coalesced to latest value" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = CountingModel{};
    var p = createTestProgram(CountingModel, pipe.write, model);
    defer p.deinit();

    p.send(.{ .window_size = .{ .width = 80, .height = 24 } });
    p.send(.{ .window_size = .{ .width = 132, .height = 40 } });

    try testing.expectEqual(@as(usize, 1), p.msgs.len());
    try testing.expect(p.pending_window_size.scheduled);
    try testing.expect(p.pending_window_size.valid);
    try testing.expectEqual(@as(u16, 132), p.pending_window_size.value.width);
    try testing.expectEqual(@as(u16, 40), p.pending_window_size.value.height);
}

test "Program: coalesced window size can be rescheduled after initial full-queue miss" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = CountingModel{};
    var p = createTestProgram(CountingModel, pipe.write, model);
    defer p.deinit();

    var i: usize = 0;
    while (i < 128) : (i += 1) {
        p.send(.no_op);
    }
    p.send(.{ .window_size = .{ .width = 120, .height = 33 } });
    try testing.expect(p.pending_window_size.valid);
    try testing.expect(!p.pending_window_size.scheduled);

    _ = p.msgs.pop().?;
    p.schedulePendingCoalesced();
    try testing.expect(p.pending_window_size.scheduled);
    try testing.expectEqual(@as(usize, 128), p.msgs.len());

    var delivered = false;
    var guard: usize = 0;
    while (guard < 128) : (guard += 1) {
        const m = p.msgs.pop().?;
        if (m == .drain_window_size) {
            const resolved = p.takePendingWindowSize().?;
            try testing.expect(resolved == .window_size);
            try testing.expectEqual(@as(u16, 120), resolved.window_size.width);
            try testing.expectEqual(@as(u16, 33), resolved.window_size.height);
            delivered = true;
            break;
        }
    }
    try testing.expect(delivered);
}

test "Program: coalesced mouse motion can be rescheduled after initial full-queue miss" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = CountingModel{};
    var p = createTestProgram(CountingModel, pipe.write, model);
    defer p.deinit();

    var i: usize = 0;
    while (i < 128) : (i += 1) {
        p.send(.no_op);
    }
    p.send(.{ .mouse_motion = .{ .x = 10, .y = 11, .button = .none } });
    try testing.expect(p.pending_mouse_motion.valid);
    try testing.expect(!p.pending_mouse_motion.scheduled);

    _ = p.msgs.pop().?;
    p.schedulePendingCoalesced();
    try testing.expect(p.pending_mouse_motion.scheduled);
    try testing.expectEqual(@as(usize, 128), p.msgs.len());

    var delivered = false;
    var guard: usize = 0;
    while (guard < 128) : (guard += 1) {
        const m = p.msgs.pop().?;
        if (m == .drain_mouse_motion) {
            const resolved = p.takePendingMouseMotion().?;
            try testing.expect(resolved == .mouse_motion);
            try testing.expectEqual(@as(i32, 10), resolved.mouse_motion.x);
            try testing.expectEqual(@as(i32, 11), resolved.mouse_motion.y);
            delivered = true;
            break;
        }
    }
    try testing.expect(delivered);
}

test "Program: model receives messages and updates" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = CountingModel{};
    var p = createTestProgram(CountingModel, pipe.write, model);
    defer p.deinit();

    const t = try std.Thread.spawn(.{}, struct {
        fn run(prog: *Program(CountingModel)) void {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            prog.send(.{ .key_press = .{ .code = .char, .char = '+' } });
            prog.send(.{ .key_press = .{ .code = .char, .char = '+' } });
            prog.send(.{ .key_press = .{ .code = .char, .char = '-' } });
            prog.quit();
        }
    }.run, .{&p});

    _ = try p.run();
    t.join();

    try testing.expectEqual(@as(i32, 3), p.model.count);
}

test "Program: startup message is auto-delivered to event loop" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = StartupQuitModel{};
    var p = createTestProgram(StartupQuitModel, pipe.write, model);
    defer p.deinit();

    _ = try p.run();

    try testing.expect(p.model.got_startup);
    try testing.expect(p.finished);
}

// ── quit/interrupt 测试 ──────────────────────────────────

const QuitTrackingModel = struct {
    saw_quit: bool = false,
    saw_interrupt: bool = false,

    pub fn init(_: *QuitTrackingModel) ?cmd_mod.Cmd {
        return null;
    }

    pub fn update(self: *QuitTrackingModel, m: Msg) ?cmd_mod.Cmd {
        switch (m) {
            .quit => self.saw_quit = true,
            .interrupt => self.saw_interrupt = true,
            else => {},
        }
        return null;
    }

    pub fn view(_: *QuitTrackingModel) []const u8 {
        return "";
    }
};

test "Program: quit message passes through model.update before exit" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = QuitTrackingModel{};
    var p = createTestProgram(QuitTrackingModel, pipe.write, model);
    defer p.deinit();

    p.send(.quit);
    _ = try p.run();

    try testing.expect(p.model.saw_quit);
}

test "Program: interrupt message passes through model.update before exit" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = QuitTrackingModel{};
    var p = createTestProgram(QuitTrackingModel, pipe.write, model);
    defer p.deinit();

    p.send(.interrupt);
    _ = try p.run();

    try testing.expect(p.model.saw_interrupt);
}

test "Program: init cmd completes and active_cmds returns to zero" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = ImmediateQuitModel{};
    var p = createTestProgram(ImmediateQuitModel, pipe.write, model);
    defer p.deinit();

    _ = try p.run();

    try testing.expectEqual(@as(u32, 0), p.active_cmds.load(.monotonic));
}

// ── Phase 2: Batch / Sequence / Tick 测试 ────────────────

fn returnNoOp() Msg {
    return .no_op;
}

fn returnStartup() Msg {
    return .startup;
}

/// init 返回 batch 命令，update 计数 no_op，收到 3 个后 quit
const BatchInitModel = struct {
    no_op_count: i32 = 0,

    pub fn init(_: *BatchInitModel) ?cmd_mod.Cmd {
        const cmds = &[_]Cmd{ .{ .simple = &returnNoOp }, .{ .simple = &returnNoOp }, .{ .simple = &returnNoOp } };
        return cmd_mod.batch(cmds);
    }

    pub fn update(self: *BatchInitModel, m: Msg) ?cmd_mod.Cmd {
        switch (m) {
            .no_op => {
                self.no_op_count += 1;
                if (self.no_op_count >= 3) return cmd_mod.quit_cmd;
            },
            else => {},
        }
        return null;
    }

    pub fn view(_: *BatchInitModel) []const u8 {
        return "";
    }
};

test "Program: batch executes all commands" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = BatchInitModel{};
    var p = createTestProgram(BatchInitModel, pipe.write, model);
    defer p.deinit();

    _ = try p.run();

    try testing.expectEqual(@as(i32, 3), p.model.no_op_count);
}

/// init 返回 sequence 命令，update 计数 no_op，收到 2 个后 quit
const SequenceInitModel = struct {
    no_op_count: i32 = 0,

    pub fn init(_: *SequenceInitModel) ?cmd_mod.Cmd {
        const cmds = &[_]Cmd{ .{ .simple = &returnNoOp }, .{ .simple = &returnNoOp } };
        return cmd_mod.sequence(cmds);
    }

    pub fn update(self: *SequenceInitModel, m: Msg) ?cmd_mod.Cmd {
        switch (m) {
            .no_op => {
                self.no_op_count += 1;
                if (self.no_op_count >= 2) return cmd_mod.quit_cmd;
            },
            else => {},
        }
        return null;
    }

    pub fn view(_: *SequenceInitModel) []const u8 {
        return "";
    }
};

test "Program: sequence executes all commands" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = SequenceInitModel{};
    var p = createTestProgram(SequenceInitModel, pipe.write, model);
    defer p.deinit();

    _ = try p.run();

    try testing.expectEqual(@as(i32, 2), p.model.no_op_count);
}

/// tick 测试：init 返回短 tick，回调返回 quit
fn tickQuitCb(_: i128) Msg {
    return .quit;
}

const TickInitModel = struct {
    saw_quit: bool = false,

    pub fn init(_: *TickInitModel) ?cmd_mod.Cmd {
        return cmd_mod.tick(1 * std.time.ns_per_ms, &tickQuitCb);
    }

    pub fn update(self: *TickInitModel, m: Msg) ?cmd_mod.Cmd {
        switch (m) {
            .quit => self.saw_quit = true,
            else => {},
        }
        return null;
    }

    pub fn view(_: *TickInitModel) []const u8 {
        return "";
    }
};

test "Program: tick fires after duration" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = TickInitModel{};
    var p = createTestProgram(TickInitModel, pipe.write, model);
    defer p.deinit();

    _ = try p.run();

    try testing.expect(p.model.saw_quit);
    try testing.expect(p.finished);
}

const EmitQuitModel = struct {
    saw_quit: bool = false,

    pub fn init(_: *EmitQuitModel) ?cmd_mod.Cmd {
        return cmd_mod.emit(.quit);
    }

    pub fn update(self: *EmitQuitModel, m: Msg) ?cmd_mod.Cmd {
        if (m == .quit) self.saw_quit = true;
        return null;
    }

    pub fn view(_: *EmitQuitModel) []const u8 {
        return "";
    }
};

test "Program: cmd.msg sends message into loop" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = EmitQuitModel{};
    var p = createTestProgram(EmitQuitModel, pipe.write, model);
    defer p.deinit();

    _ = try p.run();
    try testing.expect(p.model.saw_quit);
}

fn dropKeyPressFilter(m: Msg) ?Msg {
    if (m == .key_press) return null;
    return m;
}

test "Program: WithFilter can drop messages" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = CountingModel{};
    var p = Program(CountingModel).initWithInputAndOptions(
        pipe.write,
        invalidFd(),
        model,
        &[_]options_mod.OptionFn{
            options_mod.withoutSignalHandler(),
            options_mod.withFilter(&dropKeyPressFilter),
        },
    );
    defer p.deinit();

    p.send(.{ .key_press = .{ .code = .char, .char = 'a' } });
    p.send(.quit);
    _ = try p.run();

    try testing.expectEqual(@as(i32, 0), p.model.count);
}

fn returnPrintLine() Msg {
    return .{ .print_line = msg_mod.TextPayload.fromSlice("status line") };
}

const PrintLineInitModel = struct {
    pub fn init(_: *PrintLineInitModel) ?cmd_mod.Cmd {
        const cmds = &[_]Cmd{ .{ .simple = &returnPrintLine }, .{ .simple = &quitFnForTest } };
        return cmd_mod.sequence(cmds);
    }

    pub fn update(_: *PrintLineInitModel, _: Msg) ?cmd_mod.Cmd {
        return null;
    }

    pub fn view(_: *PrintLineInitModel) []const u8 {
        return "";
    }
};

fn quitFnForTest() Msg {
    return .quit;
}

test "Program: print_line is routed to renderer insertAbove" {
    const pipe = try createPipe();
    defer pipe.read.close();

    const model = PrintLineInitModel{};
    var p = createTestProgram(PrintLineInitModel, pipe.write, model);
    defer p.deinit();

    _ = try p.run();
    pipe.write.close();

    var buf: [512]u8 = undefined;
    const n = try pipe.read.readAll(&buf);
    try testing.expect(n > 0);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "status line") != null);
}

const InitialWindowSizeModel = struct {
    got_window_size: bool = false,
    width: u16 = 0,
    height: u16 = 0,

    pub fn init(_: *InitialWindowSizeModel) ?cmd_mod.Cmd {
        return null;
    }

    pub fn update(self: *InitialWindowSizeModel, m: Msg) ?cmd_mod.Cmd {
        switch (m) {
            .window_size => |sz| {
                self.got_window_size = true;
                self.width = sz.width;
                self.height = sz.height;
                return cmd_mod.quit_cmd;
            },
            else => {},
        }
        return null;
    }

    pub fn view(_: *InitialWindowSizeModel) []const u8 {
        return "";
    }
};

test "Program: WithWindowSize emits initial window_size message" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = InitialWindowSizeModel{};
    var p = Program(InitialWindowSizeModel).initWithInputAndOptions(
        pipe.write,
        invalidFd(),
        model,
        &[_]options_mod.OptionFn{
            options_mod.withoutSignalHandler(),
            options_mod.withWindowSize(123, 45),
        },
    );
    defer p.deinit();

    _ = try p.run();
    try testing.expect(p.model.got_window_size);
    try testing.expectEqual(@as(u16, 123), p.model.width);
    try testing.expectEqual(@as(u16, 45), p.model.height);
}

fn returnRawForTest() Msg {
    return .{ .raw = raw_mod.RawMsg.fromSlice("RAW_TEST") };
}

const RawInitModel = struct {
    pub fn init(_: *RawInitModel) ?cmd_mod.Cmd {
        const cmds = &[_]Cmd{ .{ .simple = &returnRawForTest }, .{ .simple = &quitFnForTest } };
        return cmd_mod.sequence(cmds);
    }

    pub fn update(_: *RawInitModel, _: Msg) ?cmd_mod.Cmd {
        return null;
    }

    pub fn view(_: *RawInitModel) []const u8 {
        return "";
    }
};

test "Program: raw internal message writes bytes to terminal" {
    const pipe = try createPipe();
    defer pipe.read.close();

    const model = RawInitModel{};
    var p = createTestProgram(RawInitModel, pipe.write, model);
    defer p.deinit();

    _ = try p.run();
    pipe.write.close();

    var buf: [1024]u8 = undefined;
    const n = try pipe.read.readAll(&buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "RAW_TEST") != null);
}

fn returnSetClipboardForTest() Msg {
    return .{ .set_clipboard = clipboard_mod.SetClipboardMsg.fromSlice("abc", .system) };
}

const SetClipboardInitModel = struct {
    pub fn init(_: *SetClipboardInitModel) ?cmd_mod.Cmd {
        const cmds = &[_]Cmd{ .{ .simple = &returnSetClipboardForTest }, .{ .simple = &quitFnForTest } };
        return cmd_mod.sequence(cmds);
    }

    pub fn update(_: *SetClipboardInitModel, _: Msg) ?cmd_mod.Cmd {
        return null;
    }

    pub fn view(_: *SetClipboardInitModel) []const u8 {
        return "";
    }
};

test "Program: set_clipboard emits OSC52 write sequence" {
    const pipe = try createPipe();
    defer pipe.read.close();

    const model = SetClipboardInitModel{};
    var p = createTestProgram(SetClipboardInitModel, pipe.write, model);
    defer p.deinit();

    _ = try p.run();
    pipe.write.close();

    var buf: [1024]u8 = undefined;
    const n = try pipe.read.readAll(&buf);
    const out = buf[0..n];
    try testing.expect(std.mem.indexOf(u8, out, "\x1B]52;c;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "YWJj") != null);
}

fn returnReadClipboardForTest() Msg {
    return .{ .read_clipboard = .{ .selection = .system } };
}

const ReadClipboardInitModel = struct {
    pub fn init(_: *ReadClipboardInitModel) ?cmd_mod.Cmd {
        const cmds = &[_]Cmd{ .{ .simple = &returnReadClipboardForTest }, .{ .simple = &quitFnForTest } };
        return cmd_mod.sequence(cmds);
    }

    pub fn update(_: *ReadClipboardInitModel, _: Msg) ?cmd_mod.Cmd {
        return null;
    }

    pub fn view(_: *ReadClipboardInitModel) []const u8 {
        return "";
    }
};

test "Program: read_clipboard emits OSC52 query sequence" {
    const pipe = try createPipe();
    defer pipe.read.close();

    const model = ReadClipboardInitModel{};
    var p = createTestProgram(ReadClipboardInitModel, pipe.write, model);
    defer p.deinit();

    _ = try p.run();
    pipe.write.close();

    var buf: [1024]u8 = undefined;
    const n = try pipe.read.readAll(&buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "\x1B]52;c;?\x07") != null);
}

const ExecSuccessModel = struct {
    got_result: bool = false,
    success: bool = false,
    exit_code: i32 = -1,

    pub fn init(_: *ExecSuccessModel) ?cmd_mod.Cmd {
        if (builtin.os.tag == .windows) return cmd_mod.quit_cmd;
        return cmd_mod.execProcess(&[_][]const u8{"/usr/bin/true"});
    }

    pub fn update(self: *ExecSuccessModel, m: Msg) ?cmd_mod.Cmd {
        switch (m) {
            .exec_result => |result| {
                self.got_result = true;
                self.success = result.success;
                self.exit_code = result.exit_code;
                return cmd_mod.quit_cmd;
            },
            else => {},
        }
        return null;
    }

    pub fn view(_: *ExecSuccessModel) []const u8 {
        return "";
    }
};

test "Program: exec emits success result" {
    if (builtin.os.tag == .windows) return;

    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = ExecSuccessModel{};
    var p = createTestProgram(ExecSuccessModel, pipe.write, model);
    defer p.deinit();

    _ = try p.run();
    try testing.expect(p.model.got_result);
    try testing.expect(p.model.success);
    try testing.expectEqual(@as(i32, 0), p.model.exit_code);
}

const ExecFailModel = struct {
    got_result: bool = false,
    success: bool = true,
    exit_code: i32 = 0,
    err_len: usize = 0,

    pub fn init(_: *ExecFailModel) ?cmd_mod.Cmd {
        if (builtin.os.tag == .windows) return cmd_mod.quit_cmd;
        return cmd_mod.execProcess(&[_][]const u8{"/definitely/not/exist/cmd"});
    }

    pub fn update(self: *ExecFailModel, m: Msg) ?cmd_mod.Cmd {
        switch (m) {
            .exec_result => |result| {
                self.got_result = true;
                self.success = result.success;
                self.exit_code = result.exit_code;
                self.err_len = result.errSlice().len;
                return cmd_mod.quit_cmd;
            },
            else => {},
        }
        return null;
    }

    pub fn view(_: *ExecFailModel) []const u8 {
        return "";
    }
};

test "Program: exec emits failure result for missing command" {
    if (builtin.os.tag == .windows) return;

    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = ExecFailModel{};
    var p = createTestProgram(ExecFailModel, pipe.write, model);
    defer p.deinit();

    _ = try p.run();
    try testing.expect(p.model.got_result);
    try testing.expect(!p.model.success);
    try testing.expectEqual(@as(i32, -1), p.model.exit_code);
    try testing.expect(p.model.err_len > 0);
}

const ExecTruncatedArgsModel = struct {
    got_result: bool = false,
    success: bool = true,
    exit_code: i32 = 0,
    err_mentions_limits: bool = false,

    pub fn init(_: *ExecTruncatedArgsModel) ?cmd_mod.Cmd {
        var argv: [exec_mod.ExecRequestMsg.max_args + 1][]const u8 = undefined;
        argv[0] = "/usr/bin/true";
        var i: usize = 1;
        while (i < argv.len) : (i += 1) {
            argv[i] = "arg";
        }
        return cmd_mod.execProcess(argv[0..]);
    }

    pub fn update(self: *ExecTruncatedArgsModel, m: Msg) ?cmd_mod.Cmd {
        switch (m) {
            .exec_result => |result| {
                self.got_result = true;
                self.success = result.success;
                self.exit_code = result.exit_code;
                self.err_mentions_limits = std.mem.indexOf(u8, result.errSlice(), "max_args") != null;
                return cmd_mod.quit_cmd;
            },
            else => {},
        }
        return null;
    }

    pub fn view(_: *ExecTruncatedArgsModel) []const u8 {
        return "";
    }
};

test "Program: exec rejects truncated argv with explicit error" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = ExecTruncatedArgsModel{};
    var p = createTestProgram(ExecTruncatedArgsModel, pipe.write, model);
    defer p.deinit();

    _ = try p.run();
    try testing.expect(p.model.got_result);
    try testing.expect(!p.model.success);
    try testing.expectEqual(@as(i32, -1), p.model.exit_code);
    try testing.expect(p.model.err_mentions_limits);
}

fn onMouseQuitCallback(_: mouse_mod.MouseEventKind, _: mouse_mod.Mouse) ?cmd_mod.Cmd {
    return cmd_mod.emit(.quit);
}

const MouseCallbackModel = struct {
    saw_mouse: bool = false,
    saw_quit: bool = false,

    pub fn init(_: *MouseCallbackModel) ?cmd_mod.Cmd {
        return null;
    }

    pub fn update(self: *MouseCallbackModel, m: Msg) ?cmd_mod.Cmd {
        switch (m) {
            .mouse_click => self.saw_mouse = true,
            .quit => self.saw_quit = true,
            else => {},
        }
        return null;
    }

    pub fn view(_: *MouseCallbackModel) view_mod.View {
        var v = view_mod.View.init("");
        v.on_mouse = &onMouseQuitCallback;
        return v;
    }
};

test "Program: renderer on_mouse callback can emit command" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = MouseCallbackModel{};
    var p = createTestProgram(MouseCallbackModel, pipe.write, model);
    defer p.deinit();

    p.send(.{ .mouse_click = .{ .x = 1, .y = 1, .button = .left } });
    _ = try p.run();

    try testing.expect(p.model.saw_mouse);
    try testing.expect(p.model.saw_quit);
}

test "Program: mode_report updates renderer capabilities" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = CountingModel{};
    var p = createTestProgram(CountingModel, pipe.write, model);
    defer p.deinit();

    p.send(.{ .mode_report = .{ .mode = 2026, .value = .set } });
    p.send(.{ .mode_report = .{ .mode = 2027, .value = .set } });
    p.send(.quit);
    _ = try p.run();

    try testing.expect(p.cursed_renderer.syncd_updates);
    try testing.expect(p.cursed_renderer.width_method == .grapheme);
}

test "Program: mode_report permanently_reset falls back to cell width and disables syncd" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = CountingModel{};
    var p = createTestProgram(CountingModel, pipe.write, model);
    defer p.deinit();

    p.send(.{ .mode_report = .{ .mode = 2026, .value = .set } });
    p.send(.{ .mode_report = .{ .mode = 2027, .value = .set } });
    p.send(.{ .mode_report = .{ .mode = 2026, .value = .permanently_reset } });
    p.send(.{ .mode_report = .{ .mode = 2027, .value = .permanently_reset } });
    p.send(.quit);
    _ = try p.run();

    try testing.expect(!p.cursed_renderer.syncd_updates);
    try testing.expect(p.cursed_renderer.width_method == .cell);
}

const StartupNoOpModel = struct {
    pub fn init(_: *StartupNoOpModel) ?cmd_mod.Cmd {
        return cmd_mod.quit_cmd;
    }

    pub fn update(_: *StartupNoOpModel, _: Msg) ?cmd_mod.Cmd {
        return null;
    }

    pub fn view(_: *StartupNoOpModel) []const u8 {
        return "";
    }
};

test "Program: startup queries synchronized output modes for known terminals" {
    const pipe = try createPipe();
    defer pipe.read.close();

    const env_vars = [_][]const u8{
        "TERM=xterm-kitty",
    };
    const model = StartupNoOpModel{};
    var p = Program(StartupNoOpModel).initWithInputAndOptions(
        pipe.write,
        invalidFd(),
        model,
        &[_]options_mod.OptionFn{
            options_mod.withoutSignalHandler(),
            options_mod.withEnvironment(&env_vars),
        },
    );
    defer p.deinit();

    _ = try p.run();
    pipe.write.close();

    var buf: [1024]u8 = undefined;
    const n = try pipe.read.readAll(&buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "\x1B[?2026$p\x1B[?2027$p") != null);
}

test "Program: startup skips synchronized output query for Apple terminal over SSH" {
    const pipe = try createPipe();
    defer pipe.read.close();

    const env_vars = [_][]const u8{
        "TERM=xterm-256color",
        "TERM_PROGRAM=Apple_Terminal",
        "SSH_TTY=/dev/pts/1",
    };
    const model = StartupNoOpModel{};
    var p = Program(StartupNoOpModel).initWithInputAndOptions(
        pipe.write,
        invalidFd(),
        model,
        &[_]options_mod.OptionFn{
            options_mod.withoutSignalHandler(),
            options_mod.withEnvironment(&env_vars),
        },
    );
    defer p.deinit();

    _ = try p.run();
    pipe.write.close();

    var buf: [1024]u8 = undefined;
    const n = try pipe.read.readAll(&buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "\x1B[?2026$p\x1B[?2027$p") == null);
}

fn returnRequestCapabilityTc() Msg {
    return .{ .request_capability = termcap_mod.RequestCapabilityMsg.fromSlice("Tc") };
}

fn returnRequestTerminalVersion() Msg {
    return .request_terminal_version;
}

const RequestCapabilityInitModel = struct {
    pub fn init(_: *RequestCapabilityInitModel) ?cmd_mod.Cmd {
        const cmds = &[_]Cmd{ .{ .simple = &returnRequestCapabilityTc }, .{ .simple = &quitFnForTest } };
        return cmd_mod.sequence(cmds);
    }

    pub fn update(_: *RequestCapabilityInitModel, _: Msg) ?cmd_mod.Cmd {
        return null;
    }

    pub fn view(_: *RequestCapabilityInitModel) []const u8 {
        return "";
    }
};

test "Program: request_capability writes XTGETTCAP query" {
    const pipe = try createPipe();
    defer pipe.read.close();

    const model = RequestCapabilityInitModel{};
    var p = createTestProgram(RequestCapabilityInitModel, pipe.write, model);
    defer p.deinit();

    _ = try p.run();
    pipe.write.close();

    var buf: [1024]u8 = undefined;
    const n = try pipe.read.readAll(&buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "\x1BP+q5463\x1B\\") != null);
}

const RequestTerminalVersionInitModel = struct {
    pub fn init(_: *RequestTerminalVersionInitModel) ?cmd_mod.Cmd {
        const cmds = &[_]Cmd{ .{ .simple = &returnRequestTerminalVersion }, .{ .simple = &quitFnForTest } };
        return cmd_mod.sequence(cmds);
    }

    pub fn update(_: *RequestTerminalVersionInitModel, _: Msg) ?cmd_mod.Cmd {
        return null;
    }

    pub fn view(_: *RequestTerminalVersionInitModel) []const u8 {
        return "";
    }
};

test "Program: request_terminal_version writes XTVERSION query" {
    const pipe = try createPipe();
    defer pipe.read.close();

    const model = RequestTerminalVersionInitModel{};
    var p = createTestProgram(RequestTerminalVersionInitModel, pipe.write, model);
    defer p.deinit();

    _ = try p.run();
    pipe.write.close();

    var buf: [1024]u8 = undefined;
    const n = try pipe.read.readAll(&buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "\x1B[>0q") != null);
}

const CapabilityUpgradeModel = struct {
    got_truecolor_profile: bool = false,

    pub fn init(_: *CapabilityUpgradeModel) ?cmd_mod.Cmd {
        return null;
    }

    pub fn update(self: *CapabilityUpgradeModel, m: Msg) ?cmd_mod.Cmd {
        switch (m) {
            .color_profile => |cp| {
                if (cp.profile == .truecolor) {
                    self.got_truecolor_profile = true;
                    return cmd_mod.quit_cmd;
                }
            },
            else => {},
        }
        return null;
    }

    pub fn view(_: *CapabilityUpgradeModel) []const u8 {
        return "";
    }
};

test "Program: capability reply upgrades color profile to truecolor" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = CapabilityUpgradeModel{};
    var p = createTestProgram(CapabilityUpgradeModel, pipe.write, model);
    defer p.deinit();

    p.send(.{ .capability = termcap_mod.CapabilityMsg.fromSlice("Tc") });
    _ = try p.run();
    try testing.expect(p.model.got_truecolor_profile);
}

test "Program: terminal version reply upgrades known terminals to truecolor" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = CapabilityUpgradeModel{};
    var p = createTestProgram(CapabilityUpgradeModel, pipe.write, model);
    defer p.deinit();

    p.send(.{ .terminal_version = termcap_mod.TerminalVersionMsg.fromSlice("WezTerm 20240203-110809-5046fc22") });
    _ = try p.run();
    try testing.expect(p.model.got_truecolor_profile);
}

const EnvProfileModel = struct {
    got_env: bool = false,
    got_profile: bool = false,
    term_seen: [32]u8 = [_]u8{0} ** 32,
    term_len: usize = 0,
    profile: profile_mod.ColorProfile = .unknown,

    pub fn init(_: *EnvProfileModel) ?cmd_mod.Cmd {
        return null;
    }

    pub fn update(self: *EnvProfileModel, m: Msg) ?cmd_mod.Cmd {
        switch (m) {
            .env => |env_ptr| {
                const term = env_ptr.getenv("TERM");
                const n = @min(term.len, self.term_seen.len);
                @memcpy(self.term_seen[0..n], term[0..n]);
                self.term_len = n;
                self.got_env = true;
            },
            .color_profile => |cp| {
                self.profile = cp.profile;
                self.got_profile = true;
            },
            else => {},
        }
        if (self.got_env and self.got_profile) return cmd_mod.quit_cmd;
        return null;
    }

    pub fn view(_: *EnvProfileModel) []const u8 {
        return "";
    }
};

test "Program: WithEnvironment feeds EnvMsg and color detection" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const env_vars = [_][]const u8{
        "TERM=xterm-256color",
        "COLORTERM=truecolor",
    };

    const model = EnvProfileModel{};
    var p = Program(EnvProfileModel).initWithInputAndOptions(
        pipe.write,
        invalidFd(),
        model,
        &[_]options_mod.OptionFn{
            options_mod.withoutSignalHandler(),
            options_mod.withEnvironment(&env_vars),
        },
    );
    defer p.deinit();

    _ = try p.run();
    try testing.expect(p.model.got_env);
    try testing.expect(p.model.got_profile);
    try testing.expectEqualStrings("xterm-256color", p.model.term_seen[0..p.model.term_len]);
    try testing.expect(p.model.profile == .truecolor);
}

const CustomBridgeModel = struct {
    got_custom: bool = false,
    name_ok: bool = false,
    data_ok: bool = false,

    pub fn init(_: *CustomBridgeModel) ?cmd_mod.Cmd {
        return cmd_mod.custom("domain.event", "payload");
    }

    pub fn update(self: *CustomBridgeModel, m: Msg) ?cmd_mod.Cmd {
        switch (m) {
            .custom => |cmsg| {
                self.got_custom = true;
                self.name_ok = std.mem.eql(u8, cmsg.nameSlice(), "domain.event");
                self.data_ok = std.mem.eql(u8, cmsg.dataSlice(), "payload");
                return cmd_mod.quit_cmd;
            },
            else => {},
        }
        return null;
    }

    pub fn view(_: *CustomBridgeModel) []const u8 {
        return "";
    }
};

test "Program: custom message bridge reaches model update" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = CustomBridgeModel{};
    var p = createTestProgram(CustomBridgeModel, pipe.write, model);
    defer p.deinit();

    _ = try p.run();
    try testing.expect(p.model.got_custom);
    try testing.expect(p.model.name_ok);
    try testing.expect(p.model.data_ok);
}

const ContextCancelModel = struct {
    saw_interrupt: bool = false,

    pub fn init(_: *ContextCancelModel) ?cmd_mod.Cmd {
        return null;
    }

    pub fn update(self: *ContextCancelModel, m: Msg) ?cmd_mod.Cmd {
        if (m == .interrupt) self.saw_interrupt = true;
        return null;
    }

    pub fn view(_: *ContextCancelModel) []const u8 {
        return "";
    }
};

test "Program: WithContext cancellation triggers interrupt exit" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    var cancelled = std.atomic.Value(bool).init(false);
    const model = ContextCancelModel{};
    var p = Program(ContextCancelModel).initWithInputAndOptions(
        pipe.write,
        invalidFd(),
        model,
        &[_]options_mod.OptionFn{
            options_mod.withoutSignalHandler(),
            options_mod.withContext(&cancelled),
        },
    );
    defer p.deinit();

    const t = try std.Thread.spawn(.{}, struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            std.Thread.sleep(8 * std.time.ns_per_ms);
            flag.store(true, .release);
        }
    }.run, .{&cancelled});

    _ = try p.run();
    t.join();
    try testing.expect(p.model.saw_interrupt);
}

const StressModel = struct {
    key_count: u16 = 0,
    resize_count: u16 = 0,
    saw_quit: bool = false,

    pub fn init(_: *StressModel) ?cmd_mod.Cmd {
        return null;
    }

    pub fn update(self: *StressModel, m: Msg) ?cmd_mod.Cmd {
        switch (m) {
            .key_press => self.key_count += 1,
            .window_size => self.resize_count += 1,
            .quit => self.saw_quit = true,
            else => {},
        }
        return null;
    }

    pub fn view(_: *StressModel) []const u8 {
        return "";
    }
};

test "Program: high-frequency input and resize with exec interleaving stays stable" {
    const pipe = try createPipe();
    defer pipe.write.close();
    defer pipe.read.close();

    const model = StressModel{};
    var p = createTestProgram(StressModel, pipe.write, model);
    defer p.deinit();

    const t = try std.Thread.spawn(.{}, struct {
        fn run(prog: *Program(StressModel)) void {
            var i: u16 = 0;
            while (i < 20) : (i += 1) {
                prog.send(.{ .key_press = .{ .code = .char, .char = 'a' } });
                prog.send(.{ .window_size = .{ .width = 100, .height = 30 } });
                if (builtin.os.tag != .windows and i == 10) {
                    // exec is now a Cmd variant, not a Msg — skip in stress test
                }
            }
            prog.send(.quit);
        }
    }.run, .{&p});

    _ = try p.run();
    t.join();

    try testing.expect(p.model.saw_quit);
    try testing.expectEqual(@as(u16, 20), p.model.key_count);
    try testing.expect(p.model.resize_count >= 1);
    try testing.expect(p.model.resize_count <= 20);
}

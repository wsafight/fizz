/// Command type definitions (Phase 5).
const std = @import("std");
const msg = @import("msg.zig");
const clipboard = @import("clipboard.zig");
const termcap = @import("termcap.zig");
const raw_mod = @import("raw.zig");
const exec_mod = @import("exec.zig");

/// Simple command: no-arg function pointer returning a Msg.
pub const SimpleCmd = *const fn () msg.Msg;

/// Timer command parameters.
pub const TickCmd = struct {
    duration_ns: u64,
    callback: *const fn (timestamp_ns: i128) msg.Msg,
};

/// Command type tagged union.
pub const Cmd = union(enum) {
    /// Single async command (compatible with Phase 1-3)
    simple: SimpleCmd,
    /// Send message immediately (for commands with dynamic parameters)
    msg: msg.Msg,
    /// Execute multiple commands concurrently (Go Batch equivalent)
    batch: []const Cmd,
    /// Execute multiple commands serially (Go Sequence equivalent)
    sequence: []const Cmd,
    /// Timer, not aligned to system clock (Go Tick equivalent)
    tick: TickCmd,
    /// Timer, aligned to system clock (Go Every equivalent)
    every: TickCmd,
    /// External process execution (large struct, bypasses Msg queue)
    exec: exec_mod.ExecRequestMsg,
    /// Throttle: delay then send message, dropping intermediate calls with same tag
    throttle: ThrottleCmd,
    /// Debounce: reset timer on each call, fire only after interval of silence
    debounce: ThrottleCmd,

    pub fn isQuit(self: Cmd) bool {
        return switch (self) {
            .simple => |f| f == &quitFn,
            .msg => |m| m == .quit,
            else => false,
        };
    }
};

/// Throttle/debounce command parameters.
pub const ThrottleCmd = struct {
    tag: u32,
    interval_ns: u64,
    message: msg.Msg,
};

fn noOpFn() msg.Msg {
    return .no_op;
}

fn quitFn() msg.Msg {
    return .quit;
}

pub const quit_cmd = Cmd{ .simple = &quitFn };
pub const no_op_cmd = Cmd{ .simple = &noOpFn };

fn normalizeDurationNs(duration_ns: u64) u64 {
    return if (duration_ns == 0) 1 else duration_ns;
}

pub fn emit(m: msg.Msg) Cmd {
    return .{ .msg = m };
}

pub fn custom(name: []const u8, data: []const u8) Cmd {
    return emit(.{ .custom = msg.CustomMsg.fromSlices(name, data) });
}

pub fn batch(cmds: []const Cmd) ?Cmd {
    return switch (cmds.len) {
        0 => null,
        1 => cmds[0],
        else => Cmd{ .batch = cmds },
    };
}

pub fn sequence(cmds: []const Cmd) ?Cmd {
    return switch (cmds.len) {
        0 => null,
        1 => cmds[0],
        else => Cmd{ .sequence = cmds },
    };
}

pub fn tick(duration_ns: u64, callback: *const fn (timestamp_ns: i128) msg.Msg) Cmd {
    return Cmd{ .tick = .{ .duration_ns = normalizeDurationNs(duration_ns), .callback = callback } };
}

pub fn every(duration_ns: u64, callback: *const fn (timestamp_ns: i128) msg.Msg) Cmd {
    return Cmd{ .every = .{ .duration_ns = normalizeDurationNs(duration_ns), .callback = callback } };
}

pub fn throttle(tag: u32, interval_ns: u64, message: msg.Msg) Cmd {
    return .{ .throttle = .{ .tag = tag, .interval_ns = normalizeDurationNs(interval_ns), .message = message } };
}

pub fn debounce(tag: u32, interval_ns: u64, message: msg.Msg) Cmd {
    return .{ .debounce = .{ .tag = tag, .interval_ns = normalizeDurationNs(interval_ns), .message = message } };
}

// ── Phase 4/5 request commands ───────────────────────────────────

pub fn clearScreen() Cmd {
    return emit(.clear_screen);
}

pub fn requestWindowSize() Cmd {
    return emit(.request_window_size);
}

pub fn requestBackgroundColor() Cmd {
    return emit(.request_background_color);
}

pub fn requestForegroundColor() Cmd {
    return emit(.request_foreground_color);
}

pub fn requestCursorColor() Cmd {
    return emit(.request_cursor_color);
}

pub fn requestCursorPosition() Cmd {
    return emit(.request_cursor_position);
}

pub fn requestCapability(name: []const u8) Cmd {
    return emit(.{ .request_capability = termcap.RequestCapabilityMsg.fromSlice(name) });
}

pub fn requestTerminalVersion() Cmd {
    return emit(.request_terminal_version);
}

pub fn setClipboard(content: []const u8) Cmd {
    return emit(.{ .set_clipboard = clipboard.SetClipboardMsg.fromSlice(content, .system) });
}

pub fn setPrimaryClipboard(content: []const u8) Cmd {
    return emit(.{ .set_clipboard = clipboard.SetClipboardMsg.fromSlice(content, .primary) });
}

pub fn readClipboard() Cmd {
    return emit(.{ .read_clipboard = .{ .selection = .system } });
}

pub fn readPrimaryClipboard() Cmd {
    return emit(.{ .read_clipboard = .{ .selection = .primary } });
}

pub fn raw(data: []const u8) Cmd {
    return emit(.{ .raw = raw_mod.RawMsg.fromSlice(data) });
}

pub fn printLine(text: []const u8) Cmd {
    return emit(.{ .print_line = msg.TextPayload.fromSlice(text) });
}

pub fn execProcess(argv: []const []const u8) Cmd {
    return .{ .exec = exec_mod.ExecRequestMsg.fromArgv(argv) };
}

pub fn execProcessWithCallback(argv: []const []const u8, cb: exec_mod.ExecCallback) Cmd {
    return .{ .exec = exec_mod.ExecRequestMsg.fromArgv(argv).withCallback(cb) };
}

const testing = std.testing;

test "Cmd: quit_cmd isQuit" {
    try testing.expect(quit_cmd.isQuit());
    try testing.expect(emit(.quit).isQuit());
}

test "Cmd: batch single degrades" {
    const result = batch(&[_]Cmd{quit_cmd});
    try testing.expect(result != null);
    try testing.expect(result.?.isQuit());
}

test "Cmd: request capability" {
    const c = requestCapability("Tc");
    try testing.expect(c == .msg);
    try testing.expect(c.msg == .request_capability);
    try testing.expectEqualStrings("Tc", c.msg.request_capability.slice());
}

test "Cmd: set clipboard carries payload" {
    const c = setClipboard("abc");
    try testing.expect(c == .msg);
    try testing.expect(c.msg == .set_clipboard);
    try testing.expectEqualStrings("abc", c.msg.set_clipboard.slice());
}

fn dummyTickCb(_: i128) msg.Msg {
    return .no_op;
}

test "Cmd: tick construction" {
    const c = tick(1_000_000, &dummyTickCb);
    try testing.expect(c == .tick);
    try testing.expectEqual(@as(u64, 1_000_000), c.tick.duration_ns);
}

test "Cmd: tick/every clamp zero duration to 1ns" {
    const t = tick(0, &dummyTickCb);
    const e = every(0, &dummyTickCb);
    try testing.expect(t == .tick);
    try testing.expect(e == .every);
    try testing.expectEqual(@as(u64, 1), t.tick.duration_ns);
    try testing.expectEqual(@as(u64, 1), e.every.duration_ns);
}

test "Cmd: printLine carries payload" {
    const c = printLine("hello");
    try testing.expect(c == .msg);
    try testing.expect(c.msg == .print_line);
    try testing.expectEqualStrings("hello", c.msg.print_line.slice());
}

test "Cmd: raw carries escape bytes" {
    const c = raw("\x1B[6n");
    try testing.expect(c == .msg);
    try testing.expect(c.msg == .raw);
    try testing.expectEqualStrings("\x1B[6n", c.msg.raw.slice());
}

test "Cmd: read clipboard helpers use expected selection" {
    const a = readClipboard();
    const b = readPrimaryClipboard();
    try testing.expect(a == .msg);
    try testing.expect(b == .msg);
    try testing.expect(a.msg == .read_clipboard);
    try testing.expect(b.msg == .read_clipboard);
    try testing.expect(a.msg.read_clipboard.selection == .system);
    try testing.expect(b.msg.read_clipboard.selection == .primary);
}

test "Cmd: custom helper builds custom msg" {
    const c = custom("domain.event", "xyz");
    try testing.expect(c == .msg);
    try testing.expect(c.msg == .custom);
    try testing.expectEqualStrings("domain.event", c.msg.custom.nameSlice());
    try testing.expectEqualStrings("xyz", c.msg.custom.dataSlice());
}

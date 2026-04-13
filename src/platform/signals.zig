/// Signal handling (Phase 3)
///
/// SIGWINCH listener + terminal size query.
///
/// NOTE: This module uses process-global signal state. Duplicate setup calls are
/// rejected/ignored to avoid cross-instance teardown conflicts.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// Get terminal window size.
pub fn getTerminalSize(fd: posix.fd_t) !struct { width: u16, height: u16 } {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const stdout_h = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE) catch return error.UnsupportedPlatform;
        var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (windows.kernel32.GetConsoleScreenBufferInfo(stdout_h, &info) == 0) return error.IoctlFailed;
        const w = @as(u16, @intCast(info.srWindow.Right - info.srWindow.Left + 1));
        const h = @as(u16, @intCast(info.srWindow.Bottom - info.srWindow.Top + 1));
        return .{ .width = w, .height = h };
    }

    var wsz: posix.winsize = undefined;
    const rc = posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&wsz));
    if (rc != 0) return error.IoctlFailed;
    return .{ .width = wsz.col, .height = wsz.row };
}

/// Self-pipe for notifying user thread of SIGWINCH signals.
var sigwinch_pipe: [2]posix.fd_t = .{ -1, -1 };
var sigwinch_installed: bool = false;
var signal_state_mutex: std.Thread.Mutex = .{};

fn sigwinchHandler(_: c_int) callconv(.c) void {
    // Only write in signal handler (async-signal-safe)
    _ = posix.write(sigwinch_pipe[1], "W") catch {};
}

/// Register SIGWINCH handler, return pollable read-end fd.
pub fn setupSigwinch() !posix.fd_t {
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;

    signal_state_mutex.lock();
    defer signal_state_mutex.unlock();
    if (sigwinch_installed) return error.SignalHandlerAlreadyActive;

    sigwinch_pipe = try posix.pipe2(.{
        .NONBLOCK = true,
        .CLOEXEC = true,
    });

    var sa: posix.Sigaction = .{
        .handler = .{ .handler = &sigwinchHandler },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.WINCH, &sa, null);
    sigwinch_installed = true;

    return sigwinch_pipe[0];
}

/// Clean up SIGWINCH pipe.
pub fn cleanupSigwinch() void {
    if (builtin.os.tag == .windows) return;

    signal_state_mutex.lock();
    defer signal_state_mutex.unlock();
    if (!sigwinch_installed) return;

    // Restore default handler
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.WINCH, &sa, null);

    if (sigwinch_pipe[0] != -1) {
        posix.close(sigwinch_pipe[0]);
        posix.close(sigwinch_pipe[1]);
        sigwinch_pipe = .{ -1, -1 };
    }
    sigwinch_installed = false;
}

// ── Crash recovery ──────────────────────────────────────

var crash_restore_fd: posix.fd_t = -1;
var crash_original_termios: ?posix.termios = null;
var crash_handlers_installed: bool = false;

/// Register crash signal handlers to restore terminal state on SIGSEGV/SIGBUS/SIGABRT.
pub fn setupCrashHandlers(fd: posix.fd_t, original: posix.termios) bool {
    if (builtin.os.tag == .windows) return false;

    signal_state_mutex.lock();
    defer signal_state_mutex.unlock();
    if (crash_handlers_installed) return false;

    crash_restore_fd = fd;
    crash_original_termios = original;

    var sa: posix.Sigaction = .{
        .handler = .{ .handler = &crashHandler },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESETHAND, // One-shot: re-trigger default behavior after restore
    };
    posix.sigaction(posix.SIG.SEGV, &sa, null);
    posix.sigaction(posix.SIG.BUS, &sa, null);
    posix.sigaction(posix.SIG.ABRT, &sa, null);
    crash_handlers_installed = true;
    return true;
}

pub fn cleanupCrashHandlers() void {
    if (builtin.os.tag == .windows) return;

    signal_state_mutex.lock();
    defer signal_state_mutex.unlock();
    if (!crash_handlers_installed) return;

    var sa: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.SEGV, &sa, null);
    posix.sigaction(posix.SIG.BUS, &sa, null);
    posix.sigaction(posix.SIG.ABRT, &sa, null);

    crash_original_termios = null;
    crash_restore_fd = -1;
    crash_handlers_installed = false;
}

fn crashHandler(_: c_int) callconv(.c) void {
    if (crash_original_termios) |original| {
        posix.tcsetattr(crash_restore_fd, .NOW, original) catch {};
        // Reset terminal: show cursor, exit alt screen, reset attributes
        _ = posix.write(posix.STDOUT_FILENO, "\x1B[?25h\x1B[?1049l\x1B[0m") catch {};
    }
}

// ── Panic recovery ──────────────────────────────────────

var panic_restore_fd: posix.fd_t = -1;
var panic_original_termios: ?posix.termios = null;

/// Register terminal state for panic recovery. Call before entering raw mode.
/// The Zig panic handler will restore terminal state before printing the trace.
pub fn setupPanicRestore(fd: posix.fd_t, original: posix.termios) void {
    panic_restore_fd = fd;
    panic_original_termios = original;
}

/// Clear panic restore state. Call after terminal state is already restored.
pub fn clearPanicRestore() void {
    panic_original_termios = null;
    panic_restore_fd = -1;
}

/// Restore terminal state from panic context. Safe to call from panic handler.
pub fn restoreTerminalFromPanic() void {
    if (panic_original_termios) |original| {
        posix.tcsetattr(panic_restore_fd, .NOW, original) catch {};
        _ = posix.write(posix.STDOUT_FILENO, "\x1B[?25h\x1B[?1049l\x1B[0m\n") catch {};
        panic_original_termios = null;
    }
}

// ── Unit tests ──────────────────────────────────────────────

const testing = std.testing;

test "signals: getTerminalSize on pipe returns error" {
    if (builtin.os.tag == .windows) {
        try testing.expectError(error.UnsupportedPlatform, getTerminalSize(0));
        return;
    }

    const pipes = try posix.pipe();
    defer posix.close(pipes[0]);
    defer posix.close(pipes[1]);
    const result = getTerminalSize(pipes[0]);
    try testing.expect(result == error.IoctlFailed);
}

test "signals: setupSigwinch rejects duplicate setup" {
    if (builtin.os.tag == .windows) return;

    _ = try setupSigwinch();
    defer cleanupSigwinch();
    try testing.expectError(error.SignalHandlerAlreadyActive, setupSigwinch());
}

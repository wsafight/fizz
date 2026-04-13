/// TTY raw mode management (Phase 3)
///
/// Provides terminal raw mode enter/restore, ensuring correct terminal state on exit.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const TtyState = if (builtin.os.tag == .windows)
    struct {
        fd: posix.fd_t,
        original_in_mode: u32 = 0,
        original_out_mode: u32 = 0,

        const windows = std.os.windows;
        const ENABLE_VIRTUAL_TERMINAL_INPUT: u32 = 0x0200;
        const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;
        const DISABLE_NEWLINE_AUTO_RETURN: u32 = 0x0008;

        pub fn enableRawMode(fd: posix.fd_t) !TtyState {
            var state = TtyState{ .fd = fd };
            // Save and configure stdin console mode
            const stdin_h = windows.GetStdHandle(windows.STD_INPUT_HANDLE) catch return state;
            var in_mode: u32 = 0;
            if (windows.kernel32.GetConsoleMode(stdin_h, &in_mode) != 0) {
                state.original_in_mode = in_mode;
                // Disable line input, echo; enable VT input
                const raw_in = (in_mode & ~@as(u32, 0x0006)) | ENABLE_VIRTUAL_TERMINAL_INPUT;
                _ = windows.kernel32.SetConsoleMode(stdin_h, raw_in);
            }
            // Save and configure stdout console mode
            const stdout_h = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE) catch return state;
            var out_mode: u32 = 0;
            if (windows.kernel32.GetConsoleMode(stdout_h, &out_mode) != 0) {
                state.original_out_mode = out_mode;
                _ = windows.kernel32.SetConsoleMode(stdout_h, out_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN);
            }
            return state;
        }

        pub fn restore(self: *const TtyState) void {
            const windows_inner = std.os.windows;
            if (self.original_in_mode != 0) {
                const stdin_h = windows_inner.GetStdHandle(windows_inner.STD_INPUT_HANDLE) catch return;
                _ = windows_inner.kernel32.SetConsoleMode(stdin_h, self.original_in_mode);
            }
            if (self.original_out_mode != 0) {
                const stdout_h = windows_inner.GetStdHandle(windows_inner.STD_OUTPUT_HANDLE) catch return;
                _ = windows_inner.kernel32.SetConsoleMode(stdout_h, self.original_out_mode);
            }
        }
    }
else
    struct {
        original: posix.termios,
        fd: posix.fd_t,

        /// Switch terminal to raw mode, return saved original state.
        pub fn enableRawMode(fd: posix.fd_t) !TtyState {
            const original = try posix.tcgetattr(fd);
            var raw = original;

            // iflag: disable input processing
            raw.iflag.BRKINT = false;
            raw.iflag.ICRNL = false;
            raw.iflag.INPCK = false;
            raw.iflag.ISTRIP = false;
            raw.iflag.IXON = false;

            // oflag: disable output processing
            raw.oflag.OPOST = false;

            // cflag: 8-bit characters
            raw.cflag.CSIZE = .CS8;

            // lflag: disable echo, line buffering, extended processing, signal generation
            raw.lflag.ECHO = false;
            raw.lflag.ICANON = false;
            raw.lflag.IEXTEN = false;
            raw.lflag.ISIG = false;

            // cc: minimum 1 byte read, no timeout
            raw.cc[@intFromEnum(posix.V.MIN)] = 1;
            raw.cc[@intFromEnum(posix.V.TIME)] = 0;

            try posix.tcsetattr(fd, .FLUSH, raw);

            return TtyState{ .original = original, .fd = fd };
        }

        /// Restore terminal to original state.
        pub fn restore(self: *const TtyState) void {
            posix.tcsetattr(self.fd, .FLUSH, self.original) catch {};
        }
    };

/// Open /dev/tty for terminal I/O (equivalent to Go OpenTTY).
pub fn openTTY() !std.fs.File {
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;
    return std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write });
}

// ── Unit tests ──────────────────────────────────────────────

const testing = std.testing;

test "TtyState: enableRawMode on non-tty fd returns error" {
    if (builtin.os.tag == .windows) {
        const s = try TtyState.enableRawMode(@as(posix.fd_t, @ptrFromInt(1)));
        _ = s;
        return;
    }

    // pipe fd is not a tty, should return error
    const pipes = try posix.pipe();
    defer posix.close(pipes[0]);
    defer posix.close(pipes[1]);
    const result = TtyState.enableRawMode(pipes[0]);
    try testing.expectError(error.NotATerminal, result);
}

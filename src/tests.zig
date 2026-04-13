// Aggregate test entrypoint to avoid per-file test registration drift.
comptime {
    _ = @import("buffer.zig");
    _ = @import("clipboard.zig");
    _ = @import("cmd.zig");
    _ = @import("color.zig");
    _ = @import("cursor.zig");
    _ = @import("environ.zig");
    _ = @import("exec.zig");
    _ = @import("keyboard.zig");
    _ = @import("logging.zig");
    _ = @import("model.zig");
    _ = @import("msg.zig");
    _ = @import("options.zig");
    _ = @import("paste.zig");
    _ = @import("program/program.zig");
    _ = @import("program/commands.zig");
    _ = @import("program/handlers.zig");
    _ = @import("program/program_test.zig");
    _ = @import("queue.zig");
    _ = @import("termcap.zig");
    _ = @import("view.zig");
    _ = @import("input/key.zig");
    _ = @import("input/mouse.zig");
    _ = @import("input/reader.zig");
    _ = @import("platform/signals.zig");
    _ = @import("platform/tty.zig");
    _ = @import("renderer/cursed.zig");
    _ = @import("keymap.zig");
    _ = @import("test_program.zig");
}

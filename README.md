English | [中文](README.zh_CN.md)

# fizz

A terminal UI framework for Zig, following the Elm architecture (Model-Update-View). Inspired by [Bubble Tea](https://github.com/charmbracelet/bubbletea).

Zero external dependencies, pure Zig. Suitable for counters, forms, lists, dashboards, interactive tools, and other general TUI applications.

## Features

- Elm architecture: `Model.init` → `Model.update` → `Model.view`, with comptime contract validation
- Full input support: ASCII, UTF-8, CSI, SS3, Kitty keyboard protocol, SGR mouse
- Async command system: single, batch (parallel), sequence (serial), timers (`tick`/`every`), external processes
- Rendering optimizations: frame buffering, View diffing, BSU/ESU synchronized output (flicker-free)
- Terminal features: Alt Screen, cursor control, OSC 52 clipboard, bracketed paste, color profiles (no_color → truecolor)
- Thread-safe message queue (128-slot ring buffer)
- Functional configuration options (FPS, color, window size, input filtering, etc.)
- SIGWINCH window resize handling
- Headless/testing mode (nil renderer)

## Getting Started

### Installation

**Option A: zig fetch (recommended)**

```bash
zig fetch --save=fizz git+https://github.com/wsafight/fizz.git
```

Wire it up in `build.zig`:

```zig
const fizz_dep = b.dependency("fizz", .{
    .target = b.standardTargetOptions(.{}),
    .optimize = b.standardOptimizeOption(.{}),
});
app_module.addImport("fizz", fizz_dep.module("fizz"));
```

**Option B: Local vendor**

Place the `src` directory into your project (e.g. `third_party/fizz/src`), then register the module in `build.zig`:

```zig
const fizz_module = b.createModule(.{
    .root_source_file = b.path("third_party/fizz/src/fizz.zig"),
    .target = target,
    .optimize = optimize,
});
app_module.addImport("fizz", fizz_module);
```

### Minimal Example

```zig
const std = @import("std");
const fizz = @import("fizz");

const Model = struct {
    count: i32 = 0,
    buf: [64]u8 = undefined,

    pub fn init(_: *Model) ?fizz.Cmd {
        return null;
    }

    pub fn update(self: *Model, m: fizz.Msg) ?fizz.Cmd {
        switch (m) {
            .key_press => |kp| {
                if (kp.code == .char and kp.char == 'q') return fizz.cmd.quit_cmd;
                if (kp.code == .char and kp.char == '+') self.count += 1;
                if (kp.code == .char and kp.char == '-') self.count -= 1;
            },
            else => {},
        }
        return null;
    }

    pub fn view(self: *Model) []const u8 {
        return std.fmt.bufPrint(&self.buf, "Count: {d}  (q=quit, +/- to change)", .{self.count}) catch "?";
    }
};

pub fn main() !void {
    var p = fizz.Program(Model).init(std.fs.File.stdout(), Model{});
    defer p.deinit();
    _ = try p.run();
}
```

## Core Concepts

| Concept | Description |
|---------|-------------|
| `Program(ModelType)` | Runtime core: event loop, raw mode, threading, rendering |
| `Msg` | Event message tagged union (key, mouse, window resize, clipboard, custom, etc.) |
| `Cmd` | Async commands (`simple`/`batch`/`sequence`/`tick`/`every`/`exec`) |
| `View` | Render output with text content and terminal state control |
| `OptionFn` | Functional config (`withFps`/`withColorProfile`/`withFilter`, etc.) |

### Model Contract

A Model must implement three methods (validated at comptime):

```zig
pub fn init(self: *Self) ?Cmd                // Initialize, optionally return first command
pub fn update(self: *Self, msg: Msg) ?Cmd    // Handle events, optionally return next command
pub fn view(self: *Self) []const u8           // Render to string (or return View)
```

### Command System

```zig
fizz.cmd.quit_cmd                              // Quit
fizz.cmd.tick(ns_per_s, &callback)             // One-shot timer
fizz.cmd.every(ns_per_s, &callback)            // Repeating timer
fizz.cmd.batch(&.{ cmd_a, cmd_b })             // Parallel execution
fizz.cmd.sequence(&.{ cmd_a, cmd_b })          // Serial execution
fizz.cmd.execProcess(argv)                     // External process
fizz.cmd.setClipboard(content)                 // Clipboard write (system selection)
fizz.cmd.setPrimaryClipboard(content)          // Clipboard write (primary selection)
fizz.cmd.clearScreen()                         // Clear screen
```

## Project Structure

```
src/
├── fizz.zig              # Package entry, unified public API exports
├── model.zig             # Comptime Model contract validation
├── msg.zig               # Msg tagged union
├── cmd.zig               # Cmd tagged union
├── queue.zig             # Thread-safe ring buffer
├── view.zig              # View struct
├── options.zig           # Functional ProgramOption
├── program/
│   ├── program.zig       # Event loop, raw mode, public API
│   ├── commands.zig      # Command execution: worker pool, batch, sequence, tick
│   ├── handlers.zig      # Message handling, terminal I/O, renderer management
│   └── program_test.zig  # Program integration tests
├── renderer/
│   ├── renderer.zig      # Renderer interface (manual vtable)
│   ├── cursed.zig        # Terminal renderer: frame buffer, diffing, sync output
│   └── nil.zig           # Null renderer (headless/testing)
├── input/
│   ├── key.zig           # Key parsing (ASCII/UTF-8/CSI/SS3/Kitty)
│   ├── mouse.zig         # SGR mouse event parsing
│   └── reader.zig        # Input reader thread
├── platform/
│   ├── tty.zig           # Raw mode (termios)
│   └── signals.zig       # SIGWINCH + terminal size query
├── color.zig             # RgbColor + perceptual brightness
├── cursor.zig            # Cursor position/shape/color
├── clipboard.zig         # OSC 52 clipboard
├── paste.zig             # Bracketed paste
├── keyboard.zig          # Kitty keyboard enhancements
├── termcap.zig           # Terminal capability query
├── profile.zig           # Color profiles
├── screen.zig            # WindowSize / ModeReport
├── focus.zig             # Focus/Blur
├── raw.zig               # Raw escape sequences
├── environ.zig           # Environment variable snapshot
├── exec.zig              # External process execution
├── logging.zig           # File logging
└── tests.zig             # Aggregate test entry
```

## Build & Test

```bash
zig build              # Compile (Debug)
zig build run          # Run counter example
zig build test         # Run all unit tests
```

## Platform Support

Targets POSIX systems (Linux, macOS). Depends on termios, SIGWINCH, pipe, poll.

## References

- [Bubble Tea](https://github.com/charmbracelet/bubbletea) — Go TUI framework, the inspiration for fizz

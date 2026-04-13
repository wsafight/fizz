/// Program options (functional Option).
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const msg = @import("msg.zig");
const environ = @import("environ.zig");
const profile = @import("profile.zig");

pub const default_fps: u16 = 60;
pub const max_fps: u16 = 120;

pub const FilterFn = *const fn (msg.Msg) ?msg.Msg;
pub const FilterWithModelFn = *const fn (*const anyopaque, msg.Msg) ?msg.Msg;
pub const OptionFn = union(enum) {
    context_cancelled: *const std.atomic.Value(bool),
    filter: FilterFn,
    filter_with_model: FilterWithModelFn,
    fps: u16,
    color_profile: profile.ColorProfile,
    window_size: struct { width: u16, height: u16 },
    input_fd: posix.fd_t,
    output_file: std.fs.File,
    environment: environ.EnvMsg,
    allocator: std.mem.Allocator,
    worker_count: u8,
    above_line_count: u8,
    above_line_bytes: u16,
    exec_max_args: u8,
    exec_max_arg_len: u16,
    without_renderer,
    without_signal_handler,
    without_signals,
    without_catch_panics,
};

pub const Options = struct {
    context_cancelled: ?*const std.atomic.Value(bool) = null,
    filter: ?FilterFn = null,
    filter_with_model: ?FilterWithModelFn = null,
    fps: u16 = default_fps,
    color_profile: ?profile.ColorProfile = null,
    initial_width: ?u16 = null,
    initial_height: ?u16 = null,
    input_fd: ?posix.fd_t = null,
    output_file: ?std.fs.File = null,
    environment: ?environ.EnvMsg = null,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    worker_count: u8 = 4,
    above_line_count: u8 = 32,
    above_line_bytes: u16 = 512,
    exec_max_args: u8 = 16,
    exec_max_arg_len: u16 = 128,
    disable_renderer: bool = false,
    disable_signal_handler: bool = false,
    disable_signals: bool = false,
    disable_catch_panics: bool = false,
};

pub fn applyOptions(base: Options, opts: []const OptionFn) Options {
    var out = base;
    for (opts) |o| {
        switch (o) {
            .context_cancelled => |ctx| out.context_cancelled = ctx,
            .filter => |f| out.filter = f,
            .filter_with_model => |f| out.filter_with_model = f,
            .fps => |fps| out.fps = fps,
            .color_profile => |cp| out.color_profile = cp,
            .window_size => |sz| {
                out.initial_width = sz.width;
                out.initial_height = sz.height;
            },
            .input_fd => |fd| out.input_fd = fd,
            .output_file => |f| out.output_file = f,
            .environment => |env_msg| out.environment = env_msg,
            .allocator => |a| out.allocator = a,
            .worker_count => |n| out.worker_count = if (n == 0) 1 else n,
            .above_line_count => |n| out.above_line_count = if (n == 0) 1 else n,
            .above_line_bytes => |n| out.above_line_bytes = if (n == 0) 64 else n,
            .exec_max_args => |n| out.exec_max_args = if (n == 0) 1 else n,
            .exec_max_arg_len => |n| out.exec_max_arg_len = if (n == 0) 64 else n,
            .without_renderer => out.disable_renderer = true,
            .without_signal_handler => out.disable_signal_handler = true,
            .without_signals => out.disable_signals = true,
            .without_catch_panics => out.disable_catch_panics = true,
        }
    }
    if (out.fps < 1) out.fps = default_fps;
    if (out.fps > max_fps) out.fps = max_fps;
    return out;
}

pub fn withFilter(filter: FilterFn) OptionFn {
    return .{ .filter = filter };
}

pub fn withFilterModel(filter: FilterWithModelFn) OptionFn {
    return .{ .filter_with_model = filter };
}

/// Type-safe filter: wraps a typed filter function into the opaque FilterWithModelFn.
/// Usage: withTypedFilterModel(MyModel, myFilterFn)
pub fn withTypedFilterModel(comptime ModelType: type, comptime filter: *const fn (*const ModelType, msg.Msg) ?msg.Msg) OptionFn {
    const wrapper = struct {
        fn call(ptr: *const anyopaque, m: msg.Msg) ?msg.Msg {
            const model: *const ModelType = @ptrCast(@alignCast(ptr));
            return filter(model, m);
        }
    };
    return .{ .filter_with_model = &wrapper.call };
}

pub fn withContext(cancelled: *const std.atomic.Value(bool)) OptionFn {
    return .{ .context_cancelled = cancelled };
}

pub fn withFps(fps: u16) OptionFn {
    return .{ .fps = fps };
}

pub fn withColorProfile(cp: profile.ColorProfile) OptionFn {
    return .{ .color_profile = cp };
}

pub fn withWindowSize(width: u16, height: u16) OptionFn {
    return .{ .window_size = .{ .width = width, .height = height } };
}

pub fn withInput(fd: posix.fd_t) OptionFn {
    return .{ .input_fd = fd };
}

pub fn withOutput(out_file: std.fs.File) OptionFn {
    return .{ .output_file = out_file };
}

pub fn withEnvironment(vars: []const []const u8) OptionFn {
    return .{ .environment = environ.EnvMsg.fromSlice(vars) };
}

pub fn withAllocator(alloc: std.mem.Allocator) OptionFn {
    return .{ .allocator = alloc };
}

pub fn withWorkerCount(n: u8) OptionFn {
    return .{ .worker_count = n };
}

pub fn withAboveLineCount(n: u8) OptionFn {
    return .{ .above_line_count = n };
}

pub fn withAboveLineBytes(n: u16) OptionFn {
    return .{ .above_line_bytes = n };
}

pub fn withExecMaxArgs(n: u8) OptionFn {
    return .{ .exec_max_args = n };
}

pub fn withExecMaxArgLen(n: u16) OptionFn {
    return .{ .exec_max_arg_len = n };
}

pub fn withoutRenderer() OptionFn {
    return .without_renderer;
}

pub fn withoutSignalHandler() OptionFn {
    return .without_signal_handler;
}

pub fn withoutSignals() OptionFn {
    return .without_signals;
}

pub fn withoutCatchPanics() OptionFn {
    // Zig has no Go recover equivalent; this option is an API compatibility placeholder.
    return .without_catch_panics;
}

const testing = @import("std").testing;

fn passThrough(m: msg.Msg) ?msg.Msg {
    return m;
}

test "options: apply and clamp fps" {
    const opts = applyOptions(.{}, &[_]OptionFn{
        withFilter(&passThrough),
        withFps(999),
        withoutRenderer(),
    });
    try testing.expect(opts.filter != null);
    try testing.expect(opts.disable_renderer);
    try testing.expectEqual(max_fps, opts.fps);
}

test "options: window size, color profile and signal toggle" {
    const opts = applyOptions(.{}, &[_]OptionFn{
        withWindowSize(120, 40),
        withColorProfile(.truecolor),
        withoutSignalHandler(),
    });
    try testing.expectEqual(@as(?u16, 120), opts.initial_width);
    try testing.expectEqual(@as(?u16, 40), opts.initial_height);
    try testing.expect(opts.color_profile.? == .truecolor);
    try testing.expect(opts.disable_signal_handler);
}

test "options: later values override earlier values" {
    const opts = applyOptions(.{}, &[_]OptionFn{
        withFps(30),
        withFps(144),
        withWindowSize(10, 10),
        withWindowSize(80, 24),
    });
    try testing.expectEqual(max_fps, opts.fps);
    try testing.expectEqual(@as(?u16, 80), opts.initial_width);
    try testing.expectEqual(@as(?u16, 24), opts.initial_height);
}

test "options: io, env and extra disable flags" {
    const vars = [_][]const u8{ "TERM=xterm-256color", "LANG=C.UTF-8" };
    const input_fd: posix.fd_t = if (builtin.os.tag == .windows)
        @as(posix.fd_t, @ptrFromInt(7))
    else
        7;
    const opts = applyOptions(.{}, &[_]OptionFn{
        withInput(input_fd),
        withOutput(std.fs.File.stdout()),
        withEnvironment(&vars),
        withoutSignals(),
        withoutCatchPanics(),
    });
    try testing.expect(opts.input_fd != null);
    try testing.expectEqual(input_fd, opts.input_fd.?);
    try testing.expect(opts.output_file != null);
    try testing.expect(opts.environment != null);
    try testing.expectEqualStrings("xterm-256color", opts.environment.?.getenv("TERM"));
    try testing.expect(opts.disable_signals);
    try testing.expect(opts.disable_catch_panics);
}

test "options: context cancellation hook" {
    var cancelled = std.atomic.Value(bool).init(false);
    const opts = applyOptions(.{}, &[_]OptionFn{
        withContext(&cancelled),
    });
    try testing.expect(opts.context_cancelled != null);
}

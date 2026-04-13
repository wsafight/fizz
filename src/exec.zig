/// External process execution messages.
const std = @import("std");
const msg_mod = @import("msg.zig");

/// Exec callback: receives ExecResultMsg, returns user-defined Msg.
pub const ExecCallback = *const fn (ExecResultMsg) msg_mod.Msg;

pub const ExecRequestMsg = struct {
    pub const max_args = 16;
    pub const max_arg_len = 128;

    args: [max_args]Arg = [_]Arg{Arg{}} ** max_args,
    len: u8 = 0,
    total_args: u16 = 0,
    dropped_args: u16 = 0,
    truncated_args: u16 = 0,
    truncated: bool = false,
    callback: ?ExecCallback = null,

    pub const Arg = struct {
        data: [max_arg_len]u8 = [_]u8{0} ** max_arg_len,
        len: u8 = 0,
        truncated: bool = false,

        pub fn slice(self: *const Arg) []const u8 {
            return self.data[0..self.len];
        }
    };

    pub fn fromArgv(argv: []const []const u8) ExecRequestMsg {
        var out: ExecRequestMsg = .{};
        out.total_args = @intCast(@min(argv.len, std.math.maxInt(u16)));
        for (argv) |a| {
            if (out.len >= max_args) {
                out.truncated = true;
                continue;
            }
            const n: u8 = @intCast(@min(a.len, max_arg_len));
            @memcpy(out.args[out.len].data[0..n], a[0..n]);
            out.args[out.len].len = n;
            out.args[out.len].truncated = a.len > n;
            if (out.args[out.len].truncated) {
                out.truncated_args += 1;
                out.truncated = true;
            }
            out.len += 1;
        }
        if (out.total_args > out.len) {
            out.dropped_args = out.total_args - out.len;
        } else {
            out.dropped_args = 0;
        }
        return out;
    }

    pub fn withCallback(self: ExecRequestMsg, cb: ExecCallback) ExecRequestMsg {
        var out = self;
        out.callback = cb;
        return out;
    }

    pub fn toArgv(self: *const ExecRequestMsg, allocator: std.mem.Allocator) ![][]const u8 {
        const list = try allocator.alloc([]const u8, self.len);
        errdefer allocator.free(list);
        var i: usize = 0;
        errdefer for (list[0..i]) |s| allocator.free(@constCast(s));
        while (i < self.len) : (i += 1) {
            const src = self.args[i].slice();
            list[i] = try allocator.dupe(u8, src);
        }
        return list;
    }

    pub fn freeArgv(allocator: std.mem.Allocator, argv: [][]const u8) void {
        for (argv) |s| allocator.free(s);
        allocator.free(argv);
    }
};

pub const ExecResultMsg = struct {
    success: bool = false,
    exit_code: i32 = 0,
    err_text: [128]u8 = [_]u8{0} ** 128,
    err_len: u8 = 0,

    pub fn ok() ExecResultMsg {
        return .{ .success = true, .exit_code = 0 };
    }

    pub fn fail(exit_code: i32, err: []const u8) ExecResultMsg {
        var out = ExecResultMsg{ .success = false, .exit_code = exit_code };
        const n: u8 = @intCast(@min(err.len, out.err_text.len));
        @memcpy(out.err_text[0..n], err[0..n]);
        out.err_len = n;
        return out;
    }

    pub fn errSlice(self: *const ExecResultMsg) []const u8 {
        return self.err_text[0..self.err_len];
    }
};

const testing = std.testing;

test "ExecRequestMsg: fromArgv" {
    const req = ExecRequestMsg.fromArgv(&[_][]const u8{ "echo", "hello" });
    try testing.expectEqual(@as(u8, 2), req.len);
    try testing.expectEqual(@as(u16, 2), req.total_args);
    try testing.expectEqual(@as(u16, 0), req.dropped_args);
    try testing.expectEqual(@as(u16, 0), req.truncated_args);
    try testing.expectEqualStrings("echo", req.args[0].slice());
    try testing.expectEqualStrings("hello", req.args[1].slice());
    try testing.expect(!req.truncated);
}

test "ExecRequestMsg: truncation flags" {
    var big_arg: [200]u8 = undefined;
    @memset(big_arg[0..], 'x');

    var argv: [18][]const u8 = undefined;
    argv[0] = "cmd";
    argv[1] = &big_arg;
    for (argv[2..]) |*slot| slot.* = "arg";

    const req = ExecRequestMsg.fromArgv(&argv);
    try testing.expect(req.truncated);
    try testing.expect(req.args[1].truncated);
    try testing.expectEqual(@as(u8, ExecRequestMsg.max_args), req.len);
    try testing.expectEqual(@as(u16, 18), req.total_args);
    try testing.expectEqual(@as(u16, 2), req.dropped_args);
    try testing.expectEqual(@as(u16, 1), req.truncated_args);
}

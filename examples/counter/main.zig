/// fizz 示例：Counter（raw mode）
///
/// 即时响应按键：+/- 改变计数，每秒自动 +1，q 或 Ctrl+C 退出。
/// Program.run() 自动管理 raw mode、输入读取、信号处理。
const std = @import("std");
const fizz = @import("fizz");

fn tickCb(_: i128) fizz.Msg {
    return .{ .text = fizz.TextPayload.fromSlice("tick") };
}

const CounterModel = struct {
    count: i32 = 0,
    view_buf: [128]u8 = undefined,

    pub fn init(_: *CounterModel) ?fizz.Cmd {
        return fizz.cmd.tick(1 * std.time.ns_per_s, &tickCb);
    }

    pub fn update(self: *CounterModel, m: fizz.Msg) ?fizz.Cmd {
        switch (m) {
            .key_press => |kp| {
                if (kp.modifiers.ctrl and kp.char == 'c') return fizz.cmd.quit_cmd;
                switch (kp.code) {
                    .char => {
                        if (kp.char == 'q') return fizz.cmd.quit_cmd;
                        if (kp.char == '+' or kp.char == '=') self.count += 1;
                        if (kp.char == '-') self.count -= 1;
                    },
                    .up => self.count += 1,
                    .down => self.count -= 1,
                    .escape => return fizz.cmd.quit_cmd,
                    else => {},
                }
            },
            .text => |tp| {
                if (std.mem.eql(u8, tp.slice(), "tick")) {
                    self.count += 1;
                    return fizz.cmd.tick(1 * std.time.ns_per_s, &tickCb);
                }
            },
            else => {},
        }
        return null;
    }

    pub fn view(self: *CounterModel) []const u8 {
        const result = std.fmt.bufPrint(
            &self.view_buf,
            "\rCounter: {d}  (+/-/arrows, q/Esc/Ctrl+C to quit)",
            .{self.count},
        ) catch return "\rCounter: ?";
        return result;
    }
};

pub fn main() !void {
    var program = fizz.Program(CounterModel).init(
        std.fs.File.stdout(),
        CounterModel{},
    );
    defer program.deinit();

    _ = try program.run();

    std.fs.File.stdout().writeAll("\n") catch {};
}

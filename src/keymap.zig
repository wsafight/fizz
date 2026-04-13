/// KeyMap: maps physical key events to logical actions.
///
/// Usage:
///   const Action = enum { quit, increment, decrement };
///   const km = KeyMap(Action).init(&.{
///       .{ .key = .{ .code = .char, .char = 'q' }, .action = .quit },
///       .{ .key = .{ .code = .char, .char = '+' }, .action = .increment },
///       .{ .key = .{ .code = .char, .char = '-' }, .action = .decrement },
///       .{ .key = .{ .code = .escape }, .action = .quit },
///       .{ .key = .{ .code = .char, .char = 'c', .modifiers = .{ .ctrl = true } }, .action = .quit },
///   });
///   if (km.match(key_event)) |action| { ... }
const key_mod = @import("input/key.zig");

pub fn KeyMap(comptime Action: type) type {
    return struct {
        const Self = @This();

        pub const Binding = struct {
            key: MatchKey,
            action: Action,
        };

        pub const MatchKey = struct {
            code: key_mod.KeyCode = .char,
            char: u21 = 0,
            modifiers: key_mod.Modifiers = .{},
        };

        bindings: []const Binding,

        pub fn init(bindings: []const Binding) Self {
            return .{ .bindings = bindings };
        }

        pub fn match(self: Self, event: key_mod.KeyEvent) ?Action {
            for (self.bindings) |b| {
                if (b.key.code != event.code) continue;
                if (b.key.code == .char and b.key.char != event.char) continue;
                if (@as(u9, @bitCast(b.key.modifiers)) != @as(u9, @bitCast(event.modifiers))) continue;
                return b.action;
            }
            return null;
        }
    };
}

const testing = @import("std").testing;

const TestAction = enum { quit, up, down };

test "KeyMap: matches char key" {
    const km = KeyMap(TestAction).init(&.{
        .{ .key = .{ .code = .char, .char = 'q' }, .action = .quit },
    });
    const event = key_mod.KeyEvent{ .code = .char, .char = 'q' };
    try testing.expectEqual(@as(?TestAction, .quit), km.match(event));
}

test "KeyMap: matches with modifiers" {
    const km = KeyMap(TestAction).init(&.{
        .{ .key = .{ .code = .char, .char = 'c', .modifiers = .{ .ctrl = true } }, .action = .quit },
    });
    try testing.expect(km.match(.{ .code = .char, .char = 'c' }) == null);
    try testing.expectEqual(@as(?TestAction, .quit), km.match(.{ .code = .char, .char = 'c', .modifiers = .{ .ctrl = true } }));
}

test "KeyMap: matches special keys" {
    const km = KeyMap(TestAction).init(&.{
        .{ .key = .{ .code = .up }, .action = .up },
        .{ .key = .{ .code = .down }, .action = .down },
    });
    try testing.expectEqual(@as(?TestAction, .up), km.match(.{ .code = .up }));
    try testing.expectEqual(@as(?TestAction, .down), km.match(.{ .code = .down }));
    try testing.expect(km.match(.{ .code = .left }) == null);
}

test "KeyMap: returns null for unbound key" {
    const km = KeyMap(TestAction).init(&.{
        .{ .key = .{ .code = .char, .char = 'q' }, .action = .quit },
    });
    try testing.expect(km.match(.{ .code = .char, .char = 'x' }) == null);
}

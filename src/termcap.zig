/// Terminal capability messages.
const std = @import("std");

fn FixedField(comptime N: usize) type {
    return struct {
        data: [N]u8 = [_]u8{0} ** N,
        len: u8 = 0,
        truncated: bool = false,

        pub fn set(self: *@This(), s: []const u8) void {
            const n: u8 = @intCast(@min(s.len, N));
            @memcpy(self.data[0..n], s[0..n]);
            self.len = n;
            self.truncated = s.len > n;
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self.data[0..self.len];
        }
    };
}

pub const RequestCapabilityMsg = struct {
    data: [64]u8 = [_]u8{0} ** 64,
    len: u8 = 0,

    pub fn fromSlice(s: []const u8) RequestCapabilityMsg {
        var out = RequestCapabilityMsg{};
        const n: u8 = @intCast(@min(s.len, out.data.len));
        @memcpy(out.data[0..n], s[0..n]);
        out.len = n;
        return out;
    }

    pub fn slice(self: *const RequestCapabilityMsg) []const u8 {
        return self.data[0..self.len];
    }
};

pub const CapabilityMsg = struct {
    raw: FixedField(128) = .{},
    name_field: FixedField(64) = .{},
    value_field: FixedField(64) = .{},

    pub fn fromSlice(s: []const u8) CapabilityMsg {
        var out = CapabilityMsg{};
        out.raw.set(s);

        const data = out.slice();
        const eq_idx = std.mem.indexOfScalar(u8, data, '=') orelse data.len;
        out.name_field.set(data[0..eq_idx]);
        if (eq_idx < data.len) {
            out.value_field.set(data[eq_idx + 1 ..]);
        }
        return out;
    }

    pub fn slice(self: *const CapabilityMsg) []const u8 {
        return self.raw.slice();
    }

    pub fn nameSlice(self: *const CapabilityMsg) []const u8 {
        return self.name_field.slice();
    }

    pub fn valueSlice(self: *const CapabilityMsg) []const u8 {
        return self.value_field.slice();
    }
};

pub const TerminalVersionMsg = struct {
    raw: FixedField(128) = .{},
    name_field: FixedField(64) = .{},
    version_field: FixedField(64) = .{},

    pub fn fromSlice(s: []const u8) TerminalVersionMsg {
        var out = TerminalVersionMsg{};
        out.raw.set(s);

        const data = trimAsciiSpace(out.slice());
        if (data.len == 0) return out;

        if (data[data.len - 1] == ')') {
            if (std.mem.indexOfScalar(u8, data, '(')) |open_idx| {
                out.name_field.set(trimAsciiSpace(data[0..open_idx]));
                out.version_field.set(trimAsciiSpace(data[open_idx + 1 .. data.len - 1]));
                return out;
            }
        }

        if (std.mem.indexOfScalar(u8, data, ' ')) |sep| {
            out.name_field.set(trimAsciiSpace(data[0..sep]));
            out.version_field.set(trimAsciiSpace(data[sep + 1 ..]));
        } else {
            out.name_field.set(data);
        }
        return out;
    }

    pub fn slice(self: *const TerminalVersionMsg) []const u8 {
        return self.raw.slice();
    }

    pub fn nameSlice(self: *const TerminalVersionMsg) []const u8 {
        return self.name_field.slice();
    }

    pub fn versionSlice(self: *const TerminalVersionMsg) []const u8 {
        return self.version_field.slice();
    }
};

fn trimAsciiSpace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and std.ascii.isWhitespace(s[start])) : (start += 1) {}
    while (end > start and std.ascii.isWhitespace(s[end - 1])) : (end -= 1) {}
    return s[start..end];
}

const testing = std.testing;

test "CapabilityMsg: parses name and value" {
    const c = CapabilityMsg.fromSlice("Tc=1");
    try testing.expectEqualStrings("Tc=1", c.slice());
    try testing.expectEqualStrings("Tc", c.nameSlice());
    try testing.expectEqualStrings("1", c.valueSlice());
}

test "CapabilityMsg: parses name-only payload" {
    const c = CapabilityMsg.fromSlice("RGB");
    try testing.expectEqualStrings("RGB", c.nameSlice());
    try testing.expectEqualStrings("", c.valueSlice());
}

test "TerminalVersionMsg: parses spaced format" {
    const tv = TerminalVersionMsg.fromSlice("WezTerm 20240203-110809-5046fc22");
    try testing.expectEqualStrings("WezTerm", tv.nameSlice());
    try testing.expectEqualStrings("20240203-110809-5046fc22", tv.versionSlice());
}

test "TerminalVersionMsg: parses parenthesized format" {
    const tv = TerminalVersionMsg.fromSlice("xterm(379)");
    try testing.expectEqualStrings("xterm", tv.nameSlice());
    try testing.expectEqualStrings("379", tv.versionSlice());
}

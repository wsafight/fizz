/// Environment variable messages.
const std = @import("std");

pub const EnvMsg = struct {
    pub const max_vars = 96;
    pub const max_entry_len = 256;

    entries: [max_vars]Entry = [_]Entry{Entry{}} ** max_vars,
    len: u8 = 0,
    total_vars: u16 = 0,
    dropped_vars: u16 = 0,
    truncated_entries: u16 = 0,
    truncated: bool = false,

    pub const Entry = struct {
        data: [max_entry_len]u8 = [_]u8{0} ** max_entry_len,
        len: u16 = 0,
        truncated: bool = false,

        pub fn slice(self: *const Entry) []const u8 {
            return self.data[0..self.len];
        }
    };

    pub fn empty() EnvMsg {
        return .{};
    }

    pub fn fromSlice(vars: []const []const u8) EnvMsg {
        var out = EnvMsg.empty();
        out.total_vars = @intCast(@min(vars.len, std.math.maxInt(u16)));
        for (vars) |v| {
            if (out.len >= max_vars) {
                out.truncated = true;
                continue;
            }
            out.entries[out.len] = entryFromSlice(v);
            if (out.entries[out.len].truncated) out.truncated_entries += 1;
            out.len += 1;
        }
        if (out.total_vars > out.len) out.dropped_vars = out.total_vars - out.len;
        out.truncated = out.truncated or out.dropped_vars > 0 or out.truncated_entries > 0;
        return out;
    }

    pub fn fromMap(env_map: *const std.process.EnvMap) EnvMsg {
        var out = EnvMsg.empty();
        var it = env_map.iterator();
        while (it.next()) |kv| {
            if (out.total_vars < std.math.maxInt(u16)) out.total_vars += 1;
            if (out.len >= max_vars) {
                out.truncated = true;
                continue;
            }
            out.entries[out.len] = entryFromKeyValue(kv.key_ptr.*, kv.value_ptr.*);
            if (out.entries[out.len].truncated) out.truncated_entries += 1;
            out.len += 1;
        }
        if (out.total_vars > out.len) out.dropped_vars = out.total_vars - out.len;
        out.truncated = out.truncated or out.dropped_vars > 0 or out.truncated_entries > 0;
        return out;
    }

    pub fn getenv(self: *const EnvMsg, key: []const u8) []const u8 {
        return self.lookupEnv(key) orelse "";
    }

    pub fn lookupEnv(self: *const EnvMsg, key: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const kv = self.entries[i].slice();
            const eq_index = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            if (std.mem.eql(u8, kv[0..eq_index], key)) {
                return kv[eq_index + 1 ..];
            }
        }
        return null;
    }

    fn entryFromSlice(s: []const u8) Entry {
        var e = Entry{};
        const n: u16 = @intCast(@min(s.len, max_entry_len));
        @memcpy(e.data[0..n], s[0..n]);
        e.len = n;
        e.truncated = s.len > n;
        return e;
    }

    fn entryFromKeyValue(key: []const u8, value: []const u8) Entry {
        var e = Entry{};
        const total_len = key.len + 1 + value.len;

        const key_n: usize = @min(key.len, e.data.len);
        if (key_n > 0) {
            @memcpy(e.data[0..key_n], key[0..key_n]);
        }

        if (key_n < e.data.len) {
            e.data[key_n] = '=';
            const remain = e.data.len - (key_n + 1);
            const val_n = @min(value.len, remain);
            if (val_n > 0) {
                @memcpy(e.data[key_n + 1 .. key_n + 1 + val_n], value[0..val_n]);
            }
            e.len = @intCast(key_n + 1 + val_n);
        } else {
            e.len = @intCast(key_n);
        }

        e.truncated = total_len > e.data.len;
        return e;
    }
};

const testing = std.testing;

test "EnvMsg: getenv/lookupEnv" {
    const vars = [_][]const u8{
        "TERM=xterm-256color",
        "LANG=en_US.UTF-8",
    };
    const env = EnvMsg.fromSlice(&vars);
    try testing.expectEqualStrings("xterm-256color", env.getenv("TERM"));
    try testing.expectEqualStrings("en_US.UTF-8", env.lookupEnv("LANG").?);
    try testing.expect(env.lookupEnv("NOT_EXIST") == null);
    try testing.expect(!env.truncated);
    try testing.expectEqual(@as(u16, 2), env.total_vars);
    try testing.expectEqual(@as(u16, 0), env.dropped_vars);
    try testing.expectEqual(@as(u16, 0), env.truncated_entries);
}

test "EnvMsg: marks truncation when entries exceed limits" {
    var vars: [100][]const u8 = undefined;
    for (&vars) |*slot| {
        slot.* = "A=B";
    }
    const env = EnvMsg.fromSlice(&vars);
    try testing.expect(env.truncated);
    try testing.expectEqual(@as(u8, EnvMsg.max_vars), env.len);
    try testing.expectEqual(@as(u16, 100), env.total_vars);
    try testing.expectEqual(@as(u16, 4), env.dropped_vars);
}

test "EnvMsg: tracks oversized entry truncation" {
    var big: [300]u8 = undefined;
    @memset(big[0..], 'x');
    const vars = [_][]const u8{&big};
    const env = EnvMsg.fromSlice(&vars);
    try testing.expect(env.truncated);
    try testing.expectEqual(@as(u8, 1), env.len);
    try testing.expectEqual(@as(u16, 1), env.truncated_entries);
}

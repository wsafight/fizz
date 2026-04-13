/// 输入读取线程（Phase 5）。
///
/// 从 stdin 读取原始字节，解析为 key/mouse/focus/paste 事件并发送到 Program。
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const key = @import("key.zig");
const mouse = @import("mouse.zig");
const clipboard_mod = @import("../clipboard.zig");
const color_mod = @import("../color.zig");
const cursor_mod = @import("../cursor.zig");
const screen_mod = @import("../screen.zig");
const signals = @import("../platform/signals.zig");
const msg_mod = @import("../msg.zig");
const paste_mod = @import("../paste.zig");
const termcap_mod = @import("../termcap.zig");

const Msg = msg_mod.Msg;

pub fn InputReader(comptime ProgramType: type) type {
    return struct {
        const Self = @This();

        program: *ProgramType,
        input_fd: posix.fd_t,
        quit_fd: posix.fd_t,
        sigwinch_fd: ?posix.fd_t,
        output_fd: posix.fd_t,

        pub fn start(
            program: *ProgramType,
            input_fd: posix.fd_t,
            quit_fd: posix.fd_t,
            sigwinch_fd: ?posix.fd_t,
            output_fd: posix.fd_t,
        ) !std.Thread {
            const self_data = Self{
                .program = program,
                .input_fd = input_fd,
                .quit_fd = quit_fd,
                .sigwinch_fd = sigwinch_fd,
                .output_fd = output_fd,
            };
            return std.Thread.spawn(.{}, run, .{self_data});
        }

        fn run(self: Self) void {
            if (builtin.os.tag == .windows) {
                self.runWindows();
                return;
            }

            var buf: [1024]u8 = undefined;
            var carry: usize = 0;
            var ps = ParseState{};

            var fds = [3]posix.pollfd{
                .{ .fd = self.input_fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.quit_fd, .events = posix.POLL.IN, .revents = 0 },
                .{
                    .fd = self.sigwinch_fd orelse self.quit_fd,
                    .events = if (self.sigwinch_fd != null) posix.POLL.IN else 0,
                    .revents = 0,
                },
            };

            while (true) {
                const ready = posix.poll(&fds, -1) catch {
                    self.program.send(.interrupt);
                    return;
                };
                if (ready == 0) continue;

                // quit pipe
                if (fds[1].revents & posix.POLL.IN != 0) return;

                // SIGWINCH
                if (self.sigwinch_fd != null and fds[2].revents & posix.POLL.IN != 0) {
                    const sig_fd = self.sigwinch_fd.?;
                    var drain: [32]u8 = undefined;
                    _ = posix.read(sig_fd, &drain) catch {};
                    if (signals.getTerminalSize(self.output_fd)) |sz| {
                        self.program.send(.{ .window_size = .{ .width = sz.width, .height = sz.height } });
                    } else |_| {}
                }

                // stdin
                if (fds[0].revents & posix.POLL.IN != 0) {
                    normalizeCarry(&carry, buf.len);

                    const n = posix.read(self.input_fd, buf[carry..]) catch {
                        self.program.send(.interrupt);
                        return;
                    };

                    if (n == 0) {
                        self.program.send(.quit);
                        return;
                    }

                    var total = carry + n;
                    const pos = self.processBuffer(&ps, &buf, &total);

                    if (pos < total) {
                        carry = total - pos;
                        std.mem.copyForwards(u8, buf[0..carry], buf[pos..total]);
                    } else {
                        carry = 0;
                    }
                }
            }
        }

        fn runWindows(self: Self) void {
            const windows = std.os.windows;
            var buf: [1024]u8 = undefined;
            var carry: usize = 0;
            var ps = ParseState{};

            while (true) {
                if (programClosing(self.program)) return;

                windows.WaitForSingleObject(self.input_fd, 100) catch |err| {
                    if (err == error.WaitTimeOut) continue;
                    self.program.send(.interrupt);
                    return;
                };

                normalizeCarry(&carry, buf.len);
                const n = windows.ReadFile(self.input_fd, buf[carry..], null) catch {
                    self.program.send(.interrupt);
                    return;
                };
                if (n == 0) {
                    self.program.send(.quit);
                    return;
                }

                var total = carry + n;
                const pos = self.processBuffer(&ps, &buf, &total);

                if (pos < total) {
                    carry = total - pos;
                    std.mem.copyForwards(u8, buf[0..carry], buf[pos..total]);
                } else {
                    carry = 0;
                }
            }
        }

        const ParseState = struct {
            in_paste: bool = false,
            paste_buf: [256]u8 = undefined,
            paste_len: usize = 0,
        };

        /// 解析缓冲区中的事件，返回已消费的字节位置。total 可能因 ESC 超时读取而增长。
        fn processBuffer(self: Self, ps: *ParseState, buf: *[1024]u8, total: *usize) usize {
            var pos: usize = 0;

            while (pos < total.*) {
                const remaining = buf[pos..total.*];

                if (ps.in_paste) {
                    const end_seq = "\x1B[201~";
                    if (std.mem.indexOf(u8, remaining, end_seq)) |idx| {
                        appendPasteChunked(self.program, &ps.paste_buf, &ps.paste_len, remaining[0..idx]);
                        flushPaste(self.program, &ps.paste_buf, &ps.paste_len);
                        self.program.send(.{ .paste_end = .{} });
                        ps.in_paste = false;
                        pos += idx + end_seq.len;
                        continue;
                    }
                    appendPasteChunked(self.program, &ps.paste_buf, &ps.paste_len, remaining);
                    pos = total.*;
                    break;
                }

                const ctrl_res = self.parseTerminalResponse(remaining);
                if (ctrl_res.need_more) break;
                if (ctrl_res.handled) {
                    pos += ctrl_res.consumed;
                    continue;
                }

                if (std.mem.startsWith(u8, remaining, "\x1B[I")) {
                    self.program.send(.{ .focus = .{} });
                    pos += 3;
                    continue;
                }
                if (std.mem.startsWith(u8, remaining, "\x1B[O")) {
                    self.program.send(.{ .blur = .{} });
                    pos += 3;
                    continue;
                }

                if (std.mem.startsWith(u8, remaining, "\x1B[200~")) {
                    ps.in_paste = true;
                    ps.paste_len = 0;
                    self.program.send(.{ .paste_start = .{} });
                    pos += 6;
                    continue;
                }
                if (std.mem.startsWith(u8, remaining, "\x1B[201~")) {
                    self.program.send(.{ .paste_end = .{} });
                    pos += 6;
                    continue;
                }

                const mres = mouse.parseSgr(remaining);
                if (mres.kind) |kind| {
                    switch (kind) {
                        .click => self.program.send(.{ .mouse_click = mres.mouse }),
                        .release => self.program.send(.{ .mouse_release = mres.mouse }),
                        .wheel => self.program.send(.{ .mouse_wheel = mres.mouse }),
                        .motion => self.program.send(.{ .mouse_motion = mres.mouse }),
                    }
                    pos += mres.consumed;
                    continue;
                } else if (mres.consumed > 0) {
                    pos += mres.consumed;
                    continue;
                }

                // ESC timeout: POSIX 用 poll 等待更多数据，Windows 仅检查长度
                const is_esc_timeout = remaining[0] == 0x1B and remaining.len == 1 and blk: {
                    if (builtin.os.tag == .windows) break :blk true;
                    var esc_fds = [1]posix.pollfd{
                        .{ .fd = self.input_fd, .events = posix.POLL.IN, .revents = 0 },
                    };
                    const esc_ready = posix.poll(&esc_fds, 50) catch break :blk true;
                    if (esc_ready == 0) break :blk true;
                    const extra = posix.read(self.input_fd, buf[total.*..]) catch break :blk true;
                    if (extra == 0) break :blk true;
                    total.* += extra;
                    break :blk false;
                };

                const kres = key.parseInput(remaining, is_esc_timeout);
                if (kres.key) |k| {
                    if (k.code == .char and k.modifiers.ctrl and (k.char == 'z' or k.char == 'Z')) {
                        self.program.send(.suspend_msg);
                    } else {
                        self.program.send(.{ .key_press = k });
                    }
                    pos += kres.consumed;
                } else if (kres.consumed > 0) {
                    pos += kres.consumed;
                } else {
                    break;
                }
            }

            return pos;
        }

        fn programClosing(program: *ProgramType) bool {
            if (comptime @hasField(ProgramType, "closing")) {
                return program.closing.load(.acquire);
            }
            return false;
        }

        fn appendPasteChunked(program: *ProgramType, dst: *[256]u8, len: *usize, chunk: []const u8) void {
            if (chunk.len == 0) return;

            var off: usize = 0;
            while (off < chunk.len) {
                if (len.* == dst.len) {
                    program.send(.{ .paste = paste_mod.PasteMsg.fromSlice(dst[0..len.*]) });
                    len.* = 0;
                }

                const available = dst.len - len.*;
                const n = @min(available, chunk.len - off);
                @memcpy(dst[len.* .. len.* + n], chunk[off .. off + n]);
                len.* += n;
                off += n;
            }
        }

        fn flushPaste(program: *ProgramType, dst: *[256]u8, len: *usize) void {
            if (len.* == 0) return;
            program.send(.{ .paste = paste_mod.PasteMsg.fromSlice(dst[0..len.*]) });
            len.* = 0;
        }

        fn normalizeCarry(carry: *usize, cap: usize) void {
            if (carry.* >= cap) carry.* = 0;
        }

        const ParseControlResult = struct {
            handled: bool = false,
            consumed: usize = 0,
            need_more: bool = false,
        };

        fn parseTerminalResponse(self: Self, data: []const u8) ParseControlResult {
            if (data.len < 2 or data[0] != 0x1B) return .{};
            return switch (data[1]) {
                '[' => self.parseCsiResponse(data),
                ']' => self.parseOscResponse(data),
                'P' => self.parseDcsResponse(data),
                else => .{},
            };
        }

        fn parseCsiResponse(self: Self, data: []const u8) ParseControlResult {
            if (data.len < 3) return .{};

            const third = data[2];
            if (third >= '0' and third <= '9') {
                // Cursor position report: ESC [ <row> ; <col> R
                var idx: usize = 2;
                const row = parseInt(data, &idx) orelse return .{};
                if (idx >= data.len) return .{ .need_more = true };

                if (data[idx] == 'u') {
                    const ok = self.parseKittyKeyEvent(data[2 .. idx + 1]);
                    return .{ .handled = ok, .consumed = if (ok) idx + 1 else 0 };
                }

                if (data[idx] != ';') return .{};
                idx += 1;
                const col = parseInt(data, &idx) orelse return .{};
                if (idx >= data.len) return .{ .need_more = true };
                const term = data[idx];
                if (term == 'R') {
                    const x = @as(i32, @intCast(@max(@as(i64, 0), @as(i64, col) - 1)));
                    const y = @as(i32, @intCast(@max(@as(i64, 0), @as(i64, row) - 1)));
                    self.program.send(.{ .cursor_position = cursor_mod.CursorPositionMsg{ .x = x, .y = y } });
                    return .{ .handled = true, .consumed = idx + 1 };
                }
                if (term == 'u') {
                    const ok = self.parseKittyKeyEvent(data[2 .. idx + 1]);
                    return .{ .handled = ok, .consumed = if (ok) idx + 1 else 0 };
                }
                if (term == ';') {
                    var u_idx = idx + 1;
                    while (u_idx < data.len and data[u_idx] != 'u') : (u_idx += 1) {}
                    if (u_idx >= data.len) return .{ .need_more = true };
                    const ok = self.parseKittyKeyEvent(data[2 .. u_idx + 1]);
                    return .{ .handled = ok, .consumed = if (ok) u_idx + 1 else 0 };
                }
                if (term == ':') {
                    var u_idx = idx + 1;
                    while (u_idx < data.len and data[u_idx] != 'u') : (u_idx += 1) {}
                    if (u_idx >= data.len) return .{ .need_more = true };
                    const ok = self.parseKittyKeyEvent(data[2 .. u_idx + 1]);
                    return .{ .handled = ok, .consumed = if (ok) u_idx + 1 else 0 };
                }
                return .{};
            }

            if (third == '?') {
                // Mode report: ESC [ ? <mode> ; <value> $ y
                var idx: usize = 3;
                const mode = parseInt(data, &idx) orelse return .{};
                if (idx >= data.len) return .{ .need_more = true };
                if (data[idx] != ';') return .{};
                idx += 1;
                const value_raw = parseInt(data, &idx) orelse return .{};
                if (idx + 1 >= data.len) return .{ .need_more = true };
                if (data[idx] != '$' or data[idx + 1] != 'y') return .{};
                idx += 2;

                self.program.send(.{
                    .mode_report = screen_mod.ModeReportMsg{
                        .mode = @intCast(@max(@as(i64, 0), mode)),
                        .value = modeValueFromInt(value_raw),
                    },
                });
                return .{ .handled = true, .consumed = idx };
            }

            return .{};
        }

        fn parseOscResponse(self: Self, data: []const u8) ParseControlResult {
            if (!std.mem.startsWith(u8, data, "\x1B]")) return .{};
            // 仅在明显为 OSC 响应时解析，避免 Alt+] 等按键前缀被误判。
            if (data.len < 3) return .{};
            const leader = data[2];
            if (leader < '0' or leader > '9') return .{};
            const end = findOscTerminator(data) orelse return .{ .need_more = true };
            if (end.payload_end <= 2) return .{ .handled = true, .consumed = end.total_end };

            const payload = data[2..end.payload_end];
            self.handleOscPayload(payload);
            return .{ .handled = true, .consumed = end.total_end };
        }

        fn parseDcsResponse(self: Self, data: []const u8) ParseControlResult {
            if (!std.mem.startsWith(u8, data, "\x1BP")) return .{};
            // 仅解析当前实现会用到的 DCS 响应前缀，避免 Alt+P 误判。
            if (data.len < 3) return .{};
            const leader = data[2];
            if (leader != '>' and leader != '1' and leader != '+') return .{};
            const end = findStTerminator(data) orelse return .{ .need_more = true };
            if (end.payload_end <= 2) return .{ .handled = true, .consumed = end.total_end };

            const payload = data[2..end.payload_end];
            if (std.mem.startsWith(u8, payload, ">|")) {
                self.program.send(.{ .terminal_version = termcap_mod.TerminalVersionMsg.fromSlice(payload[2..]) });
            } else if (std.mem.startsWith(u8, payload, "1+r")) {
                var decoded: [128]u8 = undefined;
                const capability_content = decodeTermcapPayload(payload[3..], &decoded);
                self.program.send(.{ .capability = termcap_mod.CapabilityMsg.fromSlice(capability_content) });
            } else if (std.mem.startsWith(u8, payload, "+r")) {
                var decoded: [128]u8 = undefined;
                const capability_content = decodeTermcapPayload(payload[2..], &decoded);
                self.program.send(.{ .capability = termcap_mod.CapabilityMsg.fromSlice(capability_content) });
            }

            return .{ .handled = true, .consumed = end.total_end };
        }

        fn parseKittyKeyEvent(self: Self, payload: []const u8) bool {
            // Kitty format: codepoint[:shifted[:base]];modifiers[:event_type][;text]u
            if (payload.len < 2 or payload[payload.len - 1] != 'u') return false;
            const params = payload[0 .. payload.len - 1];
            const semi = std.mem.indexOfScalar(u8, params, ';') orelse {
                const key_codepoint_only = parseLeadingIntSlice(params) orelse return false;
                const kev_only = keyEventFromCodepoint(key_codepoint_only, .{}) orelse return false;
                self.program.send(.{ .key_press = kev_only });
                return true;
            };

            const key_part = params[0..semi];
            const rest = params[semi + 1 ..];
            const next_semi = std.mem.indexOfScalar(u8, rest, ';');
            const mod_part = if (next_semi) |idx| rest[0..idx] else rest;
            const text_part = if (next_semi) |idx| rest[idx + 1 ..] else "";

            // Parse key_part: codepoint[:shifted[:base]]
            const key_codepoint = parseLeadingIntSlice(key_part) orelse return false;
            var shifted_code: u21 = 0;
            var base_code: u21 = 0;
            if (std.mem.indexOfScalar(u8, key_part, ':')) |colon1| {
                const after1 = key_part[colon1 + 1 ..];
                if (parseLeadingIntSlice(after1)) |sc| {
                    shifted_code = @intCast(@max(@as(i64, 0), @min(sc, 0x10FFFF)));
                }
                if (std.mem.indexOfScalar(u8, after1, ':')) |colon2| {
                    if (parseLeadingIntSlice(after1[colon2 + 1 ..])) |bc| {
                        base_code = @intCast(@max(@as(i64, 0), @min(bc, 0x10FFFF)));
                    }
                }
            }

            // Parse mod_part: modifiers[:event_type]
            const mod_raw = parseLeadingIntSlice(mod_part) orelse 1;
            var event_type: i64 = blk: {
                const colon = std.mem.indexOfScalar(u8, mod_part, ':') orelse break :blk 1;
                break :blk parseLeadingIntSlice(mod_part[colon + 1 ..]) orelse 1;
            };

            // 兼容旧格式：第三个 ; 分隔字段如果是 1-3 的数字，视为 event_type
            var actual_text = text_part;
            if (event_type == 1 and text_part.len > 0 and text_part.len <= 1) {
                if (parseLeadingIntSlice(text_part)) |et| {
                    if (et >= 1 and et <= 3) {
                        event_type = et;
                        actual_text = "";
                    }
                }
            }

            const mods = decodeModParam(@intCast(@max(@as(i64, 1), mod_raw)));
            var kev = keyEventFromCodepoint(key_codepoint, mods) orelse return false;
            kev.shifted_code = shifted_code;
            kev.base_code = base_code;
            kev.is_repeat = (event_type == 2);

            // Associated text
            if (actual_text.len > 0) {
                const n = @min(actual_text.len, kev.text.len);
                @memcpy(kev.text[0..n], actual_text[0..n]);
                kev.text_len = @intCast(n);
            }

            if (event_type == 3) {
                self.program.send(.{ .key_release = kev });
            } else {
                self.program.send(.{ .key_press = kev });
            }
            return true;
        }

        fn handleOscPayload(self: Self, payload: []const u8) void {
            if (std.mem.startsWith(u8, payload, "10;")) {
                if (parseOscColor(payload[3..])) |rgb| {
                    self.program.send(.{ .foreground_color = .{ .color = rgb } });
                }
                return;
            }
            if (std.mem.startsWith(u8, payload, "11;")) {
                if (parseOscColor(payload[3..])) |rgb| {
                    self.program.send(.{ .background_color = .{ .color = rgb } });
                }
                return;
            }
            if (std.mem.startsWith(u8, payload, "12;")) {
                if (parseOscColor(payload[3..])) |rgb| {
                    self.program.send(.{ .cursor_color = .{ .color = rgb } });
                }
                return;
            }
            if (std.mem.startsWith(u8, payload, "52;")) {
                self.handleOsc52Clipboard(payload[3..]);
            }
        }

        fn handleOsc52Clipboard(self: Self, payload: []const u8) void {
            const sel_end = std.mem.indexOfScalar(u8, payload, ';') orelse return;
            const sel = payload[0..sel_end];
            const encoded = payload[sel_end + 1 ..];
            if (std.mem.eql(u8, encoded, "?")) return;

            const max_decoded = (clipboard_mod.ClipboardMsg{}).buf.data.len;
            const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return;
            if (decoded_len > max_decoded) return;

            var decoded: [256]u8 = undefined;
            std.base64.standard.Decoder.decode(decoded[0..decoded_len], encoded) catch return;
            const selection = if (sel.len > 0 and sel[0] == 'p') clipboard_mod.ClipboardSelection.primary else clipboard_mod.ClipboardSelection.system;
            self.program.send(.{ .clipboard = clipboard_mod.ClipboardMsg.fromSlice(decoded[0..decoded_len], selection) });
        }

        fn parseOscColor(s: []const u8) ?color_mod.RgbColor {
            if (std.mem.startsWith(u8, s, "rgb:")) {
                const body = s[4..];
                const idx1 = std.mem.indexOfScalar(u8, body, '/') orelse return null;
                const idx2_rel = std.mem.indexOfScalar(u8, body[idx1 + 1 ..], '/') orelse return null;
                const idx2 = idx1 + 1 + idx2_rel;

                const r = parseHexChannel(body[0..idx1]) orelse return null;
                const g = parseHexChannel(body[idx1 + 1 .. idx2]) orelse return null;
                const b = parseHexChannel(body[idx2 + 1 ..]) orelse return null;
                return .{ .r = r, .g = g, .b = b };
            }

            if (s.len == 7 and s[0] == '#') {
                const r = std.fmt.parseInt(u8, s[1..3], 16) catch return null;
                const g = std.fmt.parseInt(u8, s[3..5], 16) catch return null;
                const b = std.fmt.parseInt(u8, s[5..7], 16) catch return null;
                return .{ .r = r, .g = g, .b = b };
            }
            return null;
        }

        fn parseHexChannel(s: []const u8) ?u8 {
            if (s.len == 0) return null;
            const v = std.fmt.parseInt(u16, s, 16) catch return null;
            return switch (s.len) {
                1 => @as(u8, @intCast(v * 17)),
                2 => @as(u8, @intCast(v)),
                3 => @as(u8, @intCast(v >> 4)),
                4 => @as(u8, @intCast(v >> 8)),
                else => null,
            };
        }

        fn decodeTermcapPayload(raw: []const u8, dst: *[128]u8) []const u8 {
            const eq_idx = std.mem.indexOfScalar(u8, raw, '=') orelse raw.len;
            const encoded_name = raw[0..eq_idx];
            const encoded_value = if (eq_idx < raw.len) raw[eq_idx + 1 ..] else "";

            var tmp_name: [64]u8 = undefined;
            const name = decodeHexAscii(encoded_name, &tmp_name) orelse encoded_name;

            if (eq_idx >= raw.len) {
                const nn = @min(name.len, dst.len);
                @memcpy(dst[0..nn], name[0..nn]);
                return dst[0..nn];
            }

            var tmp_value: [63]u8 = undefined;
            const value = decodeHexAscii(encoded_value, &tmp_value) orelse encoded_value;

            const name_len = @min(name.len, dst.len);
            @memcpy(dst[0..name_len], name[0..name_len]);
            if (name_len >= dst.len) return dst[0..name_len];

            dst[name_len] = '=';
            const remain = dst.len - name_len - 1;
            const value_len = @min(value.len, remain);
            @memcpy(dst[name_len + 1 .. name_len + 1 + value_len], value[0..value_len]);
            return dst[0 .. name_len + 1 + value_len];
        }

        fn decodeHexAscii(src: []const u8, dst: anytype) ?[]const u8 {
            if (src.len == 0 or src.len % 2 != 0) return null;
            const out_len = src.len / 2;
            if (out_len > dst.len) return null;

            var i: usize = 0;
            while (i < src.len) : (i += 2) {
                const hi = std.fmt.charToDigit(src[i], 16) catch return null;
                const lo = std.fmt.charToDigit(src[i + 1], 16) catch return null;
                dst[i / 2] = @as(u8, @intCast((hi << 4) | lo));
            }
            return dst[0..out_len];
        }

        fn parseInt(data: []const u8, idx: *usize) ?i64 {
            return key.parseDigits(data, idx);
        }

        fn parseLeadingIntSlice(s: []const u8) ?i64 {
            var idx: usize = 0;
            return parseInt(s, &idx);
        }

        fn decodeModParam(raw: u16) key.Modifiers {
            return key.decodeModifiers(raw);
        }

        fn keyEventFromCodepoint(cp: i64, mods: key.Modifiers) ?key.KeyEvent {
            if (cp < 0 or cp > 0x10FFFF) return null;
            const ucp: u21 = @intCast(cp);
            // C0 control codes
            if (ucp == 9) return .{ .code = .tab, .modifiers = mods };
            if (ucp == 13) return .{ .code = .enter, .modifiers = mods };
            if (ucp == 27) return .{ .code = .escape, .modifiers = mods };
            if (ucp == 127) return .{ .code = .backspace, .modifiers = mods };
            if (ucp == ' ') return .{ .code = .space, .char = ' ', .modifiers = mods };
            // Kitty extended key codes (0xE000+)
            const kc: ?key.KeyCode = switch (ucp) {
                57358 => .caps_lock,
                57359 => .scroll_lock,
                57360 => .num_lock,
                57361 => .print_screen,
                57362 => .pause,
                57363 => .menu,
                // F13-F35
                57376...57398 => @enumFromInt(@intFromEnum(key.KeyCode.f13) + (ucp - 57376)),
                // Keypad
                57399 => .kp_0,
                57400 => .kp_1,
                57401 => .kp_2,
                57402 => .kp_3,
                57403 => .kp_4,
                57404 => .kp_5,
                57405 => .kp_6,
                57406 => .kp_7,
                57407 => .kp_8,
                57408 => .kp_9,
                57409 => .kp_decimal,
                57410 => .kp_divide,
                57411 => .kp_multiply,
                57412 => .kp_minus,
                57413 => .kp_plus,
                57414 => .kp_enter,
                57415 => .kp_equal,
                57416 => .kp_separator,
                57417 => .kp_left,
                57418 => .kp_right,
                57419 => .kp_up,
                57420 => .kp_down,
                57421 => .kp_page_up,
                57422 => .kp_page_down,
                57423 => .kp_home,
                57424 => .kp_end,
                57425 => .kp_insert,
                57426 => .kp_delete,
                57427 => .kp_begin,
                // Media
                57428 => .media_play,
                57429 => .media_pause,
                57430 => .media_play_pause,
                57431 => .media_reverse,
                57432 => .media_stop,
                57433 => .media_fast_forward,
                57434 => .media_rewind,
                57435 => .media_next,
                57436 => .media_prev,
                57437 => .media_record,
                57438 => .lower_vol,
                57439 => .raise_vol,
                57440 => .mute,
                // Modifier keys
                57441 => .left_shift,
                57442 => .left_ctrl,
                57443 => .left_alt,
                57444 => .left_super,
                57445 => .left_hyper,
                57446 => .left_meta,
                57447 => .right_shift,
                57448 => .right_ctrl,
                57449 => .right_alt,
                57450 => .right_super,
                57451 => .right_hyper,
                57452 => .right_meta,
                else => null,
            };
            if (kc) |code| return .{ .code = code, .modifiers = mods };
            return .{ .code = .char, .char = ucp, .modifiers = mods };
        }

        fn modeValueFromInt(v: i64) screen_mod.ModeReportValue {
            return switch (v) {
                1 => .set,
                2 => .reset,
                3 => .permanently_set,
                4 => .permanently_reset,
                else => .not_recognized,
            };
        }

        const TermEnd = struct {
            payload_end: usize,
            total_end: usize,
        };

        fn findOscTerminator(data: []const u8) ?TermEnd {
            var i: usize = 2;
            while (i < data.len) : (i += 1) {
                if (data[i] == 0x07) {
                    return .{ .payload_end = i, .total_end = i + 1 };
                }
                if (data[i] == 0x1B and i + 1 < data.len and data[i + 1] == '\\') {
                    return .{ .payload_end = i, .total_end = i + 2 };
                }
            }
            return null;
        }

        fn findStTerminator(data: []const u8) ?TermEnd {
            var i: usize = 2;
            while (i < data.len) : (i += 1) {
                if (data[i] == 0x1B and i + 1 < data.len and data[i + 1] == '\\') {
                    return .{ .payload_end = i, .total_end = i + 2 };
                }
                if (data[i] == 0x07) {
                    return .{ .payload_end = i, .total_end = i + 1 };
                }
            }
            return null;
        }
    };
}

const testing = std.testing;

const ReaderTestProgram = struct {
    messages: [16]Msg = undefined,
    len: usize = 0,

    pub fn send(self: *ReaderTestProgram, m: Msg) void {
        if (self.len >= self.messages.len) return;
        self.messages[self.len] = m;
        self.len += 1;
    }
};

fn createTestReader(program: *ReaderTestProgram) InputReader(ReaderTestProgram) {
    return .{
        .program = program,
        .input_fd = invalidFd(),
        .quit_fd = invalidFd(),
        .sigwinch_fd = null,
        .output_fd = invalidFd(),
    };
}

fn invalidFd() posix.fd_t {
    if (builtin.os.tag == .windows) {
        return @as(posix.fd_t, @ptrFromInt(std.math.maxInt(usize)));
    }
    return -1;
}

test "reader: parses CSI mode report" {
    var p = ReaderTestProgram{};
    const Reader = InputReader(ReaderTestProgram);
    const reader = createTestReader(&p);

    const seq = "\x1B[?2027;1$y";
    const result = Reader.parseTerminalResponse(reader, seq);
    try testing.expect(result.handled);
    try testing.expectEqual(seq.len, result.consumed);
    try testing.expectEqual(@as(usize, 1), p.len);
    try testing.expect(p.messages[0] == .mode_report);
    try testing.expectEqual(@as(u16, 2027), p.messages[0].mode_report.mode);
    try testing.expect(p.messages[0].mode_report.value == .set);
}

test "reader: parses DCS termcap reply and decodes hex payload" {
    var p = ReaderTestProgram{};
    const Reader = InputReader(ReaderTestProgram);
    const reader = createTestReader(&p);

    const seq = "\x1BP1+r5463=31\x1B\\";
    const result = Reader.parseTerminalResponse(reader, seq);
    try testing.expect(result.handled);
    try testing.expectEqual(seq.len, result.consumed);
    try testing.expectEqual(@as(usize, 1), p.len);
    try testing.expect(p.messages[0] == .capability);
    try testing.expectEqualStrings("Tc=1", p.messages[0].capability.slice());
    try testing.expectEqualStrings("Tc", p.messages[0].capability.nameSlice());
    try testing.expectEqualStrings("1", p.messages[0].capability.valueSlice());
}

test "reader: parses kitty key release event" {
    var p = ReaderTestProgram{};
    const Reader = InputReader(ReaderTestProgram);
    const reader = createTestReader(&p);

    const seq = "\x1B[97;1:3u";
    const result = Reader.parseTerminalResponse(reader, seq);
    try testing.expect(result.handled);
    try testing.expectEqual(seq.len, result.consumed);
    try testing.expectEqual(@as(usize, 1), p.len);
    try testing.expect(p.messages[0] == .key_release);
    try testing.expect(p.messages[0].key_release.code == .char);
    try testing.expectEqual(@as(u21, 'a'), p.messages[0].key_release.char);
}

test "reader: parses kitty key press with default modifiers" {
    var p = ReaderTestProgram{};
    const Reader = InputReader(ReaderTestProgram);
    const reader = createTestReader(&p);

    const seq = "\x1B[97u";
    const result = Reader.parseTerminalResponse(reader, seq);
    try testing.expect(result.handled);
    try testing.expectEqual(seq.len, result.consumed);
    try testing.expectEqual(@as(usize, 1), p.len);
    try testing.expect(p.messages[0] == .key_press);
    try testing.expect(p.messages[0].key_press.code == .char);
    try testing.expectEqual(@as(u21, 'a'), p.messages[0].key_press.char);
}

test "reader: parses kitty key release event with third parameter form" {
    var p = ReaderTestProgram{};
    const Reader = InputReader(ReaderTestProgram);
    const reader = createTestReader(&p);

    const seq = "\x1B[97;1;3u";
    const result = Reader.parseTerminalResponse(reader, seq);
    try testing.expect(result.handled);
    try testing.expectEqual(seq.len, result.consumed);
    try testing.expectEqual(@as(usize, 1), p.len);
    try testing.expect(p.messages[0] == .key_release);
    try testing.expect(p.messages[0].key_release.code == .char);
    try testing.expectEqual(@as(u21, 'a'), p.messages[0].key_release.char);
}

test "reader: normalizeCarry clears full buffer carry" {
    const Reader = InputReader(ReaderTestProgram);
    var carry: usize = 1024;
    Reader.normalizeCarry(&carry, 1024);
    try testing.expectEqual(@as(usize, 0), carry);
}

test "reader: chunked paste emits multiple messages without truncation" {
    var p = ReaderTestProgram{};
    const Reader = InputReader(ReaderTestProgram);
    var paste_buf: [256]u8 = undefined;
    var paste_len: usize = 0;

    var chunk: [700]u8 = undefined;
    @memset(chunk[0..], 'p');

    Reader.appendPasteChunked(&p, &paste_buf, &paste_len, &chunk);
    try testing.expectEqual(@as(usize, 2), p.len);
    try testing.expect(p.messages[0] == .paste);
    try testing.expectEqual(@as(u16, 256), p.messages[0].paste.len);
    try testing.expect(p.messages[1] == .paste);
    try testing.expectEqual(@as(u16, 256), p.messages[1].paste.len);
    try testing.expectEqual(@as(usize, 188), paste_len);

    Reader.flushPaste(&p, &paste_buf, &paste_len);
    try testing.expectEqual(@as(usize, 3), p.len);
    try testing.expect(p.messages[2] == .paste);
    try testing.expectEqual(@as(u16, 188), p.messages[2].paste.len);
    try testing.expectEqual(@as(usize, 0), paste_len);
}

test "reader: does not treat Alt+] prefix as OSC response" {
    var p = ReaderTestProgram{};
    const Reader = InputReader(ReaderTestProgram);
    const reader = createTestReader(&p);

    const seq = "\x1B]x";
    const result = Reader.parseTerminalResponse(reader, seq);
    try testing.expect(!result.handled);
    try testing.expectEqual(@as(usize, 0), result.consumed);
    try testing.expect(!result.need_more);
    try testing.expectEqual(@as(usize, 0), p.len);
}

test "reader: does not treat Alt+P prefix as DCS response" {
    var p = ReaderTestProgram{};
    const Reader = InputReader(ReaderTestProgram);
    const reader = createTestReader(&p);

    const seq = "\x1BPx";
    const result = Reader.parseTerminalResponse(reader, seq);
    try testing.expect(!result.handled);
    try testing.expectEqual(@as(usize, 0), result.consumed);
    try testing.expect(!result.need_more);
    try testing.expectEqual(@as(usize, 0), p.len);
}

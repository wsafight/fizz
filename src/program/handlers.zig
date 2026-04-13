/// 消息处理、终端 I/O、渲染器管理、环境检测。
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const msg_mod = @import("../msg.zig");
const cmd_mod = @import("../cmd.zig");
const options_mod = @import("../options.zig");
const signals_mod = @import("../platform/signals.zig");
const renderer_mod = @import("../renderer/renderer.zig");
const cursed_renderer_mod = @import("../renderer/cursed.zig");
const nil_renderer_mod = @import("../renderer/nil.zig");
const clipboard_mod = @import("../clipboard.zig");
const environ_mod = @import("../environ.zig");
const exec_mod = @import("../exec.zig");
const mouse_mod = @import("../input/mouse.zig");
const profile_mod = @import("../profile.zig");
const screen_mod = @import("../screen.zig");
const termcap_mod = @import("../termcap.zig");
const tty_mod = @import("../platform/tty.zig");

const Msg = msg_mod.Msg;

pub fn Handlers(comptime Self: type) type {
    return struct {
        // ── Renderer management ──────────────────────────────────

        pub fn initRenderer(self: *Self, width: u16, height: u16) void {
            if (self.opts.disable_renderer) {
                self.nil_renderer = nil_renderer_mod.NilRenderer.init(self.out_file, width, height);
                self.renderer = self.nil_renderer.asRenderer();
            } else {
                self.cursed_renderer = cursed_renderer_mod.CursedRenderer.initWithAboveConfig(
                    self.out_file,
                    width,
                    height,
                    self.opts.allocator,
                    self.opts.above_line_count,
                    self.opts.above_line_bytes,
                );
                self.renderer = self.cursed_renderer.asRenderer();
            }

            if (self.renderer) |r| {
                r.start();
                if (self.opts.color_profile) |cp| {
                    r.setColorProfile(cp);
                }
            }
        }

        pub fn shutdownRenderer(self: *Self) void {
            if (self.renderer) |r| {
                flushRenderer(self, true, true);
                r.close() catch |err| {
                    std.log.err("renderer close failed: {}", .{err});
                };
            }
            self.renderer = null;
        }

        pub fn flushRenderer(self: *Self, force: bool, closing: bool) void {
            const r = self.renderer orelse return;
            if (!force) {
                const interval_ns: i128 = @divTrunc(@as(i128, std.time.ns_per_s), @as(i128, self.opts.fps));
                const now = std.time.nanoTimestamp();
                if (self.last_flush_ns != 0 and (now - self.last_flush_ns) < interval_ns) {
                    _ = self.stats.flush_throttled.fetchAdd(1, .monotonic);
                    return;
                }
                self.last_flush_ns = now;
            }
            r.flush(closing) catch |err| {
                std.log.err("renderer flush failed: {}", .{err});
            };
        }

        pub fn writeToTerminal(self: *Self, s: []const u8) void {
            if (s.len == 0) return;
            if (self.renderer) |r| {
                _ = r.writeString(s) catch |err| {
                    std.log.err("renderer write failed: {}", .{err});
                };
                return;
            }
            self.out_file.writeAll(s) catch |err| {
                std.log.err("terminal write failed: {}", .{err});
            };
        }

        // ── Pre-update effects ───────────────────────────────────

        pub fn applyPreUpdateEffects(self: *Self, m: Msg) void {
            switch (m) {
                .window_size => |sz| {
                    if (self.renderer) |r| r.resize(sz.width, sz.height);
                },
                .mode_report => |mr| applyModeReport(self, mr),
                .mouse_click => |mm| dispatchMouse(self, .click, mm),
                .mouse_release => |mm| dispatchMouse(self, .release, mm),
                .mouse_wheel => |mm| dispatchMouse(self, .wheel, mm),
                .mouse_motion => |mm| dispatchMouse(self, .motion, mm),
                .capability => |cap| applyCapability(self, cap),
                .terminal_version => |tv| applyTerminalVersion(self, tv),
                .suspend_msg => suspendProcess(self),
                else => {},
            }
        }

        pub fn handleInternalMessage(self: *Self, m: Msg) bool {
            switch (m) {
                .clear_screen => {
                    if (self.renderer) |r| r.clearScreen();
                    return true;
                },
                .raw => |raw_msg| {
                    writeToTerminal(self, raw_msg.slice());
                    return true;
                },
                .print_line => |line| {
                    if (self.renderer) |r| {
                        r.insertAbove(line.slice()) catch {};
                    } else {
                        writeToTerminal(self, line.slice());
                        writeToTerminal(self, "\n");
                    }
                    return true;
                },
                .request_window_size => {
                    if (signals_mod.getTerminalSize(self.out_file.handle)) |sz| {
                        self.send(.{ .window_size = .{ .width = sz.width, .height = sz.height } });
                    } else |_| {}
                    return true;
                },
                .request_background_color => {
                    writeToTerminal(self, "\x1B]11;?\x07");
                    return true;
                },
                .request_foreground_color => {
                    writeToTerminal(self, "\x1B]10;?\x07");
                    return true;
                },
                .request_cursor_color => {
                    writeToTerminal(self, "\x1B]12;?\x07");
                    return true;
                },
                .request_cursor_position => {
                    writeToTerminal(self, "\x1B[6n");
                    return true;
                },
                .request_capability => |req| {
                    writeTermcapQuery(self, req.slice());
                    return true;
                },
                .request_terminal_version => {
                    writeToTerminal(self, "\x1B[>0q");
                    return true;
                },
                .set_clipboard => |set_msg| {
                    writeOsc52Set(self, set_msg.selection, set_msg.slice());
                    return true;
                },
                .read_clipboard => |read_msg| {
                    writeOsc52Query(self, read_msg.selection);
                    return true;
                },
                .run_exec => {
                    drainPendingExecQueue(self);
                    return true;
                },
                else => return false,
            }
        }

        pub fn forceFlushAfterInternalMessage(m: Msg) bool {
            return switch (m) {
                .request_window_size, .run_exec => false,
                else => true,
            };
        }

        // ── Exec queue ───────────────────────────────────────────

        pub fn enqueueExecOnMainThread(self: *Self, req: exec_mod.ExecRequestMsg) void {
            if (self.closing.load(.acquire)) return;

            const ExecNode = Self.ExecNode;
            const node = self.opts.allocator.create(ExecNode) catch {
                handleExec(self, req);
                return;
            };
            node.* = .{ .req = req };

            self.pending_exec_mutex.lock();
            if (self.pending_exec_tail) |tail| {
                tail.next = node;
            } else {
                self.pending_exec_head = node;
            }
            self.pending_exec_tail = node;
            self.pending_exec_mutex.unlock();

            self.send(.run_exec);

            node.done_mutex.lock();
            while (!node.done) {
                node.done_cond.wait(&node.done_mutex);
            }
            node.done_mutex.unlock();
            self.opts.allocator.destroy(node);
        }

        fn drainPendingExecQueue(self: *Self) void {
            while (true) {
                self.pending_exec_mutex.lock();
                const node = self.pending_exec_head orelse {
                    self.pending_exec_tail = null;
                    self.pending_exec_mutex.unlock();
                    break;
                };
                self.pending_exec_head = node.next;
                if (self.pending_exec_head == null) {
                    self.pending_exec_tail = null;
                }
                node.next = null;
                self.pending_exec_mutex.unlock();

                handleExec(self, node.req);

                node.done_mutex.lock();
                node.done = true;
                node.done_cond.broadcast();
                node.done_mutex.unlock();
            }
        }

        pub fn cancelPendingExecQueue(self: *Self) void {
            while (true) {
                self.pending_exec_mutex.lock();
                const node = self.pending_exec_head orelse {
                    self.pending_exec_tail = null;
                    self.pending_exec_mutex.unlock();
                    break;
                };
                self.pending_exec_head = node.next;
                if (self.pending_exec_head == null) {
                    self.pending_exec_tail = null;
                }
                node.next = null;
                self.pending_exec_mutex.unlock();

                node.done_mutex.lock();
                node.done = true;
                node.done_cond.broadcast();
                node.done_mutex.unlock();
            }
        }

        pub fn handleExec(self: *Self, req: exec_mod.ExecRequestMsg) void {
            var arena = std.heap.ArenaAllocator.init(self.opts.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            if (req.truncated) {
                sendExecResult(self, req, exec_mod.ExecResultMsg.fail(-1, "argv exceeds max_args/max_arg_len"));
                return;
            }

            if (req.len == 0) {
                sendExecResult(self, req, exec_mod.ExecResultMsg.fail(-1, "empty argv"));
                return;
            }

            var argv_buf: [exec_mod.ExecRequestMsg.max_args][]const u8 = undefined;
            var i: usize = 0;
            while (i < req.len) : (i += 1) {
                argv_buf[i] = req.args[i].slice();
            }
            const argv = argv_buf[0..req.len];

            flushRenderer(self, true, false);
            self.releaseTerminal();
            defer self.restoreTerminal();
            defer self.send(.request_window_size);
            defer flushRenderer(self, true, false);

            var child = std.process.Child.init(argv, alloc);
            child.stdin_behavior = .Inherit;
            child.stdout_behavior = .Inherit;
            child.stderr_behavior = .Inherit;

            const term = child.spawnAndWait() catch |err| {
                sendExecResult(self, req, exec_mod.ExecResultMsg.fail(-1, @errorName(err)));
                return;
            };

            const result = switch (term) {
                .Exited => |code| if (code == 0)
                    exec_mod.ExecResultMsg.ok()
                else
                    exec_mod.ExecResultMsg.fail(@as(i32, @intCast(code)), "process exited"),
                .Signal => |sig| blk: {
                    var buf: [32]u8 = undefined;
                    const text = std.fmt.bufPrint(&buf, "signal {d}", .{sig}) catch "signaled";
                    break :blk exec_mod.ExecResultMsg.fail(-1, text);
                },
                else => exec_mod.ExecResultMsg.fail(-1, "process terminated"),
            };

            sendExecResult(self, req, result);
        }

        fn sendExecResult(self: *Self, req: exec_mod.ExecRequestMsg, result: exec_mod.ExecResultMsg) void {
            if (req.callback) |cb| {
                self.send(cb(result));
            } else {
                self.send(.{ .exec_result = result });
            }
        }

        // ── Terminal detection / I/O ─────────────────────────────

        fn dispatchMouse(self: *Self, kind: mouse_mod.MouseEventKind, m: mouse_mod.Mouse) void {
            if (self.renderer) |r| {
                if (r.onMouse(kind, m)) |mouse_cmd| {
                    self.spawnCmd(mouse_cmd);
                }
            }
        }

        fn applyModeReport(self: *Self, mr: screen_mod.ModeReportMsg) void {
            const r = self.renderer orelse return;
            if (mr.mode == 2026) {
                switch (mr.value) {
                    .set, .permanently_set => r.setSyncdUpdates(true),
                    .reset, .permanently_reset, .not_recognized => r.setSyncdUpdates(false),
                }
            }

            if (mr.mode == 2027) {
                switch (mr.value) {
                    .set, .permanently_set => r.setWidthMethod(.grapheme),
                    .reset, .permanently_reset, .not_recognized => r.setWidthMethod(.cell),
                }
            }
        }

        fn applyCapability(self: *Self, cap: termcap_mod.CapabilityMsg) void {
            const capability_name = cap.nameSlice();
            if (std.mem.eql(u8, capability_name, "RGB") or std.mem.eql(u8, capability_name, "Tc")) {
                if (self.renderer) |r| r.setColorProfile(.truecolor);
                self.send(.{ .color_profile = .{ .profile = .truecolor } });
            }
        }

        fn applyTerminalVersion(self: *Self, tv: termcap_mod.TerminalVersionMsg) void {
            const term_name = tv.nameSlice();
            if (!isKnownTruecolorTerminal(term_name)) return;
            if (self.renderer) |r| r.setColorProfile(.truecolor);
            self.send(.{ .color_profile = .{ .profile = .truecolor } });
        }

        fn suspendProcess(self: *Self) void {
            if (builtin.os.tag == .windows) {
                self.send(.resume_msg);
                return;
            }
            self.releaseTerminal();
            flushRenderer(self, true, false);
            posix.raise(posix.SIG.TSTP) catch {};
            self.restoreTerminal();
            self.send(.request_window_size);
            flushRenderer(self, true, false);
            self.send(.resume_msg);
        }

        pub fn sendRuntimeInfo(self: *Self) void {
            var arena = std.heap.ArenaAllocator.init(self.opts.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            self.send(.{ .keyboard_enhancements = .{ .flags = 0 } });
            self.send(.{ .color_profile = .{ .profile = detectColorProfile(self, alloc) } });

            if (self.opts.environment) |env_msg| {
                self.pending_env = env_msg;
                self.send(.{ .env = &self.pending_env.? });
                return;
            }

            var env_map = std.process.getEnvMap(alloc) catch return;
            defer env_map.deinit();

            const env_msg = environ_mod.EnvMsg.fromMap(&env_map);
            self.pending_env = env_msg;
            self.send(.{ .env = &self.pending_env.? });
        }

        fn detectColorProfile(self: *Self, alloc: std.mem.Allocator) profile_mod.ColorProfile {
            if (getEnvFallback(self, "COLORTERM", alloc)) |v| {
                if (std.mem.indexOf(u8, v, "truecolor") != null or std.mem.indexOf(u8, v, "24bit") != null) return .truecolor;
            }

            if (getEnvFallback(self, "TERM", alloc)) |v| {
                if (std.mem.indexOf(u8, v, "256color") != null) return .ansi256;
                if (std.mem.indexOf(u8, v, "color") != null) return .ansi16;
            }

            return .unknown;
        }

        fn lookupEnv(self: *Self, key: []const u8) ?[]const u8 {
            if (self.opts.environment) |env_msg| {
                return env_msg.lookupEnv(key);
            }
            return null;
        }

        fn getEnvFallback(self: *Self, key: []const u8, alloc: std.mem.Allocator) ?[]const u8 {
            if (lookupEnv(self, key)) |v| return v;
            if (self.opts.environment != null) return null;
            return std.process.getEnvVarOwned(alloc, key) catch null;
        }

        fn writeOsc52Set(self: *Self, selection: clipboard_mod.ClipboardSelection, content: []const u8) void {
            const encoded_len = std.base64.standard.Encoder.calcSize(content.len);
            if (encoded_len > 1024) return;

            var encoded: [1024]u8 = undefined;
            _ = std.base64.standard.Encoder.encode(encoded[0..encoded_len], content);

            var prefix: [16]u8 = undefined;
            const start = std.fmt.bufPrint(&prefix, "\x1B]52;{c};", .{@as(u8, @intFromEnum(selection))}) catch return;
            writeToTerminal(self, start);
            writeToTerminal(self, encoded[0..encoded_len]);
            writeToTerminal(self, "\x07");
        }

        fn writeOsc52Query(self: *Self, selection: clipboard_mod.ClipboardSelection) void {
            var seq: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&seq, "\x1B]52;{c};?\x07", .{@as(u8, @intFromEnum(selection))}) catch return;
            writeToTerminal(self, s);
        }

        fn writeTermcapQuery(self: *Self, name: []const u8) void {
            if (name.len == 0) return;

            var seq: [256]u8 = undefined;
            var idx: usize = 0;
            const prefix_str = "\x1BP+q";
            if (prefix_str.len > seq.len) return;
            @memcpy(seq[idx .. idx + prefix_str.len], prefix_str);
            idx += prefix_str.len;

            for (name) |ch| {
                if (idx + 2 >= seq.len) return;
                seq[idx] = hexNibble((ch >> 4) & 0x0F);
                seq[idx + 1] = hexNibble(ch & 0x0F);
                idx += 2;
            }

            const suffix = "\x1B\\";
            if (idx + suffix.len > seq.len) return;
            @memcpy(seq[idx .. idx + suffix.len], suffix);
            idx += suffix.len;
            writeToTerminal(self, seq[0..idx]);
        }

        pub fn requestRendererModeReports(self: *Self) void {
            writeToTerminal(self, "\x1B[?2026$p\x1B[?2027$p");
        }

        pub fn shouldQuerySynchronizedOutput(self: *Self) bool {
            var buf: [512]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            return shouldQuerySynchronizedOutputWith(self, fba.allocator());
        }

        fn shouldQuerySynchronizedOutputWith(self: *Self, alloc: std.mem.Allocator) bool {
            const term = getEnvFallback(self, "TERM", alloc) orelse "";
            const term_program = getEnvFallback(self, "TERM_PROGRAM", alloc);
            const has_ssh_tty = getEnvFallback(self, "SSH_TTY", alloc) != null;
            const has_wt_session = getEnvFallback(self, "WT_SESSION", alloc) != null;

            if (term_program == null and !has_ssh_tty) return true;
            if (has_wt_session) return true;

            if (term_program) |tp| {
                if (!containsCaseInsensitive(tp, "apple") and !has_ssh_tty) return true;
            }

            return containsCaseInsensitive(term, "ghostty") or
                containsCaseInsensitive(term, "wezterm") or
                containsCaseInsensitive(term, "alacritty") or
                containsCaseInsensitive(term, "kitty") or
                containsCaseInsensitive(term, "rio");
        }

        // ── Utilities ────────────────────────────────────────────

        fn hexNibble(v: u8) u8 {
            return if (v < 10) ('0' + v) else ('A' + (v - 10));
        }

        fn containsCaseInsensitive(haystack: []const u8, comptime needle: []const u8) bool {
            if (needle.len == 0) return true;
            if (needle.len > haystack.len) return false;

            var i: usize = 0;
            while (i + needle.len <= haystack.len) : (i += 1) {
                var j: usize = 0;
                while (j < needle.len) : (j += 1) {
                    if (std.ascii.toLower(haystack[i + j]) != needle[j]) break;
                }
                if (j == needle.len) return true;
            }
            return false;
        }

        fn isKnownTruecolorTerminal(name: []const u8) bool {
            return containsCaseInsensitive(name, "ghostty") or
                containsCaseInsensitive(name, "wezterm") or
                containsCaseInsensitive(name, "alacritty") or
                containsCaseInsensitive(name, "kitty") or
                containsCaseInsensitive(name, "rio");
        }
    };
}

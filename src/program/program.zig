/// Program — Bubble Tea 运行时核心
///
/// 泛型 Program(ModelType) 实现 Elm 架构事件循环：
///   model.init() → 初始渲染 → eventLoop(pop → update → cmd → render) → 退出
///
/// run() 内部管理 raw mode、输入读取、信号处理、渲染器与内部命令处理。
///
/// 命令执行逻辑见 program/commands.zig，
/// 消息处理与终端 I/O 见 program/handlers.zig。
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const msg_mod = @import("../msg.zig");
const cmd_mod = @import("../cmd.zig");
const model_mod = @import("../model.zig");
const options_mod = @import("../options.zig");
const queue_mod = @import("../queue.zig");
const tty_mod = @import("../platform/tty.zig");
const signals_mod = @import("../platform/signals.zig");
const reader_mod = @import("../input/reader.zig");
const view_mod = @import("../view.zig");
const renderer_mod = @import("../renderer/renderer.zig");
const cursed_renderer_mod = @import("../renderer/cursed.zig");
const nil_renderer_mod = @import("../renderer/nil.zig");
const environ_mod = @import("../environ.zig");
const exec_mod = @import("../exec.zig");
const mouse_mod = @import("../input/mouse.zig");
const screen_mod = @import("../screen.zig");

const Msg = msg_mod.Msg;
const Cmd = cmd_mod.Cmd;
const SimpleCmd = cmd_mod.SimpleCmd;

pub fn Program(comptime ModelType: type) type {
    comptime {
        model_mod.validateModel(ModelType);
    }

    return struct {
        const Self = @This();
        const Queue = queue_mod.MessageQueue(128);
        const SimpleCmdQueue = queue_mod.BlockingQueue(SimpleCmd, 256);
        const max_workers: usize = 16;

        const commands = @import("commands.zig").Commands(Self);
        const handlers = @import("handlers.zig").Handlers(Self);

        pub fn CoalescedSlot(comptime T: type) type {
            return struct {
                value: T,
                valid: bool = false,
                scheduled: bool = false,
                mutex: std.Thread.Mutex = .{},
            };
        }

        pub const ExecNode = struct {
            next: ?*ExecNode = null,
            req: exec_mod.ExecRequestMsg,
            done_mutex: std.Thread.Mutex = .{},
            done_cond: std.Thread.Condition = .{},
            done: bool = false,
        };

        pub const ExitReason = enum {
            quit,
            interrupt,
            killed,
        };

        pub const RunResult = struct {
            model: *ModelType,
            exit_reason: ExitReason,
        };

        out_file: std.fs.File,
        input_fd: posix.fd_t,
        model: ModelType,
        opts: options_mod.Options,
        msgs: Queue,
        started: bool = false,
        finished: bool = false,
        closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        closing_wait_mutex: std.Thread.Mutex = .{},
        closing_wait_cond: std.Thread.Condition = .{},
        tty_state: ?tty_mod.TtyState = null,
        tty_released: bool = false,
        quit_write_fd: ?posix.fd_t = null,
        renderer: ?renderer_mod.Renderer = null,
        cursed_renderer: cursed_renderer_mod.CursedRenderer = undefined,
        nil_renderer: nil_renderer_mod.NilRenderer = undefined,
        last_flush_ns: i128 = 0,
        active_cmds: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        cmds_mutex: std.Thread.Mutex = .{},
        cmds_done: std.Thread.Condition = .{},
        simple_cmd_queue: SimpleCmdQueue = SimpleCmdQueue.init(),
        simple_cmd_workers: [max_workers]?std.Thread = [_]?std.Thread{null} ** max_workers,
        simple_cmd_workers_started: bool = false,
        simple_cmd_workers_mutex: std.Thread.Mutex = .{},
        fallback_thread_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        pending_env: ?environ_mod.EnvMsg = null,
        pending_window_size: CoalescedSlot(screen_mod.WindowSizeMsg) = .{ .value = .{ .width = 0, .height = 0 } },
        pending_mouse_motion: CoalescedSlot(mouse_mod.Mouse) = .{ .value = .{ .x = 0, .y = 0, .button = .none } },
        pending_exec_head: ?*ExecNode = null,
        pending_exec_tail: ?*ExecNode = null,
        pending_exec_mutex: std.Thread.Mutex = .{},
        finished_mutex: std.Thread.Mutex = .{},
        finished_cond: std.Thread.Condition = .{},
        exit_reason: ExitReason = .quit,
        frame_arena: std.heap.ArenaAllocator = undefined,

        // Throttle/debounce state: last fire time per tag (throttle), generation counter per tag (debounce)
        throttle_last: [32]i128 = [_]i128{0} ** 32,
        debounce_gen: [32]std.atomic.Value(u32) = init_debounce_gen(),

        // Observable metrics
        stats: Stats = .{},

        pub const Stats = struct {
            queue_push_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
            active_cmds_peak: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
            flush_throttled: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
            frames_rendered: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
            fallback_spawns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

            pub fn snapshot(self: *const Stats) StatsSnapshot {
                return .{
                    .queue_push_failures = self.queue_push_failures.load(.monotonic),
                    .active_cmds_peak = self.active_cmds_peak.load(.monotonic),
                    .flush_throttled = self.flush_throttled.load(.monotonic),
                    .frames_rendered = self.frames_rendered.load(.monotonic),
                    .fallback_spawns = self.fallback_spawns.load(.monotonic),
                };
            }
        };

        pub const StatsSnapshot = struct {
            queue_push_failures: u64,
            active_cmds_peak: u32,
            flush_throttled: u64,
            frames_rendered: u64,
            fallback_spawns: u64,
        };

        fn init_debounce_gen() [32]std.atomic.Value(u32) {
            var arr: [32]std.atomic.Value(u32) = undefined;
            for (&arr) |*v| v.* = std.atomic.Value(u32).init(0);
            return arr;
        }

        // ── Construction / destruction ────────────────────────────

        pub fn init(out_file: std.fs.File, model: ModelType) Self {
            return Self.initWithInputAndOptions(out_file, std.fs.File.stdin().handle, model, &.{});
        }

        pub fn initWithOptions(out_file: std.fs.File, model: ModelType, opts: []const options_mod.OptionFn) Self {
            return Self.initWithInputAndOptions(out_file, std.fs.File.stdin().handle, model, opts);
        }

        pub fn initWithInput(out_file: std.fs.File, input_fd: posix.fd_t, model: ModelType) Self {
            return Self.initWithInputAndOptions(out_file, input_fd, model, &.{});
        }

        pub fn initWithInputAndOptions(
            out_file: std.fs.File,
            input_fd: posix.fd_t,
            model: ModelType,
            opts: []const options_mod.OptionFn,
        ) Self {
            const applied_opts = options_mod.applyOptions(.{}, opts);
            return Self{
                .out_file = applied_opts.output_file orelse out_file,
                .input_fd = applied_opts.input_fd orelse input_fd,
                .model = model,
                .opts = applied_opts,
                .msgs = Queue.init(),
                .frame_arena = std.heap.ArenaAllocator.init(applied_opts.allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            handlers.cancelPendingExecQueue(self);
            if (comptime model_mod.hasDeinit(ModelType)) {
                self.model.deinit();
            }
            self.msgs.close();
            self.frame_arena.deinit();
        }

        // ── Public API ───────────────────────────────────────────

        /// 主入口，阻塞直到退出。
        pub fn run(self: *Self) !RunResult {
            self.started = true;
            self.closing.store(false, .release);
            self.last_flush_ns = 0;
            self.exit_reason = .quit;
            self.finished_mutex.lock();
            self.finished = false;
            self.finished_mutex.unlock();
            defer {
                self.finished_mutex.lock();
                self.finished = true;
                self.finished_cond.broadcast();
                self.finished_mutex.unlock();
            }

            var closing_marked = false;
            defer if (!closing_marked) self.markClosing();

            var owns_crash_handlers = false;
            self.tty_state = if (isFdUsable(self.input_fd))
                tty_mod.TtyState.enableRawMode(self.input_fd) catch null
            else
                null;
            self.tty_released = false;

            if (self.tty_state) |ts| {
                if (builtin.os.tag != .windows) {
                    owns_crash_handlers = signals_mod.setupCrashHandlers(self.input_fd, ts.original);
                    signals_mod.setupPanicRestore(self.input_fd, ts.original);
                }
            }
            defer {
                if (owns_crash_handlers) {
                    signals_mod.cleanupCrashHandlers();
                }
                if (builtin.os.tag != .windows) {
                    signals_mod.clearPanicRestore();
                }
                if (self.tty_state) |*ts| ts.restore();
                self.tty_state = null;
                self.tty_released = false;
            }

            var quit_read_fd: ?posix.fd_t = null;
            if (builtin.os.tag != .windows) {
                const quit_pipe = try posix.pipe2(.{ .CLOEXEC = true });
                quit_read_fd = quit_pipe[0];
                self.quit_write_fd = quit_pipe[1];
                defer {
                    posix.close(quit_pipe[0]);
                    if (self.quit_write_fd) |fd| {
                        posix.close(fd);
                        self.quit_write_fd = null;
                    }
                }
            } else {
                self.quit_write_fd = null;
            }

            var sigwinch_fd: ?posix.fd_t = null;
            var owns_sigwinch = false;
            if (!self.opts.disable_signal_handler and !self.opts.disable_signals) {
                sigwinch_fd = signals_mod.setupSigwinch() catch null;
                owns_sigwinch = sigwinch_fd != null;
            }
            defer if (owns_sigwinch) signals_mod.cleanupSigwinch();

            var initial_width: u16 = self.opts.initial_width orelse 0;
            var initial_height: u16 = self.opts.initial_height orelse 0;
            if (initial_width == 0 or initial_height == 0) {
                if (signals_mod.getTerminalSize(self.out_file.handle)) |sz| {
                    initial_width = sz.width;
                    initial_height = sz.height;
                } else |_| {}
            }

            handlers.initRenderer(self, initial_width, initial_height);
            defer handlers.shutdownRenderer(self);

            if (initial_width > 0 and initial_height > 0) {
                self.send(.{ .window_size = .{ .width = initial_width, .height = initial_height } });
            }
            handlers.sendRuntimeInfo(self);
            self.send(.startup);

            const context_thread = if (self.opts.context_cancelled) |ctx|
                std.Thread.spawn(.{}, contextWatcher, .{ self, ctx }) catch null
            else
                null;
            defer if (context_thread) |t| t.join();

            const Reader = reader_mod.InputReader(Self);
            const reader_quit_fd = quit_read_fd orelse self.input_fd;
            const reader_thread = if (isFdUsable(self.input_fd) and (builtin.os.tag == .windows or quit_read_fd != null))
                Reader.start(
                    self,
                    self.input_fd,
                    reader_quit_fd,
                    sigwinch_fd,
                    self.out_file.handle,
                ) catch null
            else
                null;

            if (!self.opts.disable_renderer and handlers.shouldQuerySynchronizedOutput(self)) {
                handlers.requestRendererModeReports(self);
            }

            defer commands.stopSimpleCmdWorkers(self);

            const init_cmd = self.model.init();
            if (init_cmd) |c| {
                self.spawnCmd(c);
            }

            self.render();
            handlers.flushRenderer(self, true, false);

            self.eventLoop();
            self.markClosing();
            closing_marked = true;
            handlers.cancelPendingExecQueue(self);

            commands.waitCmds(self);
            self.msgs.close();

            if (self.quit_write_fd) |fd| {
                _ = posix.write(fd, "q") catch {};
                posix.close(fd);
                self.quit_write_fd = null;
            }
            if (reader_thread) |rt| rt.join();

            return .{ .model = &self.model, .exit_reason = self.exit_reason };
        }

        pub fn send(self: *Self, m: Msg) void {
            switch (m) {
                .window_size => |sz| {
                    self.enqueueWindowSize(sz);
                    return;
                },
                .mouse_motion => |mm| {
                    self.enqueueMouseMotion(mm);
                    return;
                },
                else => {},
            }

            // Fast path: non-blocking push succeeds when queue has space (common case).
            // Slow path: block until space is available or queue is closed.
            if (!self.msgs.tryPush(m)) {
                _ = self.stats.queue_push_failures.fetchAdd(1, .monotonic);
                _ = self.msgs.push(m);
            }
        }

        pub fn quit(self: *Self) void {
            self.send(.quit);
        }

        pub fn kill(self: *Self) void {
            self.exit_reason = .killed;
            self.send(.interrupt);
        }

        pub fn wait(self: *Self) void {
            self.finished_mutex.lock();
            defer self.finished_mutex.unlock();
            while (!self.finished) {
                self.finished_cond.wait(&self.finished_mutex);
            }
        }

        pub fn println(self: *Self, line: []const u8) void {
            self.send(.{ .print_line = msg_mod.TextPayload.fromSlice(line) });
        }

        pub fn printf(self: *Self, comptime fmt: []const u8, args: anytype) void {
            var buf: [1024]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
            self.println(line);
        }

        pub fn releaseTerminal(self: *Self) void {
            if (self.tty_state) |*ts| {
                ts.restore();
                self.tty_released = true;
            }
        }

        pub fn restoreTerminal(self: *Self) void {
            if (!self.tty_released) return;
            self.tty_state = tty_mod.TtyState.enableRawMode(self.input_fd) catch self.tty_state;
            self.tty_released = false;
        }

        // ── Delegation to extracted modules ──────────────────────

        pub fn spawnCmd(self: *Self, c: Cmd) void {
            commands.spawnCmd(self, c);
        }

        pub fn handleExec(self: *Self, req: exec_mod.ExecRequestMsg) void {
            handlers.handleExec(self, req);
        }

        pub fn enqueueExecOnMainThread(self: *Self, req: exec_mod.ExecRequestMsg) void {
            handlers.enqueueExecOnMainThread(self, req);
        }

        pub fn decActiveCmds(self: *Self) void {
            commands.decActiveCmds(self);
        }

        // ── Event loop ───────────────────────────────────────────

        fn eventLoop(self: *Self) void {
            while (true) {
                self.schedulePendingCoalesced();
                const raw_m = self.msgs.pop() orelse break;
                const resolved_m = switch (raw_m) {
                    .drain_window_size => self.takePendingWindowSize() orelse continue,
                    .drain_mouse_motion => self.takePendingMouseMotion() orelse continue,
                    else => raw_m,
                };

                const m = blk: {
                    if (self.opts.filter_with_model) |fwm| {
                        break :blk fwm(@ptrCast(&self.model), resolved_m) orelse continue;
                    } else if (self.opts.filter) |filter| {
                        break :blk filter(resolved_m) orelse continue;
                    }
                    break :blk resolved_m;
                };

                handlers.applyPreUpdateEffects(self, m);

                if (handlers.handleInternalMessage(self, m)) {
                    handlers.flushRenderer(self, handlers.forceFlushAfterInternalMessage(m), false);
                    continue;
                }

                const c = model_mod.callUpdate(ModelType, &self.model, m, self.frame_arena.allocator());

                if (c) |cmd| {
                    if (cmd.isQuit()) {
                        self.exit_reason = .quit;
                        return;
                    }
                    self.spawnCmd(cmd);
                }

                self.render();
                handlers.flushRenderer(self, false, false);

                switch (m) {
                    .quit => {
                        self.exit_reason = .quit;
                        return;
                    },
                    .interrupt => {
                        self.exit_reason = .interrupt;
                        return;
                    },
                    else => {},
                }
            }
        }

        // ── Coalesced slots ──────────────────────────────────────

        pub fn schedulePendingCoalesced(self: *Self) void {
            self.scheduleSlot(&self.pending_window_size, .drain_window_size);
            self.scheduleSlot(&self.pending_mouse_motion, .drain_mouse_motion);
        }

        fn enqueueWindowSize(self: *Self, sz: screen_mod.WindowSizeMsg) void {
            self.enqueueCoalesced(&self.pending_window_size, sz, .drain_window_size);
        }

        fn enqueueMouseMotion(self: *Self, mm: mouse_mod.Mouse) void {
            self.enqueueCoalesced(&self.pending_mouse_motion, mm, .drain_mouse_motion);
        }

        fn enqueueCoalesced(self: *Self, slot: anytype, value: anytype, drain_msg: Msg) void {
            slot.mutex.lock();
            slot.value = value;
            slot.valid = true;
            slot.mutex.unlock();
            self.scheduleSlot(slot, drain_msg);
        }

        fn scheduleSlot(self: *Self, slot: anytype, drain_msg: Msg) void {
            var should_schedule = false;
            slot.mutex.lock();
            if (slot.valid and !slot.scheduled) {
                slot.scheduled = true;
                should_schedule = true;
            }
            slot.mutex.unlock();

            if (!should_schedule) return;
            if (self.msgs.tryPush(drain_msg)) return;

            slot.mutex.lock();
            slot.scheduled = false;
            slot.mutex.unlock();
        }

        pub fn takePendingWindowSize(self: *Self) ?Msg {
            const sz = takeCoalesced(&self.pending_window_size) orelse return null;
            return .{ .window_size = sz };
        }

        pub fn takePendingMouseMotion(self: *Self) ?Msg {
            const mm = takeCoalesced(&self.pending_mouse_motion) orelse return null;
            return .{ .mouse_motion = mm };
        }

        fn takeCoalesced(slot: anytype) ?@TypeOf(slot.value) {
            slot.mutex.lock();
            defer slot.mutex.unlock();

            if (!slot.valid) {
                slot.scheduled = false;
                return null;
            }

            const v = slot.value;
            slot.valid = false;
            slot.scheduled = false;
            return v;
        }

        // ── Render + utilities ───────────────────────────────────

        fn render(self: *Self) void {
            _ = self.frame_arena.reset(.retain_capacity);
            _ = self.stats.frames_rendered.fetchAdd(1, .monotonic);
            const v = model_mod.viewOf(ModelType, &self.model, self.frame_arena.allocator());
            if (self.renderer) |r| {
                r.render(v);
                return;
            }

            self.out_file.writeAll(v.content) catch |err| {
                std.log.err("render write failed (fallback): {}", .{err});
            };
        }

        fn contextWatcher(self: *Self, cancelled: *const std.atomic.Value(bool)) void {
            while (!self.closing.load(.acquire)) {
                if (cancelled.load(.acquire)) {
                    self.send(.interrupt);
                    return;
                }
                self.closing_wait_mutex.lock();
                if (!self.closing.load(.acquire)) {
                    self.closing_wait_cond.timedWait(&self.closing_wait_mutex, 50 * std.time.ns_per_ms) catch {};
                }
                self.closing_wait_mutex.unlock();
            }
        }

        fn markClosing(self: *Self) void {
            self.closing.store(true, .release);
            self.closing_wait_mutex.lock();
            self.closing_wait_cond.broadcast();
            self.closing_wait_mutex.unlock();
        }

        fn isFdUsable(fd: posix.fd_t) bool {
            if (builtin.os.tag == .windows) {
                const v = @intFromPtr(fd);
                return v != 0 and v != std.math.maxInt(usize);
            }
            return fd >= 0;
        }
    };
}

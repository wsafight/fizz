/// 命令执行模块：worker 池、batch、sequence、tick。
const std = @import("std");
const cmd_mod = @import("../cmd.zig");
const exec_mod = @import("../exec.zig");
const queue_mod = @import("../queue.zig");

const Cmd = cmd_mod.Cmd;
const SimpleCmd = cmd_mod.SimpleCmd;

pub fn Commands(comptime Self: type) type {
    const SimpleCmdQueue = queue_mod.BlockingQueue(SimpleCmd, 256);
    const batch_parallel_limit: usize = 8;

    const max_fallback_threads: usize = 16;

    return struct {
        /// 根据 Cmd variant 分发执行。
        pub fn spawnCmd(self: *Self, c: Cmd) void {
            switch (c) {
                .simple => |f| spawnSimple(self, f),
                .msg => |m| self.send(m),
                .batch => |cmds| spawnBatch(self, cmds),
                .sequence => |cmds| spawnSequence(self, cmds),
                .tick => |t| spawnTick(self, t, false),
                .every => |t| spawnTick(self, t, true),
                .exec => |req| self.handleExec(req),
                .throttle => |t| spawnThrottle(self, t),
                .debounce => |d| spawnDebounce(self, d),
            }
        }

        /// 单个命令：优先进入 worker 池，队列繁忙时退化为有限临时线程或同步执行。
        fn spawnSimple(self: *Self, f: SimpleCmd) void {
            const new_count = self.active_cmds.fetchAdd(1, .monotonic) + 1;
            // Track peak active commands
            var peak = self.stats.active_cmds_peak.load(.monotonic);
            while (new_count > peak) {
                peak = self.stats.active_cmds_peak.cmpxchgWeak(peak, new_count, .monotonic, .monotonic) orelse break;
            }
            if (ensureSimpleCmdWorkersStarted(self)) {
                if (self.simple_cmd_queue.tryPush(f)) return;
            }

            // Bounded fallback: limit detached threads to prevent thread explosion
            const current = self.fallback_thread_count.load(.monotonic);
            if (current >= max_fallback_threads) {
                // Execute synchronously on current thread as last resort
                self.send(f());
                decActiveCmds(self);
                return;
            }

            _ = self.fallback_thread_count.fetchAdd(1, .monotonic);
            _ = self.stats.fallback_spawns.fetchAdd(1, .monotonic);
            const thread = std.Thread.spawn(.{}, simpleDetachedRunner, .{ self, f }) catch |err| {
                std.log.err("failed to spawn fallback cmd thread: {}", .{err});
                _ = self.fallback_thread_count.fetchSub(1, .monotonic);
                self.send(f());
                decActiveCmds(self);
                return;
            };
            thread.detach();
        }

        fn simpleDetachedRunner(self: *Self, f: SimpleCmd) void {
            self.send(f());
            decActiveCmds(self);
            _ = self.fallback_thread_count.fetchSub(1, .monotonic);
        }

        fn simpleCmdRunner(self: *Self) void {
            while (self.simple_cmd_queue.pop()) |f| {
                self.send(f());
                decActiveCmds(self);
            }
        }

        fn ensureSimpleCmdWorkersStarted(self: *Self) bool {
            self.simple_cmd_workers_mutex.lock();
            defer self.simple_cmd_workers_mutex.unlock();

            if (self.simple_cmd_workers_started) return true;

            self.simple_cmd_queue = SimpleCmdQueue.init();
            for (&self.simple_cmd_workers) |*slot| slot.* = null;

            const target_count: usize = @min(self.opts.worker_count, Self.max_workers);
            var started: usize = 0;
            while (started < target_count) : (started += 1) {
                self.simple_cmd_workers[started] = std.Thread.spawn(.{}, simpleCmdRunner, .{self}) catch {
                    self.simple_cmd_queue.close();
                    while (started > 0) {
                        started -= 1;
                        if (self.simple_cmd_workers[started]) |t| t.join();
                        self.simple_cmd_workers[started] = null;
                    }
                    self.simple_cmd_queue = SimpleCmdQueue.init();
                    return false;
                };
            }

            self.simple_cmd_workers_started = true;
            return true;
        }

        pub fn stopSimpleCmdWorkers(self: *Self) void {
            self.simple_cmd_workers_mutex.lock();
            if (!self.simple_cmd_workers_started) {
                self.simple_cmd_workers_mutex.unlock();
                return;
            }
            self.simple_cmd_workers_started = false;
            self.simple_cmd_queue.close();
            self.simple_cmd_workers_mutex.unlock();

            for (&self.simple_cmd_workers) |*slot| {
                if (slot.*) |t| t.join();
                slot.* = null;
            }

            self.simple_cmd_workers_mutex.lock();
            defer self.simple_cmd_workers_mutex.unlock();
            self.simple_cmd_queue = SimpleCmdQueue.init();
        }

        /// Batch：并发执行多个命令。
        fn spawnBatch(self: *Self, cmds: []const Cmd) void {
            _ = self.active_cmds.fetchAdd(1, .monotonic);
            const thread = std.Thread.spawn(.{}, batchRunner, .{ self, cmds }) catch |err| {
                std.log.err("failed to spawn batch thread: {}", .{err});
                _ = self.active_cmds.fetchSub(1, .monotonic);
                return;
            };
            thread.detach();
        }

        fn batchRunner(self: *Self, cmds: []const Cmd) void {
            if (cmds.len == 0) {
                decActiveCmds(self);
                return;
            }

            var threads: [batch_parallel_limit]std.Thread = undefined;
            var next_idx = std.atomic.Value(usize).init(0);
            var spawned: usize = 0;
            const target = @min(cmds.len, threads.len);

            while (spawned < target) : (spawned += 1) {
                threads[spawned] = std.Thread.spawn(.{}, batchItemRunner, .{ self, cmds, &next_idx }) catch break;
            }

            if (spawned < target) {
                batchWorkLoop(self, cmds, &next_idx);
            }

            for (threads[0..spawned]) |t| {
                t.join();
            }

            // 兜底：确保所有任务都被处理（包括并发竞争边界）。
            batchWorkLoop(self, cmds, &next_idx);
            decActiveCmds(self);
        }

        fn batchItemRunner(self: *Self, cmds: []const Cmd, next_idx: *std.atomic.Value(usize)) void {
            batchWorkLoop(self, cmds, next_idx);
        }

        fn batchWorkLoop(self: *Self, cmds: []const Cmd, next_idx: *std.atomic.Value(usize)) void {
            while (true) {
                const idx = next_idx.fetchAdd(1, .monotonic);
                if (idx >= cmds.len) break;
                execCmdSync(self, cmds[idx]);
            }
        }

        /// Sequence：串行执行多个命令。
        fn spawnSequence(self: *Self, cmds: []const Cmd) void {
            _ = self.active_cmds.fetchAdd(1, .monotonic);
            const thread = std.Thread.spawn(.{}, sequenceRunner, .{ self, cmds }) catch |err| {
                std.log.err("failed to spawn sequence thread: {}", .{err});
                _ = self.active_cmds.fetchSub(1, .monotonic);
                return;
            };
            thread.detach();
        }

        fn sequenceRunner(self: *Self, cmds: []const Cmd) void {
            for (cmds) |c| {
                execCmdSync(self, c);
            }
            decActiveCmds(self);
        }

        /// 同步执行单个 Cmd（用于 batch/sequence 内部）。
        fn execCmdSync(self: *Self, c: Cmd) void {
            switch (c) {
                .simple => |f| self.send(f()),
                .msg => |m| self.send(m),
                .batch => |cmds| {
                    for (cmds) |sub| execCmdSync(self, sub);
                },
                .sequence => |cmds| {
                    for (cmds) |sub| execCmdSync(self, sub);
                },
                .tick => |t| {
                    std.Thread.sleep(t.duration_ns);
                    self.send(t.callback(std.time.nanoTimestamp()));
                },
                .every => |t| {
                    std.Thread.sleep(t.duration_ns);
                    self.send(t.callback(std.time.nanoTimestamp()));
                },
                .exec => |req| self.enqueueExecOnMainThread(req),
                .throttle => |t| {
                    std.Thread.sleep(t.interval_ns);
                    self.send(t.message);
                },
                .debounce => |d| {
                    std.Thread.sleep(d.interval_ns);
                    self.send(d.message);
                },
            }
        }

        /// Tick/Every：sleep 后调用回调。
        fn spawnTick(self: *Self, t: cmd_mod.TickCmd, align_to_clock: bool) void {
            _ = self.active_cmds.fetchAdd(1, .monotonic);
            const thread = std.Thread.spawn(.{}, tickRunner, .{ self, t, align_to_clock }) catch |err| {
                std.log.err("failed to spawn tick thread: {}", .{err});
                _ = self.active_cmds.fetchSub(1, .monotonic);
                return;
            };
            thread.detach();
        }

        fn tickRunner(self: *Self, t: cmd_mod.TickCmd, align_to_clock: bool) void {
            const normalized_duration_ns: u64 = if (t.duration_ns == 0) 1 else t.duration_ns;
            const duration: i128 = @intCast(normalized_duration_ns);

            if (align_to_clock) {
                // Repeating timer: fire repeatedly until closing
                while (!self.closing.load(.acquire)) {
                    const now = std.time.nanoTimestamp();
                    const elapsed = @mod(now, duration);
                    const remaining = duration - elapsed;
                    const total_ns: u64 = @intCast(@max(1, remaining));

                    if (!sleepChunked(self, total_ns)) break;

                    if (self.closing.load(.acquire)) break;

                    const timestamp: i128 = std.time.nanoTimestamp();
                    self.send(t.callback(timestamp));
                }
            } else {
                // One-shot timer
                if (!sleepChunked(self, normalized_duration_ns)) {
                    decActiveCmds(self);
                    return;
                }

                if (self.closing.load(.acquire)) {
                    decActiveCmds(self);
                    return;
                }

                const timestamp: i128 = std.time.nanoTimestamp();
                self.send(t.callback(timestamp));
            }

            decActiveCmds(self);
        }

        /// Sleep in 50ms chunks, checking closing flag each iteration.
        /// Returns true if sleep completed, false if closing was detected.
        fn sleepChunked(self: *Self, total_ns: u64) bool {
            const chunk: u64 = 50 * std.time.ns_per_ms;
            var slept: u64 = 0;
            while (slept < total_ns) {
                if (self.closing.load(.acquire)) return false;
                const remaining = total_ns - slept;
                std.Thread.sleep(@min(chunk, remaining));
                slept += @min(chunk, remaining);
            }
            return true;
        }

        /// Throttle: drop if fired too recently, otherwise sleep then send.
        fn spawnThrottle(self: *Self, t: cmd_mod.ThrottleCmd) void {
            const slot = t.tag % self.throttle_last.len;
            const now = std.time.nanoTimestamp();
            const last = self.throttle_last[slot];
            const interval: i128 = @intCast(t.interval_ns);
            if (last != 0 and (now - last) < interval) return; // drop — too soon
            self.throttle_last[slot] = now;
            _ = self.active_cmds.fetchAdd(1, .monotonic);
            const thread = std.Thread.spawn(.{}, throttleRunner, .{ self, t }) catch {
                self.send(t.message);
                decActiveCmds(self);
                return;
            };
            thread.detach();
        }

        fn throttleRunner(self: *Self, t: cmd_mod.ThrottleCmd) void {
            if (!sleepChunked(self, t.interval_ns)) {
                decActiveCmds(self);
                return;
            }
            self.send(t.message);
            decActiveCmds(self);
        }

        /// Debounce: bump generation, sleep, only fire if generation unchanged.
        fn spawnDebounce(self: *Self, d: cmd_mod.ThrottleCmd) void {
            const slot = d.tag % self.debounce_gen.len;
            const gen = self.debounce_gen[slot].fetchAdd(1, .monotonic) +% 1;
            _ = self.active_cmds.fetchAdd(1, .monotonic);
            const thread = std.Thread.spawn(.{}, debounceRunner, .{ self, d, gen, slot }) catch {
                self.send(d.message);
                decActiveCmds(self);
                return;
            };
            thread.detach();
        }

        fn debounceRunner(self: *Self, d: cmd_mod.ThrottleCmd, gen: u32, slot: usize) void {
            if (!sleepChunked(self, d.interval_ns)) {
                decActiveCmds(self);
                return;
            }
            // Only fire if no newer debounce was scheduled
            if (self.debounce_gen[slot].load(.monotonic) == gen) {
                self.send(d.message);
            }
            decActiveCmds(self);
        }

        /// 递减活跃命令计数，归零时通知 waitCmds。
        pub fn decActiveCmds(self: *Self) void {
            const prev = self.active_cmds.fetchSub(1, .monotonic);
            if (prev == 1) {
                self.cmds_mutex.lock();
                defer self.cmds_mutex.unlock();
                self.cmds_done.signal();
            }
        }

        /// 等待所有活跃 cmd 完成。
        pub fn waitCmds(self: *Self) void {
            self.cmds_mutex.lock();
            defer self.cmds_mutex.unlock();
            while (self.active_cmds.load(.monotonic) > 0) {
                self.cmds_done.wait(&self.cmds_mutex);
            }
        }
    };
}

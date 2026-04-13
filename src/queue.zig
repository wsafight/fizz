/// Thread-safe message queue (Phase 1)
///
/// Replaces Go's `chan Msg`. Fixed-capacity ring buffer + Mutex + Condition.
/// push() blocks when full (backpressure), pop() blocks when empty, close() wakes all waiters.
///
/// Memory note: queue is a value type, buffer size = capacity * sizeof(T).
/// When T is a large union (e.g. Msg), copy-by-value and cache usage increase significantly.
const std = @import("std");
const Msg = @import("msg.zig").Msg;

pub fn BlockingQueue(comptime T: type, comptime capacity: usize) type {
    comptime {
        if (capacity == 0) @compileError("MessageQueue capacity must be > 0");
    }

    return struct {
        const Self = @This();
        const capacity_is_pow2 = std.math.isPowerOfTwo(capacity);

        buffer: [capacity]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,
        mutex: std.Thread.Mutex = .{},
        not_empty: std.Thread.Condition = .{},
        not_full: std.Thread.Condition = .{},
        closed: bool = false,

        pub fn init() Self {
            return .{};
        }

        /// Push a message. Blocks when full until space is available or queue is closed.
        /// Returns true on success, false if queue is closed and message was dropped.
        pub fn push(self: *Self, m: T) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.count == capacity and !self.closed) {
                self.not_full.wait(&self.mutex);
            }
            if (self.closed) return false;

            self.buffer[self.tail] = m;
            self.tail = nextIndex(self.tail);
            self.count += 1;
            self.not_empty.signal();
            return true;
        }

        /// Try to push a message. Returns false immediately if full or closed, non-blocking.
        pub fn tryPush(self: *Self, m: T) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed or self.count == capacity) return false;

            self.buffer[self.tail] = m;
            self.tail = nextIndex(self.tail);
            self.count += 1;
            self.not_empty.signal();
            return true;
        }

        /// Pop a message. Blocks when empty until a message arrives or queue is closed (returns null).
        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.count == 0 and !self.closed) {
                self.not_empty.wait(&self.mutex);
            }
            if (self.count == 0) return null;

            const m = self.buffer[self.head];
            self.head = nextIndex(self.head);
            self.count -= 1;
            self.not_full.signal();
            return m;
        }

        /// Close the queue, wake all waiting push/pop.
        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
            self.not_empty.broadcast();
            self.not_full.broadcast();
        }

        /// Current number of messages in queue (for testing).
        pub fn len(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.count;
        }

        fn nextIndex(i: usize) usize {
            if (comptime capacity_is_pow2) {
                return (i + 1) & (capacity - 1);
            }
            return (i + 1) % capacity;
        }
    };
}

pub fn MessageQueue(comptime capacity: usize) type {
    return BlockingQueue(Msg, capacity);
}

// ── Unit tests ──────────────────────────────────────────────

const testing = std.testing;

test "Queue: push and pop single message" {
    var q = MessageQueue(4).init();
    try testing.expect(q.push(.quit));
    const m = q.pop();
    try testing.expect(m != null);
    try testing.expect(m.? == .quit);
}

test "Queue: FIFO order" {
    var q = MessageQueue(4).init();
    try testing.expect(q.push(.startup));
    try testing.expect(q.push(.quit));
    try testing.expect(q.push(.interrupt));
    try testing.expect(q.pop().? == .startup);
    try testing.expect(q.pop().? == .quit);
    try testing.expect(q.pop().? == .interrupt);
}

test "Queue: close unblocks pop" {
    var q = MessageQueue(4).init();
    // Close in another thread, main thread pop should return null
    const t = try std.Thread.spawn(.{}, struct {
        fn run(queue: *MessageQueue(4)) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            queue.close();
        }
    }.run, .{&q});
    const m = q.pop();
    try testing.expect(m == null);
    t.join();
}

test "Queue: pop blocks until push" {
    var q = MessageQueue(4).init();
    const t = try std.Thread.spawn(.{}, struct {
        fn run(queue: *MessageQueue(4)) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            _ = queue.push(.quit);
        }
    }.run, .{&q});
    const m = q.pop();
    try testing.expect(m != null);
    try testing.expect(m.? == .quit);
    t.join();
}

test "Queue: len tracks count" {
    var q = MessageQueue(4).init();
    try testing.expectEqual(@as(usize, 0), q.len());
    _ = q.push(.startup);
    _ = q.push(.quit);
    try testing.expectEqual(@as(usize, 2), q.len());
    _ = q.pop();
    try testing.expectEqual(@as(usize, 1), q.len());
}

test "Queue: close allows draining remaining messages" {
    var q = MessageQueue(4).init();
    _ = q.push(.startup);
    _ = q.push(.quit);
    q.close();
    // Can still read existing messages after close
    try testing.expect(q.pop().? == .startup);
    try testing.expect(q.pop().? == .quit);
    // Queue empty and closed, returns null
    try testing.expect(q.pop() == null);
}

test "Queue: push after close returns false" {
    var q = MessageQueue(4).init();
    q.close();
    try testing.expect(!q.push(.quit));
}

test "Queue: push on full queue unblocks when closed" {
    // Capacity 2, fill up then close in another thread, blocked push should return false
    var q = MessageQueue(2).init();
    _ = q.push(.startup);
    _ = q.push(.quit);

    const t = try std.Thread.spawn(.{}, struct {
        fn run(queue: *MessageQueue(2)) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            queue.close();
        }
    }.run, .{&q});

    // Queue full, push blocks until close
    try testing.expect(!q.push(.interrupt));
    t.join();
}

test "Queue: tryPush is non-blocking on full queue" {
    var q = MessageQueue(1).init();
    try testing.expect(q.tryPush(.startup));
    try testing.expect(!q.tryPush(.quit));
}

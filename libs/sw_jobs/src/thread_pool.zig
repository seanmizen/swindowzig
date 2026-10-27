//! A pool of native worker threads (REQ-JOBS-001). Each worker has its own
//! handler and its own queue. A worker runs the messages of its queue in
//! order, one at a time, and the main thread takes the replies.
//!
//! `Handler` is a type with this function:
//!
//! ```zig
//! pub fn handle(self: *Handler, msg: []const u8) jobs.Answer
//! ```
//!
//! The handler gives a reply that the pool allocator owns, no reply, or a
//! failure. Optional declarations:
//!
//!   - `Snapshot` (a struct with defaults) and
//!     `fn snapshot(self: *const Handler) Snapshot`: the pool copies the
//!     snapshot after each message, so the main thread can read the
//!     counters of a worker while it runs.
//!   - `fn deinit(self: *Handler) void`: `deinit` of the pool calls it.
//!
//! The pool must not move after `init`: the threads hold pointers to it.
//!
//! The technique follows the thread pool of horizon (MIT). No code of
//! horizon is in this file.
const std = @import("std");

/// What a handler gives for one message.
pub const Answer = union(enum) {
    /// No reply, for example for a message that only changes the state.
    none,
    /// A reply. The pool allocator owns the bytes.
    reply: []u8,
    /// The message failed, for example with no memory. The main thread
    /// gets a reply with no bytes.
    failed,
};

pub fn ThreadPool(comptime Handler: type) type {
    return struct {
        const Self = @This();

        pub const has_snapshot = @hasDecl(Handler, "Snapshot");
        pub const Snapshot = if (has_snapshot) Handler.Snapshot else void;

        /// A reply from a worker. `bytes` is null when the message failed.
        pub const Reply = struct {
            worker: usize,
            id: u32,
            bytes: ?[]u8,
        };

        const Message = struct {
            id: u32,
            bytes: []u8,
        };

        const Worker = struct {
            pool: *Self,
            index: usize,
            thread: ?std.Thread = null,
            handler: Handler,

            // Shared with the thread, under `mutex`.
            mutex: std.Io.Mutex = .init,
            cond: std.Io.Condition = .init,
            inbox: std.ArrayList(Message) = .empty,
            inbox_head: usize = 0,
            stop: bool = false,
            snapshot: Snapshot = if (has_snapshot) .{} else {},

            fn run(self: *Worker) void {
                const io = self.pool.io;
                const a = self.pool.allocator;
                while (true) {
                    self.mutex.lockUncancelable(io);
                    while (self.inbox_head == self.inbox.items.len and !self.stop) self.cond.waitUncancelable(io, &self.mutex);
                    if (self.stop) {
                        // Shutdown: the messages that wait do not run.
                        self.mutex.unlock(io);
                        return;
                    }
                    const msg = self.inbox.items[self.inbox_head];
                    self.inbox_head += 1;
                    if (self.inbox_head == self.inbox.items.len) {
                        self.inbox.clearRetainingCapacity();
                        self.inbox_head = 0;
                    }
                    self.mutex.unlock(io);

                    const answer = self.handler.handle(msg.bytes);
                    a.free(msg.bytes);
                    if (has_snapshot) {
                        const s = self.handler.snapshot();
                        self.mutex.lockUncancelable(io);
                        self.snapshot = s;
                        self.mutex.unlock(io);
                    }
                    switch (answer) {
                        .none => {},
                        .reply => |bytes| self.pool.pushReply(.{ .worker = self.index, .id = msg.id, .bytes = bytes }),
                        .failed => self.pool.pushReply(.{ .worker = self.index, .id = msg.id, .bytes = null }),
                    }
                }
            }
        };

        allocator: std.mem.Allocator,
        io: std.Io,
        workers: []Worker,
        /// Replies from the workers, under `reply_mutex`.
        reply_mutex: std.Io.Mutex = .init,
        reply_cond: std.Io.Condition = .init,
        replies: std.ArrayList(Reply) = .empty,

        /// Make one worker for each handler. The pool takes the handlers.
        /// The threads start in `start`, so the caller can use
        /// `handler(i)` before (for example for a handshake).
        pub fn init(self: *Self, allocator: std.mem.Allocator, io: std.Io, handlers: []const Handler) !void {
            std.debug.assert(handlers.len >= 1);
            const workers = try allocator.alloc(Worker, handlers.len);
            for (workers, handlers, 0..) |*w, h, i| w.* = .{ .pool = self, .index = i, .handler = h };
            self.* = .{ .allocator = allocator, .io = io, .workers = workers };
        }

        /// Start one thread for each worker. On an error, the threads that
        /// started stay: `deinit` stops them.
        pub fn start(self: *Self) !void {
            for (self.workers) |*w| {
                if (w.thread == null) w.thread = try std.Thread.spawn(.{}, Worker.run, .{w});
            }
        }

        /// Shutdown: stop each thread after its current message, and wait
        /// for it. Then free the messages that wait and the replies that
        /// main did not take, and call `deinit` of each handler.
        pub fn deinit(self: *Self) void {
            const a = self.allocator;
            for (self.workers) |*w| {
                w.mutex.lockUncancelable(self.io);
                w.stop = true;
                w.cond.signal(self.io);
                w.mutex.unlock(self.io);
            }
            for (self.workers) |*w| {
                if (w.thread) |t| t.join();
                w.thread = null;
                for (w.inbox.items[w.inbox_head..]) |m| a.free(m.bytes);
                w.inbox.deinit(a);
                if (@hasDecl(Handler, "deinit")) w.handler.deinit();
            }
            a.free(self.workers);
            self.workers = &.{};
            for (self.replies.items) |r| if (r.bytes) |b| a.free(b);
            self.replies.deinit(a);
        }

        /// The number of workers.
        pub fn count(self: *const Self) usize {
            return self.workers.len;
        }

        /// The handler of worker `i`. Use it only before `start`: after,
        /// its thread owns it.
        pub fn handler(self: *Self, i: usize) *Handler {
            return &self.workers[i].handler;
        }

        /// The last snapshot of worker `i`.
        pub fn snapshot(self: *Self, i: usize) Snapshot {
            const w = &self.workers[i];
            w.mutex.lockUncancelable(self.io);
            defer w.mutex.unlock(self.io);
            return w.snapshot;
        }

        /// Put `msg` at the end of the queue of worker `i`. The pool owns
        /// `msg` (from its allocator) after the call. On an error, the
        /// caller still owns it. `id` comes back with the reply.
        pub fn post(self: *Self, i: usize, id: u32, msg: []u8) !void {
            const w = &self.workers[i];
            w.mutex.lockUncancelable(self.io);
            defer w.mutex.unlock(self.io);
            try w.inbox.append(self.allocator, .{ .id = id, .bytes = msg });
            w.cond.signal(self.io);
        }

        /// Put a copy of `msg` at the end of the queue of each worker.
        pub fn broadcast(self: *Self, id: u32, msg: []const u8) !void {
            for (0..self.workers.len) |i| {
                const copy = try self.allocator.dupe(u8, msg);
                errdefer self.allocator.free(copy);
                try self.post(i, id, copy);
            }
        }

        /// Remove the messages with `id` that wait in a queue, and free
        /// them. A message that runs now is not removed. Returns the number
        /// of messages removed.
        pub fn cancel(self: *Self, id: u32) usize {
            var removed: usize = 0;
            for (self.workers) |*w| {
                w.mutex.lockUncancelable(self.io);
                defer w.mutex.unlock(self.io);
                var i = w.inbox_head;
                while (i < w.inbox.items.len) {
                    if (w.inbox.items[i].id == id) {
                        self.allocator.free(w.inbox.items[i].bytes);
                        _ = w.inbox.orderedRemove(i);
                        removed += 1;
                    } else i += 1;
                }
            }
            return removed;
        }

        /// The messages that wait in the queue of worker `i`, without the
        /// message that runs.
        pub fn queued(self: *Self, i: usize) usize {
            const w = &self.workers[i];
            w.mutex.lockUncancelable(self.io);
            defer w.mutex.unlock(self.io);
            return w.inbox.items.len - w.inbox_head;
        }

        fn pushReply(self: *Self, r: Reply) void {
            self.reply_mutex.lockUncancelable(self.io);
            defer self.reply_mutex.unlock(self.io);
            defer self.reply_cond.signal(self.io);
            self.replies.append(self.allocator, r) catch {
                // No memory for the list: the reply is lost.
                if (r.bytes) |b| self.allocator.free(b);
            };
        }

        /// Move the replies that arrived to the end of `out`. The caller
        /// owns their bytes, from the pool allocator.
        pub fn takeReplies(self: *Self, out: *std.ArrayList(Reply)) !void {
            self.reply_mutex.lockUncancelable(self.io);
            defer self.reply_mutex.unlock(self.io);
            try out.appendSlice(self.allocator, self.replies.items);
            self.replies.clearRetainingCapacity();
        }

        /// Wait until a reply arrives, or `timeout_us` passes.
        pub fn waitForReply(self: *Self, timeout_us: i64) void {
            self.reply_mutex.lockUncancelable(self.io);
            defer self.reply_mutex.unlock(self.io);
            if (self.replies.items.len > 0) return;
            const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMicroseconds(timeout_us), .clock = .awake } };
            self.reply_cond.waitTimeout(self.io, &self.reply_mutex, timeout) catch {};
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// A handler that answers each message with the message and the index of
/// the worker. A message "wait" waits until `gate` opens.
const Echo = struct {
    allocator: std.mem.Allocator,
    index: u8,
    gate: *std.atomic.Value(bool),
    started: *std.atomic.Value(u32),
    handled: u32 = 0,

    pub const Snapshot = struct { handled: u32 = 0 };

    pub fn handle(self: *Echo, msg: []const u8) Answer {
        _ = self.started.fetchAdd(1, .seq_cst);
        if (std.mem.eql(u8, msg, "wait")) {
            while (!self.gate.load(.seq_cst)) std.Thread.yield() catch {};
        }
        self.handled += 1;
        if (std.mem.eql(u8, msg, "quiet")) return .none;
        if (std.mem.eql(u8, msg, "fail")) return .failed;
        const out = self.allocator.alloc(u8, msg.len + 1) catch return .failed;
        @memcpy(out[0..msg.len], msg);
        out[msg.len] = '0' + self.index;
        return .{ .reply = out };
    }

    pub fn snapshot(self: *const Echo) Snapshot {
        return .{ .handled = self.handled };
    }
};

const EchoPool = ThreadPool(Echo);

const Fixture = struct {
    gate: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(u32) = .init(0),
    pool: EchoPool = undefined,
    replies: std.ArrayList(EchoPool.Reply) = .empty,

    fn init(f: *Fixture, n: u8) !void {
        var handlers: [4]Echo = undefined;
        for (0..n) |i| handlers[i] = .{ .allocator = testing.allocator, .index = @intCast(i), .gate = &f.gate, .started = &f.started };
        try f.pool.init(testing.allocator, testing.io, handlers[0..n]);
        try f.pool.start();
    }

    fn deinit(f: *Fixture) void {
        f.gate.store(true, .seq_cst);
        f.pool.deinit();
        for (f.replies.items) |r| if (r.bytes) |b| testing.allocator.free(b);
        f.replies.deinit(testing.allocator);
    }

    fn send(f: *Fixture, worker: usize, id: u32, text: []const u8) !void {
        const msg = try testing.allocator.dupe(u8, text);
        errdefer testing.allocator.free(msg);
        try f.pool.post(worker, id, msg);
    }

    /// Wait until `n` replies arrived.
    fn waitFor(f: *Fixture, n: usize) !void {
        var tries: usize = 0;
        while (f.replies.items.len < n) : (tries += 1) {
            if (tries > 20_000) return error.Timeout;
            f.pool.waitForReply(1000);
            try f.pool.takeReplies(&f.replies);
        }
    }
};

test "jobs: a worker runs its messages in order (REQ-JOBS-001)" {
    var f: Fixture = .{};
    try f.init(2);
    defer f.deinit();
    for (0..20) |i| try f.send(i % 2, @intCast(i), "m");
    try f.waitFor(20);
    // The replies of one worker come in the order of its messages.
    var last: [2]?u32 = .{ null, null };
    for (f.replies.items) |r| {
        try testing.expectEqual(@as(usize, r.id % 2), r.worker);
        try testing.expectEqualStrings(if (r.worker == 0) "m0" else "m1", r.bytes.?);
        if (last[r.worker]) |l| try testing.expect(r.id > l);
        last[r.worker] = r.id;
    }
    try testing.expectEqual(@as(u32, 10), f.pool.snapshot(0).handled);
}

test "jobs: no reply, a failure, and a broadcast (REQ-JOBS-001)" {
    var f: Fixture = .{};
    try f.init(3);
    defer f.deinit();
    try f.send(0, 1, "quiet");
    try f.send(0, 2, "fail");
    try f.pool.broadcast(3, "b");
    try f.waitFor(4);
    try testing.expectEqual(@as(u32, 2), f.replies.items[0].id);
    try testing.expectEqual(@as(?[]u8, null), f.replies.items[0].bytes);
    var seen: [3]bool = @splat(false);
    for (f.replies.items[1..]) |r| {
        try testing.expectEqual(@as(u32, 3), r.id);
        seen[r.worker] = true;
    }
    try testing.expect(seen[0] and seen[1] and seen[2]);
}

test "jobs: cancel removes the messages that wait, not the message that runs (REQ-JOBS-001)" {
    var f: Fixture = .{};
    try f.init(1);
    defer f.deinit();
    try f.send(0, 1, "wait");
    // Wait until the first message runs.
    while (f.started.load(.seq_cst) == 0) std.Thread.yield() catch {};
    try f.send(0, 2, "a");
    try f.send(0, 3, "b");
    try f.send(0, 2, "c");
    try testing.expectEqual(@as(usize, 3), f.pool.queued(0));
    try testing.expectEqual(@as(usize, 2), f.pool.cancel(2));
    try testing.expectEqual(@as(usize, 0), f.pool.cancel(1));
    try testing.expectEqual(@as(usize, 1), f.pool.queued(0));
    f.gate.store(true, .seq_cst);
    try f.waitFor(2);
    try testing.expectEqual(@as(u32, 1), f.replies.items[0].id);
    try testing.expectEqual(@as(u32, 3), f.replies.items[1].id);
    try testing.expectEqualStrings("b0", f.replies.items[1].bytes.?);
}

test "jobs: shutdown stops after the message that runs, and frees the queue (REQ-JOBS-001)" {
    var f: Fixture = .{};
    try f.init(2);
    try f.send(0, 1, "wait");
    while (f.started.load(.seq_cst) == 0) std.Thread.yield() catch {};
    for (0..50) |i| try f.send(0, @intCast(10 + i), "x");
    for (0..5) |i| try f.send(1, @intCast(100 + i), "y");
    // deinit opens the gate, stops each thread and frees the 50 messages
    // that wait. The testing allocator finds a leak.
    f.deinit();
    try testing.expect(f.started.load(.seq_cst) < 1 + 50 + 5 + 1);
}

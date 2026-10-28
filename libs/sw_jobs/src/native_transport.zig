//! The Transport of a native ThreadPool (REQ-JOBS-002). Code that uses a
//! `Transport` runs the same on native threads and on Web Workers.
//!
//! ```zig
//! var pool: jobs.ThreadPool(MyHandler) = undefined;
//! try pool.init(allocator, io, &handlers);
//! try pool.start();
//! var link = jobs.NativeTransport(MyHandler).init(&pool);
//! defer link.deinit();
//! const t = link.transport();
//! _ = t.post(0, "message");
//! ```
const std = @import("std");
const thread_pool = @import("thread_pool.zig");
const transport = @import("transport.zig");

const Transport = transport.Transport;

pub fn NativeTransport(comptime Handler: type) type {
    return struct {
        const Self = @This();
        const Pool = thread_pool.ThreadPool(Handler);

        pool: *Pool,
        /// Replies that arrived and that main did not take yet.
        queue: std.ArrayList(Pool.Reply) = .empty,
        queue_head: usize = 0,
        /// Results that main took, by handle.
        held: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
        next_handle: u32 = 1,

        pub fn init(pool: *Pool) Self {
            return .{ .pool = pool };
        }

        /// Free the results that wait and the held results. Call it before
        /// `deinit` of the pool.
        pub fn deinit(self: *Self) void {
            const a = self.pool.allocator;
            for (self.queue.items[self.queue_head..]) |r| if (r.bytes) |b| a.free(b);
            self.queue.deinit(a);
            var it = self.held.valueIterator();
            while (it.next()) |b| a.free(b.*);
            self.held.deinit(a);
        }

        pub fn transport(self: *Self) Transport {
            return .{ .ptr = self, .vtable = &vtable };
        }

        const vtable: Transport.VTable = .{
            .slots = slots,
            .alive = alive,
            .post = post,
            .broadcast = broadcast,
            .nextLen = nextLen,
            .takeHead = takeHead,
            .held = .{ .read = read, .release = release },
        };

        fn cast(ptr: *anyopaque) *Self {
            return @ptrCast(@alignCast(ptr));
        }

        fn slots(ptr: *anyopaque) usize {
            return cast(ptr).pool.count();
        }

        fn alive(ptr: *anyopaque, slot: usize) bool {
            return slot < cast(ptr).pool.count();
        }

        fn post(ptr: *anyopaque, slot: usize, msg: []const u8) bool {
            const self = cast(ptr);
            const a = self.pool.allocator;
            const copy = a.dupe(u8, msg) catch return false;
            self.pool.post(slot, 0, copy) catch {
                a.free(copy);
                return false;
            };
            return true;
        }

        fn broadcast(ptr: *anyopaque, msg: []const u8) bool {
            cast(ptr).pool.broadcast(0, msg) catch return false;
            return true;
        }

        /// Move the replies of the pool to the queue. A failed message has
        /// no result: the transport drops it.
        fn fill(self: *Self) void {
            if (self.queue_head == self.queue.items.len) {
                self.queue.clearRetainingCapacity();
                self.queue_head = 0;
            }
            self.pool.takeReplies(&self.queue) catch {};
            while (self.queue_head < self.queue.items.len and self.queue.items[self.queue_head].bytes == null) self.queue_head += 1;
        }

        fn nextLen(ptr: *anyopaque) usize {
            const self = cast(ptr);
            self.fill();
            if (self.queue_head == self.queue.items.len) return 0;
            return self.queue.items[self.queue_head].bytes.?.len;
        }

        fn takeHead(ptr: *anyopaque, head: []u8) u32 {
            const self = cast(ptr);
            self.fill();
            if (self.queue_head == self.queue.items.len) return 0;
            const bytes = self.queue.items[self.queue_head].bytes.?;
            const handle = self.next_handle;
            self.held.put(self.pool.allocator, handle, bytes) catch return 0;
            self.queue_head += 1;
            self.next_handle +%= 1;
            if (self.next_handle == 0) self.next_handle = 1;
            const n = @min(head.len, bytes.len);
            @memcpy(head[0..n], bytes[0..n]);
            return handle;
        }

        fn read(ptr: *anyopaque, handle: u32, offset: usize, out: []u8) void {
            const bytes = cast(ptr).held.get(handle) orelse return;
            @memcpy(out, bytes[offset..][0..out.len]);
        }

        fn release(ptr: *anyopaque, handle: u32) void {
            const self = cast(ptr);
            const kv = self.held.fetchRemove(handle) orelse return;
            self.pool.allocator.free(kv.value);
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Answers each message with the message twice.
const Twice = struct {
    allocator: std.mem.Allocator,

    pub fn handle(self: *Twice, msg: []const u8) thread_pool.Answer {
        if (msg.len == 0) return .none;
        const out = self.allocator.alloc(u8, msg.len * 2) catch return .failed;
        @memcpy(out[0..msg.len], msg);
        @memcpy(out[msg.len..], msg);
        return .{ .reply = out };
    }
};

test "jobs: the native pool gives the Transport API (REQ-JOBS-002)" {
    var pool: thread_pool.ThreadPool(Twice) = undefined;
    const handlers = [_]Twice{ .{ .allocator = testing.allocator }, .{ .allocator = testing.allocator } };
    try pool.init(testing.allocator, testing.io, &handlers);
    defer pool.deinit();
    try pool.start();
    var link = NativeTransport(Twice).init(&pool);
    defer link.deinit();
    const t = link.transport();

    try testing.expectEqual(@as(usize, 2), t.slots());
    try testing.expect(t.alive(1) and !t.alive(2));
    try testing.expect(t.post(0, "abc"));
    try testing.expect(t.post(1, ""));
    try testing.expect(t.broadcast("xy"));

    var got: usize = 0;
    var tries: usize = 0;
    var head: [2]u8 = undefined;
    while (got < 3) : (tries += 1) {
        try testing.expect(tries < 20_000);
        if (t.nextLen() == 0) {
            pool.waitForReply(1000);
            continue;
        }
        const len = t.nextLen();
        const h = t.takeHead(&head);
        try testing.expect(h != 0);
        var rest: [6]u8 = undefined;
        t.read(h, 0, rest[0..len]);
        if (len == 6) {
            try testing.expectEqualStrings("abcabc", rest[0..6]);
            try testing.expectEqualStrings("ab", &head);
        } else {
            try testing.expectEqualStrings("xyxy", rest[0..4]);
        }
        t.release(h);
        got += 1;
    }
    try testing.expectEqual(@as(usize, 0), t.nextLen());
    try testing.expectEqual(@as(u32, 0), t.takeHead(&head));
}

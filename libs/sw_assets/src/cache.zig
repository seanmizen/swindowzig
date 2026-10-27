//! A cache of large data that the game made, for example the result of a
//! slow conversion. One API for OPFS (web) and a folder (native).
//!
//!   var w = cache.write("index-v1", bytes);    // write copies the bytes
//!   var r = cache.read(allocator, "index-v1");
//!   ... each frame:
//!   switch (r.poll()) {
//!       .pending => {},
//!       .bytes => |data| { ... allocator.free(data); },
//!       .missing => {},                         // not in the cache
//!       .failed => |err| log(cache.errorMessage(err)),
//!   }
//!
//! Web: the Origin Private File System (OPFS), in the folder
//! `swindowzig-cache`. OPFS needs a secure context (HTTPS, or
//! http://localhost). In other pages each request fails with
//! `error.InsecureContext` (REQ-ASSETS-002). The browser can clear OPFS:
//! the game must be able to make the data again.
//!
//! Native: one file for each name in the folder that the app sets with
//! `useDirectory` or `useDirectoryPath`. `read`, `write` and `delete` do
//! the work before they return, and the first `poll` gives the result.
//!
//! Poll a request until it is not `.pending`. A finished request cannot be
//! polled again. Stop a read that you do not want with `cancel`.
const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.target.cpu.arch == .wasm32;
const web = if (is_wasm) @import("web_blob.zig") else struct {};

/// The cache refuses larger values.
pub const max_size = 1024 * 1024 * 1024;
pub const max_name_len = 128;

pub const CacheError = error{
    /// The name is empty, longer than `max_name_len`, starts with `.`, or
    /// has a character outside [a-z0-9._-].
    InvalidName,
    /// Native: the app did not set a cache folder.
    NoDirectory,
    /// Web: the page is not in a secure context, so OPFS is not available.
    InsecureContext,
    /// Web: the browser has no OPFS, or it blocks it.
    Unavailable,
    /// The value is larger than `max_size`.
    TooLarge,
    /// The storage quota or the disk is full.
    NoSpace,
    /// The read or write failed.
    IoFailed,
    /// The request is finished or not valid.
    InvalidRequest,
    OutOfMemory,
};

/// A sentence for a log line or a screen.
pub fn errorMessage(err: CacheError) []const u8 {
    return switch (err) {
        error.InvalidName => "The cache name is not valid. Use 1 to 128 characters from a-z, 0-9, '.', '_' and '-'. Do not start with '.'.",
        error.NoDirectory => "No cache folder is set. Call cache.useDirectory or cache.useDirectoryPath first.",
        error.InsecureContext => "The cache needs a secure context (HTTPS or http://localhost). This page is not in a secure context, so the browser does not give OPFS.",
        error.Unavailable => "The browser does not give OPFS, or it blocks it. The cache is not available.",
        error.TooLarge => "The value is larger than the size limit.",
        error.NoSpace => "The storage is full.",
        error.IoFailed => "The cache read or write failed.",
        error.InvalidRequest => "The request is finished or not valid.",
        error.OutOfMemory => "Out of memory.",
    };
}

pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len or name[0] == '.') return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

pub const ReadResult = union(enum) {
    pending,
    /// The value. The caller owns it and frees it with the allocator that
    /// was given to `read`.
    bytes: []u8,
    /// The cache has no value with this name.
    missing,
    failed: CacheError,
};

pub const WriteResult = union(enum) {
    pending,
    done,
    failed: CacheError,
};

/// Start to read the value of `name`.
pub fn read(allocator: std.mem.Allocator, name: []const u8) ReadRequest {
    if (!isValidName(name)) return .{ .allocator = allocator, .state = .{ .failed = error.InvalidName } };
    if (is_wasm) return .{ .allocator = allocator, .state = .{ .web = .{ .id = web.jsCacheOpen(name.ptr, name.len) } } };
    return .{ .allocator = allocator, .state = native.read(allocator, name) };
}

/// Start to write `bytes` as the value of `name`. A new value replaces the
/// old value. `write` copies the bytes before it returns.
pub fn write(name: []const u8, bytes: []const u8) WriteRequest {
    if (!isValidName(name)) return .{ .state = .{ .failed = error.InvalidName } };
    if (bytes.len > max_size) return .{ .state = .{ .failed = error.TooLarge } };
    if (is_wasm) return .{ .state = .{ .web = web.jsCacheWrite(name.ptr, name.len, bytes.ptr, bytes.len) } };
    return .{ .state = native.write(name, bytes) };
}

/// Start to delete the value of `name`. A name with no value is not an
/// error.
pub fn delete(name: []const u8) WriteRequest {
    if (!isValidName(name)) return .{ .state = .{ .failed = error.InvalidName } };
    if (is_wasm) return .{ .state = .{ .web = web.jsCacheDelete(name.ptr, name.len) } };
    return .{ .state = native.delete(name) };
}

pub const ReadRequest = struct {
    allocator: std.mem.Allocator,
    state: State,

    const State = union(enum) {
        web: if (is_wasm) web.BlobRead else void,
        bytes: []u8,
        missing,
        failed: CacheError,
        finished,
    };

    pub fn poll(self: *ReadRequest) ReadResult {
        switch (self.state) {
            .web => |*blob| {
                if (!is_wasm) unreachable;
                const step = blob.step(self.allocator, max_size);
                if (step == .pending) return .pending;
                self.state = .finished;
                return switch (step) {
                    .pending => unreachable,
                    .done => |data| .{ .bytes = data },
                    .failed => |code| if (code == web.missing) .missing else .{ .failed = webError(code) },
                };
            },
            .bytes => |data| {
                self.state = .finished;
                return .{ .bytes = data };
            },
            .missing => {
                self.state = .finished;
                return .missing;
            },
            .failed => |err| {
                self.state = .finished;
                return .{ .failed = err };
            },
            .finished => return .{ .failed = error.InvalidRequest },
        }
    }

    /// Stop the request and free its memory. Use it for a request that you
    /// do not poll to the end.
    pub fn cancel(self: *ReadRequest) void {
        switch (self.state) {
            .web => |*blob| if (is_wasm) blob.cancel(self.allocator),
            .bytes => |data| self.allocator.free(data),
            else => {},
        }
        self.state = .finished;
    }
};

pub const WriteRequest = struct {
    state: State,

    const State = union(enum) {
        web: u32,
        done,
        failed: CacheError,
        finished,
    };

    pub fn poll(self: *WriteRequest) WriteResult {
        switch (self.state) {
            .web => |id| {
                if (!is_wasm) unreachable;
                const rc = web.jsBlobPoll(id, max_size);
                if (rc == web.pending) return .pending;
                web.jsBlobDrop(id);
                self.state = .finished;
                return if (rc >= 0) .done else .{ .failed = webError(rc) };
            },
            .done => {
                self.state = .finished;
                return .done;
            },
            .failed => |err| {
                self.state = .finished;
                return .{ .failed = err };
            },
            .finished => return .{ .failed = error.InvalidRequest },
        }
    }
};

fn webError(code: i32) CacheError {
    if (!is_wasm) unreachable;
    return switch (code) {
        web.insecure => error.InsecureContext,
        web.unavailable => error.Unavailable,
        web.too_large => error.TooLarge,
        web.no_space => error.NoSpace,
        web.no_memory => error.OutOfMemory,
        else => error.IoFailed,
    };
}

/// Native only: keep the cache in `dir`. `dir` and `io` must stay valid
/// while the cache is used.
pub fn useDirectory(dir: std.Io.Dir, io: std.Io) void {
    native.store = .{ .dir = dir, .io = io };
}

/// Native only: keep the cache in the folder at `path` (relative to the
/// working directory, or absolute). The folder is made when it does not
/// exist.
pub fn useDirectoryPath(io: std.Io, path: []const u8) !void {
    const dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{});
    useDirectory(dir, io);
}

// ---------------------------------------------------------------------------
// Native backend: one file for each name.
// ---------------------------------------------------------------------------

const native = struct {
    const Store = struct { dir: std.Io.Dir, io: std.Io };
    var store: ?Store = null;

    const tmp_suffix = ".tmp";

    fn read(allocator: std.mem.Allocator, name: []const u8) ReadRequest.State {
        const s = store orelse return .{ .failed = error.NoDirectory };
        const data = s.dir.readFileAlloc(s.io, name, allocator, .limited(max_size + 1)) catch |err| return switch (err) {
            error.FileNotFound => .missing,
            error.OutOfMemory => .{ .failed = error.OutOfMemory },
            error.StreamTooLong => .{ .failed = error.TooLarge },
            else => .{ .failed = error.IoFailed },
        };
        return .{ .bytes = data };
    }

    /// Write to a temporary file, then rename it over the old one. A crash
    /// in the middle leaves the old value.
    fn write(name: []const u8, bytes: []const u8) WriteRequest.State {
        const s = store orelse return .{ .failed = error.NoDirectory };
        var buf: [max_name_len + tmp_suffix.len]u8 = undefined;
        const tmp = std.fmt.bufPrint(&buf, "{s}{s}", .{ name, tmp_suffix }) catch unreachable;
        const file = s.dir.createFile(s.io, tmp, .{ .truncate = true }) catch return .{ .failed = error.IoFailed };
        file.writeStreamingAll(s.io, bytes) catch |err| {
            file.close(s.io);
            s.dir.deleteFile(s.io, tmp) catch {};
            return .{ .failed = if (err == error.NoSpaceLeft) error.NoSpace else error.IoFailed };
        };
        file.close(s.io);
        s.dir.rename(tmp, s.dir, name, s.io) catch return .{ .failed = error.IoFailed };
        return .done;
    }

    fn delete(name: []const u8) WriteRequest.State {
        const s = store orelse return .{ .failed = error.NoDirectory };
        s.dir.deleteFile(s.io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return .{ .failed = error.IoFailed },
        };
        return .done;
    }
};

// ---------------------------------------------------------------------------
// Tests (native backend)
// ---------------------------------------------------------------------------

test "cache: isValidName" {
    try std.testing.expect(isValidName("index-v1"));
    try std.testing.expect(isValidName("a.b_c-9"));
    try std.testing.expect(!isValidName(""));
    try std.testing.expect(!isValidName(".hidden"));
    try std.testing.expect(!isValidName("a/b"));
    try std.testing.expect(!isValidName("A"));
    const long: [max_name_len + 1]u8 = @splat('x');
    try std.testing.expect(!isValidName(&long));
}

test "cache: write, read and delete in a folder" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    defer native.store = null;

    native.store = null;
    var r0 = read(a, "data");
    try std.testing.expectEqual(CacheError.NoDirectory, r0.poll().failed);

    useDirectory(tmp.dir, io);
    var r1 = read(a, "data");
    try std.testing.expect(r1.poll() == .missing);
    try std.testing.expectEqual(CacheError.InvalidRequest, r1.poll().failed);

    var w = write("data", "first");
    try std.testing.expect(w.poll() == .done);
    var w2 = write("data", "second value");
    try std.testing.expect(w2.poll() == .done);

    var r2 = read(a, "data");
    const result = r2.poll();
    try std.testing.expect(result == .bytes);
    defer a.free(result.bytes);
    try std.testing.expectEqualStrings("second value", result.bytes);

    var d = delete("data");
    try std.testing.expect(d.poll() == .done);
    var d2 = delete("data");
    try std.testing.expect(d2.poll() == .done);
    var r3 = read(a, "data");
    try std.testing.expect(r3.poll() == .missing);

    // A read that is not polled frees its memory with cancel.
    var w3 = write("other", "x");
    try std.testing.expect(w3.poll() == .done);
    var r4 = read(a, "other");
    r4.cancel();

    var bad = write("../escape", "x");
    try std.testing.expectEqual(CacheError.InvalidName, bad.poll().failed);
}

test "cache: useDirectoryPath makes the folder" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    defer native.store = null;
    const base = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const path = try std.fs.path.join(std.testing.allocator, &.{ base, "a", "cache" });
    defer std.testing.allocator.free(path);
    try useDirectoryPath(io, path);
    defer native.store.?.dir.close(io);
    var w = write("v", "1");
    try std.testing.expect(w.poll() == .done);
    const data = try tmp.dir.readFileAlloc(io, "a/cache/v", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("1", data);
}

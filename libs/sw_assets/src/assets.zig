//! Asynchronous byte loading. One API for a local folder (native) and for a
//! URL (web).
//!
//!   var request = try assets.loadBytes(allocator, "sprites/hero.png");
//!   ... each frame:
//!   switch (request.poll()) {
//!       .pending => {},                       // not done, try next frame
//!       .bytes => |data| { ... allocator.free(data); },
//!       .failed => |err| log(assets.errorMessage(err)),
//!   }
//!
//! `loadBytes` returns at once and `poll` never waits, so a frame is not
//! blocked. Poll a request until it is not `.pending`. A request that
//! finished cannot be polled again (the next poll returns
//! `error.InvalidRequest`). Do not drop a request that is still pending: it
//! leaks until the platform finishes.
//!
//! Web: the JS bridge (backends/wasm/assets.ts) uses `fetch`. A relative URL
//! resolves against the page.
//!
//! Native: a relative path names a file in the base directory that the app
//! sets with `useDirectory` or `useDirectoryPath`. A thread reads the file.
//! An `http://` or `https://` URL is not supported and fails with
//! `error.UnsupportedUrl`.
const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.target.cpu.arch == .wasm32;

/// Larger files are refused.
pub const max_size = 256 * 1024 * 1024;

pub const LoadError = error{
    /// The source is a URL. Native builds read files only.
    UnsupportedUrl,
    /// The path is empty, absolute, or has a `..` component.
    InvalidPath,
    /// Native: the app did not set a base directory.
    NoBaseDirectory,
    /// The file does not exist, or the server answered 404.
    NotFound,
    /// The file is larger than `max_size`.
    TooLarge,
    /// Native: the file could not be read.
    IoFailed,
    /// Web: the request did not reach the server.
    NetworkFailed,
    /// Web: the server answered with an error status.
    HttpError,
    /// The request was already finished, or is not valid.
    InvalidRequest,
    OutOfMemory,
};

/// A sentence for a log line or a screen.
pub fn errorMessage(err: LoadError) []const u8 {
    return switch (err) {
        error.UnsupportedUrl => "Cannot load a URL on native builds. Use a file path relative to the base directory.",
        error.InvalidPath => "The path must be relative, with no '..' component.",
        error.NoBaseDirectory => "No base directory is set. Call assets.useDirectory or assets.useDirectoryPath first.",
        error.NotFound => "The file was not found.",
        error.TooLarge => "The file is larger than the size limit.",
        error.IoFailed => "The file could not be read.",
        error.NetworkFailed => "The request did not reach the server.",
        error.HttpError => "The server answered with an error status.",
        error.InvalidRequest => "The request is finished or not valid.",
        error.OutOfMemory => "Out of memory.",
    };
}

pub const Result = union(enum) {
    /// Not finished. Poll again next frame.
    pending,
    /// The file. The caller owns the slice and frees it with the allocator
    /// that was given to `loadBytes`.
    bytes: []u8,
    failed: LoadError,
};

/// Start a load. `url_or_path` is a URL (web) or a path relative to the base
/// directory (native). The only error is `OutOfMemory`; every other failure
/// arrives through `Request.poll`.
pub fn loadBytes(allocator: std.mem.Allocator, url_or_path: []const u8) error{OutOfMemory}!Request {
    return .{ .allocator = allocator, .impl = try Impl.start(url_or_path) };
}

pub const Request = struct {
    allocator: std.mem.Allocator,
    impl: Impl,

    pub fn poll(self: *Request) Result {
        return self.impl.poll(self.allocator);
    }
};

/// Native only: read files from `dir`. Call once at startup, before the first
/// `loadBytes`. `dir` and `io` must stay valid while loads run.
pub fn useDirectory(dir: std.Io.Dir, io: std.Io) void {
    native_base = .{ .dir = dir, .io = io };
}

/// Native only: read files from the directory at `path`, relative to the
/// working directory or absolute.
pub fn useDirectoryPath(io: std.Io, path: []const u8) !void {
    const dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    useDirectory(dir, io);
}

const NativeBase = struct { dir: std.Io.Dir, io: std.Io };
var native_base: ?NativeBase = null;

/// True when `source` starts with a URL scheme (`https://`, `http://`, ...).
fn hasUrlScheme(source: []const u8) bool {
    const sep = std.mem.indexOf(u8, source, "://") orelse return false;
    if (sep == 0) return false;
    for (source[0..sep]) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.';
        if (!ok) return false;
    }
    return true;
}

/// The reason a native path is refused, or null when it is a usable relative
/// path.
fn checkRelativePath(path: []const u8) ?LoadError {
    if (path.len == 0) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (path[0] == '/' or path[0] == '\\') return error.InvalidPath;
    // A Windows drive, for example `C:`.
    if (path.len >= 2 and path[1] == ':') return error.InvalidPath;
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.InvalidPath;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Native backend: one thread for each load.
// ---------------------------------------------------------------------------

const Slot = struct {
    const State = enum(u8) { pending, done, failed };

    /// The thread writes `bytes` or `err`, then stores `done` or `failed`
    /// with release order. `poll` loads with acquire order and then reads.
    state: std.atomic.Value(State) = .init(.pending),
    path: []u8 = &.{},
    base: ?NativeBase = null,
    bytes: []u8 = &.{},
    err: LoadError = error.IoFailed,

    // The thread and the main thread share these allocations, so they come
    // from a thread safe allocator, not from the app's.
    const slot_allocator = std.heap.smp_allocator;

    fn run(self: *Slot) void {
        const base = self.base.?;
        if (base.dir.readFileAlloc(base.io, self.path, slot_allocator, .limited(max_size))) |data| {
            self.bytes = data;
            self.state.store(.done, .release);
        } else |err| {
            self.err = switch (err) {
                error.FileNotFound => error.NotFound,
                error.OutOfMemory => error.OutOfMemory,
                else => error.IoFailed,
            };
            self.state.store(.failed, .release);
        }
    }

    fn destroy(self: *Slot) void {
        slot_allocator.free(self.bytes);
        slot_allocator.free(self.path);
        slot_allocator.destroy(self);
    }
};

const NativeImpl = struct {
    slot: ?*Slot,

    fn start(source: []const u8) error{OutOfMemory}!NativeImpl {
        const slot = try Slot.slot_allocator.create(Slot);
        slot.* = .{};
        errdefer Slot.slot_allocator.destroy(slot);

        if (hasUrlScheme(source)) {
            slot.err = error.UnsupportedUrl;
        } else if (checkRelativePath(source)) |err| {
            slot.err = err;
        } else if (native_base == null) {
            slot.err = error.NoBaseDirectory;
        } else {
            slot.path = try Slot.slot_allocator.dupe(u8, source);
            slot.base = native_base;
            const thread = std.Thread.spawn(.{}, Slot.run, .{slot}) catch {
                slot.err = error.IoFailed;
                slot.state.store(.failed, .release);
                return .{ .slot = slot };
            };
            thread.detach();
            return .{ .slot = slot };
        }
        slot.state.store(.failed, .release);
        return .{ .slot = slot };
    }

    fn poll(self: *NativeImpl, allocator: std.mem.Allocator) Result {
        const slot = self.slot orelse return .{ .failed = error.InvalidRequest };
        switch (slot.state.load(.acquire)) {
            .pending => return .pending,
            .done => {
                const copy = allocator.dupe(u8, slot.bytes);
                slot.destroy();
                self.slot = null;
                return if (copy) |data| .{ .bytes = data } else |_| .{ .failed = error.OutOfMemory };
            },
            .failed => {
                const err = slot.err;
                slot.destroy();
                self.slot = null;
                return .{ .failed = err };
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Web backend: JS bridge (backends/wasm/assets.ts).
// ---------------------------------------------------------------------------

const web = if (is_wasm) struct {
    // Return codes of jsFetchPoll, other than a length (0 or more).
    const pending = -1;
    const network_failed = -2;
    const http_error = -3;
    const not_found = -4;
    const too_large = -5;

    /// Start `fetch(url)`. Returns a request id (1 or more).
    extern fn jsFetchStart(url_ptr: [*]const u8, url_len: usize, max_size: usize) u32;
    /// The body length when the body is read, or a negative code.
    extern fn jsFetchPoll(id: u32) i32;
    /// Copy the body to `dst` and forget the request.
    extern fn jsFetchTake(id: u32, dst: [*]u8) void;
    /// Forget the request.
    extern fn jsFetchDrop(id: u32) void;
} else struct {};

const WebImpl = struct {
    id: u32,

    fn start(source: []const u8) error{OutOfMemory}!WebImpl {
        return .{ .id = web.jsFetchStart(source.ptr, source.len, max_size) };
    }

    fn poll(self: *WebImpl, allocator: std.mem.Allocator) Result {
        if (self.id == 0) return .{ .failed = error.InvalidRequest };
        const rc = web.jsFetchPoll(self.id);
        if (rc == web.pending) return .pending;
        const id = self.id;
        self.id = 0;
        if (rc >= 0) {
            const out = allocator.alloc(u8, @intCast(rc)) catch {
                web.jsFetchDrop(id);
                return .{ .failed = error.OutOfMemory };
            };
            web.jsFetchTake(id, out.ptr);
            return .{ .bytes = out };
        }
        web.jsFetchDrop(id);
        return .{ .failed = switch (rc) {
            web.not_found => error.NotFound,
            web.http_error => error.HttpError,
            web.too_large => error.TooLarge,
            else => error.NetworkFailed,
        } };
    }
};

const Impl = if (is_wasm) WebImpl else NativeImpl;

// ---------------------------------------------------------------------------
// Tests (native backend)
// ---------------------------------------------------------------------------

/// Poll until the request is not pending. A test timeout of 10 s stops a
/// request that never finishes.
fn waitFor(request: *Request) !Result {
    var tries: usize = 0;
    while (tries < 10_000_000) : (tries += 1) {
        const result = request.poll();
        if (result != .pending) return result;
        std.Thread.yield() catch {};
    }
    return error.Timeout;
}

test "hasUrlScheme" {
    try std.testing.expect(hasUrlScheme("http://example.com/a.png"));
    try std.testing.expect(hasUrlScheme("https://cdn.example.com/a.png"));
    try std.testing.expect(hasUrlScheme("file://x"));
    try std.testing.expect(!hasUrlScheme("sprites/a.png"));
    try std.testing.expect(!hasUrlScheme("a.png"));
    try std.testing.expect(!hasUrlScheme("://x"));
    try std.testing.expect(!hasUrlScheme("dir name/a://b"));
}

test "checkRelativePath" {
    try std.testing.expect(checkRelativePath("a.png") == null);
    try std.testing.expect(checkRelativePath("sprites/a.png") == null);
    try std.testing.expect(checkRelativePath("./a..b.png") == null);
    try std.testing.expect(checkRelativePath("") != null);
    try std.testing.expect(checkRelativePath("/etc/passwd") != null);
    try std.testing.expect(checkRelativePath("\\windows") != null);
    try std.testing.expect(checkRelativePath("C:/x") != null);
    try std.testing.expect(checkRelativePath("../x") != null);
    try std.testing.expect(checkRelativePath("a/../../x") != null);
    try std.testing.expect(checkRelativePath("a\\..\\x") != null);
    try std.testing.expect(checkRelativePath("a\x00b") != null);
}

test "loadBytes: reads a file from the base directory without blocking" {
    if (is_wasm) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    defer native_base = null;

    const content = [_]u8{ 0, 1, 2, 255, 0, 10, 13 };
    const file = try tmp.dir.createFile(io, "data.bin", .{});
    try file.writeStreamingAll(io, &content);
    file.close(io);
    useDirectory(tmp.dir, io);

    var request = try loadBytes(a, "data.bin");
    const result = try waitFor(&request);
    try std.testing.expect(result == .bytes);
    defer a.free(result.bytes);
    try std.testing.expectEqualSlices(u8, &content, result.bytes);

    // A finished request cannot be polled again.
    try std.testing.expectEqual(LoadError.InvalidRequest, request.poll().failed);
}

test "loadBytes: errors arrive through poll" {
    if (is_wasm) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // No base directory yet.
    native_base = null;
    var r0 = try loadBytes(a, "a.bin");
    try std.testing.expectEqual(LoadError.NoBaseDirectory, (try waitFor(&r0)).failed);

    useDirectory(tmp.dir, io);
    defer native_base = null;

    var r1 = try loadBytes(a, "missing.bin");
    try std.testing.expectEqual(LoadError.NotFound, (try waitFor(&r1)).failed);

    var r2 = try loadBytes(a, "https://cdn.example.com/a.png");
    try std.testing.expectEqual(LoadError.UnsupportedUrl, (try waitFor(&r2)).failed);

    var r3 = try loadBytes(a, "../escape.bin");
    try std.testing.expectEqual(LoadError.InvalidPath, (try waitFor(&r3)).failed);

    // The URL message names the problem.
    try std.testing.expect(std.mem.indexOf(u8, errorMessage(error.UnsupportedUrl), "URL") != null);
}

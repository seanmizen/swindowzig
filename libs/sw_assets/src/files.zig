//! Files that the player gives to the game.
//!
//!   // Each frame:
//!   switch (files.poll(allocator)) {
//!       .none, .loading => {},
//!       .file => |file| { defer file.deinit(allocator); use(file.name, file.bytes); },
//!       .failed => |err| log(files.errorMessage(err)),
//!   }
//!
//! Web: the player drops a file on the page, or chooses one in the file
//! chooser (`showPicker`). The page can also give files with `offerFiles`
//! in `backends/wasm/files.ts`. JS copies the file into memory that `poll`
//! allocated, in chunks: a large file does not stop a frame.
//!
//! Native: the app gives a path with `offerPath`, for example from the
//! command line. The `poll` that returns the file reads it.
//!
//! `poll` returns one file at a time, in the order that they arrived. Use
//! the same allocator for each call.
const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.target.cpu.arch == .wasm32;
const web = if (is_wasm) @import("web_blob.zig") else struct {};

/// `poll` refuses larger files.
pub const max_file_size = 1024 * 1024 * 1024;
/// A longer name is cut to this length.
pub const max_name_len = 255;

pub const FileError = error{
    /// The file is larger than `max_file_size`.
    TooLarge,
    /// The file could not be read (it was removed, or access stopped).
    ReadFailed,
    /// Native: no file is at the path.
    NotFound,
    OutOfMemory,
};

/// A sentence for a log line or a screen.
pub fn errorMessage(err: FileError) []const u8 {
    return switch (err) {
        error.TooLarge => "The file is larger than the size limit.",
        error.ReadFailed => "The file could not be read.",
        error.NotFound => "The file was not found.",
        error.OutOfMemory => "Out of memory.",
    };
}

pub const PlayerFile = struct {
    /// The file name, with no folder.
    name: []u8,
    bytes: []u8,

    pub fn deinit(self: PlayerFile, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.bytes);
    }
};

pub const Event = union(enum) {
    /// No file is waiting.
    none,
    /// A file is on its way. Poll again next frame.
    loading,
    /// The caller owns the file and frees it with `deinit`.
    file: PlayerFile,
    failed: FileError,
};

/// Get the next file from the player. It never waits on the web.
pub fn poll(allocator: std.mem.Allocator) Event {
    return if (is_wasm) web_inbox.poll(allocator) else native_inbox.poll(allocator);
}

/// Web: open the file chooser of the browser. `accept` is the `accept`
/// value of a file input, for example ".zip" or "" for all files. A
/// browser opens the chooser only shortly after a click or a key press of
/// the player. Returns false on native, or when the page cannot open it.
pub fn showPicker(accept: []const u8) bool {
    if (!is_wasm) return false;
    return web.jsFilePicker(accept.ptr, accept.len) == 1;
}

pub const OfferError = error{
    /// The queue holds `max_offers` paths that `poll` did not take.
    QueueFull,
    OutOfMemory,
};

/// Native: the number of paths that can wait for `poll`.
pub const max_offers = 8;

/// Native only: give the file at `path` (absolute, or relative to the
/// working directory) to the game. A later `poll` reads it. `io` must
/// stay valid until then.
pub fn offerPath(io: std.Io, path: []const u8) OfferError!void {
    if (is_wasm) @compileError("offerPath is native only. On the web, the player gives files.");
    return native_inbox.offer(io, path);
}

// ---------------------------------------------------------------------------
// Web backend
// ---------------------------------------------------------------------------

const WebInbox = struct {
    read: ?web.BlobRead = null,
    name: [max_name_len]u8 = undefined,
    name_len: usize = 0,

    fn poll(self: *WebInbox, allocator: std.mem.Allocator) Event {
        if (self.read == null) {
            const id = web.jsFileNext();
            if (id == 0) return .none;
            self.name_len = web.jsBlobName(id, &self.name, self.name.len);
            self.read = .{ .id = id };
        }
        const step = self.read.?.step(allocator, max_file_size);
        switch (step) {
            .pending => return .loading,
            .done => |bytes| {
                self.read = null;
                const name = allocator.dupe(u8, self.name[0..self.name_len]) catch {
                    allocator.free(bytes);
                    return .{ .failed = error.OutOfMemory };
                };
                return .{ .file = .{ .name = name, .bytes = bytes } };
            },
            .failed => |code| {
                self.read = null;
                return .{ .failed = switch (code) {
                    web.too_large => error.TooLarge,
                    web.no_memory => error.OutOfMemory,
                    else => error.ReadFailed,
                } };
            },
        }
    }
};

var web_inbox: WebInbox = .{};

// ---------------------------------------------------------------------------
// Native backend
// ---------------------------------------------------------------------------

const NativeInbox = struct {
    const Offer = struct { io: std.Io, path: []u8 };
    const path_allocator = std.heap.page_allocator;

    offers: [max_offers]Offer = undefined,
    len: usize = 0,

    fn offer(self: *NativeInbox, io: std.Io, path: []const u8) OfferError!void {
        if (self.len == max_offers) return error.QueueFull;
        self.offers[self.len] = .{ .io = io, .path = try path_allocator.dupe(u8, path) };
        self.len += 1;
    }

    fn poll(self: *NativeInbox, allocator: std.mem.Allocator) Event {
        if (self.len == 0) return .none;
        const next = self.offers[0];
        std.mem.copyForwards(Offer, self.offers[0 .. self.len - 1], self.offers[1..self.len]);
        self.len -= 1;
        defer path_allocator.free(next.path);
        return readPath(allocator, next.io, next.path);
    }
};

var native_inbox: NativeInbox = .{};

fn readPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) Event {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_size)) catch |err| return .{ .failed = switch (err) {
        error.FileNotFound => error.NotFound,
        error.StreamTooLong => error.TooLarge,
        error.OutOfMemory => error.OutOfMemory,
        else => error.ReadFailed,
    } };
    const base = std.fs.path.basename(path);
    const name = allocator.dupe(u8, base[0..@min(base.len, max_name_len)]) catch {
        allocator.free(bytes);
        return .{ .failed = error.OutOfMemory };
    };
    return .{ .file = .{ .name = name, .bytes = bytes } };
}

// ---------------------------------------------------------------------------
// Tests (native backend)
// ---------------------------------------------------------------------------

test "files: a path from offerPath arrives through poll" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content = [_]u8{ 'P', 'K', 0, 255, 7 };
    try tmp.dir.writeFile(io, .{ .sub_path = "archive.zip", .data = &content });
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir_path);
    const path = try std.fs.path.join(a, &.{ dir_path, "archive.zip" });
    defer a.free(path);
    const missing = try std.fs.path.join(a, &.{ dir_path, "missing.zip" });
    defer a.free(missing);

    try std.testing.expect(poll(a) == .none);
    try offerPath(io, path);
    try offerPath(io, missing);

    const first = poll(a);
    try std.testing.expect(first == .file);
    defer first.file.deinit(a);
    try std.testing.expectEqualStrings("archive.zip", first.file.name);
    try std.testing.expectEqualSlices(u8, &content, first.file.bytes);

    try std.testing.expectEqual(FileError.NotFound, poll(a).failed);
    try std.testing.expect(poll(a) == .none);
}

test "files: the queue has a limit, and the picker is web only" {
    const io = std.testing.io;
    defer while (native_inbox.len > 0) {
        native_inbox.len -= 1;
        NativeInbox.path_allocator.free(native_inbox.offers[native_inbox.len].path);
    };
    for (0..max_offers) |_| try offerPath(io, "x");
    try std.testing.expectError(error.QueueFull, offerPath(io, "x"));
    try std.testing.expect(!showPicker(".zip"));
}

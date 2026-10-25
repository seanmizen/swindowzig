// Local key-value storage for saves.
//
//   storageGet(allocator, key) -> ?[]u8   (null when the key is not set)
//   storageSet(key, bytes)
//   storageDelete(key)                    (a key that is not set is not an error)
//
// Web: the JS bridge (backends/wasm/storage.ts) keeps each value in
// localStorage as base64. Native: each value is a file in a directory that
// the platform gives to `useDirectory` (SDL_GetPrefPath, see native_sdl.zig).
// Storage can be unavailable (private browsing, a full quota, no data
// directory). Then every call returns error.StorageUnavailable or
// error.StorageFailed, and the game continues.
const std = @import("std");
const builtin = @import("builtin");

pub const max_key_len = 64;

/// Values larger than this are refused on read and write.
pub const max_value_len = 16 * 1024 * 1024;

pub const Error = error{
    /// The key is empty, longer than `max_key_len`, or has a character
    /// outside [a-z0-9_-].
    InvalidKey,
    /// No storage backend exists (the native directory is not set, or the
    /// browser blocks localStorage).
    StorageUnavailable,
    /// The backend exists, but the operation failed (quota, I/O error).
    StorageFailed,
    OutOfMemory,
};

pub fn isValidKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_key_len) return false;
    for (key) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

const is_wasm = builtin.target.cpu.arch == .wasm32;

/// Read the value of `key`. The caller owns the returned slice. Returns null
/// when the key is not set.
pub fn storageGet(allocator: std.mem.Allocator, key: []const u8) Error!?[]u8 {
    if (!isValidKey(key)) return error.InvalidKey;
    if (is_wasm) return web.get(allocator, key);
    const store = native_store orelse return error.StorageUnavailable;
    return store.get(allocator, key);
}

/// Set `key` to `bytes`. A value that exists is replaced.
pub fn storageSet(key: []const u8, bytes: []const u8) Error!void {
    if (!isValidKey(key)) return error.InvalidKey;
    if (bytes.len > max_value_len) return error.StorageFailed;
    if (is_wasm) return web.set(key, bytes);
    const store = native_store orelse return error.StorageUnavailable;
    return store.set(key, bytes);
}

/// Remove `key`. A key that is not set is not an error.
pub fn storageDelete(key: []const u8) Error!void {
    if (!isValidKey(key)) return error.InvalidKey;
    if (is_wasm) return web.delete(key);
    const store = native_store orelse return error.StorageUnavailable;
    return store.delete(key);
}

// ---------------------------------------------------------------------------
// Native backend: one file per key.
// ---------------------------------------------------------------------------

/// A directory that holds one `<key>.sav` file per key. The directory must
/// exist. `native_sdl.initStorage` opens the per-user data directory.
pub const FileStore = struct {
    dir: std.Io.Dir,
    io: std.Io,

    const suffix = ".sav";
    const tmp_suffix = ".tmp";

    fn path(buf: *[max_key_len + suffix.len]u8, key: []const u8, sfx: []const u8) []const u8 {
        @memcpy(buf[0..key.len], key);
        @memcpy(buf[key.len..][0..sfx.len], sfx);
        return buf[0 .. key.len + sfx.len];
    }

    pub fn get(self: FileStore, allocator: std.mem.Allocator, key: []const u8) Error!?[]u8 {
        if (!isValidKey(key)) return error.InvalidKey;
        var buf: [max_key_len + suffix.len]u8 = undefined;
        const data = self.dir.readFileAlloc(self.io, path(&buf, key, suffix), allocator, .limited(max_value_len)) catch |err| switch (err) {
            error.FileNotFound => return null,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.StorageFailed,
        };
        return data;
    }

    /// Write to a temporary file, then rename it over the old one. A crash in
    /// the middle leaves the old value.
    pub fn set(self: FileStore, key: []const u8, bytes: []const u8) Error!void {
        if (!isValidKey(key)) return error.InvalidKey;
        var tmp_buf: [max_key_len + suffix.len]u8 = undefined;
        var final_buf: [max_key_len + suffix.len]u8 = undefined;
        const tmp_path = path(&tmp_buf, key, tmp_suffix);
        const final_path = path(&final_buf, key, suffix);

        const file = self.dir.createFile(self.io, tmp_path, .{ .truncate = true }) catch return error.StorageFailed;
        file.writeStreamingAll(self.io, bytes) catch {
            file.close(self.io);
            return error.StorageFailed;
        };
        file.close(self.io);
        self.dir.rename(tmp_path, self.dir, final_path, self.io) catch return error.StorageFailed;
    }

    pub fn delete(self: FileStore, key: []const u8) Error!void {
        if (!isValidKey(key)) return error.InvalidKey;
        var buf: [max_key_len + suffix.len]u8 = undefined;
        self.dir.deleteFile(self.io, path(&buf, key, suffix)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return error.StorageFailed,
        };
    }
};

var native_store: ?FileStore = null;

/// Native only: store values in `dir`. Call once at startup.
pub fn useDirectory(dir: std.Io.Dir, io: std.Io) void {
    native_store = .{ .dir = dir, .io = io };
}

// ---------------------------------------------------------------------------
// Web backend: JS bridge (backends/wasm/storage.ts).
// ---------------------------------------------------------------------------

const web = if (is_wasm) struct {
    // Return codes of the JS side.
    const ok = 0;
    const missing = -1;
    const unavailable = -2;

    // Reads the value into a JS buffer. Returns its length, `missing`, or
    // `unavailable`. `jsStorageTake` then copies the buffer to `dst`.
    extern fn jsStorageGet(key_ptr: [*]const u8, key_len: usize) i32;
    extern fn jsStorageTake(dst: [*]u8) void;
    extern fn jsStorageSet(key_ptr: [*]const u8, key_len: usize, val_ptr: [*]const u8, val_len: usize) i32;
    extern fn jsStorageDelete(key_ptr: [*]const u8, key_len: usize) i32;

    fn get(allocator: std.mem.Allocator, key: []const u8) Error!?[]u8 {
        const len = jsStorageGet(key.ptr, key.len);
        if (len == missing) return null;
        if (len < 0) return error.StorageUnavailable;
        const out = try allocator.alloc(u8, @intCast(len));
        jsStorageTake(out.ptr);
        return out;
    }

    fn set(key: []const u8, bytes: []const u8) Error!void {
        const rc = jsStorageSet(key.ptr, key.len, bytes.ptr, bytes.len);
        if (rc == ok) return;
        return if (rc == unavailable) error.StorageUnavailable else error.StorageFailed;
    }

    fn delete(key: []const u8) Error!void {
        const rc = jsStorageDelete(key.ptr, key.len);
        if (rc == ok) return;
        return if (rc == unavailable) error.StorageUnavailable else error.StorageFailed;
    }
} else struct {};

// ---------------------------------------------------------------------------
// Tests (native backend, temporary directory)
// ---------------------------------------------------------------------------

test "isValidKey" {
    try std.testing.expect(isValidKey("save-1_a"));
    try std.testing.expect(isValidKey(&@as([max_key_len]u8, @splat('a'))));
    try std.testing.expect(!isValidKey(""));
    try std.testing.expect(!isValidKey(&@as([max_key_len + 1]u8, @splat('a'))));
    try std.testing.expect(!isValidKey("Save"));
    try std.testing.expect(!isValidKey("a.b"));
    try std.testing.expect(!isValidKey("a/b"));
    try std.testing.expect(!isValidKey("../x"));
    try std.testing.expect(!isValidKey("a b"));
    try std.testing.expect(!isValidKey("a\x00b"));
}

test "FileStore: set, get, replace, delete" {
    if (is_wasm) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const store: FileStore = .{ .dir = tmp.dir, .io = io };
    const a = std.testing.allocator;

    try std.testing.expect((try store.get(a, "slot-1")) == null);

    try store.set("slot-1", "hello");
    const v1 = (try store.get(a, "slot-1")).?;
    defer a.free(v1);
    try std.testing.expectEqualSlices(u8, "hello", v1);

    // Binary bytes, including zero, survive.
    const bin = [_]u8{ 0, 1, 2, 255, 0, 10, 13 };
    try store.set("slot-1", &bin);
    const v2 = (try store.get(a, "slot-1")).?;
    defer a.free(v2);
    try std.testing.expectEqualSlices(u8, &bin, v2);

    // An empty value is a value, not a missing key.
    try store.set("empty", "");
    const v3 = (try store.get(a, "empty")).?;
    defer a.free(v3);
    try std.testing.expectEqual(@as(usize, 0), v3.len);

    try store.delete("slot-1");
    try std.testing.expect((try store.get(a, "slot-1")) == null);
    // Delete of a key that is not set is not an error.
    try store.delete("slot-1");
}

test "FileStore: invalid keys return an error" {
    if (is_wasm) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store: FileStore = .{ .dir = tmp.dir, .io = std.testing.io };
    const a = std.testing.allocator;

    try std.testing.expectError(error.InvalidKey, store.get(a, "../escape"));
    try std.testing.expectError(error.InvalidKey, store.set("UPPER", "x"));
    try std.testing.expectError(error.InvalidKey, store.set("", "x"));
    try std.testing.expectError(error.InvalidKey, store.delete("a/b"));
    try std.testing.expectError(error.InvalidKey, store.set(&@as([max_key_len + 1]u8, @splat('a')), "x"));
}

test "public API: error before the directory is set, then works" {
    if (is_wasm) return error.SkipZigTest;
    const a = std.testing.allocator;
    native_store = null;
    try std.testing.expectError(error.StorageUnavailable, storageGet(a, "k"));
    try std.testing.expectError(error.StorageUnavailable, storageSet("k", "v"));
    try std.testing.expectError(error.StorageUnavailable, storageDelete("k"));
    // A bad key is reported before the missing backend.
    try std.testing.expectError(error.InvalidKey, storageSet("BAD", "v"));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    useDirectory(tmp.dir, std.testing.io);
    defer native_store = null;

    try storageSet("k", "v");
    const got = (try storageGet(a, "k")).?;
    defer a.free(got);
    try std.testing.expectEqualSlices(u8, "v", got);
    try storageDelete("k");
    try std.testing.expect((try storageGet(a, "k")) == null);
}

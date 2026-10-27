//! A wasm program that uses the web parts of sw_assets: the zip reader, the
//! player files and the cache. `zig build test` builds it for
//! wasm32-freestanding, to check that they compile and link.
//! `backends/wasm/files.test.ts` builds it too, and runs it with the JS
//! bridge (backends/wasm/files.ts) to test the two sides together.

const std = @import("std");
const sw_assets = @import("sw_assets");

const alloc = std.heap.wasm_allocator;

/// The last result: file bytes, a cache value, or an error name.
var out: []const u8 = &.{};
var out_owned: ?[]u8 = null;
var name: []u8 = &.{};

var write_request: ?sw_assets.cache.WriteRequest = null;
var read_request: ?sw_assets.cache.ReadRequest = null;

fn setOut(bytes: []u8) void {
    clearOut();
    out_owned = bytes;
    out = bytes;
}

fn setError(err: anyerror) void {
    clearOut();
    out = @errorName(err);
}

fn clearOut() void {
    if (out_owned) |owned| alloc.free(owned);
    out_owned = null;
    out = &.{};
}

export fn check_alloc(len: usize) ?[*]u8 {
    const buf = alloc.alloc(u8, len) catch return null;
    return buf.ptr;
}

export fn check_out_ptr() [*]const u8 {
    return out.ptr;
}

export fn check_out_len() usize {
    return out.len;
}

export fn check_name_ptr() [*]const u8 {
    return name.ptr;
}

export fn check_name_len() usize {
    return name.len;
}

/// The number of entries, and the first entry in `out`. -1 on an error.
export fn check_zip(ptr: [*]const u8, len: usize) i32 {
    var archive = sw_assets.zip.Archive.open(alloc, ptr[0..len], .{}) catch |err| {
        setError(err);
        return -1;
    };
    defer archive.deinit(alloc);
    if (archive.entries.len == 0) return 0;
    const data = archive.read(alloc, &archive.entries[0]) catch |err| {
        setError(err);
        return -1;
    };
    setOut(data);
    return @intCast(archive.entries.len);
}

export fn check_picker(ptr: [*]const u8, len: usize) bool {
    return sw_assets.files.showPicker(ptr[0..len]);
}

/// 0 none, 1 loading, 2 a file (in `out` and `name`), -1 failed.
export fn check_file_poll() i32 {
    switch (sw_assets.files.poll(alloc)) {
        .none => return 0,
        .loading => return 1,
        .file => |file| {
            alloc.free(name);
            name = file.name;
            setOut(file.bytes);
            return 2;
        },
        .failed => |err| {
            setError(err);
            return -1;
        },
    }
}

export fn check_cache_write(name_ptr: [*]const u8, name_len: usize, ptr: [*]const u8, len: usize) void {
    write_request = sw_assets.cache.write(name_ptr[0..name_len], ptr[0..len]);
}

export fn check_cache_delete(name_ptr: [*]const u8, name_len: usize) void {
    write_request = sw_assets.cache.delete(name_ptr[0..name_len]);
}

/// 1 pending, 2 done, -1 failed.
export fn check_cache_write_poll() i32 {
    switch (write_request.?.poll()) {
        .pending => return 1,
        .done => return 2,
        .failed => |err| {
            setError(err);
            return -1;
        },
    }
}

export fn check_cache_read(name_ptr: [*]const u8, name_len: usize) void {
    read_request = sw_assets.cache.read(alloc, name_ptr[0..name_len]);
}

export fn check_cache_read_cancel() void {
    read_request.?.cancel();
}

/// 1 pending, 2 bytes (in `out`), 3 missing, -1 failed.
export fn check_cache_read_poll() i32 {
    switch (read_request.?.poll()) {
        .pending => return 1,
        .bytes => |data| {
            setOut(data);
            return 2;
        },
        .missing => return 3,
        .failed => |err| {
            setError(err);
            return -1;
        },
    }
}

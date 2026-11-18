//! Functions the Freenet node provides to Wasm modules: randomness, logging,
//! the clock, and (delegates only) secrets and context.
//!
//! On wasm32 these call the node's imports. In native builds (`zig build
//! test`) they go to `native`, an in-memory stand-in that `freenet.testing`
//! controls, so the same code can be unit-tested without a node.

const std = @import("std");
const abi = @import("abi.zig");

// ---- instance id ------------------------------------------------------------
// The node calls the exported `__frnt_set_id` after instantiation; the rand
// and log imports need that id. Delegate secrets/context don't.

var instance_id: i64 = -1;

pub fn setInstanceId(id: i64) callconv(.c) void {
    instance_id = id;
}

// ---- node imports (only referenced on wasm32) ------------------------------

const imports = struct {
    extern "freenet_rand" fn __frnt__rand__rand_bytes(id: i64, ptr: i64, len: u32) void;
    extern "freenet_log" fn __frnt__logger__info(id: i64, ptr: i64, len: i32) void;
    extern "freenet_time" fn __frnt__time__utc_now(id: i64, ptr: i64) void;

    extern "freenet_delegate_ctx" fn __frnt__delegate__ctx_len() i32;
    extern "freenet_delegate_ctx" fn __frnt__delegate__ctx_read(ptr: i64, len: i32) i32;
    extern "freenet_delegate_ctx" fn __frnt__delegate__ctx_write(ptr: i64, len: i32) i32;

    extern "freenet_delegate_secrets" fn __frnt__delegate__get_secret(key_ptr: i64, key_len: i32, out_ptr: i64, out_len: i32) i32;
    extern "freenet_delegate_secrets" fn __frnt__delegate__get_secret_len(key_ptr: i64, key_len: i32) i32;
    extern "freenet_delegate_secrets" fn __frnt__delegate__set_secret(key_ptr: i64, key_len: i32, val_ptr: i64, val_len: i32) i32;
    extern "freenet_delegate_secrets" fn __frnt__delegate__has_secret(key_ptr: i64, key_len: i32) i32;
    extern "freenet_delegate_secrets" fn __frnt__delegate__remove_secret(key_ptr: i64, key_len: i32) i32;
    extern "freenet_delegate_secrets" fn __frnt__delegate__list_secrets_len(prefix_ptr: i64, prefix_len: i32) i32;
    extern "freenet_delegate_secrets" fn __frnt__delegate__list_secrets(prefix_ptr: i64, prefix_len: i32, out_ptr: i64, out_len: i32) i32;
};

fn p(ptr: anytype) i64 {
    return abi.ptrToI64(ptr);
}

fn len32(s: []const u8) i32 {
    return @intCast(s.len);
}

/// A byte count the node returned, limited to the buffer we gave it.
fn clamp(n: i32, max: usize) usize {
    return @min(@as(usize, @intCast(@max(n, 0))), max);
}

// ---- randomness -------------------------------------------------------------

/// Cryptographically secure randomness from the node.
///
/// Only use this in delegates: a contract must compute the same result on
/// every peer, so contracts cannot use randomness meaningfully
/// (`freenet-check-wasm` rejects contracts that import it).
pub const random = struct {
    pub const Error = error{RandUnavailable};

    /// Fills `buf` with random bytes. Fails if the node never told us our
    /// instance id (it would otherwise leave `buf` untouched).
    pub fn bytes(buf: []u8) Error!void {
        if (instance_id == -1) return error.RandUnavailable;
        if (abi.is_wasm) {
            imports.__frnt__rand__rand_bytes(instance_id, p(buf.ptr), @intCast(buf.len));
        } else {
            native.rand_fn(buf);
        }
    }

    /// A uniformly random integer of type `T`.
    pub fn int(comptime T: type) Error!T {
        var b: [@sizeOf(T)]u8 = undefined;
        try bytes(&b);
        return std.mem.readInt(T, &b, .little);
    }

    /// A uniformly random integer in `[lo, hi]` (inclusive), without modulo
    /// bias (rejection sampling).
    pub fn intRange(comptime T: type, lo: T, hi: T) Error!T {
        comptime std.debug.assert(@typeInfo(T).int.bits <= 32);
        std.debug.assert(lo <= hi);
        const span: u64 = @as(u64, @intCast(@as(i64, hi) - @as(i64, lo))) + 1;
        const limit: u64 = (@as(u64, 1) << 32) / span * span;
        while (true) {
            const v: u64 = try int(u32);
            if (v < limit) return @intCast(@as(i64, lo) + @as(i64, @intCast(v % span)));
        }
    }
};

// ---- the clock --------------------------------------------------------------

/// The node's wall clock (UTC).
///
/// Only use this in delegates: a contract must compute the same result on
/// every peer, and the node deprecates contracts reading the clock (a call
/// from a contract will trap: freenet-core #5465).
pub const time = struct {
    /// Milliseconds since 1970-01-01 UTC by the node's clock, or null when
    /// the node gives none this library can read (no instance id, or a value
    /// that doesn't decode: see `decodeChrono`).
    pub fn nowMs() ?i64 {
        if (abi.is_wasm) {
            if (instance_id == -1) return null;
            // the node writes `size_of::<DateTime<Utc>>()` bytes (12 today); room to spare
            var buf: [32]u8 align(8) = @splat(0);
            imports.__frnt__time__utc_now(instance_id, p(&buf));
            return decodeChrono(buf[0..12].*);
        }
        return native.clock_fn();
    }

    /// Seconds since 1970-01-01 UTC by the node's clock, or null (`nowMs`).
    pub fn nowSeconds() ?i64 {
        return @divFloor(nowMs() orelse return null, 1000);
    }

    /// The node writes a raw Rust `chrono::DateTime<Utc>` (freenet-stdlib's
    /// `time::now` transmutes it back): no stable format, so this decodes
    /// chrono 0.4.45's in-memory layout (the node's: `strings freenet-bin |
    /// grep chrono-0.4`) and checks every part of it. Three little-endian
    /// 4-byte words in declaration order: the date's `yof` (`(year << 13) |
    /// (ordinal << 4) | flags`: bit 3 is 0 in a leap year, bits 0-2 a
    /// weekday never 0), the time's `secs` (since midnight) and `frac`
    /// (nanoseconds; 1e9 to 2e9 in a leap second). A layout that changed
    /// fails the checks (another word read as the date names no plausible
    /// year), so this answers null rather than a wrong time.
    pub fn decodeChrono(b: [12]u8) ?i64 {
        const yof = std.mem.readInt(i32, b[0..4], .little);
        const secs = std.mem.readInt(u32, b[4..8], .little);
        const frac = std.mem.readInt(u32, b[8..12], .little);
        const year = yof >> 13;
        const ordinal: u32 = @intCast((yof >> 4) & 0x1ff);
        const flags = yof & 0xf;
        if (year < 2000 or year > 9999) return null;
        const leap = (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
        if (ordinal < 1 or ordinal > @as(u32, if (leap) 366 else 365)) return null;
        if (((flags & 0b1000) == 0) != leap or (flags & 0b111) == 0) return null;
        if (secs >= 86_400 or frac >= 2_000_000_000) return null;
        const y: i64 = year - 1;
        const days = 365 * (y - 1969) + (@divFloor(y, 4) - 492) - (@divFloor(y, 100) - 19) + (@divFloor(y, 400) - 4) + (ordinal - 1);
        return days * 86_400_000 + @as(i64, secs) * 1000 + @min(frac, 999_999_999) / 1_000_000;
    }
};

// ---- logging ----------------------------------------------------------------

/// Logs to the node's log (shown with the node's normal log output).
pub const log = struct {
    pub fn info(msg: []const u8) void {
        if (abi.is_wasm) {
            if (instance_id != -1) imports.__frnt__logger__info(instance_id, p(msg.ptr), len32(msg));
        } else {
            native.log_fn(msg);
        }
    }

    /// Formats into a stack buffer (512 bytes, truncated if longer) and logs.
    pub fn print(comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.print(fmt, args) catch {};
        info(w.buffered());
    }
};

// ---- delegate context and secrets (used through freenet.Delegate) ----------

pub fn contextRead(gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
    if (!abi.is_wasm) return gpa.dupe(u8, native.context.items);
    const len = imports.__frnt__delegate__ctx_len();
    if (len <= 0) return &.{};
    const buf = try gpa.alloc(u8, @intCast(len));
    const n = imports.__frnt__delegate__ctx_read(p(buf.ptr), len);
    return buf[0..clamp(n, buf.len)];
}

pub fn contextWrite(data: []const u8) bool {
    if (!abi.is_wasm) {
        native.context.clearRetainingCapacity();
        native.context.appendSlice(native.gpa, data) catch return false;
        return true;
    }
    return imports.__frnt__delegate__ctx_write(p(data.ptr), len32(data)) == 0;
}

pub fn secretGet(gpa: std.mem.Allocator, key: []const u8) error{OutOfMemory}!?[]u8 {
    if (!abi.is_wasm) {
        const v = native.secrets.get(key) orelse return null;
        return try gpa.dupe(u8, v);
    }
    const len = imports.__frnt__delegate__get_secret_len(p(key.ptr), len32(key));
    if (len < 0) return null;
    const buf = try gpa.alloc(u8, @intCast(@max(len, 1)));
    const n = imports.__frnt__delegate__get_secret(p(key.ptr), len32(key), p(buf.ptr), len);
    if (n < 0) return null;
    return buf[0..clamp(n, buf.len)];
}

pub fn secretSet(key: []const u8, value: []const u8) bool {
    if (!abi.is_wasm) {
        const k = native.gpa.dupe(u8, key) catch return false;
        const v = native.gpa.dupe(u8, value) catch return false;
        native.secrets.put(native.gpa, k, v) catch return false;
        return true;
    }
    return imports.__frnt__delegate__set_secret(p(key.ptr), len32(key), p(value.ptr), len32(value)) == 0;
}

pub fn secretHas(key: []const u8) bool {
    if (!abi.is_wasm) return native.secrets.contains(key);
    return imports.__frnt__delegate__has_secret(p(key.ptr), len32(key)) == 1;
}

pub fn secretRemove(key: []const u8) bool {
    if (!abi.is_wasm) return native.secrets.remove(key);
    return imports.__frnt__delegate__remove_secret(p(key.ptr), len32(key)) == 0;
}

/// Keys of all secrets whose key starts with `prefix` (order unspecified;
/// the node caps how many it returns).
pub fn secretList(gpa: std.mem.Allocator, prefix: []const u8) error{OutOfMemory}![]const []const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    if (!abi.is_wasm) {
        var it = native.secrets.keyIterator();
        while (it.next()) |k| {
            if (std.mem.startsWith(u8, k.*, prefix)) try keys.append(gpa, try gpa.dupe(u8, k.*));
        }
        return keys.items;
    }
    const len = imports.__frnt__delegate__list_secrets_len(p(prefix.ptr), len32(prefix));
    if (len <= 0) return &.{};
    const buf = try gpa.alloc(u8, @intCast(len));
    const n = imports.__frnt__delegate__list_secrets(p(prefix.ptr), len32(prefix), p(buf.ptr), len);
    if (n <= 0) return &.{};
    // records: [u32 LE key length][key bytes] ...
    var rest = buf[0..clamp(n, buf.len)];
    while (rest.len >= 4) {
        const klen = std.mem.readInt(u32, rest[0..4], .little);
        if (rest.len - 4 < klen) break;
        try keys.append(gpa, rest[4..][0..klen]);
        rest = rest[4 + klen ..];
    }
    return keys.items;
}

// ---- native stand-in (tests) --------------------------------------------------

/// In-memory replacement for the node, used by native builds. Prefer the
/// helpers in `freenet.testing` over touching this directly.
pub const native = struct {
    pub var gpa: std.mem.Allocator = std.heap.smp_allocator;
    pub var rand_fn: *const fn ([]u8) void = &defaultRand;
    pub var log_fn: *const fn ([]const u8) void = &defaultLog;
    pub var clock_fn: *const fn () ?i64 = &defaultClock;
    pub var clock_ms: ?i64 = 1_735_689_600_000; // 2025-01-01T00:00:00Z: fixed, so tests repeat
    pub var secrets: std.StringHashMapUnmanaged([]u8) = .empty;
    pub var context: std.ArrayList(u8) = .empty;

    var prng: std.Random.DefaultPrng = .init(0x5eed);

    fn defaultRand(buf: []u8) void {
        prng.random().bytes(buf);
    }

    fn defaultLog(_: []const u8) void {}

    fn defaultClock() ?i64 {
        return clock_ms;
    }

    pub fn reset() void {
        rand_fn = &defaultRand;
        log_fn = &defaultLog;
        clock_fn = &defaultClock;
        clock_ms = 1_735_689_600_000;
        prng = .init(0x5eed);
        secrets = .empty; // leaks the old entries; fine for tests
        context = .empty;
        instance_id = 42;
    }
};

test "intRange stays in range and hits both ends" {
    native.reset();
    var lo_seen = false;
    var hi_seen = false;
    for (0..2000) |_| {
        const v = try random.intRange(u8, 1, 6);
        try std.testing.expect(v >= 1 and v <= 6);
        lo_seen = lo_seen or v == 1;
        hi_seen = hi_seen or v == 6;
    }
    try std.testing.expect(lo_seen and hi_seen);
    try std.testing.expectEqual(@as(i32, -3), try random.intRange(i32, -3, -3));
}

test "the node's clock: chrono 0.4.45's DateTime<Utc> decoded and checked" {
    const make = struct {
        fn f(yof: i32, secs: u32, frac: u32) [12]u8 {
            var b: [12]u8 = undefined;
            std.mem.writeInt(i32, b[0..4], yof, .little);
            std.mem.writeInt(u32, b[4..8], secs, .little);
            std.mem.writeInt(u32, b[8..12], frac, .little);
            return b;
        }
    }.f;
    // 2026-11-18T12:00:00.5Z: day 322 of a common year (bit 3 set), weekday flags 3
    try std.testing.expectEqual(@as(?i64, 1_795_003_200_500), time.decodeChrono(make((2026 << 13) | (322 << 4) | 0b1011, 43_200, 500_000_000)));
    // 1970 is outside the range read; 2024-12-31T23:59:59Z, day 366 of a leap year (bit 3 clear)
    try std.testing.expectEqual(@as(?i64, 1_735_689_599_000), time.decodeChrono(make((2024 << 13) | (366 << 4) | 0b0010, 86_399, 0)));
    // a leap second counts as the second before it
    try std.testing.expectEqual(@as(?i64, 1_735_689_599_999), time.decodeChrono(make((2024 << 13) | (366 << 4) | 0b0010, 86_399, 1_500_000_000)));
    // refused: day 366 of a common year, the leap flag wrong, no weekday, secs or frac out of range,
    // the words in another order, all zero
    try std.testing.expectEqual(@as(?i64, null), time.decodeChrono(make((2026 << 13) | (366 << 4) | 0b1011, 0, 0)));
    try std.testing.expectEqual(@as(?i64, null), time.decodeChrono(make((2026 << 13) | (322 << 4) | 0b0011, 0, 0)));
    try std.testing.expectEqual(@as(?i64, null), time.decodeChrono(make((2026 << 13) | (322 << 4) | 0b1000, 0, 0)));
    try std.testing.expectEqual(@as(?i64, null), time.decodeChrono(make((2026 << 13) | (322 << 4) | 0b1011, 86_400, 0)));
    try std.testing.expectEqual(@as(?i64, null), time.decodeChrono(make((2026 << 13) | (322 << 4) | 0b1011, 0, 2_000_000_000)));
    const b = make((2026 << 13) | (322 << 4) | 0b1011, 43_200, 500_000_000);
    try std.testing.expectEqual(@as(?i64, null), time.decodeChrono(b[4..12].* ++ b[0..4].*));
    try std.testing.expectEqual(@as(?i64, null), time.decodeChrono(@splat(0)));
}

test "the clock in native builds: freenet.testing sets it" {
    native.reset();
    try std.testing.expectEqual(@as(?i64, 1_735_689_600_000), time.nowMs());
    native.clock_ms = 1_795_003_200_500;
    try std.testing.expectEqual(@as(?i64, 1_795_003_200), time.nowSeconds());
    native.clock_ms = null;
    try std.testing.expectEqual(@as(?i64, null), time.nowMs());
}

test "random fails without an instance id" {
    native.reset();
    instance_id = -1;
    defer instance_id = 42;
    var b: [4]u8 = undefined;
    try std.testing.expectError(error.RandUnavailable, random.bytes(&b));
}

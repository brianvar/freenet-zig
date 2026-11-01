//! Web apps on Freenet: a web app is a contract whose state is the site.
//!
//! State layout expected by the node's HTTP gateway:
//!
//!     [u64 BE metadata_len][metadata][u64 BE archive_len][archive: tar.xz]
//!
//! The archive must contain `index.html` at its root. This module packs and
//! parses that layout; `freenet-pack` and `addWebApp` use it at build time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Crc32 = std.hash.Crc32;

pub const File = struct {
    /// Path inside the archive, `/`-separated (e.g. `index.html`, `img/a.png`).
    name: []const u8,
    data: []const u8,
};

/// `[u64 BE len][metadata][u64 BE len][archive]`
pub fn buildState(gpa: Allocator, metadata: []const u8, archive: []const u8) Allocator.Error![]u8 {
    const state = try gpa.alloc(u8, 16 + metadata.len + archive.len);
    std.mem.writeInt(u64, state[0..8], metadata.len, .big);
    @memcpy(state[8..][0..metadata.len], metadata);
    const rest = state[8 + metadata.len ..];
    std.mem.writeInt(u64, rest[0..8], archive.len, .big);
    @memcpy(rest[8..], archive);
    return state;
}

pub const ParsedState = struct { metadata: []const u8, archive: []const u8 };

pub fn parseState(state: []const u8) error{InvalidState}!ParsedState {
    if (state.len < 8) return error.InvalidState;
    const meta_len = std.mem.readInt(u64, state[0..8], .big);
    if (meta_len > state.len - 8) return error.InvalidState;
    const rest = state[8 + @as(usize, @intCast(meta_len)) ..];
    if (rest.len < 8) return error.InvalidState;
    const web_len = std.mem.readInt(u64, rest[0..8], .big);
    if (web_len != rest.len - 8) return error.InvalidState;
    return .{ .metadata = state[8..][0..@intCast(meta_len)], .archive = rest[8..] };
}

/// A tar archive of `files` (mode 0644, mtime 0).
pub fn tar(gpa: Allocator, files: []const File) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    var tw: std.tar.Writer = .{ .underlying_writer = &out.writer };
    for (files) |f| try tw.writeFileBytes(f.name, f.data, .{ .mode = 0o644, .mtime = 0 });
    try tw.finishPedantically();
    return out.toOwnedSlice();
}

/// Wraps `data` in a valid .xz stream without compressing it: one block of
/// LZMA2 "uncompressed" chunks with a CRC32 check. Every xz reader (the node
/// uses liblzma) accepts it; it is just not smaller. Zig's std has no xz
/// encoder, and this keeps builds free of external tools.
/// Format: https://tukaani.org/xz/xz-file-format.txt
pub fn xzStore(gpa: Allocator, data: []const u8) Allocator.Error![]u8 {
    std.debug.assert(data.len > 0);
    var out: std.ArrayList(u8) = .empty;
    const stream_flags = [2]u8{ 0x00, 0x01 }; // check type 1 = CRC32

    // Stream header
    try out.appendSlice(gpa, &.{ 0xFD, '7', 'z', 'X', 'Z', 0x00 });
    try out.appendSlice(gpa, &stream_flags);
    try appendU32(&out, gpa, Crc32.hash(&stream_flags));

    // Block header: size/4-1, flags (1 filter), LZMA2 (id 0x21, 1 property
    // byte, dictionary 4 KiB), padding, CRC32
    const block_start = out.items.len;
    const header = [8]u8{ 12 / 4 - 1, 0x00, 0x21, 0x01, 0x00, 0, 0, 0 };
    try out.appendSlice(gpa, &header);
    try appendU32(&out, gpa, Crc32.hash(&header));
    const header_size = out.items.len - block_start;

    // LZMA2 uncompressed chunks (<= 64 KiB each), then the end marker
    var rest = data;
    var first = true;
    while (rest.len > 0) {
        const n = @min(rest.len, 1 << 16);
        try out.append(gpa, if (first) 0x01 else 0x02); // 0x01 resets the dictionary
        first = false;
        var size_be: [2]u8 = undefined;
        std.mem.writeInt(u16, &size_be, @intCast(n - 1), .big);
        try out.appendSlice(gpa, &size_be);
        try out.appendSlice(gpa, rest[0..n]);
        rest = rest[n..];
    }
    try out.append(gpa, 0x00);
    const compressed_size = out.items.len - block_start - header_size;

    // Block padding, then the check (CRC32 of the uncompressed data)
    while ((out.items.len - block_start) % 4 != 0) try out.append(gpa, 0);
    try appendU32(&out, gpa, Crc32.hash(data));
    const unpadded_size = header_size + compressed_size + 4;

    // Index: indicator, 1 record (unpadded size, uncompressed size), padding, CRC32
    const index_start = out.items.len;
    try out.append(gpa, 0x00);
    try appendVarint(&out, gpa, 1);
    try appendVarint(&out, gpa, unpadded_size);
    try appendVarint(&out, gpa, data.len);
    while ((out.items.len - index_start) % 4 != 0) try out.append(gpa, 0);
    try appendU32(&out, gpa, Crc32.hash(out.items[index_start..]));
    const index_size = out.items.len - index_start;

    // Stream footer: CRC32(backward size + flags), backward size, flags, "YZ"
    var tail: [6]u8 = undefined;
    std.mem.writeInt(u32, tail[0..4], @intCast(index_size / 4 - 1), .little);
    tail[4..6].* = stream_flags;
    try appendU32(&out, gpa, Crc32.hash(&tail));
    try out.appendSlice(gpa, &tail);
    try out.appendSlice(gpa, "YZ");

    return out.toOwnedSlice(gpa);
}

fn appendU32(out: *std.ArrayList(u8), gpa: Allocator, v: u32) Allocator.Error!void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

fn appendVarint(out: *std.ArrayList(u8), gpa: Allocator, value: u64) Allocator.Error!void {
    var v = value;
    while (v >= 0x80) : (v >>= 7) try out.append(gpa, @as(u8, @truncate(v)) | 0x80);
    try out.append(gpa, @intCast(v));
}

/// tar + xz + state layout in one call (no metadata).
pub fn pack(gpa: Allocator, files: []const File) ![]u8 {
    const archive = try xzStore(gpa, try tar(gpa, files));
    return buildState(gpa, "", archive);
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

fn xzDecode(gpa: Allocator, xz: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(xz);
    var dec = try std.compress.xz.Decompress.init(&in, gpa, &.{});
    defer dec.deinit();
    return dec.reader.allocRemaining(gpa, .unlimited);
}

test "xzStore round-trips through std's xz decoder" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_]usize{ 1, 3, 65535, 65536, 65537, 200_003 }) |len| {
        const data = try arena.allocator().alloc(u8, len);
        for (data, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i >> 9));
        const xz = try xzStore(arena.allocator(), data);
        try testing.expectEqual(@as(usize, 0), xz.len % 4);
        const back = try xzDecode(testing.allocator, xz);
        defer testing.allocator.free(back);
        try testing.expectEqualSlices(u8, data, back);
    }
}

test "pack -> parseState -> xz -> tar gives the files back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]File{ .{ .name = "index.html", .data = "<h1>hi</h1>" }, .{ .name = "css/site.css", .data = "h1{}" } };
    const state = try pack(a, &files);

    const parsed = try parseState(state);
    try testing.expectEqual(@as(usize, 0), parsed.metadata.len);
    const tar_bytes = try xzDecode(a, parsed.archive);

    var in: std.Io.Reader = .fixed(tar_bytes);
    var name_buf: [256]u8 = undefined;
    var link_buf: [256]u8 = undefined;
    var it: std.tar.Iterator = .init(&in, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    for (files) |want| {
        const f = (try it.next()) orelse return error.MissingFile;
        try testing.expectEqualStrings(want.name, f.name);
        var content: std.Io.Writer.Allocating = .init(a);
        try it.streamRemaining(f, &content.writer);
        try testing.expectEqualStrings(want.data, content.written());
    }
    try testing.expect((try it.next()) == null);
}

test "parseState rejects malformed layouts" {
    try testing.expectError(error.InvalidState, parseState(""));
    try testing.expectError(error.InvalidState, parseState(&@as([7]u8, @splat(0))));
    var bad: [17]u8 = @splat(0);
    std.mem.writeInt(u64, bad[8..16], 5, .big); // claims 5 archive bytes, has 1
    try testing.expectError(error.InvalidState, parseState(&bad));
}

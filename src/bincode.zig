//! Minimal bincode 1.x codec: the wire format Freenet uses between the node
//! and Wasm modules (and on the WebSocket with `?encodingProtocol=native`).
//!
//! Layout rules (bincode 1.x "legacy" config, as used by freenet-stdlib):
//! * integers: fixed width, little-endian
//! * `bool`: one byte, 0 or 1
//! * `Vec<u8>`, `String`, serde `Bytes`: u64 length, then the bytes
//! * fixed arrays (`[u8; 32]`): the bytes, no length
//! * enums (including `Result`, Ok = 0 / Err = 1): u32 variant index, then fields
//! * `Option`: u8 0 (None) or 1 (Some) followed by the value
//! * structs: fields in declaration order, no framing

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Writer = struct {
    allocator: Allocator,
    list: std.ArrayList(u8) = .empty,

    pub fn init(allocator: Allocator) Writer {
        return .{ .allocator = allocator };
    }

    /// The encoded bytes so far. Owned by the writer.
    pub fn items(w: *const Writer) []const u8 {
        return w.list.items;
    }

    pub fn raw(w: *Writer, data: []const u8) Allocator.Error!void {
        try w.list.appendSlice(w.allocator, data);
    }

    pub fn int(w: *Writer, comptime T: type, v: T) Allocator.Error!void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        try w.raw(&b);
    }

    pub fn boolean(w: *Writer, v: bool) Allocator.Error!void {
        try w.int(u8, @intFromBool(v));
    }

    /// Enum variant index (also `Result`: Ok = 0, Err = 1).
    pub fn tag(w: *Writer, v: u32) Allocator.Error!void {
        try w.int(u32, v);
    }

    /// Length-prefixed bytes: `Vec<u8>`, `String`, serde `Bytes`.
    pub fn bytes(w: *Writer, data: []const u8) Allocator.Error!void {
        try w.int(u64, data.len);
        try w.raw(data);
    }

    /// `Option<Vec<u8>>`-style value.
    pub fn optionalBytes(w: *Writer, data: ?[]const u8) Allocator.Error!void {
        if (data) |d| {
            try w.int(u8, 1);
            try w.bytes(d);
        } else try w.int(u8, 0);
    }
};

pub const Error = error{ EndOfStream, InvalidBool, InvalidOption };

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn remaining(r: *const Reader) usize {
        return r.buf.len - r.pos;
    }

    pub fn raw(r: *Reader, n: usize) Error![]const u8 {
        if (r.remaining() < n) return error.EndOfStream;
        defer r.pos += n;
        return r.buf[r.pos..][0..n];
    }

    pub fn array(r: *Reader, comptime n: usize) Error![n]u8 {
        return (try r.raw(n))[0..n].*;
    }

    pub fn int(r: *Reader, comptime T: type) Error!T {
        const b = try r.raw(@sizeOf(T));
        return std.mem.readInt(T, b[0..@sizeOf(T)], .little);
    }

    pub fn boolean(r: *Reader) Error!bool {
        return switch (try r.int(u8)) {
            0 => false,
            1 => true,
            else => error.InvalidBool,
        };
    }

    pub fn tag(r: *Reader) Error!u32 {
        return r.int(u32);
    }

    pub fn bytes(r: *Reader) Error![]const u8 {
        const len = try r.int(u64);
        if (len > r.remaining()) return error.EndOfStream;
        return r.raw(@intCast(len));
    }

    pub fn optionalBytes(r: *Reader) Error!?[]const u8 {
        return switch (try r.int(u8)) {
            0 => null,
            1 => try r.bytes(),
            else => error.InvalidOption,
        };
    }
};

test "round trip and exact layout" {
    var w: Writer = .init(std.testing.allocator);
    defer w.list.deinit(std.testing.allocator);
    try w.tag(2);
    try w.bytes("hi");
    try w.boolean(true);
    try w.optionalBytes(null);
    try w.optionalBytes("x");
    try std.testing.expectEqualSlices(u8, &.{
        2, 0, 0, 0, // tag
        2, 0, 0, 0, 0, 0, 0, 0, 'h', 'i', // bytes
        1, // bool
        0, // None
        1, 1, 0, 0, 0, 0, 0, 0, 0, 'x', // Some(bytes)
    }, w.items());

    var r: Reader = .init(w.items());
    try std.testing.expectEqual(@as(u32, 2), try r.tag());
    try std.testing.expectEqualStrings("hi", try r.bytes());
    try std.testing.expect(try r.boolean());
    try std.testing.expect((try r.optionalBytes()) == null);
    try std.testing.expectEqualStrings("x", (try r.optionalBytes()).?);
    try std.testing.expectError(error.EndOfStream, r.int(u8));
}

test "length prefix larger than the input is rejected" {
    var r: Reader = .init(&.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f, 1 });
    try std.testing.expectError(error.EndOfStream, r.bytes());
}

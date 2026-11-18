//! An LZMA2 encoder, for `webapp.xzCompress`: Zig's std reads .xz but has no
//! encoder, and a web app's archive stored without compression is 4–6 times
//! its size (a site is mostly text and base64).
//!
//! Plain LZMA with lc=3, lp=0, pb=2 (xz's defaults): literals, matches found
//! on hash chains with one step of lazy matching, and repeats of the last
//! distance. No optimal parsing, so it is larger than `xz -6` (Hive's site,
//! 2026-11-18: 5.08 MB stored, 1.05 MB here in 0.8 s, 0.85 MB by `xz -6`),
//! and it is deterministic: the same input always gives the same bytes, so a
//! site still rebuilds byte for byte.
//!
//! The output is a raw LZMA2 stream (chunks and the end marker) for an xz
//! block whose dictionary is `dictSize(dictProp(data.len))`. Read by liblzma
//! (the node, `xz`) and by std.compress.xz.

const std = @import("std");
const Allocator = std.mem.Allocator;

const lc = 3;
const pb = 2;
const pos_mask = (1 << pb) - 1;
/// (pb * 5 + lp) * 9 + lc
pub const props_byte: u8 = (pb * 5 + 0) * 9 + lc;

const min_match = 2;
const max_match = 273;
const nice_len = 273;
const chain_depth = 256;
const hash_bits = 17;

/// LZMA2 limits on one chunk.
const max_chunk_unpacked = 1 << 21;
const max_chunk_packed = 1 << 16;
/// More than any one symbol can add to a chunk (a match is at most ~160
/// bits: 22 coded decisions of ≤ 6.05 bits and 26 direct bits).
const symbol_margin = 64;

/// The xz LZMA2 filter's dictionary property `p`: 2 or 3 times a power of two.
pub fn dictSize(p: u6) u64 {
    return @as(u64, 2 | (p & 1)) << @intCast(p / 2 + 11);
}

/// The smallest dictionary property whose dictionary holds `len` bytes, at most
/// 16 MiB (24): no distance longer than the dictionary is used.
pub fn dictProp(len: usize) u6 {
    var p: u6 = 0;
    while (p < 24 and dictSize(p) < len) p += 1;
    return p;
}

const RangeEncoder = struct {
    low: u64 = 0,
    range: u32 = 0xFFFF_FFFF,
    cache: u8 = 0,
    cache_size: u64 = 1,
    out: std.ArrayList(u8) = .empty,

    fn shiftLow(rc: *RangeEncoder, gpa: Allocator) Allocator.Error!void {
        if (@as(u32, @truncate(rc.low)) < 0xFF00_0000 or (rc.low >> 32) != 0) {
            const carry: u8 = @intCast(rc.low >> 32);
            var temp = rc.cache;
            while (true) {
                try rc.out.append(gpa, temp +% carry);
                temp = 0xFF;
                rc.cache_size -= 1;
                if (rc.cache_size == 0) break;
            }
            rc.cache = @truncate(rc.low >> 24);
        }
        rc.cache_size += 1;
        rc.low = (rc.low & 0x00FF_FFFF) << 8;
    }

    fn bit(rc: *RangeEncoder, gpa: Allocator, prob: *u16, b: u1) Allocator.Error!void {
        const bound = (rc.range >> 11) * @as(u32, prob.*);
        if (b == 0) {
            rc.range = bound;
            prob.* += (0x800 - prob.*) >> 5;
        } else {
            rc.low += bound;
            rc.range -= bound;
            prob.* -= prob.* >> 5;
        }
        while (rc.range < (1 << 24)) {
            rc.range <<= 8;
            try rc.shiftLow(gpa);
        }
    }

    fn direct(rc: *RangeEncoder, gpa: Allocator, value: u32, count: u5) Allocator.Error!void {
        var i: u5 = count;
        while (i > 0) {
            i -= 1;
            rc.range >>= 1;
            if ((value >> i) & 1 == 1) rc.low += rc.range;
            while (rc.range < (1 << 24)) {
                rc.range <<= 8;
                try rc.shiftLow(gpa);
            }
        }
    }

    fn tree(rc: *RangeEncoder, gpa: Allocator, probs: []u16, count: u5, value: u32) Allocator.Error!void {
        var m: u32 = 1;
        var i: u5 = count;
        while (i > 0) {
            i -= 1;
            const b: u1 = @truncate(value >> i);
            try rc.bit(gpa, &probs[m], b);
            m = (m << 1) | b;
        }
    }

    fn reverse(rc: *RangeEncoder, gpa: Allocator, probs: []u16, offset: usize, count: u5, value: u32) Allocator.Error!void {
        var m: usize = 1;
        var v = value;
        for (0..count) |_| {
            const b: u1 = @truncate(v);
            v >>= 1;
            try rc.bit(gpa, &probs[offset + m], b);
            m = (m << 1) | b;
        }
    }

    /// Bytes the chunk has once flushed.
    fn pending(rc: RangeEncoder) u64 {
        return rc.out.items.len + rc.cache_size + 4;
    }

    fn flush(rc: *RangeEncoder, gpa: Allocator) Allocator.Error!void {
        for (0..5) |_| try rc.shiftLow(gpa);
    }
};

const LenProbs = struct {
    choice: u16 = 0x400,
    choice2: u16 = 0x400,
    low: [16][8]u16 = @splat(@splat(0x400)),
    mid: [16][8]u16 = @splat(@splat(0x400)),
    high: [256]u16 = @splat(0x400),

    fn encode(p: *LenProbs, rc: *RangeEncoder, gpa: Allocator, len: u32, pos_state: usize) Allocator.Error!void {
        const v = len - min_match;
        if (v < 8) {
            try rc.bit(gpa, &p.choice, 0);
            try rc.tree(gpa, &p.low[pos_state], 3, v);
        } else if (v < 16) {
            try rc.bit(gpa, &p.choice, 1);
            try rc.bit(gpa, &p.choice2, 0);
            try rc.tree(gpa, &p.mid[pos_state], 3, v - 8);
        } else {
            try rc.bit(gpa, &p.choice, 1);
            try rc.bit(gpa, &p.choice2, 1);
            try rc.tree(gpa, &p.high, 8, v - 16);
        }
    }
};

const Model = struct {
    is_match: [12 << 4]u16 = @splat(0x400),
    is_rep: [12]u16 = @splat(0x400),
    is_rep_g0: [12]u16 = @splat(0x400),
    is_rep_g1: [12]u16 = @splat(0x400),
    is_rep_g2: [12]u16 = @splat(0x400),
    is_rep0_long: [12 << 4]u16 = @splat(0x400),
    literal: [0x300 << lc]u16 = @splat(0x400),
    pos_slot: [4][64]u16 = @splat(@splat(0x400)),
    pos_special: [115]u16 = @splat(0x400),
    align_: [16]u16 = @splat(0x400),
    len: LenProbs = .{},
    rep_len: LenProbs = .{},
    state: u8 = 0,
    /// Distances minus one, newest first.
    reps: [4]u32 = @splat(0),
};

fn posSlot(dist: u32) u32 {
    if (dist < 4) return dist;
    const n: u32 = 32 - @clz(dist);
    return 2 * (n - 1) + ((dist >> @intCast(n - 2)) & 1);
}

const Encoder = struct {
    gpa: Allocator,
    data: []const u8,
    max_dist: u64,
    m: *Model,
    rc: RangeEncoder = .{},
    /// The finished LZMA2 stream.
    out: std.ArrayList(u8) = .empty,
    chunk_start: usize = 0,
    first_chunk: bool = true,
    head: []u32,
    prev: []u32,

    const none = std.math.maxInt(u32);

    fn hash(e: *const Encoder, pos: usize) usize {
        const d = e.data;
        const v = @as(u32, d[pos]) | @as(u32, d[pos + 1]) << 8 | @as(u32, d[pos + 2]) << 16;
        return (v *% 2654435761) >> (32 - hash_bits);
    }

    fn insert(e: *Encoder, pos: usize) void {
        if (pos + 3 > e.data.len) return;
        const h = e.hash(pos);
        e.prev[pos] = e.head[h];
        e.head[h] = @intCast(pos);
    }

    fn matchLen(e: *const Encoder, a: usize, b: usize, limit: usize) usize {
        var n: usize = 0;
        while (n < limit and e.data[a + n] == e.data[b + n]) n += 1;
        return n;
    }

    const Match = struct { len: usize = 0, dist: u32 = 0 };

    /// The longest match at `pos` on the hash chain (positions before `pos`).
    fn find(e: *const Encoder, pos: usize) Match {
        var best: Match = .{};
        const limit = @min(max_match, e.data.len - pos);
        if (limit < 3) return best;
        var cand = e.head[e.hash(pos)];
        var depth: usize = 0;
        while (cand != none and depth < chain_depth) : (depth += 1) {
            const dist = pos - cand;
            if (dist > e.max_dist) break;
            if (e.data[cand + best.len] == e.data[pos + best.len]) {
                const len = e.matchLen(cand, pos, limit);
                if (len > best.len) {
                    best = .{ .len = len, .dist = @intCast(dist - 1) };
                    if (len >= nice_len or len == limit) break;
                }
            }
            cand = e.prev[cand];
        }
        // a 3-byte match far away costs more than its literals
        if (best.len == 3 and best.dist >= 1 << 14) best = .{};
        return best;
    }

    fn repLen(e: *const Encoder, pos: usize) usize {
        const back: usize = @as(usize, e.m.reps[0]) + 1;
        if (pos < back) return 0;
        return e.matchLen(pos - back, pos, @min(max_match, e.data.len - pos));
    }

    /// Ends the chunk when `len` more bytes wouldn't fit in it.
    fn room(e: *Encoder, pos: usize, len: usize) Allocator.Error!void {
        if (pos - e.chunk_start + len <= max_chunk_unpacked and e.rc.pending() + symbol_margin <= max_chunk_packed) return;
        try e.endChunk(pos);
    }

    fn endChunk(e: *Encoder, pos: usize) Allocator.Error!void {
        const unpacked = pos - e.chunk_start;
        if (unpacked == 0) return;
        try e.rc.flush(e.gpa);
        const packed_len = e.rc.out.items.len;
        std.debug.assert(packed_len <= max_chunk_packed and unpacked <= max_chunk_unpacked);
        // 0xE0: dictionary, state and properties reset (the first chunk); 0x80: none
        const control: u8 = (if (e.first_chunk) @as(u8, 0xE0) else 0x80) | @as(u8, @intCast((unpacked - 1) >> 16));
        try e.out.append(e.gpa, control);
        var be: [2]u8 = undefined;
        std.mem.writeInt(u16, &be, @truncate(unpacked - 1), .big);
        try e.out.appendSlice(e.gpa, &be);
        std.mem.writeInt(u16, &be, @intCast(packed_len - 1), .big);
        try e.out.appendSlice(e.gpa, &be);
        if (e.first_chunk) try e.out.append(e.gpa, props_byte);
        try e.out.appendSlice(e.gpa, e.rc.out.items);
        e.rc.out.deinit(e.gpa);
        e.rc = .{};
        e.chunk_start = pos;
        e.first_chunk = false;
    }

    fn literal(e: *Encoder, pos: usize) Allocator.Error!void {
        const m = e.m;
        const pos_state = pos & pos_mask;
        try e.rc.bit(e.gpa, &m.is_match[(@as(usize, m.state) << 4) + pos_state], 0);
        const prev_byte: usize = if (pos > 0) e.data[pos - 1] else 0;
        const probs = m.literal[0x300 * (prev_byte >> (8 - lc)) ..][0..0x300];
        const byte = e.data[pos];
        var result: u32 = 1;
        var k: u4 = 0;
        if (m.state >= 7) {
            var match_byte: u32 = e.data[pos - m.reps[0] - 1];
            while (k < 8) : (k += 1) {
                const match_bit = (match_byte >> 7) & 1;
                match_byte <<= 1;
                const b: u1 = @truncate(byte >> @intCast(7 - k));
                try e.rc.bit(e.gpa, &probs[((1 + match_bit) << 8) + result], b);
                result = (result << 1) | b;
                if (match_bit != b) {
                    k += 1;
                    break;
                }
            }
        }
        while (k < 8) : (k += 1) {
            const b: u1 = @truncate(byte >> @intCast(7 - k));
            try e.rc.bit(e.gpa, &probs[result], b);
            result = (result << 1) | b;
        }
        m.state = if (m.state < 4) 0 else if (m.state < 10) m.state - 3 else m.state - 6;
    }

    fn match(e: *Encoder, pos: usize, len: usize, dist: u32) Allocator.Error!void {
        const m = e.m;
        const pos_state = pos & pos_mask;
        try e.rc.bit(e.gpa, &m.is_match[(@as(usize, m.state) << 4) + pos_state], 1);
        try e.rc.bit(e.gpa, &m.is_rep[m.state], 0);
        try m.len.encode(&e.rc, e.gpa, @intCast(len), pos_state);
        const len_state = @min(len - min_match, 3);
        const slot = posSlot(dist);
        try e.rc.tree(e.gpa, &m.pos_slot[len_state], 6, slot);
        if (slot >= 4) {
            const footer: u5 = @intCast((slot >> 1) - 1);
            const base = (2 | (slot & 1)) << footer;
            const reduced = dist - base;
            if (slot < 14) {
                try e.rc.reverse(e.gpa, &m.pos_special, base - slot, footer, reduced);
            } else {
                try e.rc.direct(e.gpa, reduced >> 4, footer - 4);
                try e.rc.reverse(e.gpa, &m.align_, 0, 4, reduced & 15);
            }
        }
        m.reps = .{ dist, m.reps[0], m.reps[1], m.reps[2] };
        m.state = if (m.state < 7) 7 else 10;
    }

    fn rep0(e: *Encoder, pos: usize, len: usize) Allocator.Error!void {
        const m = e.m;
        const pos_state = pos & pos_mask;
        try e.rc.bit(e.gpa, &m.is_match[(@as(usize, m.state) << 4) + pos_state], 1);
        try e.rc.bit(e.gpa, &m.is_rep[m.state], 1);
        try e.rc.bit(e.gpa, &m.is_rep_g0[m.state], 0);
        try e.rc.bit(e.gpa, &m.is_rep0_long[(@as(usize, m.state) << 4) + pos_state], 1);
        try m.rep_len.encode(&e.rc, e.gpa, @intCast(len), pos_state);
        m.state = if (m.state < 7) 8 else 11;
    }

    fn run(e: *Encoder) Allocator.Error!void {
        const n = e.data.len;
        var pos: usize = 0;
        var next: ?Match = null; // the lazy look's match at `pos`, already searched
        while (pos < n) {
            const rl = if (pos > 0) e.repLen(pos) else 0;
            const here = next orelse e.find(pos);
            next = null;
            // a repeat of the last distance is cheaper: take it unless the match is clearly longer
            if (rl >= min_match and rl + 2 >= here.len) {
                try e.room(pos, rl);
                try e.rep0(pos, rl);
                for (pos..pos + rl) |p| e.insert(p);
                pos += rl;
                continue;
            }
            if (here.len >= 3) {
                if (here.len < nice_len and pos + 1 < n) {
                    e.insert(pos);
                    const later = e.find(pos + 1);
                    if (later.len > here.len) {
                        try e.room(pos, 1);
                        try e.literal(pos);
                        pos += 1;
                        next = later;
                        continue;
                    }
                    try e.room(pos, here.len);
                    try e.match(pos, here.len, here.dist);
                    for (pos + 1..pos + here.len) |p| e.insert(p);
                } else {
                    try e.room(pos, here.len);
                    try e.match(pos, here.len, here.dist);
                    for (pos..pos + here.len) |p| e.insert(p);
                }
                pos += here.len;
                continue;
            }
            try e.room(pos, 1);
            try e.literal(pos);
            e.insert(pos);
            pos += 1;
        }
        try e.endChunk(pos);
        try e.out.append(e.gpa, 0x00);
    }
};

/// The LZMA2 stream of `data` (not empty), for a dictionary of
/// `dictSize(dictProp(data.len))`.
pub fn encode(gpa: Allocator, data: []const u8) Allocator.Error![]u8 {
    std.debug.assert(data.len > 0);
    const model = try gpa.create(Model);
    defer gpa.destroy(model);
    model.* = .{};
    const head = try gpa.alloc(u32, 1 << hash_bits);
    defer gpa.free(head);
    @memset(head, Encoder.none);
    const prev = try gpa.alloc(u32, data.len);
    defer gpa.free(prev);
    var e: Encoder = .{
        .gpa = gpa,
        .data = data,
        .max_dist = dictSize(dictProp(data.len)),
        .m = model,
        .head = head,
        .prev = prev,
    };
    errdefer e.out.deinit(gpa);
    defer e.rc.out.deinit(gpa);
    try e.run();
    return e.out.toOwnedSlice(gpa);
}

test "posSlot matches LZMA's distance slots" {
    try std.testing.expectEqual(@as(u32, 0), posSlot(0));
    try std.testing.expectEqual(@as(u32, 3), posSlot(3));
    try std.testing.expectEqual(@as(u32, 4), posSlot(4));
    try std.testing.expectEqual(@as(u32, 5), posSlot(6));
    try std.testing.expectEqual(@as(u32, 6), posSlot(8));
    try std.testing.expectEqual(@as(u32, 13), posSlot(127));
    try std.testing.expectEqual(@as(u32, 14), posSlot(128));
    try std.testing.expectEqual(@as(u32, 63), posSlot(0xFFFF_FFFF));
}

test "dictProp: the smallest dictionary that holds the data" {
    try std.testing.expectEqual(@as(u64, 4096), dictSize(0));
    try std.testing.expectEqual(@as(u64, 6144), dictSize(1));
    try std.testing.expectEqual(@as(u64, 8 << 20), dictSize(22));
    try std.testing.expectEqual(@as(u6, 0), dictProp(1));
    try std.testing.expectEqual(@as(u6, 1), dictProp(4097));
    try std.testing.expectEqual(@as(u6, 22), dictProp(7 << 20));
    try std.testing.expectEqual(@as(u6, 24), dictProp(100 << 20));
}

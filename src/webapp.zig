//! Web apps on Freenet: a web app is a contract whose state is the site.
//!
//! State layout expected by the node's HTTP gateway:
//!
//!     [u64 BE metadata_len][metadata][u64 BE archive_len][archive: tar.xz]
//!
//! The archive must contain `index.html` at its root. This module packs and
//! parses that layout; `freenet-pack` and `addWebApp` use it at build time.
//!
//! The built-in web container (`webcontainer.zig`) stores *signed* sites, in
//! the same format as freenet-core's `fdev website`: the metadata is CBOR
//! `{ "version": u32, "signature": bytes(64) }`, where the signature is an
//! Ed25519 signature over `version (u32 BE) ‖ archive`, made by the key whose
//! public half is the contract's parameters.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Crc32 = std.hash.Crc32;
const Ed25519 = std.crypto.sign.Ed25519;

pub const File = struct {
    /// Path inside the archive, `/`-separated (e.g. `index.html`, `img/a.png`).
    name: []const u8,
    data: []const u8,
};

/// The largest contract state the node stores (freenet-core `MAX_STATE_SIZE`).
pub const max_state_size = 50 * 1024 * 1024;

/// The node refuses metadata larger than this.
pub const max_metadata_size = 1024;

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
    if (meta_len > max_metadata_size or meta_len > state.len - 8) return error.InvalidState;
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

// ---- signed sites ------------------------------------------------------------

pub const Metadata = struct {
    /// Strictly increases with every release; 0 is invalid.
    version: u32,
    signature: [Ed25519.Signature.encoded_length]u8,
};

/// CBOR `{ "version": <uint>, "signature": <bytes(64)> }`.
pub fn encodeMetadata(gpa: Allocator, m: Metadata) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(gpa, 0xa2); // map(2)
    try out.append(gpa, 0x67); // text(7)
    try out.appendSlice(gpa, "version");
    var uint_buf: [5]u8 = undefined;
    try out.appendSlice(gpa, cborUint(&uint_buf, m.version));
    try out.append(gpa, 0x69); // text(9)
    try out.appendSlice(gpa, "signature");
    try out.appendSlice(gpa, &.{ 0x58, 0x40 }); // bytes(64)
    try out.appendSlice(gpa, &m.signature);
    return out.toOwnedSlice(gpa);
}

/// `v` as a CBOR unsigned integer (shortest form), written into `buf`. This
/// is also how the web container writes its sync summary.
pub fn cborUint(buf: *[5]u8, v: u32) []const u8 {
    if (v < 24) {
        buf[0] = @intCast(v);
        return buf[0..1];
    }
    if (v <= 0xff) {
        buf[0] = 0x18;
        buf[1] = @intCast(v);
        return buf[0..2];
    }
    if (v <= 0xffff) {
        buf[0] = 0x19;
        std.mem.writeInt(u16, buf[1..3], @intCast(v), .big);
        return buf[0..3];
    }
    buf[0] = 0x1a;
    std.mem.writeInt(u32, buf[1..5], v, .big);
    return buf[0..5];
}

const CborHead = struct { major: u8, arg: u64 };

/// Reads one CBOR item header (definite lengths only) at `pos.*`.
fn cborHead(b: []const u8, pos: *usize) error{InvalidState}!CborHead {
    if (pos.* >= b.len) return error.InvalidState;
    const first = b[pos.*];
    pos.* += 1;
    const info = first & 0x1f;
    if (info < 24) return .{ .major = first >> 5, .arg = info };
    const width: usize = switch (info) {
        24 => 1,
        25 => 2,
        26 => 4,
        27 => 8,
        else => return error.InvalidState, // indefinite lengths and reserved values
    };
    if (b.len - pos.* < width) return error.InvalidState;
    var arg: u64 = 0;
    for (b[pos.*..][0..width]) |byte| arg = (arg << 8) | byte;
    pos.* += width;
    return .{ .major = first >> 5, .arg = arg };
}

/// A CBOR unsigned integer that fits in a u32, and nothing after it.
pub fn parseCborUint(b: []const u8) error{InvalidState}!u32 {
    var pos: usize = 0;
    const h = try cborHead(b, &pos);
    if (h.major != 0 or h.arg > std.math.maxInt(u32) or pos != b.len) return error.InvalidState;
    return @intCast(h.arg);
}

/// Parses the metadata. Accepts the signature as a CBOR byte string (what
/// `encodeMetadata` writes) or as an array of 64 small integers (what
/// `fdev website` writes), and the two keys in either order.
pub fn parseMetadata(b: []const u8) error{InvalidState}!Metadata {
    var pos: usize = 0;
    const map = try cborHead(b, &pos);
    if (map.major != 5 or map.arg != 2) return error.InvalidState;
    var version: ?u32 = null;
    var signature: ?[64]u8 = null;
    for (0..2) |_| {
        const key_head = try cborHead(b, &pos);
        if (key_head.major != 3 or key_head.arg > b.len - pos) return error.InvalidState;
        const key = b[pos..][0..@intCast(key_head.arg)];
        pos += key.len;
        if (std.mem.eql(u8, key, "version") and version == null) {
            const v = try cborHead(b, &pos);
            if (v.major != 0 or v.arg > std.math.maxInt(u32)) return error.InvalidState;
            version = @as(u32, @intCast(v.arg));
        } else if (std.mem.eql(u8, key, "signature") and signature == null) {
            const v = try cborHead(b, &pos);
            if (v.arg != 64) return error.InvalidState;
            var sig: [64]u8 = undefined;
            switch (v.major) {
                2 => { // byte string
                    if (b.len - pos < 64) return error.InvalidState;
                    sig = b[pos..][0..64].*;
                    pos += 64;
                },
                4 => for (&sig) |*byte| { // array of unsigned integers
                    const e = try cborHead(b, &pos);
                    if (e.major != 0 or e.arg > 0xff) return error.InvalidState;
                    byte.* = @intCast(e.arg);
                },
                else => return error.InvalidState,
            }
            signature = sig;
        } else return error.InvalidState; // unknown or repeated key
    }
    if (pos != b.len) return error.InvalidState;
    return .{ .version = version.?, .signature = signature.? };
}

/// The release number of a state (without checking its signature).
pub fn stateVersion(state: []const u8) error{InvalidState}!u32 {
    return (try parseMetadata((try parseState(state)).metadata)).version;
}

pub const VerifyError = error{ InvalidState, BadSignature };

/// Checks that `state` has the web-app layout, a version above 0, and a valid
/// signature by `public_key` over `version ‖ archive`.
pub fn verifyState(public_key: [32]u8, state: []const u8) VerifyError!Metadata {
    const parsed = try parseState(state);
    const meta = try parseMetadata(parsed.metadata);
    if (meta.version == 0) return error.InvalidState;
    const key = Ed25519.PublicKey.fromBytes(public_key) catch return error.InvalidState;
    var v = Ed25519.Signature.fromBytes(meta.signature).verifier(key) catch return error.BadSignature;
    var version_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &version_be, meta.version, .big);
    v.update(&version_be);
    v.update(parsed.archive);
    v.verifyStrict() catch return error.BadSignature;
    return meta;
}

/// Signs `archive` as release `version` and returns the complete state.
pub fn signState(gpa: Allocator, key_pair: Ed25519.KeyPair, version: u32, archive: []const u8) ![]u8 {
    const message = try gpa.alloc(u8, 4 + archive.len);
    defer gpa.free(message);
    std.mem.writeInt(u32, message[0..4], version, .big);
    @memcpy(message[4..], archive);
    const signature = try key_pair.sign(message, null);
    const metadata = try encodeMetadata(gpa, .{ .version = version, .signature = signature.toBytes() });
    defer gpa.free(metadata);
    return buildState(gpa, metadata, archive);
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

/// A page's references to the site's own files, with the release appended:
/// every `src="name"` or `href="name"` (either quote, any letter case)
/// whose value is exactly one of `names` becomes `name?v=<version>`. The
/// node serves the page itself uncached but the files it loads with
/// validators only, so a browser may reuse an old stylesheet beside a new
/// script after an update; a new URL per release rules that out. Anything
/// else (absolute or external URLs, values with a query or fragment, other
/// attributes such as `data-src`) is left as it is. The same input gives the
/// same bytes, so builds stay reproducible.
pub fn versionRefs(gpa: Allocator, html: []const u8, names: []const []const u8, version: u32) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    var copied: usize = 0;
    while (i < html.len) : (i += 1) {
        const attr_len: usize = if (attrAt(html, i, "src")) 3 else if (attrAt(html, i, "href")) 4 else continue;
        var j = i + attr_len;
        while (j < html.len and isSpace(html[j])) j += 1;
        if (j >= html.len or html[j] != '=') continue;
        j += 1;
        while (j < html.len and isSpace(html[j])) j += 1;
        if (j >= html.len or (html[j] != '"' and html[j] != '\'')) continue;
        const quote = html[j];
        const start = j + 1;
        const end = std.mem.indexOfScalarPos(u8, html, start, quote) orelse break;
        const value = html[start..end];
        for (names) |n| {
            if (!std.mem.eql(u8, value, n)) continue;
            try out.appendSlice(gpa, html[copied..end]);
            try out.print(gpa, "?v={d}", .{version});
            copied = end;
            break;
        }
        i = end;
    }
    try out.appendSlice(gpa, html[copied..]);
    return out.toOwnedSlice(gpa);
}

/// `name` starts at `i` as an attribute: after white space, in any letter case.
fn attrAt(html: []const u8, i: usize, name: []const u8) bool {
    if (i == 0 or !isSpace(html[i - 1]) or i + name.len > html.len) return false;
    return std.ascii.eqlIgnoreCase(html[i..][0..name.len], name);
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0c';
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

test "tar -> xz -> buildState -> parseState gives the files back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]File{ .{ .name = "index.html", .data = "<h1>hi</h1>" }, .{ .name = "css/site.css", .data = "h1{}" } };
    const state = try buildState(a, "", try xzStore(a, try tar(a, &files)));

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

/// Made with Node's Ed25519 (RFC 8032, so deterministic) from seed 7×32,
/// version 1780000000 and archive "hello archive", and accepted by
/// freenet-core's own website contract.
const vector_public_key = "ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c";
const vector_state = "000000000000005aa26776657273696f6e1a6a18a500697369676e6174757265584036a70520775fd7a914ea7b7ce3bbb44a8d36a00f00996f7a563835f5af979d224384ede57ea22b2abfb62c060c7f6b18cd1d869876f3177aebba300c7fd25a0a000000000000000d68656c6c6f2061726368697665";
/// The same release as `fdev website` writes it (signature as an array).
const vector_state_fdev = "0000000000000091a26776657273696f6e1a6a18a500697369676e61747572659840183618a70518201877185f18d718a91418ea187b187c18e318bb18b4184a188d183618a00f001899186f187a18561838183518f518af1897189d18221843188418ed18e5187e18a2182b182a18bf18b6182c060c187f186b181818cd181d18861898187618f317187a18eb18ba18300c187f18d2185a0a000000000000000d68656c6c6f2061726368697665";

fn unhex(comptime hex: []const u8) [hex.len / 2]u8 {
    @setEvalBranchQuota(100_000);
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

fn testKeyPair() !Ed25519.KeyPair {
    return Ed25519.KeyPair.generateDeterministic(@splat(7));
}

test "signState writes exactly the bytes freenet-core's contract accepts" {
    const kp = try testKeyPair();
    try testing.expectEqualSlices(u8, &unhex(vector_public_key), &kp.public_key.toBytes());
    const state = try signState(testing.allocator, kp, 1_780_000_000, "hello archive");
    defer testing.allocator.free(state);
    try testing.expectEqualSlices(u8, &unhex(vector_state), state);
}

test "verifyState accepts both metadata encodings" {
    const pk = unhex(vector_public_key);
    const mine = try verifyState(pk, &unhex(vector_state));
    const fdev = try verifyState(pk, &unhex(vector_state_fdev));
    try testing.expectEqual(@as(u32, 1_780_000_000), mine.version);
    try testing.expectEqualSlices(u8, &mine.signature, &fdev.signature);
}

test "verifyState rejects tampering, other keys and version 0" {
    const pk = unhex(vector_public_key);
    var state = unhex(vector_state);
    state[state.len - 1] ^= 1; // archive changed
    try testing.expectError(error.BadSignature, verifyState(pk, &state));

    var other = unhex(vector_state);
    other[40] ^= 1; // a byte of the signature (inside the metadata)
    try testing.expectError(error.BadSignature, verifyState(pk, &other));

    const other_key = (try Ed25519.KeyPair.generateDeterministic(@splat(8))).public_key.toBytes();
    try testing.expectError(error.BadSignature, verifyState(other_key, &unhex(vector_state)));

    const kp = try testKeyPair();
    const v0 = try signState(testing.allocator, kp, 0, "hello archive");
    defer testing.allocator.free(v0);
    try testing.expectError(error.InvalidState, verifyState(pk, v0));
}

test "parseMetadata rejects malformed CBOR" {
    const good = (try parseState(&unhex(vector_state))).metadata;
    _ = try parseMetadata(good);
    try testing.expectError(error.InvalidState, parseMetadata(good[0 .. good.len - 1]));
    const trailing = try std.mem.concat(testing.allocator, u8, &.{ good, "x" });
    defer testing.allocator.free(trailing);
    try testing.expectError(error.InvalidState, parseMetadata(trailing));
    try testing.expectError(error.InvalidState, parseMetadata(""));
    const one_key = [_]u8{ 0xa1, 0x67 } ++ "version".* ++ [_]u8{0x01};
    try testing.expectError(error.InvalidState, parseMetadata(&one_key));
    try testing.expectError(error.InvalidState, parseMetadata(&.{ 0xbf, 0xff })); // indefinite map
}

test "cbor uints round trip in their shortest form" {
    var buf: [5]u8 = undefined;
    for ([_]u32{ 0, 23, 24, 255, 256, 65535, 65536, std.math.maxInt(u32) }) |v| {
        const encoded = cborUint(&buf, v);
        try testing.expectEqual(v, try parseCborUint(encoded));
    }
    try testing.expectEqualSlices(u8, &.{ 0x18, 200 }, cborUint(&buf, 200)); // ciborium: 18c8
    try testing.expectError(error.InvalidState, parseCborUint(&.{ 0x1b, 0, 0, 0, 1, 0, 0, 0, 0 })); // > u32
    try testing.expectError(error.InvalidState, parseCborUint(&.{ 0x01, 0x02 })); // trailing byte
}

test "parseState rejects malformed layouts" {
    try testing.expectError(error.InvalidState, parseState(""));
    try testing.expectError(error.InvalidState, parseState(&@as([7]u8, @splat(0))));
    var bad: [17]u8 = @splat(0);
    std.mem.writeInt(u64, bad[8..16], 5, .big); // claims 5 archive bytes, has 1
    try testing.expectError(error.InvalidState, parseState(&bad));
    var big_meta: [8]u8 = undefined;
    std.mem.writeInt(u64, &big_meta, max_metadata_size + 1, .big);
    try testing.expectError(error.InvalidState, parseState(&big_meta));
}

test "versionRefs versions the site's own files and nothing else" {
    const gpa = testing.allocator;
    const names: []const []const u8 = &.{ "style.css", "app.js", "freenet.js", "img/logo.png" };
    const page =
        \\<link rel="stylesheet" href="style.css">
        \\<link rel="icon" href="data:image/svg+xml,x">
        \\<script src="freenet.js"></script>
        \\<script SRC = 'app.js'></script>
        \\<img src="img/logo.png" data-src="app.js">
        \\<a href="https://example.com/app.js">x</a> <a href="#/app.js">y</a>
        \\<script src="other.js"></script><script src="app.js?v=1"></script>
        \\<p>src="app.js" in text, href=app.js unquoted</p><div xsrc="app.js"></div>
    ;
    const out = try versionRefs(gpa, page, names, 1234);
    defer gpa.free(out);
    try testing.expectEqualStrings(
        \\<link rel="stylesheet" href="style.css?v=1234">
        \\<link rel="icon" href="data:image/svg+xml,x">
        \\<script src="freenet.js?v=1234"></script>
        \\<script SRC = 'app.js?v=1234'></script>
        \\<img src="img/logo.png?v=1234" data-src="app.js">
        \\<a href="https://example.com/app.js">x</a> <a href="#/app.js">y</a>
        \\<script src="other.js"></script><script src="app.js?v=1"></script>
        \\<p>src="app.js" in text, href=app.js unquoted</p><div xsrc="app.js"></div>
    , out);
    // the same input, the same bytes
    const again = try versionRefs(gpa, page, names, 1234);
    defer gpa.free(again);
    try testing.expectEqualStrings(out, again);
    // a page without references, or an unterminated quote, comes back as it was
    for ([_][]const u8{ "", "<p>hello</p>", "<script src=\"app.js" }) |p| {
        const same = try versionRefs(gpa, p, names, 7);
        defer gpa.free(same);
        try testing.expectEqualStrings(p, same);
    }
}

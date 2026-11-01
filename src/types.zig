//! Identifiers shared by contracts, delegates and tools.

const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;

/// 32-byte contract instance id: BLAKE3(BLAKE3(code) || parameters).
/// Shown to users in base58 (see `encodeBase58`).
pub const ContractInstanceId = [32]u8;

/// BLAKE3 of Wasm code.
pub const CodeHash = [32]u8;

/// A delegate's identity: BLAKE3(code_hash || parameters), plus the code hash.
pub const DelegateKey = struct {
    key: [32]u8,
    code_hash: CodeHash,
};

pub fn blake3(parts: []const []const u8) [32]u8 {
    var h = Blake3.init(.{});
    for (parts) |part| h.update(part);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

pub fn codeHash(wasm: []const u8) CodeHash {
    return blake3(&.{wasm});
}

/// Same derivation as freenet-stdlib `ContractInstanceId::from_params_and_code`.
pub fn contractInstanceId(wasm: []const u8, parameters: []const u8) ContractInstanceId {
    return blake3(&.{ &codeHash(wasm), parameters });
}

/// Same derivation as freenet-stdlib `DelegateKey::from_params_and_code`.
pub fn delegateKey(wasm: []const u8, parameters: []const u8) DelegateKey {
    const hash = codeHash(wasm);
    return .{ .key = blake3(&.{ &hash, parameters }), .code_hash = hash };
}

/// Bitcoin-alphabet base58, as Freenet prints keys. `out` needs at least
/// 44 bytes for a 32-byte input.
pub fn encodeBase58(out: []u8, input: []const u8) []const u8 {
    const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    var digits: [128]u8 = undefined; // little-endian base-58 digits
    std.debug.assert(input.len <= 90);
    var n: usize = 0;
    for (input) |byte| {
        var carry: u32 = byte;
        for (digits[0..n]) |*d| {
            carry += @as(u32, d.*) << 8;
            d.* = @intCast(carry % 58);
            carry /= 58;
        }
        while (carry > 0) : (carry /= 58) {
            digits[n] = @intCast(carry % 58);
            n += 1;
        }
    }
    var len: usize = 0;
    for (input) |byte| {
        if (byte != 0) break;
        out[len] = '1';
        len += 1;
    }
    var i = n;
    while (i > 0) {
        i -= 1;
        out[len] = alphabet[digits[i]];
        len += 1;
    }
    return out[0..len];
}

test "blake3 known vector (keys depend on it)" {
    try std.testing.expectEqualStrings(
        "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262",
        &std.fmt.bytesToHex(blake3(&.{ "", "" }), .lower),
    );
}

test "base58 known vectors" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("StV1DL6CwTryKyV", encodeBase58(&buf, "hello world"));
    try std.testing.expectEqualStrings("11", encodeBase58(&buf, &.{ 0, 0 }));
}

test "key derivations agree with each other" {
    const k = delegateKey("code", "params");
    try std.testing.expectEqualSlices(u8, &codeHash("code"), &k.code_hash);
    try std.testing.expectEqualSlices(u8, &contractInstanceId("code", "params"), &k.key);
}

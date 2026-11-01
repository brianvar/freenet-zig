//! The default web-app contract used by `addWebApp`: a signed site.
//!
//! Parameters = the publisher's Ed25519 public key (32 bytes). A state is
//! accepted only if it carries a version above 0 and the publisher's signature
//! over `version ‖ archive` (see `webapp.zig`), and an update only if its
//! version is higher than the current one.
//!
//! The contract's id is BLAKE3(BLAKE3(this code) ‖ public key). It does not
//! depend on the site, so it stays the same across releases, and a delegate
//! can be told the id of the app it belongs to (see `Delegate.requireApp`).
//! Whoever holds the signing key can change the site.
//!
//! This follows freenet-core's `fdev website` contract: the same state
//! format, signed bytes, version rule and sync summary, so states made by
//! either tool are valid for both contracts.

const std = @import("std");
const freenet = @import("freenet.zig");
const webapp = freenet.webapp;

fn publicKey(c: *freenet.Contract) error{ContractFailed}![32]u8 {
    if (c.parameters.len != 32) return c.fail("parameters must be the publisher's 32-byte Ed25519 public key");
    return c.parameters[0..32].*;
}

/// Version of a state whose signature checks out.
fn verified(c: *freenet.Contract, key: [32]u8, state: []const u8) !u32 {
    const meta = webapp.verifyState(key, state) catch |err| switch (err) {
        error.BadSignature => return c.fail("signature verification failed"),
        error.InvalidState => return error.InvalidState,
    };
    return meta.version;
}

pub fn validateState(c: *freenet.Contract, state: []const u8, _: freenet.RelatedContracts) !freenet.ValidateResult {
    _ = try verified(c, try publicKey(c), state);
    return .valid;
}

/// Takes the newest signed state among the updates. Deltas are either empty
/// ("nothing new") or a whole state (see `getStateDelta`).
pub fn updateState(c: *freenet.Contract, state: []const u8, updates: *freenet.Updates) !freenet.UpdateResult {
    const key = try publicKey(c);
    var current = state;
    var version: u32 = if (state.len == 0) 0 else try webapp.stateVersion(state);
    while (try updates.next()) |u| {
        const candidate = switch (u) {
            .state => |s| s,
            .delta => |d| if (d.len == 0) continue else d,
            .state_and_delta => |x| x.state,
            else => return c.fail("related contracts are not used by this contract"),
        };
        const v = try verified(c, key, candidate);
        if (v == version and std.mem.eql(u8, candidate, current)) continue; // already have it
        if (v <= version) return c.fail("the new version must be higher than the current one");
        current = candidate;
        version = v;
    }
    return .{ .new_state = current };
}

/// The summary is the state's version as a CBOR integer (empty for no state).
pub fn summarizeState(c: *freenet.Contract, state: []const u8) ![]const u8 {
    if (state.len == 0) return "";
    var buf: [5]u8 = undefined;
    return c.allocator.dupe(u8, webapp.cborUint(&buf, try webapp.stateVersion(state)));
}

/// A peer on an older (or no) version gets the whole state; otherwise nothing.
pub fn getStateDelta(_: *freenet.Contract, state: []const u8, summary: []const u8) ![]const u8 {
    if (state.len == 0) return "";
    const theirs: u32 = if (summary.len == 0) 0 else (webapp.parseCborUint(summary) catch return error.InvalidDelta);
    return if (try webapp.stateVersion(state) > theirs) state else "";
}

// ---- tests ----------------------------------------------------------------

const t = freenet.testing;
const testing = std.testing;
const Ed25519 = std.crypto.sign.Ed25519;

fn keyPair(seed_byte: u8) !Ed25519.KeyPair {
    return Ed25519.KeyPair.generateDeterministic(@splat(seed_byte));
}

/// A signed state; freed by the test's arena.
fn site(a: std.mem.Allocator, seed_byte: u8, version: u32, archive: []const u8) ![]u8 {
    return webapp.signState(a, try keyPair(seed_byte), version, archive);
}

test "valid only for the publisher's signed, well-formed state" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = (try keyPair(1)).public_key.toBytes();
    const state = try site(a, 1, 10, "archive");

    try testing.expectEqual(freenet.ValidateResult.valid, (try t.validate(@This(), &key, state, .{})).ok);

    const other_key = (try keyPair(2)).public_key.toBytes();
    try testing.expectEqualStrings("signature verification failed", (try t.validate(@This(), &other_key, state, .{})).err.other);

    var tampered = try a.dupe(u8, state);
    tampered[tampered.len - 1] ^= 1;
    try testing.expectEqualStrings("signature verification failed", (try t.validate(@This(), &key, tampered, .{})).err.other);

    try testing.expectEqual(freenet.testing.ContractError.invalid_state, (try t.validate(@This(), &key, "", .{})).err);
    try testing.expectEqual(freenet.testing.ContractError.invalid_state, (try t.validate(@This(), &key, try site(a, 1, 0, "archive"), .{})).err);
    try testing.expectEqualStrings("parameters must be the publisher's 32-byte Ed25519 public key", (try t.validate(@This(), "short", state, .{})).err.other);
}

test "a state made by fdev website is valid too" {
    // see the vectors in webapp.zig; this is the same site, array-style signature
    const key = (try keyPair(7)).public_key.toBytes();
    const state = comptime blk: {
        @setEvalBranchQuota(100_000);
        const hex = "0000000000000091a26776657273696f6e1a6a18a500697369676e61747572659840183618a70518201877185f18d718a91418ea187b187c18e318bb18b4184a188d183618a00f001899186f187a18561838183518f518af1897189d18221843188418ed18e5187e18a2182b182a18bf18b6182c060c187f186b181818cd181d18861898187618f317187a18eb18ba18300c187f18d2185a0a000000000000000d68656c6c6f2061726368697665";
        var out: [hex.len / 2]u8 = undefined;
        _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
        break :blk out;
    };
    try testing.expectEqual(freenet.ValidateResult.valid, (try t.validate(@This(), &key, &state, .{})).ok);
}

test "updates: only newer signed states, and the same one again is a no-op" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = (try keyPair(1)).public_key.toBytes();
    const v10 = try site(a, 1, 10, "ten");
    const v20 = try site(a, 1, 20, "twenty");
    const v30 = try site(a, 1, 30, "thirty");

    const newer = try t.update(@This(), &key, v10, &.{.{ .state = v20 }});
    try testing.expectEqualSlices(u8, v20, newer.ok.new_state);

    const again = try t.update(@This(), &key, v10, &.{.{ .state = v10 }});
    try testing.expectEqualSlices(u8, v10, again.ok.new_state);

    const empty_delta = try t.update(@This(), &key, v10, &.{.{ .delta = "" }});
    try testing.expectEqualSlices(u8, v10, empty_delta.ok.new_state);

    const full_delta = try t.update(@This(), &key, v10, &.{.{ .delta = v20 }});
    try testing.expectEqualSlices(u8, v20, full_delta.ok.new_state);

    // several at once: in order, each newer than the last
    const batch = try t.update(@This(), &key, v10, &.{ .{ .state = v20 }, .{ .state = v30 } });
    try testing.expectEqualSlices(u8, v30, batch.ok.new_state);

    // the first state, from nothing
    const first = try t.update(@This(), &key, "", &.{.{ .state = v10 }});
    try testing.expectEqualSlices(u8, v10, first.ok.new_state);

    const rollback = try t.update(@This(), &key, v20, &.{.{ .state = v10 }});
    try testing.expectEqualStrings("the new version must be higher than the current one", rollback.err.invalid_update_with_info);

    // a different site at the same version is a conflict, not a no-op
    const rival = try site(a, 1, 20, "rival");
    const conflict = try t.update(@This(), &key, v20, &.{.{ .state = rival }});
    try testing.expectEqualStrings("the new version must be higher than the current one", conflict.err.invalid_update_with_info);

    // someone else's signature, however high the version
    const forged = try site(a, 2, 99, "evil");
    const refused = try t.update(@This(), &key, v10, &.{.{ .state = forged }});
    try testing.expectEqualStrings("signature verification failed", refused.err.invalid_update_with_info);
}

test "sync: summaries are versions, and only older peers get the state" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = (try keyPair(1)).public_key.toBytes();
    const v20 = try site(a, 1, 20, "twenty");
    const v10 = try site(a, 1, 10, "ten");

    const summary = (try t.summarize(@This(), &key, v20)).ok;
    try testing.expectEqualSlices(u8, &.{ 0x14 }, summary); // CBOR 20
    try testing.expectEqual(@as(usize, 0), (try t.summarize(@This(), &key, "")).ok.len);

    try testing.expectEqual(@as(usize, 0), (try t.delta(@This(), &key, v20, summary)).ok.len);
    const old_summary = (try t.summarize(@This(), &key, v10)).ok;
    try testing.expectEqualSlices(u8, v20, (try t.delta(@This(), &key, v20, old_summary)).ok);
    try testing.expectEqualSlices(u8, v20, (try t.delta(@This(), &key, v20, "")).ok); // peer has nothing
    try testing.expectEqual(freenet.testing.ContractError.invalid_delta, (try t.delta(@This(), &key, v20, "junk")).err);
}

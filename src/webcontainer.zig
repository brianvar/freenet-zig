//! The default web-app contract used by `addWebApp`: content-addressed.
//!
//! Parameters = BLAKE3(state). A contract key is derived from code and
//! parameters, so the key commits to the exact site bytes: nobody (including
//! you) can replace them. A changed site is a new contract with a new key.

const std = @import("std");
const freenet = @import("freenet.zig");

fn matches(params: []const u8, state: []const u8) bool {
    if (params.len != 32) return false;
    return std.mem.eql(u8, params, &freenet.types.blake3(&.{state}));
}

pub fn validateState(c: *freenet.Contract, state: []const u8, _: freenet.RelatedContracts) !freenet.ValidateResult {
    if (!matches(c.parameters, state)) return .invalid;
    _ = freenet.webapp.parseState(state) catch return .invalid;
    return .valid;
}

/// Accepts only the one state the parameters hash to. Deltas are either
/// empty ("nothing new") or the whole state (see `getStateDelta`).
pub fn updateState(c: *freenet.Contract, state: []const u8, updates: *freenet.Updates) !freenet.UpdateResult {
    var new_state = state;
    while (try updates.next()) |u| {
        const candidate = switch (u) {
            .state => |s| s,
            .delta => |d| if (d.len == 0) continue else d,
            .state_and_delta => |x| x.state,
            else => return c.fail("related contracts are not used by this contract"),
        };
        if (!matches(c.parameters, candidate)) return c.fail("state does not match the contract's hash");
        new_state = candidate;
    }
    return .{ .new_state = new_state };
}

/// The summary is the state's hash (= the parameters for a valid state).
pub fn summarizeState(c: *freenet.Contract, state: []const u8) ![]const u8 {
    const h = freenet.types.blake3(&.{state});
    return c.allocator.dupe(u8, &h);
}

/// Peer has this exact state: nothing to send; otherwise send all of it.
pub fn getStateDelta(_: *freenet.Contract, state: []const u8, summary: []const u8) ![]const u8 {
    const h = freenet.types.blake3(&.{state});
    return if (std.mem.eql(u8, summary, &h)) "" else state;
}

// ---- tests ----------------------------------------------------------------

const t = freenet.testing;
const testing = std.testing;

/// [u64 BE 0: no metadata][u64 BE 5]["hello"]: enough for the layout check
const site = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5 } ++ "hello".*;

fn siteParams() [32]u8 {
    return freenet.types.blake3(&.{&site});
}

test "valid only for the hashed, well-formed state" {
    const p = siteParams();
    try testing.expectEqual(freenet.ValidateResult.valid, (try t.validate(@This(), &p, &site, .{})).ok);
    try testing.expectEqual(freenet.ValidateResult.invalid, (try t.validate(@This(), &p, site[1..], .{})).ok);
    // right hash but not a web-app layout
    const junk = "junk";
    const jp = freenet.types.blake3(&.{junk});
    try testing.expectEqual(freenet.ValidateResult.invalid, (try t.validate(@This(), &jp, junk, .{})).ok);
}

test "updates: only the same state is accepted" {
    const p = siteParams();
    const same = try t.update(@This(), &p, &site, &.{.{ .state = &site }});
    try testing.expectEqualSlices(u8, &site, same.ok.new_state);
    const empty = try t.update(@This(), &p, &site, &.{.{ .delta = "" }});
    try testing.expectEqualSlices(u8, &site, empty.ok.new_state);
    const other = try t.update(@This(), &p, &site, &.{.{ .state = "evil" }});
    try testing.expectEqualStrings("state does not match the contract's hash", other.err.invalid_update_with_info);
}

test "sync: in-sync peers get an empty delta" {
    const p = siteParams();
    const sum = (try t.summarize(@This(), &p, &site)).ok;
    try testing.expectEqualSlices(u8, &p, sum);
    try testing.expectEqual(@as(usize, 0), (try t.delta(@This(), &p, &site, sum)).ok.len);
    try testing.expectEqualSlices(u8, &site, (try t.delta(@This(), &p, &site, "stale")).ok);
}

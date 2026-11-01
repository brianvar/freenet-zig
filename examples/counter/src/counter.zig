//! A shared click counter: a contract whose state is a grow-only counter.
//!
//! State (text):
//!
//!     counter-v1
//!     <visitor id: 16 hex chars>:<that visitor's clicks>
//!     ...                                  (sorted by id, no duplicates)
//!
//! A delta is just entry lines. Merging takes the maximum per visitor, so it
//! is commutative and idempotent: peers that see the same updates in any
//! order, even repeated, end up with identical states. The total is the sum.
//!
//! (A demo: anyone can claim any visitor id. A real app would have each
//! visitor sign their entry, for example with a key held in a delegate.)

const std = @import("std");
const freenet = @import("freenet");

comptime {
    freenet.exportContract(@This());
}

const header = "counter-v1";
const max_entries = 10_000;

const Entry = struct { id: [16]u8, count: u64 };

/// Parses entry lines into `out` (merging by max). `with_header`: a full state.
fn parseInto(gpa: std.mem.Allocator, out: *std.ArrayList(Entry), text: []const u8, with_header: bool) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    if (with_header and !std.mem.eql(u8, lines.next() orelse "", header)) return error.InvalidState;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line.len < 18 or line[16] != ':') return error.InvalidState;
        const id = line[0..16].*;
        for (id) |ch| if (!std.ascii.isHex(ch) or std.ascii.isUpper(ch)) return error.InvalidState;
        const count = std.fmt.parseInt(u64, line[17..], 10) catch return error.InvalidState;
        try merge(gpa, out, .{ .id = id, .count = count });
        if (out.items.len > max_entries) return error.InvalidState;
    }
}

fn merge(gpa: std.mem.Allocator, entries: *std.ArrayList(Entry), e: Entry) !void {
    for (entries.items) |*existing| {
        if (std.mem.eql(u8, &existing.id, &e.id)) {
            existing.count = @max(existing.count, e.count);
            return;
        }
    }
    try entries.append(gpa, e);
}

fn lessThan(_: void, x: Entry, y: Entry) bool {
    return std.mem.lessThan(u8, &x.id, &y.id);
}

fn serialize(gpa: std.mem.Allocator, entries: []Entry) ![]const u8 {
    std.mem.sort(Entry, entries, {}, lessThan);
    var out: std.Io.Writer.Allocating = .init(gpa);
    try out.writer.writeAll(header ++ "\n");
    for (entries) |e| try out.writer.print("{s}:{d}\n", .{ &e.id, e.count });
    return out.written();
}

pub fn validateState(c: *freenet.Contract, state: []const u8, _: freenet.RelatedContracts) !freenet.ValidateResult {
    var entries: std.ArrayList(Entry) = .empty;
    parseInto(c.allocator, &entries, state, true) catch return .invalid;
    // canonical form only (sorted, no duplicates), so equal counters are equal bytes
    const canonical = try serialize(c.allocator, entries.items);
    return if (std.mem.eql(u8, canonical, state)) .valid else .invalid;
}

pub fn updateState(c: *freenet.Contract, state: []const u8, updates: *freenet.Updates) !freenet.UpdateResult {
    var entries: std.ArrayList(Entry) = .empty;
    try parseInto(c.allocator, &entries, state, true);
    while (try updates.next()) |u| switch (u) {
        .state => |s| try parseInto(c.allocator, &entries, s, true),
        .delta => |d| try parseInto(c.allocator, &entries, d, false),
        .state_and_delta => |x| {
            try parseInto(c.allocator, &entries, x.state, true);
            try parseInto(c.allocator, &entries, x.delta, false);
        },
        else => return c.fail("this contract has no related contracts"),
    };
    return .{ .new_state = try serialize(c.allocator, entries.items) };
}

pub fn summarizeState(c: *freenet.Contract, state: []const u8) ![]const u8 {
    return c.allocator.dupe(u8, &freenet.types.blake3(&.{state}));
}

/// In sync: nothing. Otherwise all entries (merging is idempotent, so
/// sending entries the peer already has is harmless).
pub fn getStateDelta(_: *freenet.Contract, state: []const u8, summary: []const u8) ![]const u8 {
    if (std.mem.eql(u8, summary, &freenet.types.blake3(&.{state}))) return "";
    return state[header.len + 1 ..];
}

// ---- tests ----------------------------------------------------------------

const t = freenet.testing;
const testing = std.testing;

const empty = header ++ "\n";
const a = "aaaaaaaaaaaaaaaa";
const b = "bbbbbbbbbbbbbbbb";

test "validate: canonical states only" {
    try testing.expectEqual(freenet.ValidateResult.valid, (try t.validate(@This(), "", empty, .{})).ok);
    try testing.expectEqual(freenet.ValidateResult.valid, (try t.validate(@This(), "", empty ++ a ++ ":1\n" ++ b ++ ":2\n", .{})).ok);
    try testing.expectEqual(freenet.ValidateResult.invalid, (try t.validate(@This(), "", empty ++ b ++ ":2\n" ++ a ++ ":1\n", .{})).ok); // unsorted
    try testing.expectEqual(freenet.ValidateResult.invalid, (try t.validate(@This(), "", "hello", .{})).ok);
}

test "update: deltas merge by max per visitor" {
    const res = try t.update(@This(), "", empty ++ a ++ ":5\n", &.{
        .{ .delta = b ++ ":1\n" },
        .{ .delta = a ++ ":3\n" }, // older than what we have: ignored
        .{ .delta = b ++ ":2\n" },
    });
    try testing.expectEqualStrings(empty ++ a ++ ":5\n" ++ b ++ ":2\n", res.ok.new_state);
}

test "merge is commutative and idempotent" {
    const d1: freenet.Update = .{ .delta = a ++ ":1\n" };
    const d2: freenet.Update = .{ .delta = b ++ ":4\n" ++ a ++ ":2\n" };
    const d3: freenet.Update = .{ .state = empty ++ b ++ ":3\n" };
    const orders = [_][]const freenet.Update{
        &.{ d1, d2, d3 }, &.{ d3, d2, d1 }, &.{ d2, d1, d3 }, &.{ d1, d1, d3, d2, d2 },
    };
    var first: ?[]const u8 = null;
    for (orders) |order| {
        const s = (try t.update(@This(), "", empty, order)).ok.new_state;
        if (first) |f| try testing.expectEqualStrings(f, s) else first = s;
    }
    try testing.expectEqualStrings(empty ++ a ++ ":2\n" ++ b ++ ":4\n", first.?);
}

test "sync: delta brings a stale peer up to date" {
    const state = empty ++ a ++ ":2\n";
    const sum = (try t.summarize(@This(), "", state)).ok;
    try testing.expectEqual(@as(usize, 0), (try t.delta(@This(), "", state, sum)).ok.len);
    const d = (try t.delta(@This(), "", state, "old")).ok;
    const caught_up = (try t.update(@This(), "", empty, &.{.{ .delta = d }})).ok.new_state;
    try testing.expectEqualStrings(state, caught_up);
}

test "garbage updates are rejected" {
    const res = try t.update(@This(), "", empty, &.{.{ .delta = "nope" }});
    try testing.expectEqual(freenet.contract.ContractError.invalid_state, res.err);
}

//! A contract for js/test.html's `follow` tests, run by freenet.js in the page
//! (ContractRunner). `zig build test` builds it and writes it to
//! js/test-contract.js (git-ignored) as base64, which test.html loads.
//!
//! State: lines, sorted, no duplicates, each ending in a newline. Merging is the
//! union. The summary is the lines joined by `,`, so a test can see which state
//! the page summarized; the delta for a summary is the lines it lacks. A line
//! `bad` makes a merge fail, and a line `log` makes it call the log import.

const std = @import("std");
const freenet = @import("freenet");

comptime {
    freenet.exportContract(@This());
}

fn linesOf(gpa: std.mem.Allocator, out: *std.ArrayList([]const u8), text: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| if (line.len > 0) try out.append(gpa, line);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Sorted, without duplicates.
fn canonical(set: *std.ArrayList([]const u8)) void {
    std.mem.sort([]const u8, set.items, {}, lessThan);
    var n: usize = 0;
    for (set.items) |line| {
        if (n > 0 and std.mem.eql(u8, set.items[n - 1], line)) continue;
        set.items[n] = line;
        n += 1;
    }
    set.shrinkRetainingCapacity(n);
}

fn join(gpa: std.mem.Allocator, set: []const []const u8, comptime sep: []const u8, end: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    for (set, 0..) |line, i| {
        if (i > 0 and !end) try out.writer.writeAll(sep);
        try out.writer.writeAll(line);
        if (end) try out.writer.writeAll(sep);
    }
    return out.written();
}

pub fn validateState(_: *freenet.Contract, _: []const u8, _: freenet.RelatedContracts) !freenet.ValidateResult {
    return .valid;
}

pub fn updateState(c: *freenet.Contract, state: []const u8, updates: *freenet.Updates) !freenet.UpdateResult {
    var set: std.ArrayList([]const u8) = .empty;
    try linesOf(c.allocator, &set, state);
    while (try updates.next()) |u| switch (u) {
        .state => |s| try linesOf(c.allocator, &set, s),
        .delta => |d| try linesOf(c.allocator, &set, d),
        else => return c.fail("no related contracts here"),
    };
    for (set.items) |line| {
        if (std.mem.eql(u8, line, "bad")) return c.fail("a bad line");
        if (std.mem.eql(u8, line, "log")) freenet.log.info("merging a log line");
    }
    canonical(&set);
    return .{ .new_state = try join(c.allocator, set.items, "\n", true) };
}

pub fn summarizeState(c: *freenet.Contract, state: []const u8) ![]const u8 {
    var set: std.ArrayList([]const u8) = .empty;
    try linesOf(c.allocator, &set, state);
    canonical(&set);
    return join(c.allocator, set.items, ",", false);
}

pub fn getStateDelta(c: *freenet.Contract, state: []const u8, summary: []const u8) ![]const u8 {
    var have: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, summary, ',');
    while (it.next()) |line| try have.append(c.allocator, line);
    var missing: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, state, '\n');
    outer: while (lines.next()) |line| {
        if (line.len == 0) continue;
        for (have.items) |h| if (std.mem.eql(u8, h, line)) continue :outer;
        try missing.append(c.allocator, line);
    }
    return join(c.allocator, missing.items, "\n", true);
}

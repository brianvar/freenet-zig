//! Wire-format tests: inputs and expected outputs are written out byte by
//! byte from the freenet-stdlib type definitions, independently of the
//! library's own encoder. If these pass, the bytes on the wire are right.

const std = @import("std");
const freenet = @import("freenet.zig");
const t = freenet.testing;
const testing = std.testing;

fn le32(comptime v: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    return b;
}

fn le64(comptime v: u64) [8]u8 {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    return b;
}

/// Vec<u8> / String / serde Bytes
fn vec(comptime s: []const u8) [8 + s.len]u8 {
    return le64(s.len) ++ s[0..s.len].*;
}

const web_origin = le32(0) ++ @as([32]u8, @splat(7)); // MessageOrigin::WebApp(id)

/// InboundDelegateMsg::ApplicationMessage { payload, context: [], processed: false }
fn appMsg(comptime payload: []const u8) [4 + 8 + payload.len + 8 + 1]u8 {
    return le32(0) ++ vec(payload) ++ vec("") ++ [_]u8{0};
}

// ---- delegates ---------------------------------------------------------------

const Echo = struct {
    pub fn handle(d: *freenet.Delegate, msg: freenet.Inbound) !void {
        switch (msg) {
            .application => |app| {
                if (std.mem.eql(u8, app.payload, "fail")) return d.fail("nope");
                if (std.mem.eql(u8, app.payload, "boom")) return error.Boom;
                if (std.mem.eql(u8, app.payload, "ctx")) return d.setContext("c1");
                if (std.mem.eql(u8, app.payload, "origin")) return d.replyFmt("{s}", .{@tagName(d.origin)});
                try d.reply(app.payload);
            },
            .unsupported => {},
        }
    }
};

test "delegate: reply bytes" {
    const out = t.raw.callDelegate(Echo, "", &web_origin, &appMsg("hi"));
    const expected = le32(0) ++ le64(1) ++ // Ok, one message
        le32(0) ++ vec("hi") ++ vec("") ++ [_]u8{1}; // ApplicationMessage, processed
    try testing.expectEqualSlices(u8, &expected, out);
}

test "delegate: ContextUpdated bytes" {
    const out = t.raw.callDelegate(Echo, "", &web_origin, &appMsg("ctx"));
    const expected = le32(0) ++ le64(1) ++ le32(2) ++ vec("c1");
    try testing.expectEqualSlices(u8, &expected, out);
}

test "delegate: errors become DelegateError::Other" {
    try testing.expectEqualSlices(u8, &(le32(1) ++ le32(1) ++ vec("nope")), t.raw.callDelegate(Echo, "", &web_origin, &appMsg("fail")));
    try testing.expectEqualSlices(u8, &(le32(1) ++ le32(1) ++ vec("Boom")), t.raw.callDelegate(Echo, "", &web_origin, &appMsg("boom")));
    try testing.expectEqualSlices(u8, &(le32(1) ++ le32(1) ++ vec("EndOfStream")), t.raw.callDelegate(Echo, "", &web_origin, &.{ 0, 0, 0, 0, 0xff }));
}

test "delegate: other inbound variants (e.g. Lifecycle, tag 10) reach handle as .unsupported" {
    const out = t.raw.callDelegate(Echo, "", "", &(le32(10) ++ le32(0)));
    try testing.expectEqualSlices(u8, &(le32(0) ++ le64(0)), out);
}

test "delegate: origins" {
    t.reset();
    try testing.expectEqualStrings("web_app", (try t.ask(Echo, "origin", .{}))[0]);
    try testing.expectEqualStrings("none", (try t.ask(Echo, "origin", .{ .origin = .none }))[0]);
    try testing.expectEqualStrings("delegate", (try t.ask(Echo, "origin", .{ .origin = .{ .delegate = .{ .key = @splat(1), .code_hash = @splat(2) } } }))[0]);
    // raw MessageOrigin::Delegate(DelegateKey { key, code_hash })
    const delegate_origin = le32(1) ++ @as([64]u8, @splat(3));
    const out = t.raw.callDelegate(Echo, "", &delegate_origin, &appMsg("origin"));
    try testing.expectEqualSlices(u8, &(le32(0) ++ le64(1) ++ le32(0) ++ vec("delegate") ++ vec("") ++ [_]u8{1}), out);
}

const Vault = struct {
    pub fn handle(d: *freenet.Delegate, msg: freenet.Inbound) !void {
        const app = switch (msg) {
            .application => |a| a,
            .unsupported => return,
        };
        const s = d.secrets();
        if (std.mem.startsWith(u8, app.payload, "set ")) {
            try s.set("k", app.payload[4..]);
            try d.reply("ok");
        } else if (std.mem.eql(u8, app.payload, "get")) {
            try d.reply((try s.get("k")) orelse "(none)");
        } else if (std.mem.eql(u8, app.payload, "rm")) {
            try d.reply(if (s.remove("k")) "removed" else "missing");
        } else if (std.mem.eql(u8, app.payload, "list")) {
            try d.replyFmt("{d}", .{(try s.list("")).len});
        }
    }
};

test "delegate: secrets persist across calls" {
    t.reset();
    try testing.expectEqualStrings("(none)", (try t.ask(Vault, "get", .{}))[0]);
    _ = try t.ask(Vault, "set hunter2", .{});
    try testing.expectEqualStrings("hunter2", (try t.ask(Vault, "get", .{}))[0]);
    try testing.expectEqualStrings("hunter2", t.secret("k").?);
    try testing.expectEqualStrings("1", (try t.ask(Vault, "list", .{}))[0]);
    try testing.expectEqualStrings("removed", (try t.ask(Vault, "rm", .{}))[0]);
    try testing.expectEqualStrings("missing", (try t.ask(Vault, "rm", .{}))[0]);
}

// ---- contracts ---------------------------------------------------------------

/// State is a decimal counter; updates are deltas "+N". Needs a related
/// contract when asked to (to exercise request_related / requires).
const Counter = struct {
    pub fn validateState(c: *freenet.Contract, state: []const u8, related: freenet.RelatedContracts) !freenet.ValidateResult {
        if (std.mem.eql(u8, state, "need-related")) {
            if (related.get(@splat(9))) |e| return if (e.state != null) .valid else .invalid;
            return .{ .request_related = try c.allocator.dupe([32]u8, &.{@splat(9)}) };
        }
        _ = std.fmt.parseInt(u64, state, 10) catch return .invalid;
        return .valid;
    }
    pub fn updateState(c: *freenet.Contract, state: []const u8, updates: *freenet.Updates) !freenet.UpdateResult {
        var n = std.fmt.parseInt(u64, state, 10) catch return error.InvalidState;
        while (try updates.next()) |u| switch (u) {
            .delta => |d| n += std.fmt.parseInt(u64, d[1..], 10) catch return c.fail("bad delta"),
            .related_state => return .{ .requires = &.{.{ .id = @splat(9), .mode = .state_then_subscribe }} },
            else => return error.InvalidUpdate,
        };
        return .{ .new_state = try c.allocator.print("{d}", .{n}) };
    }
    pub fn summarizeState(_: *freenet.Contract, state: []const u8) ![]const u8 {
        return state;
    }
    pub fn getStateDelta(_: *freenet.Contract, _: []const u8, _: []const u8) ![]const u8 {
        return error.NotImplemented;
    }
};

test "contract: validate bytes" {
    const no_related = le64(0);
    try testing.expectEqualSlices(u8, &(le32(0) ++ le32(0)), try t.raw.callContract(Counter, .validate_state, "", "41", &no_related));
    try testing.expectEqualSlices(u8, &(le32(0) ++ le32(1)), try t.raw.callContract(Counter, .validate_state, "", "x", &no_related));
    // RequestRelated(vec![id])
    try testing.expectEqualSlices(u8, &(le32(0) ++ le32(2) ++ le64(1) ++ @as([32]u8, @splat(9))), try t.raw.callContract(Counter, .validate_state, "", "need-related", &no_related));
    // with the related state supplied: map { id => Some(state) }
    const related = le64(1) ++ @as([32]u8, @splat(9)) ++ [_]u8{1} ++ vec("s");
    try testing.expectEqualSlices(u8, &(le32(0) ++ le32(0)), try t.raw.callContract(Counter, .validate_state, "", "need-related", &related));
}

test "contract: update bytes" {
    // Vec<UpdateData> [Delta("+2")]
    const updates = le64(1) ++ le32(1) ++ vec("+2");
    // Ok(UpdateModification { new_state: Some("42"), related: [] })
    try testing.expectEqualSlices(u8, &(le32(0) ++ [_]u8{1} ++ vec("42") ++ le64(0)), try t.raw.callContract(Counter, .update_state, "", "40", &updates));
    // RelatedState -> Ok(UpdateModification { new_state: None, related: [{ id, StateThenSubscribe }] })
    const rel = le64(1) ++ le32(3) ++ @as([32]u8, @splat(9)) ++ vec("s");
    try testing.expectEqualSlices(u8, &(le32(0) ++ [_]u8{0} ++ le64(1) ++ @as([32]u8, @splat(9)) ++ le32(1)), try t.raw.callContract(Counter, .update_state, "", "40", &rel));
}

test "contract: error mapping bytes" {
    const bad_delta = le64(1) ++ le32(1) ++ vec("+x");
    // c.fail in update -> InvalidUpdateWithInfo { reason }
    try testing.expectEqualSlices(u8, &(le32(1) ++ le32(2) ++ vec("bad delta")), try t.raw.callContract(Counter, .update_state, "", "1", &bad_delta));
    // error.InvalidState -> InvalidState
    try testing.expectEqualSlices(u8, &(le32(1) ++ le32(3)), try t.raw.callContract(Counter, .update_state, "", "x", &(le64(0))));
    // error.InvalidUpdate -> InvalidUpdate
    try testing.expectEqualSlices(u8, &(le32(1) ++ le32(1)), try t.raw.callContract(Counter, .update_state, "", "1", &(le64(1) ++ le32(0) ++ vec("9"))));
    // truncated input -> Deser("EndOfStream")
    try testing.expectEqualSlices(u8, &(le32(1) ++ le32(0) ++ vec("EndOfStream")), try t.raw.callContract(Counter, .update_state, "", "1", &.{ 1, 2 }));
    // any other error -> Other(name)
    try testing.expectEqualSlices(u8, &(le32(1) ++ le32(5) ++ vec("NotImplemented")), try t.raw.callContract(Counter, .state_delta, "", "1", ""));
}

test "contract: summarize bytes and typed helpers" {
    try testing.expectEqualSlices(u8, &(le32(0) ++ vec("7")), try t.raw.callContract(Counter, .summarize_state, "", "7", null));
    const res = try t.update(Counter, "", "1", &.{ .{ .delta = "+1" }, .{ .delta = "+1" } });
    try testing.expectEqualStrings("3", res.ok.new_state);
}

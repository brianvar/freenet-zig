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
                if (std.mem.eql(u8, app.payload, "stale")) {
                    d.failure = "handled"; // as if it had called d.fail(...) and recovered
                    return error.Boom;
                }
                if (std.mem.eql(u8, app.payload, "ctx")) return d.setContext("c1");
                if (std.mem.eql(u8, app.payload, "origin")) return d.replyFmt("{s}", .{@tagName(d.origin)});
                try d.reply(app.payload);
            },
            .user_response, .unsupported => {},
        }
    }
};

test "delegate: reply bytes" {
    const out = t.raw.callDelegate(Echo, "", &web_origin, &appMsg("hi"));
    const expected = le32(0) ++ le64(1) ++ // Ok, one message
        le32(0) ++ vec("hi") ++ vec("") ++ [_]u8{1}; // ApplicationMessage, processed
    try testing.expectEqualSlices(u8, &expected, out);
}

test "delegate: setContext writes the node's context" {
    t.reset();
    const out = t.raw.callDelegate(Echo, "", &web_origin, &appMsg("ctx"));
    try testing.expectEqualSlices(u8, &(le32(0) ++ le64(0)), out); // Ok, no messages
    try testing.expectEqualStrings("c1", t.context());
}

test "delegate: errors become DelegateError::Other, malformed input Deser" {
    try testing.expectEqualSlices(u8, &(le32(1) ++ le32(1) ++ vec("nope")), t.raw.callDelegate(Echo, "", &web_origin, &appMsg("fail")));
    try testing.expectEqualSlices(u8, &(le32(1) ++ le32(1) ++ vec("Boom")), t.raw.callDelegate(Echo, "", &web_origin, &appMsg("boom")));
    // a fail() message the delegate recovered from doesn't stick to a later error
    try testing.expectEqualSlices(u8, &(le32(1) ++ le32(1) ++ vec("Boom")), t.raw.callDelegate(Echo, "", &web_origin, &appMsg("stale")));
    try testing.expectEqualSlices(u8, &(le32(1) ++ le32(0) ++ vec("EndOfStream")), t.raw.callDelegate(Echo, "", &web_origin, &.{ 0, 0, 0, 0, 0xff }));
}

test "delegate: other inbound variants (e.g. Lifecycle, tag 10) reach handle as .unsupported" {
    const out = t.raw.callDelegate(Echo, "", "", &(le32(10) ++ le32(0)));
    try testing.expectEqualSlices(u8, &(le32(0) ++ le64(0)), out);
}

const Guarded = struct {
    pub fn handle(d: *freenet.Delegate, msg: freenet.Inbound) !void {
        switch (msg) {
            .application => {
                try d.requireApp();
                try d.reply("secret");
            },
            .user_response, .unsupported => {},
        }
    }
};

test "delegate: requireApp lets in only the app named by the parameters" {
    t.reset();
    const app: [32]u8 = @splat(7); // the default origin's id
    try testing.expectEqualStrings("secret", (try t.ask(Guarded, "x", .{ .parameters = &app }))[0]);

    const stranger: [32]u8 = @splat(9);
    const refused = try t.send(Guarded, .{ .application = .{ .payload = "x" } }, .{ .parameters = &stranger });
    try testing.expectEqualStrings("this delegate only answers its own web app", refused.err);

    // no parameters: nobody is let in
    const unset = try t.send(Guarded, .{ .application = .{ .payload = "x" } }, .{});
    try testing.expectEqualStrings("this delegate only answers its own web app", unset.err);

    // other delegates and unknown origins are refused too
    const from_delegate = try t.send(Guarded, .{ .application = .{ .payload = "x" } }, .{
        .parameters = &app,
        .origin = .{ .delegate = .{ .key = @splat(7), .code_hash = @splat(7) } },
    });
    try testing.expectEqualStrings("this delegate only answers its own web app", from_delegate.err);
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

const Prompter = struct {
    pub fn handle(d: *freenet.Delegate, msg: freenet.Inbound) !void {
        switch (msg) {
            .application => |app| {
                if (std.mem.eql(u8, app.payload, "too many")) {
                    return d.requestUserInput(1, "?", &@as([11][]const u8, @splat("x")));
                }
                if (std.mem.eql(u8, app.payload, "empty label")) return d.requestUserInput(1, "?", &.{""});
                if (std.mem.eql(u8, app.payload, "long label")) return d.requestUserInput(1, "?", &.{&@as([65]u8, @splat('x'))});
                if (std.mem.eql(u8, app.payload, "long message")) return d.requestUserInput(1, &@as([2049]u8, @splat('x')), &.{"ok"});
                try d.reply("asked");
                try d.requestUserInput(0x01020304, "Pay 5?", &.{ "Cancel", "Pay" });
            },
            .user_response => |u| try d.replyFmt("{x}:{s}:{d}", .{ u.request_id, u.response, u.context.len }),
            .unsupported => {},
        }
    }
};

test "delegate: RequestUserInput bytes (after the replies)" {
    t.reset();
    const out = t.raw.callDelegate(Prompter, "", &web_origin, &appMsg("ask"));
    const expected = le32(0) ++ le64(2) ++ // Ok, two messages
        le32(0) ++ vec("asked") ++ vec("") ++ [_]u8{1} ++ // ApplicationMessage, processed
        le32(1) ++ le32(0x01020304) ++ // RequestUserInput { request_id
        vec("Pay 5?") ++ // message: NotificationMessage (serde Bytes)
        le64(2) ++ vec("Cancel") ++ vec("Pay"); // responses: Vec<ClientResponse> }
    try testing.expectEqualSlices(u8, &expected, out);
}

test "delegate: UserResponse (tag 1) reaches handle as .user_response" {
    t.reset();
    // InboundDelegateMsg::UserResponse(UserInputResponse { request_id, response, context })
    const in = le32(1) ++ le32(0xabcdef01) ++ vec("Pay") ++ vec("cx");
    const out = t.raw.callDelegate(Prompter, "", &web_origin, &in);
    try testing.expectEqualSlices(u8, &(le32(0) ++ le64(1) ++ le32(0) ++ vec("abcdef01:Pay:2") ++ vec("") ++ [_]u8{1}), out);
    // truncated: a Deser error, not a guess
    try testing.expectEqualSlices(u8, &(le32(1) ++ le32(0) ++ vec("EndOfStream")), t.raw.callDelegate(Prompter, "", &web_origin, &(le32(1) ++ [_]u8{ 1, 2 })));
}

test "delegate: testing harness shows prompts and answers them" {
    t.reset();
    try testing.expectEqualStrings("asked", (try t.ask(Prompter, "ask", .{}))[0]);
    const asked = t.prompts();
    try testing.expectEqual(1, asked.len);
    try testing.expectEqual(0x01020304, asked[0].request_id);
    try testing.expectEqualStrings("Pay 5?", asked[0].message);
    try testing.expectEqual(2, asked[0].responses.len);
    try testing.expectEqualStrings("Pay", asked[0].responses[1]);

    const answer = try t.respond(Prompter, asked[0].request_id, "Pay", .{});
    try testing.expectEqualStrings("1020304:Pay:0", answer.ok[0]);
    try testing.expectEqual(0, t.prompts().len);
    const refused = try t.respond(Prompter, 9, "", .{});
    try testing.expectEqualStrings("9::0", refused.ok[0]);
}

test "delegate: requestUserInput refuses what the node would cut" {
    t.reset();
    const cases = [_][2][]const u8{
        .{ "too many", "a prompt needs 1 to 10 responses" },
        .{ "empty label", "prompt responses are 1 to 64 bytes" },
        .{ "long label", "prompt responses are 1 to 64 bytes" },
        .{ "long message", "a prompt message is at most 2048 bytes" },
    };
    for (cases) |c| {
        const res = try t.send(Prompter, .{ .application = .{ .payload = c[0] } }, .{});
        try testing.expectEqualStrings(c[1], res.err);
        try testing.expectEqual(0, t.prompts().len);
    }
}

const Vault = struct {
    pub fn handle(d: *freenet.Delegate, msg: freenet.Inbound) !void {
        const app = switch (msg) {
            .application => |a| a,
            .user_response, .unsupported => return,
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
            .delta => |d| {
                if (std.mem.eql(u8, d, "stale")) {
                    c.failure = "handled"; // as if it had called c.fail(...) and recovered
                    return error.InvalidDelta;
                }
                n += std.fmt.parseInt(u64, d[1..], 10) catch return c.fail("bad delta");
            },
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
    // a recovered c.fail() doesn't override a later error: InvalidDelta
    try testing.expectEqualSlices(u8, &(le32(1) ++ le32(4)), try t.raw.callContract(Counter, .update_state, "", "1", &(le64(1) ++ le32(1) ++ vec("stale"))));
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

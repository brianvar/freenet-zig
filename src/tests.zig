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
            .user_response, .contract_state, .unsupported => {},
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
            .user_response, .contract_state, .unsupported => {},
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
            .contract_state, .unsupported => {},
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

const Reader = struct {
    pub fn handle(d: *freenet.Delegate, msg: freenet.Inbound) !void {
        switch (msg) {
            .application => |app| {
                if (std.mem.eql(u8, app.payload, "big context")) return d.getContract(@splat(5), &@as([409601]u8, @splat(0)));
                try d.reply("fetching");
                try d.getContract(@splat(5), "n1");
            },
            .contract_state => |c| try d.replyFmt("{x}:{s}:{s}", .{ c.contract_id[0], c.state orelse "none", c.context }),
            .user_response, .unsupported => {},
        }
    }
};

test "delegate: GetContractRequest bytes (last, not processed)" {
    t.reset();
    const out = t.raw.callDelegate(Reader, "", &web_origin, &appMsg("get"));
    const expected = le32(0) ++ le64(2) ++ // Ok, two messages
        le32(0) ++ vec("fetching") ++ vec("") ++ [_]u8{1} ++ // ApplicationMessage, processed
        le32(3) ++ @as([32]u8, @splat(5)) ++ // GetContractRequest { contract_id: 32 bytes
        vec("n1") ++ [_]u8{0}; // context: DelegateContext (Bytes), processed: false }
    try testing.expectEqualSlices(u8, &expected, out);
}

test "delegate: GetContractResponse (tag 2) reaches handle as .contract_state" {
    t.reset();
    // InboundDelegateMsg::GetContractResponse { contract_id, state: Some(WrappedState), context }
    const found = le32(2) ++ @as([32]u8, @splat(0xab)) ++ [_]u8{1} ++ vec("st") ++ vec("n1");
    try testing.expectEqualSlices(u8, &(le32(0) ++ le64(1) ++ le32(0) ++ vec("ab:st:n1") ++ vec("") ++ [_]u8{1}), t.raw.callDelegate(Reader, "", &web_origin, &found));
    // state: None (not found, or the node's request failed)
    const missing = le32(2) ++ @as([32]u8, @splat(0xab)) ++ [_]u8{0} ++ vec("n1");
    try testing.expectEqualSlices(u8, &(le32(0) ++ le64(1) ++ le32(0) ++ vec("ab:none:n1") ++ vec("") ++ [_]u8{1}), t.raw.callDelegate(Reader, "", &web_origin, &missing));
    // a bad Option tag is a Deser error
    const bad = le32(2) ++ @as([32]u8, @splat(0xab)) ++ [_]u8{2};
    try testing.expectEqualSlices(u8, &(le32(1) ++ le32(0) ++ vec("InvalidOption")), t.raw.callDelegate(Reader, "", &web_origin, &bad));
}

test "delegate: testing harness shows contract requests and answers them" {
    t.reset();
    try testing.expectEqualStrings("fetching", (try t.ask(Reader, "get", .{}))[0]);
    const asked = t.contractRequests();
    try testing.expectEqual(1, asked.len);
    try testing.expectEqual(@as([32]u8, @splat(5)), asked[0].contract_id);
    try testing.expectEqualStrings("n1", asked[0].context);
    const got = try t.contractState(Reader, asked[0], "state", .{});
    try testing.expectEqualStrings("5:state:n1", got.ok[0]);
    try testing.expectEqual(0, t.contractRequests().len);
    try testing.expectEqualStrings("5:none:n1", (try t.contractState(Reader, asked[0], null, .{})).ok[0]);
    // a context the node wouldn't take is refused
    const big = try t.send(Reader, .{ .application = .{ .payload = "big context" } }, .{});
    try testing.expectEqualStrings("a contract request's context is at most 400 KiB", big.err);
}

const Vault = struct {
    pub fn handle(d: *freenet.Delegate, msg: freenet.Inbound) !void {
        const app = switch (msg) {
            .application => |a| a,
            .user_response, .contract_state, .unsupported => return,
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

// ---- client (WebSocket API) ----------------------------------------------------
// Requests as freenet.js's Writer calls produce them; responses as the node
// serializes `Result<HostResponse, ClientError>` (client_api/client_events.rs).

const id: [32]u8 = @splat(0x11);
const other_id: [32]u8 = @splat(0x22);
const code_hash: [32]u8 = @splat(0x33);

/// A fake node: the frames it sends (unmasked, binary) and what the client wrote.
const FakeNode = struct {
    input: std.Io.Writer.Allocating,
    in: std.Io.Reader = undefined,
    out: std.Io.Writer.Allocating,

    fn init() FakeNode {
        return .{ .input = .init(testing.allocator), .out = .init(testing.allocator) };
    }

    fn deinit(n: *FakeNode) void {
        n.input.deinit();
        n.out.deinit();
    }

    /// Queues one message, in frames of at most `frame_len` bytes.
    fn send(n: *FakeNode, payload: []const u8, frame_len: usize) !void {
        const w = &n.input.writer;
        var i: usize = 0;
        while (true) {
            const part = payload[i..][0..@min(frame_len, payload.len - i)];
            const fin = i + part.len == payload.len;
            try w.writeByte(@as(u8, if (fin) 0x80 else 0) | @as(u8, if (i == 0) 2 else 0));
            if (part.len < 126) {
                try w.writeByte(@intCast(part.len));
            } else if (part.len <= 0xffff) {
                try w.writeByte(126);
                try w.writeInt(u16, @intCast(part.len), .big);
            } else {
                try w.writeByte(127);
                try w.writeInt(u64, part.len, .big);
            }
            try w.writeAll(part);
            i += part.len;
            if (fin) break;
        }
    }

    fn client(n: *FakeNode) freenet.client.Client {
        n.in = .fixed(n.input.written());
        var c: freenet.client.Client = .init(testing.allocator, testing.io, &n.in, &n.out.writer);
        c.fixed_mask = .{ 0, 0, 0, 0 }; // payloads go out as they are
        return c;
    }
};

const get_request = le32(1) ++ le32(2) ++ id ++ [_]u8{ 0, 0, 0 }; // ContractOp(Get { id, false, false, false })
const ok_contract = le32(0) ++ le32(0); // Ok(HostResponse::ContractResponse(..))
fn getResponse(comptime key_id: [32]u8, comptime state: []const u8) [8 + 4 + 64 + 1 + 8 + state.len]u8 {
    // GetResponse { key: ContractKey { id, code_hash }, contract: None, state }
    return ok_contract ++ le32(0) ++ key_id ++ code_hash ++ [_]u8{0} ++ vec(state);
}
/// Err(ClientError { kind: RequestError(ContractError(<v> ...)) })
const contract_error = le32(1) ++ le32(8) ++ le32(0);

test "client: get request bytes, and the state from a GetResponse" {
    var n: FakeNode = .init();
    defer n.deinit();
    try n.send(&getResponse(id, "the state"), 1000);
    var c = n.client();
    const state = (try c.get(testing.allocator, id)).?;
    defer testing.allocator.free(state);
    try testing.expectEqualStrings("the state", state);
    // FIN + binary, masked, 43 bytes; mask 0
    try testing.expectEqualSlices(u8, &([_]u8{ 0x82, 0x80 | 43, 0, 0, 0, 0 } ++ get_request), n.out.written());
}

test "client: the client masks its frames" {
    var n: FakeNode = .init();
    defer n.deinit();
    try n.send(&getResponse(id, "s"), 1000);
    var c = n.client();
    c.fixed_mask = .{ 0xff, 0, 0xff, 0 };
    const state = (try c.get(testing.allocator, id)).?;
    testing.allocator.free(state);
    var expected = get_request;
    for (&expected, 0..) |*b, i| b.* ^= c.fixed_mask.?[i % 4];
    try testing.expectEqualSlices(u8, &([_]u8{ 0x82, 0x80 | 43, 0xff, 0, 0xff, 0 } ++ expected), n.out.written());
}

test "client: get skips other replies, and decodes a contract container" {
    var n: FakeNode = .init();
    defer n.deinit();
    try n.send(&(ok_contract ++ le32(5) ++ other_id), 1000); // NotFound for another contract
    try n.send(&(le32(0) ++ le32(3)), 1000); // Ok(HostResponse::Ok)
    // GetResponse with Some(ContractContainer::Wasm(V1(WrappedContract { data, params, key })))
    try n.send(&(ok_contract ++ le32(0) ++ id ++ code_hash ++ [_]u8{1} ++
        le32(0) ++ le32(0) ++ vec("wasm") ++ code_hash ++ vec("params") ++ id ++ code_hash ++ vec("st")), 1000);
    var c = n.client();
    const state = (try c.get(testing.allocator, id)).?;
    defer testing.allocator.free(state);
    try testing.expectEqualStrings("st", state);
}

test "client: the ways a node says it doesn't have the contract" {
    const replies = [_][]const u8{
        &(ok_contract ++ le32(5) ++ id), // ContractResponse::NotFound { instance_id }
        &(contract_error ++ le32(6) ++ id), // MissingContract { key }
        &(contract_error ++ le32(0) ++ id ++ code_hash ++ vec("Contract state Not Found")), // Get { key, cause }
    };
    for (replies) |reply| {
        var n: FakeNode = .init();
        defer n.deinit();
        try n.send(reply, 1000);
        var c = n.client();
        try testing.expect(try c.get(testing.allocator, id) == null);
    }
}

test "client: other errors fail the request, and say why" {
    var n: FakeNode = .init();
    defer n.deinit();
    try n.send(&(contract_error ++ le32(0) ++ id ++ code_hash ++ vec("timed out")), 1000);
    try n.send(&(contract_error ++ le32(6) ++ other_id), 1000); // MissingContract, not ours
    try n.send(&(le32(1) ++ le32(6) ++ vec("boom")), 1000); // Unhandled { cause }
    var c = n.client();
    var b58: [64]u8 = undefined;
    const id_text = freenet.types.encodeBase58(&b58, &id);
    try testing.expectError(error.NodeError, c.get(testing.allocator, id));
    try testing.expect(std.mem.startsWith(u8, c.lastError(), "Get "));
    try testing.expect(std.mem.endsWith(u8, c.lastError(), ": timed out"));
    try testing.expectEqualStrings(id_text, c.lastError()[4 .. c.lastError().len - 11]);
    try testing.expectError(error.NodeError, c.get(testing.allocator, id));
    try testing.expect(std.mem.startsWith(u8, c.lastError(), "MissingContract "));
    try testing.expectError(error.NodeError, c.get(testing.allocator, id));
    try testing.expectEqualStrings("Unhandled: boom", c.lastError());
    try testing.expectError(error.ConnectionClosed, c.get(testing.allocator, id)); // no more input
}

test "client: a large state in fragments, and a streamed response" {
    const big = try testing.allocator.alloc(u8, 200_000);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i * 31);
    var res: std.Io.Writer.Allocating = .init(testing.allocator);
    defer res.deinit();
    try res.writer.writeAll(&(ok_contract ++ le32(0) ++ id ++ code_hash ++ [_]u8{0} ++ le64(200_000)));
    try res.writer.writeAll(big);
    const whole = res.written();

    var n: FakeNode = .init();
    defer n.deinit();
    try n.send(whole, 70_000); // fragments with 64-bit lengths, then a 16-bit one
    // StreamHeader { stream_id: 9, total_bytes, content: GetResponse { key, includes_contract: false } }
    try n.send(&(le32(0) ++ le32(5) ++ le32(9) ++ le64(200_085) ++ le32(0) ++ id ++ code_hash ++ [_]u8{0}), 1000);
    // StreamChunk { stream_id, index, total, data } x 3, out of order
    const cuts = [_]usize{ 0, 80_000, 160_000, whole.len };
    for ([_]u32{ 1, 0, 2 }) |i| {
        var chunk: std.Io.Writer.Allocating = .init(testing.allocator);
        defer chunk.deinit();
        const data = whole[cuts[i]..cuts[i + 1]];
        try chunk.writer.writeAll(&(le32(0) ++ le32(4) ++ le32(9)));
        try chunk.writer.writeInt(u32, i, .little);
        try chunk.writer.writeInt(u32, 3, .little);
        try chunk.writer.writeInt(u64, data.len, .little);
        try chunk.writer.writeAll(data);
        try n.send(chunk.written(), 1 << 20);
    }
    var c = n.client();
    for (0..2) |_| {
        const state = (try c.get(testing.allocator, id)).?;
        defer testing.allocator.free(state);
        try testing.expectEqualSlices(u8, big, state);
    }
}

test "client: update sends a Delta and returns the summary" {
    var n: FakeNode = .init();
    defer n.deinit();
    try n.send(&(ok_contract ++ le32(3) ++ id ++ code_hash ++ vec("sum")), 1000); // UpdateResponse { key, summary }
    var c = n.client();
    const summary = try c.update(testing.allocator, id, code_hash, "delta!");
    defer testing.allocator.free(summary);
    try testing.expectEqualStrings("sum", summary);
    // ContractOp(Update { key: ContractKey { id, code_hash }, data: UpdateData::Delta(bytes) })
    const request = le32(1) ++ le32(1) ++ id ++ code_hash ++ le32(1) ++ vec("delta!");
    try testing.expectEqualSlices(u8, &([_]u8{ 0x82, 0x80 | request.len, 0, 0, 0, 0 } ++ request), n.out.written());

    var n2: FakeNode = .init();
    defer n2.deinit();
    try n2.send(&(contract_error ++ le32(2) ++ id ++ code_hash ++ vec("invalid delta")), 1000);
    var c2 = n2.client();
    try testing.expectError(error.NodeError, c2.update(testing.allocator, id, code_hash, "x"));
    try testing.expect(std.mem.endsWith(u8, c2.lastError(), ": invalid delta"));
}

test "client: put sends the code, params and state; a PutResponse or an UpdateResponse counts" {
    const wasm = "\x00asm-code";
    const params = "pp";
    const put_id = freenet.types.contractInstanceId(wasm, params);
    const put_hash = freenet.types.codeHash(wasm);
    // ContractOp(Put { contract: Wasm(V1(WrappedContract { data: ContractCode { data, code_hash }, params, key })),
    //   state, related_contracts: empty, subscribe: false, blocking_subscribe: false }), as freenet.js `put`
    const request = le32(1) ++ le32(0) ++ le32(0) ++ le32(0) ++ vec(wasm) ++ put_hash ++ vec(params) ++ put_id ++ put_hash ++ vec("state") ++ [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 } ++ [_]u8{ 0, 0 };
    for ([_][]const u8{ &(ok_contract ++ le32(1) ++ put_id ++ put_hash), &(ok_contract ++ le32(3) ++ put_id ++ put_hash ++ vec("sum")) }) |reply| {
        var n: FakeNode = .init();
        defer n.deinit();
        try n.send(reply, 1000);
        var c = n.client();
        try c.put(testing.allocator, wasm, params, "state");
        // over 125 bytes: the 16-bit extended length
        try testing.expectEqualSlices(u8, &([_]u8{ 0x82, 0x80 | 126, 0, request.len, 0, 0, 0, 0 } ++ request), n.out.written());
    }
    var n2: FakeNode = .init();
    defer n2.deinit();
    try n2.send(&(contract_error ++ le32(1) ++ put_id ++ put_hash ++ vec("invalid state")), 1000);
    var c2 = n2.client();
    try testing.expectError(error.NodeError, c2.put(testing.allocator, wasm, params, "x"));
    try testing.expect(std.mem.endsWith(u8, c2.lastError(), ": invalid state"));
}

const dkey: freenet.types.DelegateKey = .{ .key = @splat(0x44), .code_hash = @splat(0x55) };
const ok_delegate = le32(0) ++ le32(1) ++ dkey.key ++ dkey.code_hash; // Ok(HostResponse::DelegateResponse { key, values })

test "client: a message to a delegate, its replies and the prompts the node didn't show" {
    var n: FakeNode = .init();
    defer n.deinit();
    try n.send(&(le32(0) ++ le32(3)), 1000); // Ok(HostResponse::Ok): not this request's answer
    try n.send(&(le32(0) ++ le32(1) ++ @as([32]u8, @splat(0x66)) ++ dkey.code_hash ++ le64(0)), 1000); // another delegate's
    // two replies and a RequestUserInput { request_id: 7, message, responses: ["Cancel", "Pay"] }
    try n.send(&(ok_delegate ++ le64(3) ++ appMsg("one") ++ appMsg("two") ++
        le32(1) ++ le32(7) ++ vec("Pay 5?") ++ le64(2) ++ vec("Cancel") ++ vec("Pay")), 1000);
    var c = n.client();
    const reply = try c.sendToDelegate(testing.allocator, dkey, "pp", "hello");
    defer reply.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), reply.payloads.len);
    try testing.expectEqualStrings("one", reply.payloads[0]);
    try testing.expectEqualStrings("two", reply.payloads[1]);
    try testing.expectEqual(@as(usize, 1), reply.prompts.len);
    try testing.expectEqual(@as(u32, 7), reply.prompts[0].request_id);
    try testing.expectEqualStrings("Pay 5?", reply.prompts[0].message);
    try testing.expectEqualStrings("Pay", reply.prompts[0].labels[1]);
    // DelegateOp(ApplicationMessages { key: DelegateKey { key, code_hash }, params, inbound: [ApplicationMessage] }), as freenet.js
    const request = le32(0) ++ le32(0) ++ dkey.key ++ dkey.code_hash ++ vec("pp") ++ le64(1) ++ appMsg("hello");
    try testing.expectEqualSlices(u8, &([_]u8{ 0x82, 0x80 | request.len, 0, 0, 0, 0 } ++ request), n.out.written());
}

test "client: an answer to a delegate's prompt" {
    var n: FakeNode = .init();
    defer n.deinit();
    try n.send(&(ok_delegate ++ le64(1) ++ appMsg("paid")), 1000);
    var c = n.client();
    const reply = try c.respondToDelegate(testing.allocator, dkey, "", 7, "Pay");
    defer reply.deinit(testing.allocator);
    try testing.expectEqualStrings("paid", reply.payloads[0]);
    // inbound: UserResponse(UserInputResponse { request_id, response, context })
    const request = le32(0) ++ le32(0) ++ dkey.key ++ dkey.code_hash ++ vec("") ++ le64(1) ++ le32(1) ++ le32(7) ++ vec("Pay") ++ vec("");
    try testing.expectEqualSlices(u8, &([_]u8{ 0x82, 0x80 | request.len, 0, 0, 0, 0 } ++ request), n.out.written());
}

test "client: a delegate's failure says why" {
    var n: FakeNode = .init();
    defer n.deinit();
    // Err(RequestError(DelegateError(ExecutionError(cause))))
    try n.send(&(le32(1) ++ le32(8) ++ le32(1) ++ le32(1) ++ vec("this delegate only answers its own web app")), 1000);
    // Err(RequestError(DelegateError(Missing(key))))
    try n.send(&(le32(1) ++ le32(8) ++ le32(1) ++ le32(2) ++ dkey.key ++ dkey.code_hash), 1000);
    var c = n.client();
    try testing.expectError(error.NodeError, c.sendToDelegate(testing.allocator, dkey, "", "whoami"));
    try testing.expectEqualStrings("DelegateExecutionError: this delegate only answers its own web app", c.lastError());
    try testing.expectError(error.NodeError, c.sendToDelegate(testing.allocator, dkey, "", "whoami"));
    try testing.expect(std.mem.startsWith(u8, c.lastError(), "MissingDelegate "));
}

test "client: registering a delegate sends its code and key; Ok counts" {
    const wasm = "\x00asm-delegate";
    const params = "app";
    const k = freenet.types.delegateKey(wasm, params);
    var n: FakeNode = .init();
    defer n.deinit();
    try n.send(&(le32(0) ++ le32(3)), 1000); // Ok(HostResponse::Ok)
    var c = n.client();
    try c.registerDelegate(testing.allocator, wasm, params);
    // DelegateOp(RegisterDelegate { delegate: Wasm(V1(Delegate { parameters, data: { data, code_hash }, key })), cipher, nonce })
    const request = le32(0) ++ le32(1) ++ le32(0) ++ le32(0) ++ vec(params) ++ vec(wasm) ++ k.code_hash ++ k.key ++ k.code_hash ++ @as([56]u8, @splat(0));
    try testing.expectEqualSlices(u8, &([_]u8{ 0x82, 0x80 | 126, 0, request.len, 0, 0, 0, 0 } ++ request), n.out.written());
}

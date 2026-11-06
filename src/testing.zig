//! Unit-test delegates and contracts natively, without a Freenet node.
//!
//! The harness plays the node's part exactly as freenet-core does: it fills
//! buffers via `__frnt__initiate_buffer` and `last_write`, calls the generated
//! entry points, and decodes the result structs. Host functions (random,
//! log, secrets, context) go to an in-memory stand-in you can control.
//!
//! ```zig
//! test "echo" {
//!     freenet.testing.reset();
//!     const replies = try freenet.testing.ask(@This(), "hello", .{});
//!     try std.testing.expectEqualStrings("hello", replies[0]);
//! }
//! ```

const std = @import("std");
const abi = @import("abi.zig");
const bincode = @import("bincode.zig");
const host = @import("host.zig");
const delegate = @import("delegate.zig");
const contract = @import("contract.zig");

const gpa = abi.allocator;

// ---- fake host ----------------------------------------------------------------

/// Fresh fake node: deterministic randomness (fixed seed), no secrets, empty
/// context, instance id set. Call at the start of each test.
pub fn reset() void {
    host.native.reset();
    last_prompts = &.{};
    last_requests = &.{};
}

/// Replace the random source (for example to force edge cases).
pub fn setRandom(f: *const fn ([]u8) void) void {
    host.native.rand_fn = f;
}

/// Capture `freenet.log` output.
pub fn setLog(f: *const fn ([]const u8) void) void {
    host.native.log_fn = f;
}

/// Simulate a node that never called `__frnt_set_id` (random then fails).
pub fn clearInstanceId() void {
    host.setInstanceId(-1);
}

/// Read a secret from the fake node's store.
pub fn secret(key: []const u8) ?[]const u8 {
    return host.native.secrets.get(key);
}

/// Seed the fake node's secret store.
pub fn putSecret(key: []const u8, value: []const u8) !void {
    if (!host.secretSet(key, value)) return error.OutOfMemory;
}

/// The delegate context as the last call left it (`d.setContext`).
pub fn context() []const u8 {
    return host.native.context.items;
}

// ---- delegates ---------------------------------------------------------------

pub const SendOptions = struct {
    origin: delegate.Origin = .{ .web_app = @splat(7) },
    parameters: []const u8 = "",
};

/// What a delegate call returned: its reply payloads, or the error message
/// it failed with. Prompts it asked for are in `prompts()`.
pub const Result = union(enum) {
    ok: []const []const u8,
    err: []const u8,
};

var last_prompts: []const delegate.UserInputRequest = &.{};
var last_requests: []const delegate.ContractRequest = &.{};

/// The contract state requests (`d.getContract`) the last successful delegate
/// call made, in order; empty after a failed call. Answer one with
/// `contractState`.
pub fn contractRequests() []const delegate.ContractRequest {
    return last_requests;
}

/// Answer a contract request the way the node does: a `GetContractResponse`
/// with the request's id and context and `state` (null: not found).
pub fn contractState(comptime Impl: type, request: delegate.ContractRequest, state: ?[]const u8, opts: SendOptions) !Result {
    return send(Impl, .{ .contract_state = .{ .contract_id = request.contract_id, .state = state, .context = request.context } }, opts);
}

/// The prompts (`d.requestUserInput`) the last successful delegate call asked
/// for, in order; empty after a failed call. Answer one with `respond`.
pub fn prompts() []const delegate.UserInputRequest {
    return last_prompts;
}

/// Answer a prompt the way the node does: a `UserResponse` with `request_id`
/// and the chosen response's bytes (`""` for refused or timed out).
pub fn respond(comptime Impl: type, request_id: u32, response: []const u8, opts: SendOptions) !Result {
    return send(Impl, .{ .user_response = .{ .request_id = request_id, .response = response } }, opts);
}

/// Send one inbound message to delegate `Impl`.
pub fn send(comptime Impl: type, msg: delegate.Inbound, opts: SendOptions) !Result {
    var w: bincode.Writer = .init(gpa);
    try encodeInbound(&w, msg);
    var o: bincode.Writer = .init(gpa);
    try encodeOrigin(&o, opts.origin);
    return decodeResult(raw.callDelegate(Impl, opts.parameters, o.items(), w.items()));
}

/// Send an `ApplicationMessage` with `payload` and return the payloads of
/// the delegate's replies. Fails with `error.DelegateReturnedError` (after
/// printing the message) if the delegate failed.
pub fn ask(comptime Impl: type, payload: []const u8, opts: SendOptions) ![]const []const u8 {
    switch (try send(Impl, .{ .application = .{ .payload = payload } }, opts)) {
        .err => |m| {
            std.debug.print("delegate failed: {s}\n", .{m});
            return error.DelegateReturnedError;
        },
        .ok => |replies| return replies,
    }
}

fn encodeOrigin(w: *bincode.Writer, origin: delegate.Origin) !void {
    switch (origin) {
        .none, .unknown => {},
        .web_app => |id| {
            try w.tag(0);
            try w.raw(&id);
        },
        .delegate => |k| {
            try w.tag(1);
            try w.raw(&k.key);
            try w.raw(&k.code_hash);
        },
    }
}

fn encodeInbound(w: *bincode.Writer, msg: delegate.Inbound) !void {
    switch (msg) {
        .application => |app| {
            try w.tag(0);
            try w.bytes(app.payload);
            try w.bytes(app.context);
            try w.boolean(app.processed);
        },
        .user_response => |u| {
            try w.tag(1);
            try w.int(u32, u.request_id);
            try w.bytes(u.response);
            try w.bytes(u.context);
        },
        .contract_state => |c| {
            try w.tag(2);
            try w.raw(&c.contract_id);
            try w.optionalBytes(c.state);
            try w.bytes(c.context);
        },
        .unsupported => |u| try w.raw(u.raw),
    }
}

/// Decodes `Result<Vec<OutboundDelegateMsg>, DelegateError>` as the library
/// writes it (`ApplicationMessage` replies, `RequestUserInput` prompts and
/// `GetContractRequest`s).
fn decodeResult(bytes: []const u8) !Result {
    var r: bincode.Reader = .init(bytes);
    last_prompts = &.{};
    last_requests = &.{};
    switch (try r.tag()) {
        0 => {
            var replies: std.ArrayList([]const u8) = .empty;
            var asked: std.ArrayList(delegate.UserInputRequest) = .empty;
            var requested: std.ArrayList(delegate.ContractRequest) = .empty;
            for (0..@as(usize, @intCast(try r.int(u64)))) |_| switch (try r.tag()) {
                0 => {
                    try replies.append(gpa, try r.bytes());
                    _ = try r.bytes(); // context
                    _ = try r.boolean(); // processed
                },
                1 => {
                    const id = try r.int(u32);
                    const message = try r.bytes();
                    const labels = try gpa.alloc([]const u8, @intCast(try r.int(u64)));
                    for (labels) |*l| l.* = try r.bytes();
                    try asked.append(gpa, .{ .request_id = id, .message = message, .responses = labels });
                },
                3 => {
                    const id = try r.array(32);
                    const ctx = try r.bytes();
                    if (try r.boolean()) return error.ProcessedContractRequest; // the node would skip it
                    try requested.append(gpa, .{ .contract_id = id, .context = ctx });
                },
                else => return error.UnsupportedOutbound,
            };
            if (r.remaining() != 0) return error.TrailingBytes;
            last_prompts = asked.items;
            last_requests = requested.items;
            return .{ .ok = replies.items };
        },
        1 => {
            _ = try r.tag(); // DelegateError variant (Deser = 0, Other = 1)
            return .{ .err = try r.bytes() };
        },
        else => return error.BadResultTag,
    }
}

// ---- contracts ---------------------------------------------------------------

/// A `ContractError` as the node would receive it.
pub const ContractError = union(enum) {
    deser: []const u8,
    invalid_update,
    invalid_update_with_info: []const u8,
    invalid_state,
    invalid_delta,
    other: []const u8,
};

pub fn Outcome(comptime T: type) type {
    return union(enum) { ok: T, err: ContractError };
}

pub fn validate(comptime Impl: type, parameters: []const u8, state: []const u8, related: contract.RelatedContracts) !Outcome(contract.ValidateResult) {
    var w: bincode.Writer = .init(gpa);
    try w.int(u64, related.entries.len);
    for (related.entries) |e| {
        try w.raw(&e.id);
        try w.optionalBytes(e.state);
    }
    var r: bincode.Reader = .init(try raw.callContract(Impl, .validate_state, parameters, state, w.items()));
    if (try r.tag() == 1) return .{ .err = try decodeError(&r) };
    return .{ .ok = switch (try r.tag()) {
        0 => .valid,
        1 => .invalid,
        2 => blk: {
            const ids = try gpa.alloc([32]u8, @intCast(try r.int(u64)));
            for (ids) |*id| id.* = try r.array(32);
            break :blk .{ .request_related = ids };
        },
        else => return error.BadValidateResult,
    } };
}

pub fn update(comptime Impl: type, parameters: []const u8, state: []const u8, updates: []const contract.Update) !Outcome(contract.UpdateResult) {
    var w: bincode.Writer = .init(gpa);
    try encodeUpdates(&w, updates);
    var r: bincode.Reader = .init(try raw.callContract(Impl, .update_state, parameters, state, w.items()));
    if (try r.tag() == 1) return .{ .err = try decodeError(&r) };
    const new_state = try r.optionalBytes();
    const reqs = try gpa.alloc(contract.RelatedRequest, @intCast(try r.int(u64)));
    for (reqs) |*req| req.* = .{ .id = try r.array(32), .mode = @fromBackingInt(@intCast(try r.tag())) };
    if (new_state) |s| return .{ .ok = .{ .new_state = s } };
    return .{ .ok = .{ .requires = reqs } };
}

pub fn summarize(comptime Impl: type, parameters: []const u8, state: []const u8) !Outcome([]const u8) {
    return bytesOutcome(try raw.callContract(Impl, .summarize_state, parameters, state, null));
}

pub fn delta(comptime Impl: type, parameters: []const u8, state: []const u8, summary: []const u8) !Outcome([]const u8) {
    return bytesOutcome(try raw.callContract(Impl, .state_delta, parameters, state, summary));
}

fn bytesOutcome(bytes: []const u8) !Outcome([]const u8) {
    var r: bincode.Reader = .init(bytes);
    if (try r.tag() == 1) return .{ .err = try decodeError(&r) };
    return .{ .ok = try r.bytes() };
}

fn decodeError(r: *bincode.Reader) !ContractError {
    return switch (try r.tag()) {
        0 => .{ .deser = try r.bytes() },
        1 => .invalid_update,
        2 => .{ .invalid_update_with_info = try r.bytes() },
        3 => .invalid_state,
        4 => .invalid_delta,
        5 => .{ .other = try r.bytes() },
        else => error.UnknownContractError,
    };
}

/// `Vec<UpdateData>`
fn encodeUpdates(w: *bincode.Writer, updates: []const contract.Update) !void {
    try w.int(u64, updates.len);
    for (updates) |u| switch (u) {
        .state => |s| {
            try w.tag(0);
            try w.bytes(s);
        },
        .delta => |d| {
            try w.tag(1);
            try w.bytes(d);
        },
        .state_and_delta => |x| {
            try w.tag(2);
            try w.bytes(x.state);
            try w.bytes(x.delta);
        },
        .related_state => |x| {
            try w.tag(3);
            try w.raw(&x.related_to);
            try w.bytes(x.state);
        },
        .related_delta => |x| {
            try w.tag(4);
            try w.raw(&x.related_to);
            try w.bytes(x.delta);
        },
        .related_state_and_delta => |x| {
            try w.tag(5);
            try w.raw(&x.related_to);
            try w.bytes(x.state);
            try w.bytes(x.delta);
        },
    };
}

// ---- raw access (for wire-format tests) --------------------------------------

/// Call entry points with pre-encoded input bytes and get the raw result
/// bytes back, exactly as the node would see them.
pub const raw = struct {
    fn fill(bytes: []const u8) i64 {
        const ptr = abi.initiateBuffer(@intCast(bytes.len));
        const b = abi.i64ToPtr(*abi.BufferBuilder, ptr);
        std.debug.assert(@as(usize, @intCast(ptr)) % 8 == 0 and b.capacity >= bytes.len);
        @memcpy(abi.i64ToPtr([*]u8, b.start)[0..bytes.len], bytes);
        abi.i64ToPtr(*u32, b.last_write).* = @intCast(bytes.len);
        return ptr;
    }

    pub fn callDelegate(comptime Impl: type, parameters: []const u8, origin: []const u8, inbound: []const u8) []const u8 {
        const res = delegate.Exports(Impl).process(fill(parameters), fill(origin), fill(inbound));
        const r = abi.i64ToPtr(*const abi.DelegateResult, res);
        return abi.i64ToPtr([*]const u8, r.ptr)[0..r.size];
    }

    /// `third` is related contracts (validate), updates (update) or summary
    /// (delta); null for summarize.
    pub fn callContract(comptime Impl: type, kind: abi.ResultKind, parameters: []const u8, state: []const u8, third: ?[]const u8) ![]const u8 {
        const E = contract.Exports(Impl);
        const p = fill(parameters);
        const s = fill(state);
        const res = switch (kind) {
            .validate_state => E.validate_state(p, s, fill(third.?)),
            .update_state => E.update_state(p, s, fill(third.?)),
            .summarize_state => E.summarize_state(p, s),
            .state_delta => E.get_state_delta(p, s, fill(third.?)),
        };
        const r = abi.i64ToPtr(*const abi.ContractResult, res);
        if (r.kind != @backingInt(kind)) return error.WrongResultKind;
        return abi.i64ToPtr([*]const u8, r.ptr)[0..r.size];
    }
};

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

// ---- delegates ---------------------------------------------------------------

pub const SendOptions = struct {
    origin: delegate.Origin = .{ .web_app = @splat(7) },
    parameters: []const u8 = "",
};

/// Send one inbound message to delegate `Impl`; returns what it emitted or
/// the error message it failed with.
pub fn send(comptime Impl: type, msg: delegate.Inbound, opts: SendOptions) !delegate.Result {
    var w: bincode.Writer = .init(gpa);
    try delegate.encodeInbound(&w, msg);
    var o: bincode.Writer = .init(gpa);
    try delegate.encodeOrigin(&o, opts.origin);
    return delegate.decodeResult(gpa, raw.callDelegate(Impl, opts.parameters, o.items(), w.items()));
}

/// Send an `ApplicationMessage` with `payload` and return the payloads of
/// the delegate's replies. Fails with `error.DelegateReturnedError` (after
/// printing the message) if the delegate failed.
pub fn ask(comptime Impl: type, payload: []const u8, opts: SendOptions) ![]const []const u8 {
    const res = try send(Impl, .{ .application = .{ .payload = payload } }, opts);
    switch (res) {
        .err => |m| {
            std.debug.print("delegate failed: {s}\n", .{m});
            return error.DelegateReturnedError;
        },
        .ok => |out| {
            var replies: std.ArrayList([]const u8) = .empty;
            for (out) |m| switch (m) {
                .application => |p| try replies.append(gpa, p),
                .context_updated => {},
            };
            return replies.items;
        },
    }
}

// ---- contracts ---------------------------------------------------------------

pub fn Outcome(comptime T: type) type {
    return union(enum) { ok: T, err: contract.ContractError };
}

pub fn validate(comptime Impl: type, parameters: []const u8, state: []const u8, related: contract.RelatedContracts) !Outcome(contract.ValidateResult) {
    var w: bincode.Writer = .init(gpa);
    try related.encode(&w);
    var r: bincode.Reader = .init(try raw.callContract(Impl, .validate_state, parameters, state, w.items()));
    if (try r.tag() == 1) return .{ .err = try contract.decodeError(&r) };
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
    try contract.encodeUpdates(&w, updates);
    var r: bincode.Reader = .init(try raw.callContract(Impl, .update_state, parameters, state, w.items()));
    if (try r.tag() == 1) return .{ .err = try contract.decodeError(&r) };
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
    if (try r.tag() == 1) return .{ .err = try contract.decodeError(&r) };
    return .{ .ok = try r.bytes() };
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
            .validate_delta => unreachable,
        };
        const r = abi.i64ToPtr(*const abi.ContractResult, res);
        if (r.kind != @backingInt(kind)) return error.WrongResultKind;
        return abi.i64ToPtr([*]const u8, r.ptr)[0..r.size];
    }
};

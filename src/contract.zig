//! Writing a contract: Wasm code that defines which states are valid and how
//! updates merge. Every peer that stores the contract runs it, so it must be
//! deterministic, and merging must give the same result in any order.
//!
//! ```zig
//! const freenet = @import("freenet");
//!
//! comptime {
//!     freenet.exportContract(@This());
//! }
//!
//! pub fn validateState(c: *freenet.Contract, state: []const u8, related: freenet.RelatedContracts) !freenet.ValidateResult { ... }
//! pub fn updateState(c: *freenet.Contract, state: []const u8, updates: *freenet.Updates) !freenet.UpdateResult { ... }
//! pub fn summarizeState(c: *freenet.Contract, state: []const u8) ![]const u8 { ... }
//! pub fn getStateDelta(c: *freenet.Contract, state: []const u8, summary: []const u8) ![]const u8 { ... }
//! ```
//!
//! Wire types follow `freenet_stdlib::contract_interface`.

const std = @import("std");
const abi = @import("abi.zig");
const bincode = @import("bincode.zig");
const host = @import("host.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Id = types.ContractInstanceId;

/// Handed to every contract function.
pub const Contract = struct {
    /// Allocator for this call; freed by the node when the call ends.
    allocator: Allocator,
    /// The contract's parameters (part of its key).
    parameters: []const u8,

    failure: ?[]const u8 = null,

    /// Fail with a reason. In `updateState` the node receives
    /// `ContractError::InvalidUpdateWithInfo { reason }`, elsewhere
    /// `ContractError::Other(reason)`. Use as `return c.fail("...")`.
    pub fn fail(c: *Contract, reason: []const u8) error{ContractFailed} {
        c.failure = reason;
        return error.ContractFailed;
    }
};

pub const ValidateResult = union(enum) {
    valid,
    invalid,
    /// Ask the node to fetch these contracts and call `validateState` again
    /// with their states in `related`.
    request_related: []const Id,
};

pub const RelatedMode = enum(u32) {
    /// Fetch the state once.
    state_once = 0,
    /// Fetch the state, then keep receiving its updates.
    state_then_subscribe = 1,
};

pub const RelatedRequest = struct {
    id: Id,
    mode: RelatedMode = .state_once,
};

pub const UpdateResult = union(enum) {
    /// The merged state.
    new_state: []const u8,
    /// Can't merge yet: fetch these contracts first (must not be empty).
    requires: []const RelatedRequest,
};

/// One `UpdateData` entry.
pub const Update = union(enum) {
    state: []const u8,
    delta: []const u8,
    state_and_delta: struct { state: []const u8, delta: []const u8 },
    related_state: struct { related_to: Id, state: []const u8 },
    related_delta: struct { related_to: Id, delta: []const u8 },
    related_state_and_delta: struct { related_to: Id, state: []const u8, delta: []const u8 },
};

/// The updates passed to `updateState`, decoded lazily.
pub const Updates = struct {
    reader: bincode.Reader,
    left: u64,

    pub fn init(bytes: []const u8) bincode.Error!Updates {
        var r: bincode.Reader = .init(bytes);
        const n = if (bytes.len == 0) 0 else try r.int(u64);
        return .{ .reader = r, .left = n };
    }

    pub fn next(u: *Updates) (bincode.Error || error{UnknownUpdateKind})!?Update {
        if (u.left == 0) return null;
        u.left -= 1;
        const r = &u.reader;
        return switch (try r.tag()) {
            0 => .{ .state = try r.bytes() },
            1 => .{ .delta = try r.bytes() },
            2 => .{ .state_and_delta = .{ .state = try r.bytes(), .delta = try r.bytes() } },
            3 => .{ .related_state = .{ .related_to = try r.array(32), .state = try r.bytes() } },
            4 => .{ .related_delta = .{ .related_to = try r.array(32), .delta = try r.bytes() } },
            5 => .{ .related_state_and_delta = .{ .related_to = try r.array(32), .state = try r.bytes(), .delta = try r.bytes() } },
            else => error.UnknownUpdateKind,
        };
    }
};

/// States of related contracts the node fetched for `validateState`
/// (`RelatedContracts`: a map from id to optional state).
pub const RelatedContracts = struct {
    pub const Entry = struct { id: Id, state: ?[]const u8 };
    entries: []const Entry = &.{},

    pub fn get(rc: RelatedContracts, id: Id) ?Entry {
        for (rc.entries) |e| if (std.mem.eql(u8, &e.id, &id)) return e;
        return null;
    }

    pub fn decode(gpa: Allocator, bytes: []const u8) !RelatedContracts {
        if (bytes.len == 0) return .{};
        var r: bincode.Reader = .init(bytes);
        const n = try r.int(u64);
        if (n > r.remaining()) return error.EndOfStream;
        const entries = try gpa.alloc(Entry, @intCast(n));
        for (entries) |*e| e.* = .{ .id = try r.array(32), .state = try r.optionalBytes() };
        return .{ .entries = entries };
    }
};

/// Exports the contract ABI for `Impl` (see the module docs for the four
/// functions it must declare). Call it from a `comptime` block in your root
/// file. It does nothing in native builds; tests use `freenet.testing`.
pub fn exportContract(comptime Impl: type) void {
    inline for (.{ "validateState", "updateState", "summarizeState", "getStateDelta" }) |name| {
        if (!@hasDecl(Impl, name)) @compileError("contract " ++ @typeName(Impl) ++ " must declare `pub fn " ++ name ++ "`");
    }
    if (!abi.is_wasm) return;
    const E = Exports(Impl);
    @export(&E.validate_state, .{ .name = "validate_state" });
    @export(&E.update_state, .{ .name = "update_state" });
    @export(&E.summarize_state, .{ .name = "summarize_state" });
    @export(&E.get_state_delta, .{ .name = "get_state_delta" });
    @export(&abi.initiateBuffer, .{ .name = "__frnt__initiate_buffer" });
    @export(&host.setInstanceId, .{ .name = "__frnt_set_id" });
}

/// The generated entry points. Exposed for `freenet.testing`.
pub fn Exports(comptime Impl: type) type {
    return struct {
        pub fn validate_state(parameters: i64, state: i64, related: i64) callconv(.c) i64 {
            var c = newContract(parameters);
            var w: bincode.Writer = .init(abi.allocator);
            const done: anyerror!void = blk: {
                const rel = RelatedContracts.decode(abi.allocator, abi.input(related)) catch |e| break :blk e;
                const res = Impl.validateState(&c, abi.input(state), rel) catch |e| break :blk e;
                encodeValidate(&w, res) catch @trap();
                break :blk {};
            };
            done catch |err| encodeError(&w, &c, err, false);
            return abi.contractResult(.validate_state, w.items());
        }

        pub fn update_state(parameters: i64, state: i64, data: i64) callconv(.c) i64 {
            var c = newContract(parameters);
            var w: bincode.Writer = .init(abi.allocator);
            const done: anyerror!void = blk: {
                var updates = Updates.init(abi.input(data)) catch |e| break :blk e;
                const res = Impl.updateState(&c, abi.input(state), &updates) catch |e| break :blk e;
                encodeUpdateResult(&w, res) catch |e| break :blk e;
                break :blk {};
            };
            done catch |err| encodeError(&w, &c, err, true);
            return abi.contractResult(.update_state, w.items());
        }

        pub fn summarize_state(parameters: i64, state: i64) callconv(.c) i64 {
            var c = newContract(parameters);
            var w: bincode.Writer = .init(abi.allocator);
            if (Impl.summarizeState(&c, abi.input(state))) |summary| {
                okBytes(&w, summary);
            } else |err| encodeError(&w, &c, err, false);
            return abi.contractResult(.summarize_state, w.items());
        }

        pub fn get_state_delta(parameters: i64, state: i64, summary: i64) callconv(.c) i64 {
            var c = newContract(parameters);
            var w: bincode.Writer = .init(abi.allocator);
            if (Impl.getStateDelta(&c, abi.input(state), abi.input(summary))) |delta| {
                okBytes(&w, delta);
            } else |err| encodeError(&w, &c, err, false);
            return abi.contractResult(.state_delta, w.items());
        }
    };
}

fn newContract(parameters: i64) Contract {
    return .{ .allocator = abi.allocator, .parameters = abi.input(parameters) };
}

fn okBytes(w: *bincode.Writer, data: []const u8) void {
    w.tag(0) catch @trap();
    w.bytes(data) catch @trap();
}

pub fn encodeValidate(w: *bincode.Writer, res: ValidateResult) Allocator.Error!void {
    try w.tag(0); // Ok
    switch (res) {
        .valid => try w.tag(0),
        .invalid => try w.tag(1),
        .request_related => |ids| {
            try w.tag(2);
            try w.int(u64, ids.len);
            for (ids) |id| try w.raw(&id);
        },
    }
}

pub fn encodeUpdateResult(w: *bincode.Writer, res: UpdateResult) (Allocator.Error || error{EmptyRequires})!void {
    try w.tag(0); // Ok(UpdateModification { new_state, related })
    switch (res) {
        .new_state => |s| {
            try w.optionalBytes(s);
            try w.int(u64, 0);
        },
        .requires => |reqs| {
            if (reqs.len == 0) return error.EmptyRequires;
            try w.int(u8, 0); // new_state: None
            try w.int(u64, reqs.len);
            for (reqs) |req| {
                try w.raw(&req.id);
                try w.tag(@backingInt(req.mode));
            }
        },
    }
}

/// `Err(ContractError)`. Mapping:
/// * `c.fail(reason)` -> `InvalidUpdateWithInfo { reason }` (update) / `Other(reason)`
/// * `error.InvalidUpdate`, `error.InvalidState`, `error.InvalidDelta` -> the same-named variants
/// * malformed input (`error.EndOfStream`, ...) -> `Deser(name)`
/// * any other error -> `Other(name)`
fn encodeError(w: *bincode.Writer, c: *const Contract, err: anyerror, in_update: bool) void {
    w.list.clearRetainingCapacity();
    encodeErrorInner(w, c, err, in_update) catch @trap();
}

fn encodeErrorInner(w: *bincode.Writer, c: *const Contract, err: anyerror, in_update: bool) Allocator.Error!void {
    try w.tag(1); // Err
    if (err == error.ContractFailed) {
        try w.tag(if (in_update) 2 else 5);
        try w.bytes(c.failure orelse "ContractFailed");
        return;
    }
    switch (err) {
        error.InvalidUpdate => try w.tag(1),
        error.InvalidState => try w.tag(3),
        error.InvalidDelta => try w.tag(4),
        error.EndOfStream, error.InvalidBool, error.InvalidOption, error.UnknownUpdateKind => {
            try w.tag(0);
            try w.bytes(@errorName(err));
        },
        else => {
            try w.tag(5);
            try w.bytes(@errorName(err));
        },
    }
}

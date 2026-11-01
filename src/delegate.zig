//! Writing a delegate: a Wasm module that runs on the user's own node, keeps
//! private state, and answers messages from web apps.
//!
//! ```zig
//! const freenet = @import("freenet");
//!
//! comptime {
//!     freenet.exportDelegate(@This());
//! }
//!
//! pub fn handle(d: *freenet.Delegate, msg: freenet.Inbound) !void {
//!     switch (msg) {
//!         .application => |app| try d.reply(app.payload), // echo
//!         .unsupported => {},
//!     }
//! }
//! ```
//!
//! Wire types follow `freenet_stdlib::delegate_interface`.

const std = @import("std");
const abi = @import("abi.zig");
const bincode = @import("bincode.zig");
const host = @import("host.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

/// Who sent the message (attested by the node, so it can be trusted).
pub const Origin = union(enum) {
    /// No origin given (for example lifecycle events).
    none,
    /// A web app, identified by the contract instance id that serves it.
    web_app: types.ContractInstanceId,
    /// Another delegate.
    delegate: types.DelegateKey,
    /// A variant this library doesn't know yet (index given).
    unknown: u32,
};

/// `ApplicationMessage`: an app-defined payload, usually from a web app.
pub const ApplicationMessage = struct {
    payload: []const u8,
    context: []const u8 = "",
    processed: bool = false,
};

/// An inbound message (`InboundDelegateMsg`).
pub const Inbound = union(enum) {
    application: ApplicationMessage,
    /// Any other variant (contract responses, notifications, lifecycle
    /// events, ...). Not decoded by this library yet; `raw` is the whole
    /// bincode message, `tag` its variant index.
    unsupported: struct { tag: u32, raw: []const u8 },
};

/// An outbound message (`OutboundDelegateMsg`) the delegate emits.
pub const Outbound = union(enum) {
    /// Sent back to the app (`ApplicationMessage { processed: true }`).
    application: []const u8,
    /// Replaces the delegate context (`ContextUpdated`).
    context_updated: []const u8,
};

/// Handed to your `handle` function for each message.
pub const Delegate = struct {
    /// Allocator for this call. Everything is freed by the node when the call
    /// ends, so you never need to free.
    allocator: Allocator,
    /// The delegate's parameters (raw bytes; empty for most delegates).
    parameters: []const u8,
    /// Who sent the message.
    origin: Origin,

    outbox: std.ArrayList(Outbound) = .empty,
    failure: ?[]const u8 = null,

    /// Reply to the app with `payload`.
    pub fn reply(d: *Delegate, payload: []const u8) Allocator.Error!void {
        try d.outbox.append(d.allocator, .{ .application = payload });
    }

    /// Reply with formatted text.
    pub fn replyFmt(d: *Delegate, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try d.reply(try d.allocator.print(fmt, args));
    }

    /// Emit `ContextUpdated`, replacing the per-batch delegate context.
    pub fn setContext(d: *Delegate, data: []const u8) Allocator.Error!void {
        try d.outbox.append(d.allocator, .{ .context_updated = data });
    }

    /// Fail the call with a message the app receives as
    /// `DelegateError::Other(message)`. Use as `return d.fail("...")`.
    pub fn fail(d: *Delegate, message: []const u8) error{DelegateFailed} {
        d.failure = message;
        return error.DelegateFailed;
    }

    /// Read the delegate context (scratch state within one message batch).
    pub fn context(d: *Delegate) Allocator.Error![]const u8 {
        return host.contextRead(d.allocator);
    }

    /// Persistent, encrypted, per-delegate key/value storage on the user's node.
    pub fn secrets(d: *Delegate) Secrets {
        return .{ .allocator = d.allocator };
    }
};

pub const Secrets = struct {
    allocator: Allocator,

    pub fn get(s: Secrets, key: []const u8) Allocator.Error!?[]const u8 {
        return host.secretGet(s.allocator, key);
    }
    pub fn set(s: Secrets, key: []const u8, value: []const u8) error{SecretWriteFailed}!void {
        _ = s;
        if (!host.secretSet(key, value)) return error.SecretWriteFailed;
    }
    pub fn has(s: Secrets, key: []const u8) bool {
        _ = s;
        return host.secretHas(key);
    }
    /// Returns whether a secret was removed.
    pub fn remove(s: Secrets, key: []const u8) bool {
        _ = s;
        return host.secretRemove(key);
    }
    /// Keys starting with `prefix` (empty prefix: all keys).
    pub fn list(s: Secrets, prefix: []const u8) Allocator.Error![]const []const u8 {
        return host.secretList(s.allocator, prefix);
    }
};

/// Exports the delegate ABI (`process`, `__frnt__initiate_buffer`,
/// `__frnt_set_id`) for `Impl`, which must declare
/// `pub fn handle(d: *Delegate, msg: Inbound) !void`.
///
/// Call it from a `comptime` block in your root file. It does nothing in
/// native builds; tests drive `Impl` through `freenet.testing` instead.
pub fn exportDelegate(comptime Impl: type) void {
    if (!@hasDecl(Impl, "handle"))
        @compileError("delegate " ++ @typeName(Impl) ++ " must declare `pub fn handle(d: *freenet.Delegate, msg: freenet.Inbound) !void`");
    if (!abi.is_wasm) return;
    @export(&Exports(Impl).process, .{ .name = "process" });
    @export(&abi.initiateBuffer, .{ .name = "__frnt__initiate_buffer" });
    @export(&host.setInstanceId, .{ .name = "__frnt_set_id" });
}

/// The generated entry point. Exposed for `freenet.testing`.
pub fn Exports(comptime Impl: type) type {
    return struct {
        pub fn process(parameters: i64, origin: i64, inbound: i64) callconv(.c) i64 {
            return abi.delegateResult(run(abi.input(parameters), abi.input(origin), abi.input(inbound)));
        }

        fn run(parameters: []const u8, origin: []const u8, inbound: []const u8) []const u8 {
            var d: Delegate = .{
                .allocator = abi.allocator,
                .parameters = parameters,
                .origin = decodeOrigin(origin),
            };
            const msg = decodeInbound(inbound) catch |err| return encodeError(@errorName(err));
            Impl.handle(&d, msg) catch |err| return encodeError(d.failure orelse @errorName(err));
            return encodeOk(d.outbox.items);
        }
    };
}

// ---- wire format ------------------------------------------------------------

pub fn decodeOrigin(bytes: []const u8) Origin {
    if (bytes.len == 0) return .none;
    var r: bincode.Reader = .init(bytes);
    const t = r.tag() catch return .{ .unknown = std.math.maxInt(u32) };
    return switch (t) {
        0 => .{ .web_app = r.array(32) catch return .{ .unknown = t } },
        1 => .{ .delegate = .{
            .key = r.array(32) catch return .{ .unknown = t },
            .code_hash = r.array(32) catch return .{ .unknown = t },
        } },
        else => .{ .unknown = t },
    };
}

pub fn encodeOrigin(w: *bincode.Writer, origin: Origin) Allocator.Error!void {
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

pub fn decodeInbound(bytes: []const u8) bincode.Error!Inbound {
    var r: bincode.Reader = .init(bytes);
    const t = try r.tag();
    if (t != 0) return .{ .unsupported = .{ .tag = t, .raw = bytes } };
    return .{ .application = .{
        .payload = try r.bytes(),
        .context = try r.bytes(),
        .processed = try r.boolean(),
    } };
}

pub fn encodeInbound(w: *bincode.Writer, msg: Inbound) Allocator.Error!void {
    switch (msg) {
        .application => |app| {
            try w.tag(0);
            try w.bytes(app.payload);
            try w.bytes(app.context);
            try w.boolean(app.processed);
        },
        .unsupported => |u| try w.raw(u.raw),
    }
}

fn encodeOk(outbox: []const Outbound) []const u8 {
    var w: bincode.Writer = .init(abi.allocator);
    encodeOutbound(&w, outbox) catch @trap();
    return w.items();
}

/// `Ok(Vec<OutboundDelegateMsg>)`
pub fn encodeOutbound(w: *bincode.Writer, outbox: []const Outbound) Allocator.Error!void {
    try w.tag(0); // Ok
    try w.int(u64, outbox.len);
    for (outbox) |msg| switch (msg) {
        .application => |payload| {
            try w.tag(0); // ApplicationMessage
            try w.bytes(payload);
            try w.bytes(""); // context (the node clears it anyway)
            try w.boolean(true); // processed: deliver to the app
        },
        .context_updated => |data| {
            try w.tag(2); // ContextUpdated(DelegateContext)
            try w.bytes(data);
        },
    };
}

/// `Err(DelegateError::Other(message))`
fn encodeError(message: []const u8) []const u8 {
    var w: bincode.Writer = .init(abi.allocator);
    w.tag(1) catch @trap(); // Err
    w.tag(1) catch @trap(); // DelegateError::Other
    w.bytes(message) catch @trap();
    return w.items();
}

/// Result of a delegate call as decoded by `freenet.testing` (and useful for
/// anyone decoding delegate output).
pub const Result = union(enum) {
    ok: []const Outbound,
    err: []const u8,
};

pub fn decodeResult(gpa: Allocator, bytes: []const u8) !Result {
    var r: bincode.Reader = .init(bytes);
    switch (try r.tag()) {
        0 => {
            const n = try r.int(u64);
            var out: std.ArrayList(Outbound) = .empty;
            for (0..n) |_| switch (try r.tag()) {
                0 => {
                    const payload = try r.bytes();
                    _ = try r.bytes();
                    _ = try r.boolean();
                    try out.append(gpa, .{ .application = payload });
                },
                2 => try out.append(gpa, .{ .context_updated = try r.bytes() }),
                else => return error.UnsupportedOutbound,
            };
            if (r.remaining() != 0) return error.TrailingBytes;
            return .{ .ok = out.items };
        },
        1 => {
            _ = try r.tag(); // DelegateError variant (Deser = 0, Other = 1)
            return .{ .err = try r.bytes() };
        },
        else => return error.BadResultTag,
    }
}

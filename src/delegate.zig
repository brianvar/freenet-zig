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

/// Handed to your `handle` function for each message.
pub const Delegate = struct {
    /// Allocator for this call. Everything is freed by the node when the call
    /// ends, so you never need to free.
    allocator: Allocator,
    /// The delegate's parameters (raw bytes; empty for most delegates).
    parameters: []const u8,
    /// Who sent the message.
    origin: Origin,

    /// Reply payloads so far, sent to the app when `handle` returns.
    replies: std.ArrayList([]const u8) = .empty,
    failure: ?[]const u8 = null,

    /// Reply to the app with `payload`.
    pub fn reply(d: *Delegate, payload: []const u8) Allocator.Error!void {
        try d.replies.append(d.allocator, payload);
    }

    /// Reply with formatted text.
    pub fn replyFmt(d: *Delegate, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try d.reply(try d.allocator.print(fmt, args));
    }

    /// Replace the delegate context (scratch state within one message batch).
    pub fn setContext(d: *Delegate, data: []const u8) error{ContextWriteFailed}!void {
        _ = d;
        if (!host.contextWrite(data)) return error.ContextWriteFailed;
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

    /// Fails the call unless the message came from the web app this delegate
    /// belongs to. `freenet-pack` sets a delegate's parameters to its app's
    /// contract id (32 bytes), and the node attests the sender's id in
    /// `origin`, so no other site can pass. With no parameters, or any other
    /// origin, it fails. Use as `try d.requireApp();` before anything that
    /// reads or changes private data.
    pub fn requireApp(d: *Delegate) error{DelegateFailed}!void {
        const from_app = switch (d.origin) {
            .web_app => |id| std.mem.eql(u8, &id, d.parameters),
            else => false,
        };
        if (!from_app) return d.fail("this delegate only answers its own web app");
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
            const msg = decodeInbound(inbound) catch |err| return encodeError(.deser, @errorName(err));
            Impl.handle(&d, msg) catch |err| {
                const failed = @as(anyerror, err) == error.DelegateFailed;
                return encodeError(.other, if (failed) (d.failure orelse "DelegateFailed") else @errorName(err));
            };
            return encodeOk(d.replies.items);
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

/// `Ok(Vec<OutboundDelegateMsg>)`, one `ApplicationMessage` per reply.
fn encodeOk(replies: []const []const u8) []const u8 {
    var w: bincode.Writer = .init(abi.allocator);
    encodeReplies(&w, replies) catch @trap();
    return w.items();
}

fn encodeReplies(w: *bincode.Writer, replies: []const []const u8) Allocator.Error!void {
    try w.tag(0); // Ok
    try w.int(u64, replies.len);
    for (replies) |payload| {
        try w.tag(0); // ApplicationMessage
        try w.bytes(payload);
        try w.bytes(""); // context (the node clears it anyway)
        try w.boolean(true); // processed: deliver to the app
    }
}

const ErrorKind = enum(u32) { deser = 0, other = 1 };

/// `Err(DelegateError::Deser(message))` or `Err(DelegateError::Other(message))`
fn encodeError(kind: ErrorKind, message: []const u8) []const u8 {
    var w: bincode.Writer = .init(abi.allocator);
    w.tag(1) catch @trap(); // Err
    w.tag(@backingInt(kind)) catch @trap();
    w.bytes(message) catch @trap();
    return w.items();
}

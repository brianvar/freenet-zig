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
//!         .user_response, .contract_state, .unsupported => {},
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

/// `UserResponse`: the user's answer to a prompt this delegate asked for
/// (`Delegate.requestUserInput`).
///
/// Not proof that the user answered: a web app can send this message itself,
/// with any id and any bytes (nodes don't refuse it from clients yet). Accept
/// it only if `request_id` matches a prompt you saved before asking, with an
/// id the app can't know (random), and clear that saved prompt whatever the
/// answer. An empty `response` means refused, timed out, or no prompt shown.
pub const UserResponse = struct {
    request_id: u32,
    /// The bytes of the chosen response (the button's label), or empty.
    response: []const u8,
    /// Always empty from the node; the delegate context lives on through
    /// `d.context()`.
    context: []const u8 = "",
};

/// A prompt the node shows the user (`RequestUserInput`), queued by
/// `Delegate.requestUserInput`.
pub const UserInputRequest = struct {
    request_id: u32,
    message: []const u8,
    responses: []const []const u8,
};

/// `GetContractResponse`: the answer to `Delegate.getContract`, in a new call.
///
/// Not proof that the node sent it: a web app can send this message itself,
/// with any state. Accept it only if `context` carries a value you put in the
/// request and saved (for example a random nonce in a secret), and clear what
/// you saved either way.
pub const ContractState = struct {
    contract_id: types.ContractInstanceId,
    /// The contract's state, or null if the node has none: not stored
    /// locally and not found on the network, or the request failed (the node
    /// doesn't say which).
    state: ?[]const u8,
    /// The `context` passed to `getContract`, unchanged.
    context: []const u8,
};

/// A contract state request (`GetContractRequest`), queued by
/// `Delegate.getContract`.
pub const ContractRequest = struct {
    contract_id: types.ContractInstanceId,
    context: []const u8,
};

/// An inbound message (`InboundDelegateMsg`).
pub const Inbound = union(enum) {
    application: ApplicationMessage,
    user_response: UserResponse,
    contract_state: ContractState,
    /// Any other variant (other contract responses, notifications, lifecycle
    /// events, ...). Not decoded by this library yet; `raw` is the whole
    /// bincode message, `tag` its variant index: 5 is the node's
    /// `SubscribeContractResponse` to `subscribeContract`, 6 a
    /// `ContractNotification` (a subscribed contract's new state).
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
    /// Prompts asked for so far, sent to the node after the replies.
    prompts: std.ArrayList(UserInputRequest) = .empty,
    /// Contract state requests so far, sent to the node after the prompts.
    contract_requests: std.ArrayList(ContractRequest) = .empty,
    /// Contract subscriptions asked for so far (`subscribeContract`), sent last.
    subscriptions: std.ArrayList(types.ContractInstanceId) = .empty,
    failure: ?[]const u8 = null,

    /// Reply to the app with `payload`.
    pub fn reply(d: *Delegate, payload: []const u8) Allocator.Error!void {
        try d.replies.append(d.allocator, payload);
    }

    /// Reply with formatted text.
    pub fn replyFmt(d: *Delegate, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try d.reply(try d.allocator.print(fmt, args));
    }

    /// The most responses a prompt may offer, and the longest response (in
    /// bytes): the node shows no more and cuts longer labels.
    pub const max_responses = 10;
    pub const max_response_len = 64;
    /// The longest message (in bytes) the node shows in full; it cuts longer
    /// ones at 2048 characters.
    pub const max_message_len = 2048;

    /// Ask the node to show the user a prompt: `message` (UTF-8 text) and one
    /// button per response, whose bytes are its label. The node shows it
    /// outside every app's page, waits (60 s on current nodes), and then
    /// calls this delegate again with a `.user_response` carrying
    /// `request_id` and the chosen response's bytes (empty if refused or
    /// timed out). Replies made in either call go to the app's original
    /// request. While the prompt is open the node holds back other messages
    /// to this delegate.
    ///
    /// Save what the prompt is for (and `request_id`) in a secret before
    /// returning: the answer arrives in a new call. Use a random id and see
    /// `UserResponse` for why. Put the safe choice first: a node that answers
    /// without asking (test prompters) picks the first response.
    pub fn requestUserInput(d: *Delegate, request_id: u32, message: []const u8, responses: []const []const u8) error{ OutOfMemory, DelegateFailed }!void {
        if (responses.len == 0 or responses.len > max_responses) return d.fail("a prompt needs 1 to 10 responses");
        for (responses) |r| if (r.len == 0 or r.len > max_response_len) return d.fail("prompt responses are 1 to 64 bytes");
        if (message.len > max_message_len) return d.fail("a prompt message is at most 2048 bytes");
        try d.prompts.append(d.allocator, .{ .request_id = request_id, .message = message, .responses = responses });
    }

    /// The longest `context` a contract request may carry (the node's
    /// `DelegateContext::MAX_SIZE`).
    pub const max_context_len = 4096 * 10 * 10;

    /// Ask the node for contract `id`'s state. The node looks in its own store
    /// first, then on the network, and calls this delegate again with a
    /// `.contract_state` carrying `context` unchanged and the state (or null).
    /// Replies made in that call reach the app's original request. Nodes in
    /// local mode never call back (freenet 0.2.155; docs/delegates.md,
    /// "Reading a contract"): the app then gets the first call's replies only.
    ///
    /// The answer arrives in a new call: save what the request is for in a
    /// secret, and put a random value in `context` that you also save, since
    /// an app can send a `.contract_state` itself (see `ContractState`).
    pub fn getContract(d: *Delegate, id: types.ContractInstanceId, context_: []const u8) error{ OutOfMemory, DelegateFailed }!void {
        if (context_.len > max_context_len) return d.fail("a contract request's context is at most 400 KiB");
        try d.contract_requests.append(d.allocator, .{ .contract_id = id, .context = context_ });
    }

    /// Subscribe this delegate to contract `id` (`SubscribeContractRequest`).
    /// The node then counts the delegate as wanting the contract, like a
    /// connected client, so it keeps hosting it and renews it on the network;
    /// unlike a client's, the subscription has no end: it outlives the app's
    /// connection and is restored when the node restarts (freenet-core
    /// #4669, #5493). There is no unsubscribe yet (#5600).
    ///
    /// Each state change of the contract then calls the delegate with the
    /// new state (a `ContractNotification`, reaching `handle` as
    /// `.unsupported` with tag 6), and the node answers the request itself
    /// with a `SubscribeContractResponse` (tag 5) in a new call; both can be
    /// ignored. Subscribing again to a contract already subscribed changes
    /// nothing.
    ///
    /// **Subscribe only to contracts the node holds.** For one it doesn't,
    /// the node fetches it from the network first, and until that finishes
    /// (up to about a minute for one that isn't there) it holds back this
    /// call's replies and every further message to the delegate. At most 4
    /// such network subscriptions per call; the node refuses the rest.
    ///
    /// Limits (freenet 0.2.156): 256 contracts per delegate; past that the
    /// node drops the one it notified least recently, silently. A contract
    /// that never changes keeps the time it was subscribed. See
    /// docs/delegates.md, "Subscribing to a contract".
    pub fn subscribeContract(d: *Delegate, id: types.ContractInstanceId) Allocator.Error!void {
        try d.subscriptions.append(d.allocator, id);
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
            return encodeOk(d.replies.items, d.prompts.items, d.contract_requests.items, d.subscriptions.items);
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
    return switch (try r.tag()) {
        0 => .{ .application = .{
            .payload = try r.bytes(),
            .context = try r.bytes(),
            .processed = try r.boolean(),
        } },
        1 => .{ .user_response = .{
            .request_id = try r.int(u32),
            .response = try r.bytes(),
            .context = try r.bytes(),
        } },
        2 => .{ .contract_state = .{
            .contract_id = try r.array(32),
            .state = try r.optionalBytes(),
            .context = try r.bytes(),
        } },
        else => |t| .{ .unsupported = .{ .tag = t, .raw = bytes } },
    };
}

/// `Ok(Vec<OutboundDelegateMsg>)`: one `ApplicationMessage` per reply, then
/// one `RequestUserInput` per prompt, then one `GetContractRequest` per
/// contract request, then one `SubscribeContractRequest` per subscription
/// (requests last: the node hands each to its executor once the call returns).
fn encodeOk(replies: []const []const u8, prompts: []const UserInputRequest, requests: []const ContractRequest, subscriptions: []const types.ContractInstanceId) []const u8 {
    var w: bincode.Writer = .init(abi.allocator);
    encodeOutbound(&w, replies, prompts, requests, subscriptions) catch @trap();
    return w.items();
}

fn encodeOutbound(w: *bincode.Writer, replies: []const []const u8, prompts: []const UserInputRequest, requests: []const ContractRequest, subscriptions: []const types.ContractInstanceId) Allocator.Error!void {
    try w.tag(0); // Ok
    try w.int(u64, replies.len + prompts.len + requests.len + subscriptions.len);
    for (replies) |payload| {
        try w.tag(0); // ApplicationMessage
        try w.bytes(payload);
        try w.bytes(""); // context (the node clears it anyway)
        try w.boolean(true); // processed: deliver to the app
    }
    for (prompts) |p| {
        try w.tag(1); // RequestUserInput
        try w.int(u32, p.request_id);
        try w.bytes(p.message); // NotificationMessage
        try w.int(u64, p.responses.len);
        for (p.responses) |r| try w.bytes(r); // ClientResponse
    }
    for (requests) |q| {
        try w.tag(3); // GetContractRequest (after ApplicationMessage, RequestUserInput, ContextUpdated)
        try w.raw(&q.contract_id); // ContractInstanceId: 32 bytes, no length
        try w.bytes(q.context); // DelegateContext
        try w.boolean(false); // processed: not yet, the node fetches it
    }
    for (subscriptions) |id| {
        try w.tag(6); // SubscribeContractRequest (after PutContractRequest, UpdateContractRequest)
        try w.raw(&id); // ContractInstanceId: 32 bytes, no length
        try w.bytes(""); // context: DelegateContext (none)
        try w.boolean(false); // processed: not yet, the node subscribes
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

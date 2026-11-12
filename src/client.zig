//! A native client for the node's WebSocket API, for programs that run beside
//! the node (a git remote helper, a CLI): read a contract's state, send it a
//! delta, message a delegate. It speaks the same protocol as `js/freenet.js`
//! (bincode over `/v1/contract/command?encodingProtocol=native`). Native only (it opens a
//! TCP socket); nothing here is analyzed unless a program uses it, so Wasm
//! modules that import `freenet` are unaffected.
//!
//!     var c = try freenet.client.Client.connect(gpa, io, "127.0.0.1", 7509);
//!     defer c.close();
//!     const state = try c.get(gpa, id) orelse return error.NoSuchContract;
//!     defer gpa.free(state);
//!
//! A delegate sees a native client's messages with origin `none` (checked on
//! freenet 0.2.156): `Delegate.requireApp` refuses them, so a delegate that
//! serves native programs checks something else, such as a signature.
//!
//! Requests go out one at a time and wait for their answer, as in freenet.js:
//! replies carry no request id. With `connectWith(..., .{ .timeout = ... })`
//! (or `c.timeout`), a request whose answer doesn't come in time fails with
//! `error.Timeout`; without one, a node that never answers blocks the call.
//!
//!     var c = try freenet.client.Client.connectWith(gpa, io, "127.0.0.1", 7509, .{
//!         .timeout = .fromSeconds(60),
//!     });

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const bincode = @import("bincode.zig");
const types = @import("types.zig");

/// Path and query of the node's WebSocket endpoint (as in freenet.js).
pub const endpoint = "/v1/contract/command?encodingProtocol=native";

/// The largest message (and reassembled streamed response) accepted: the
/// node's own WebSocket limit. Contract states are at most 50 MiB.
pub const max_message_len = 100 * 1024 * 1024;

pub const Error = error{
    /// The node closed the connection, or an earlier error left it unusable.
    ConnectionClosed,
    /// The node broke the WebSocket protocol.
    ProtocolError,
    /// A message or streamed response over `max_message_len`.
    MessageTooLong,
    /// A response that doesn't decode as the node's bincode.
    BadResponse,
    /// The node refused the request: see `lastError`.
    NodeError,
    /// Generic stream failures (with `connect`'s socket they are replaced by
    /// the socket's own error).
    ReadFailed,
    WriteFailed,
} || Allocator.Error || Io.net.Stream.Reader.Error || Io.net.Stream.Writer.Error || SocketReader.ReadError || SocketWriter.WriteError;

pub const Options = struct {
    /// How long the WebSocket handshake, and later each request, may take
    /// (sending it and waiting for the answer); then `error.Timeout`, and
    /// the connection is given up. Null waits forever. The TCP connect
    /// itself is left to the system (Zig 0.17's `ConnectOptions.timeout` is
    /// not implemented on POSIX); a node that isn't running refuses at once.
    timeout: ?Io.Duration = null,
};

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    in: *Io.Reader,
    out: *Io.Writer,
    /// The socket and its buffers, when `connect` opened them.
    conn: ?*Conn = null,
    /// The node closed the connection, or a protocol error left it unusable.
    broken: bool = false,
    /// Masks for client frames; tests fix it to get repeatable bytes.
    fixed_mask: ?[4]u8 = null,
    /// See `Options.timeout`. Only for connections `connect` opened.
    timeout: ?Io.Duration = null,
    error_buf: [512]u8 = undefined,
    error_len: usize = 0,
    timeout_buf: [400]u8 = undefined,

    const Conn = struct {
        stream: Io.net.Stream,
        reader: SocketReader,
        writer: SocketWriter,
        /// When the current request gives up (`arm`).
        deadline: Io.Timeout = .none,
        read_buf: [64 * 1024]u8,
        write_buf: [64 * 1024]u8,
        node_buf: [300]u8 = undefined,
        node_len: usize = 0,
    };

    /// Connects to `ws://<host>:<port>/v1/contract/command?encodingProtocol=native`,
    /// without a timeout. `host` is an IP address or a name ("localhost"). On
    /// `error.HandshakeFailed` there is no client to ask, so the node's status
    /// line is logged.
    pub fn connect(gpa: Allocator, io: Io, host: []const u8, port: u16) !Client {
        return connectWith(gpa, io, host, port, .{});
    }

    /// `connect` with `options` (a timeout).
    pub fn connectWith(gpa: Allocator, io: Io, host: []const u8, port: u16, options: Options) !Client {
        const stream = if (Io.net.IpAddress.parse(host, port)) |addr|
            try addr.connect(io, .{ .mode = .stream })
        else |_|
            try (try Io.net.HostName.init(host)).connect(io, port, .{ .mode = .stream });
        errdefer stream.close(io);

        const conn = try gpa.create(Conn);
        errdefer gpa.destroy(conn);
        conn.* = .{ .stream = stream, .reader = undefined, .writer = undefined, .read_buf = undefined, .write_buf = undefined };
        conn.reader = .init(conn, io, &conn.read_buf);
        conn.writer = .init(conn, io, &conn.write_buf);
        conn.node_len = if (std.fmt.bufPrint(&conn.node_buf, "{s}:{d}", .{ host, port })) |n| n.len else |_| 0;

        var c: Client = .init(gpa, io, &conn.reader.interface, &conn.writer.interface);
        c.conn = conn;
        c.timeout = options.timeout;
        c.arm();
        c.handshake(host, port) catch |err| {
            if (err == error.HandshakeFailed) std.log.scoped(.freenet).err("websocket handshake: {s}", .{c.lastError()});
            return switch (err) { // error.Timeout: the caller knows which node it asked
                error.ReadFailed => conn.reader.err orelse err,
                error.WriteFailed => conn.writer.err orelse err,
                else => err,
            };
        };
        return c;
    }

    /// A client over an already-open WebSocket connection (after the
    /// handshake): `in` reads the node's frames, `out` takes ours. For tests,
    /// and for callers that bring their own transport.
    pub fn init(gpa: Allocator, io: Io, in: *Io.Reader, out: *Io.Writer) Client {
        return .{ .gpa = gpa, .io = io, .in = in, .out = out };
    }

    /// Sends a close frame (when the connection is still up) and releases the socket.
    pub fn close(c: *Client) void {
        if (!c.broken) {
            writeFrame(c.out, .connection_close, &.{ 0x03, 0xe8 }, c.mask()) catch {}; // 1000: normal closure
            c.out.flush() catch {};
            c.broken = true;
        }
        if (c.conn) |conn| {
            conn.stream.close(c.io);
            c.gpa.destroy(conn);
            c.conn = null;
        }
    }

    /// What the node said when a call failed with `error.NodeError`, or why
    /// the handshake failed: e.g. "Update <id>: invalid delta". After
    /// `error.Timeout`: "the node at <host:port> didn't answer in <n> s".
    pub fn lastError(c: *const Client) []const u8 {
        return c.error_buf[0..c.error_len];
    }

    /// The contract's current state, or null if the node doesn't have it
    /// (`id`: the contract instance id, BLAKE3(code hash ‖ parameters)).
    /// Caller owns the returned bytes.
    pub fn get(c: *Client, gpa: Allocator, id: types.ContractInstanceId) Error!?[]u8 {
        // ClientRequest::ContractOp(ContractRequest::Get { key, return_contract_code, subscribe, blocking_subscribe })
        var req: [4 + 4 + 32 + 3]u8 = undefined;
        @memcpy(req[0..8], &[_]u8{ 1, 0, 0, 0, 2, 0, 0, 0 });
        @memcpy(req[8..40], &id);
        @memcpy(req[40..], &[_]u8{ 0, 0, 0 });
        c.arm();
        c.send(&req) catch |err| return c.ioError(err);

        var streams: Reassembly = .{};
        defer streams.deinit(gpa);
        while (true) {
            const msg = c.receive(gpa, &streams) catch |err| return c.ioError(err);
            var keep = false;
            defer if (!keep) gpa.free(msg);
            switch (try c.parse(msg)) {
                .get => |g| if (std.mem.eql(u8, &g.key.id, &id)) {
                    // The state ends the message: move it to the front and
                    // shrink, rather than copy up to 50 MiB.
                    const len = g.state.len;
                    std.mem.copyForwards(u8, msg[0..len], g.state);
                    const state = gpa.realloc(msg, len) catch return try gpa.dupe(u8, msg[0..len]);
                    keep = true;
                    return state;
                },
                .not_found => |nf| if (std.mem.eql(u8, &nf, &id)) return null,
                .failure => |f| {
                    // Depending on mode and version, the node reports an
                    // unknown contract as a NotFound response, or as a
                    // MissingContract / "state not found" error.
                    if (f.isNotFound(id)) return null;
                    return error.NodeError;
                },
                .put, .updated, .delegate, .ok, .other => {},
            }
        }
    }

    /// Sends a delta to the contract (ContractRequest::Update with
    /// UpdateData::Delta); its `update_state` merges it. Returns the new
    /// summary (caller owns it). `code_hash` is BLAKE3 of the contract's Wasm.
    /// A refused delta is `error.NodeError` (see `lastError`).
    pub fn update(c: *Client, gpa: Allocator, id: types.ContractInstanceId, code_hash: types.CodeHash, delta: []const u8) Error![]u8 {
        // ClientRequest::ContractOp(ContractRequest::Update { key: ContractKey, data: UpdateData::Delta })
        var head: [4 + 4 + 64 + 4 + 8]u8 = undefined;
        @memcpy(head[0..8], &[_]u8{ 1, 0, 0, 0, 1, 0, 0, 0 });
        @memcpy(head[8..40], &id);
        @memcpy(head[40..72], &code_hash);
        std.mem.writeInt(u32, head[72..76], 1, .little);
        std.mem.writeInt(u64, head[76..84], delta.len, .little);
        c.arm();
        c.sendParts(&.{ &head, delta }) catch |err| return c.ioError(err);

        var streams: Reassembly = .{};
        defer streams.deinit(gpa);
        while (true) {
            const msg = c.receive(gpa, &streams) catch |err| return c.ioError(err);
            defer gpa.free(msg);
            switch (try c.parse(msg)) {
                .updated => |u| if (std.mem.eql(u8, &u.key.id, &id)) return gpa.dupe(u8, u.summary),
                .failure => return error.NodeError,
                .get, .put, .not_found, .delegate, .ok, .other => {},
            }
        }
    }

    /// Creates the contract `wasm` (its code, as the node runs it) with
    /// `parameters` and `state`; if the node already has it, the node merges
    /// the state in instead, which counts too (as freenet.js `put`). A
    /// refused state is `error.NodeError` (see `lastError`).
    pub fn put(c: *Client, gpa: Allocator, wasm: []const u8, parameters: []const u8, state: []const u8) Error!void {
        return c.putWith(gpa, wasm, parameters, state, .{});
    }

    pub const PutOptions = struct {
        /// Subscribe this connection to the contract as part of the put (as
        /// freenet.js `put(state, { subscribe: true })`). The node keeps a
        /// contract hosted while a client is subscribed to it, but the
        /// subscription ends when this connection closes, so it's worth it
        /// only for a client that stays connected.
        subscribe: bool = false,
    };

    /// `put` with options.
    pub fn putWith(c: *Client, gpa: Allocator, wasm: []const u8, parameters: []const u8, state: []const u8, options: PutOptions) Error!void {
        const code_hash = types.codeHash(wasm);
        const id = types.contractInstanceId(wasm, parameters);
        // ClientRequest::ContractOp(ContractRequest::Put { contract: Wasm(V1(WrappedContract {
        //   data: ContractCode { data, code_hash }, params, key: ContractKey { instance, code } })),
        //   state, related_contracts: empty, subscribe, blocking_subscribe: false })
        var head: [4 + 4 + 4 + 4 + 8]u8 = undefined;
        @memcpy(head[0..16], &[_]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
        std.mem.writeInt(u64, head[16..24], wasm.len, .little);
        var params_len: [8]u8 = undefined;
        std.mem.writeInt(u64, &params_len, parameters.len, .little);
        var state_len: [8]u8 = undefined;
        std.mem.writeInt(u64, &state_len, state.len, .little);
        const tail = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, @intFromBool(options.subscribe), 0 }; // related_contracts: u64 0 entries; subscribe; blocking_subscribe
        c.arm();
        c.sendParts(&.{ &head, wasm, &code_hash, &params_len, parameters, &id, &code_hash, &state_len, state, &tail }) catch |err| return c.ioError(err);

        var streams: Reassembly = .{};
        defer streams.deinit(gpa);
        while (true) {
            const msg = c.receive(gpa, &streams) catch |err| return c.ioError(err);
            defer gpa.free(msg);
            switch (try c.parse(msg)) {
                .put => |k| if (std.mem.eql(u8, &k.id, &id)) return,
                .updated => |u| if (std.mem.eql(u8, &u.key.id, &id)) return,
                .failure => return error.NodeError,
                .get, .not_found, .delegate, .ok, .other => {},
            }
        }
    }

    // ---- delegates ----

    /// Registers the delegate `wasm` with `parameters` on the node (as
    /// freenet.js `delegate(name)` does for a page). A node that refuses (it
    /// may already have it) is `error.NodeError`, see `lastError`; messages
    /// tell whether the delegate answers.
    pub fn registerDelegate(c: *Client, gpa: Allocator, wasm: []const u8, parameters: []const u8) Error!void {
        const key = types.delegateKey(wasm, parameters);
        // ClientRequest::DelegateOp(DelegateRequest::RegisterDelegate { delegate: DelegateContainer::Wasm(V1(Delegate {
        //   parameters, data: DelegateCode { data, code_hash }, key: DelegateKey { key, code_hash } })), cipher, nonce })
        var head: [4 * 4 + 8]u8 = undefined;
        @memcpy(head[0..16], &[_]u8{ 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
        std.mem.writeInt(u64, head[16..24], parameters.len, .little);
        var wasm_len: [8]u8 = undefined;
        std.mem.writeInt(u64, &wasm_len, wasm.len, .little);
        const cipher_nonce: [32 + 24]u8 = @splat(0); // ignored by current nodes
        c.arm();
        c.sendParts(&.{ &head, parameters, &wasm_len, wasm, &key.code_hash, &key.key, &key.code_hash, &cipher_nonce }) catch |err| return c.ioError(err);

        var streams: Reassembly = .{};
        defer streams.deinit(gpa);
        while (true) {
            const msg = c.receive(gpa, &streams) catch |err| return c.ioError(err);
            defer gpa.free(msg);
            switch (try c.parse(msg)) {
                .ok => return,
                .delegate => |d| if (std.mem.eql(u8, &d.key, &key.key)) return,
                .failure => return error.NodeError,
                .get, .put, .not_found, .updated, .other => {},
            }
        }
    }

    /// Sends `payload` to the delegate `key` (with its `parameters`) as an
    /// `ApplicationMessage`, as freenet.js `DelegateHandle.send` does. The
    /// node runs the delegate and returns what it sent back: its replies and,
    /// from a node that doesn't show prompts itself (local mode), its
    /// questions for the user. A delegate's own failure is
    /// `error.NodeError`, its message in `lastError`. Free the result with
    /// `deinit`.
    pub fn sendToDelegate(c: *Client, gpa: Allocator, key: types.DelegateKey, parameters: []const u8, payload: []const u8) Error!DelegateReply {
        // InboundDelegateMsg::ApplicationMessage { payload, context: [], processed: false }
        var head: [4 + 8]u8 = undefined;
        std.mem.writeInt(u32, head[0..4], 0, .little);
        std.mem.writeInt(u64, head[4..12], payload.len, .little);
        const tail: [9]u8 = @splat(0);
        return c.delegateRequest(gpa, key, parameters, &.{ &head, payload, &tail });
    }

    /// Answers a delegate's question (`DelegateReply.prompts`) with the
    /// chosen label, "" for none: an `InboundDelegateMsg::UserResponse`, as
    /// freenet.js `DelegateHandle.respond`. The delegate can't tell this
    /// answer from a person's.
    pub fn respondToDelegate(c: *Client, gpa: Allocator, key: types.DelegateKey, parameters: []const u8, request_id: u32, label: []const u8) Error!DelegateReply {
        // InboundDelegateMsg::UserResponse(UserInputResponse { request_id, response, context: [] })
        var head: [4 + 4 + 8]u8 = undefined;
        std.mem.writeInt(u32, head[0..4], 1, .little);
        std.mem.writeInt(u32, head[4..8], request_id, .little);
        std.mem.writeInt(u64, head[8..16], label.len, .little);
        const tail: [8]u8 = @splat(0);
        return c.delegateRequest(gpa, key, parameters, &.{ &head, label, &tail });
    }

    fn delegateRequest(c: *Client, gpa: Allocator, key: types.DelegateKey, parameters: []const u8, inbound: []const []const u8) Error!DelegateReply {
        // ClientRequest::DelegateOp(DelegateRequest::ApplicationMessages { key: DelegateKey, params, inbound: [one] })
        var head: [8 + 64 + 8]u8 = undefined;
        @memcpy(head[0..8], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });
        @memcpy(head[8..40], &key.key);
        @memcpy(head[40..72], &key.code_hash);
        std.mem.writeInt(u64, head[72..80], parameters.len, .little);
        var parts: [6][]const u8 = undefined;
        parts[0] = &head;
        parts[1] = parameters;
        parts[2] = &[_]u8{ 1, 0, 0, 0, 0, 0, 0, 0 }; // one inbound message
        @memcpy(parts[3..][0..inbound.len], inbound);
        c.arm();
        c.sendParts(parts[0 .. 3 + inbound.len]) catch |err| return c.ioError(err);

        var streams: Reassembly = .{};
        defer streams.deinit(gpa);
        while (true) {
            const msg = c.receive(gpa, &streams) catch |err| return c.ioError(err);
            defer gpa.free(msg);
            switch (try c.parse(msg)) {
                .delegate => |d| if (std.mem.eql(u8, &d.key, &key.key)) {
                    return DelegateReply.decode(gpa, d.values) catch |err| switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => error.BadResponse,
                    };
                },
                .failure => return error.NodeError,
                .get, .put, .not_found, .updated, .ok, .other => {},
            }
        }
    }

    // ---- requests and responses ----

    fn send(c: *Client, payload: []const u8) Error!void {
        return c.sendParts(&.{payload});
    }

    /// One binary message made of `parts`.
    fn sendParts(c: *Client, parts: []const []const u8) Error!void {
        if (c.broken) return error.ConnectionClosed;
        var len: u64 = 0;
        for (parts) |p| len += p.len;
        const m = c.mask();
        try writeHeader(c.out, .binary, true, len, m);
        var offset: usize = 0;
        for (parts) |p| {
            try writeMasked(c.out, p, m, offset);
            offset += p.len;
        }
        try c.out.flush();
    }

    /// The next complete response, a serialized `Result<HostResponse,
    /// ClientError>`; streamed responses (StreamChunk) come back reassembled.
    /// Caller owns it.
    fn receive(c: *Client, gpa: Allocator, streams: *Reassembly) Error![]u8 {
        while (true) {
            const msg = try c.readMessage(gpa);
            var r: bincode.Reader = .init(msg);
            if ((r.tag() catch 1) != 0) return msg; // an error, or too short: the caller parses it
            switch (r.tag() catch return msg) {
                4 => { // HostResponse::StreamChunk { stream_id, index, total, data }
                    defer gpa.free(msg);
                    const stream_id = r.int(u32) catch return error.BadResponse;
                    const index = r.int(u32) catch return error.BadResponse;
                    const total = r.int(u32) catch return error.BadResponse;
                    const data = r.bytes() catch return error.BadResponse;
                    if (try streams.add(gpa, stream_id, index, total, data)) |whole| return whole;
                },
                5 => gpa.free(msg), // StreamHeader: the chunks that follow say it all
                else => return msg,
            }
        }
    }

    const Key = struct { id: [32]u8, code_hash: [32]u8 };

    const Response = union(enum) {
        get: struct { key: Key, state: []const u8 },
        put: Key,
        not_found: [32]u8,
        updated: struct { key: Key, summary: []const u8 },
        /// HostResponse::DelegateResponse: `values` is the encoded Vec<OutboundDelegateMsg>.
        delegate: struct { key: [32]u8, values: []const u8 },
        /// HostResponse::Ok (a registered delegate, among others).
        ok,
        failure: Failure,
        other,
    };

    /// Decodes the responses the client acts on. A failure is also written
    /// to `lastError`.
    fn parse(c: *Client, msg: []const u8) error{BadResponse}!Response {
        const res = decodeResponse(msg) catch return error.BadResponse;
        if (res == .failure) {
            var w: Io.Writer = .fixed(&c.error_buf);
            res.failure.format(&w) catch {};
            c.error_len = w.end;
        }
        return res;
    }

    // ---- WebSocket ----

    fn mask(c: *Client) [4]u8 {
        if (c.fixed_mask) |m| return m;
        var m: [4]u8 = undefined;
        c.io.random(&m);
        return m;
    }

    fn handshake(c: *Client, host: []const u8, port: u16) !void {
        var nonce: [16]u8 = undefined;
        c.io.random(&nonce);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &nonce);
        const bracket = std.mem.indexOfScalar(u8, host, ':') != null; // an IPv6 literal
        try c.out.print("GET " ++ endpoint ++ " HTTP/1.1\r\nHost: {s}{s}{s}:{d}\r\n" ++
            "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{
            if (bracket) "[" else "", host, if (bracket) "]" else "", port, &key,
        });
        try c.out.flush();
        try c.readHandshakeResponse(&key);
    }

    fn readHandshakeResponse(c: *Client, key: []const u8) !void {
        const status = trimLine(try c.in.takeDelimiterInclusive('\n'));
        var parts = std.mem.tokenizeScalar(u8, status, ' ');
        _ = parts.next(); // HTTP/1.1
        const ok = std.mem.eql(u8, parts.next() orelse "", "101");
        if (!ok) c.setError("{s}", .{status});
        var upgrade = false;
        var connection = false;
        var accepted = false;
        while (true) {
            const line = trimLine(try c.in.takeDelimiterInclusive('\n'));
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
                upgrade = std.ascii.eqlIgnoreCase(value, "websocket");
            } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
                connection = std.ascii.findIgnoreCase(value, "upgrade") != null;
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
                accepted = std.mem.eql(u8, value, &acceptKey(key));
            }
        }
        if (!ok) return error.HandshakeFailed;
        if (!(upgrade and connection and accepted)) {
            c.setError("the node's 101 response lacks the WebSocket upgrade headers or the right Sec-WebSocket-Accept", .{});
            return error.HandshakeFailed;
        }
    }

    /// The payload of the next text or binary message, fragments joined.
    /// Answers pings; a close frame is answered and ends the connection.
    fn readMessage(c: *Client, gpa: Allocator) Error![]u8 {
        var data: std.ArrayList(u8) = .empty;
        errdefer data.deinit(gpa);
        var started = false;
        while (true) {
            const h = readHeader(c.in) catch |err| return c.fail(err);
            if (h.opcode.isControl()) {
                var buf: [125]u8 = undefined;
                const payload = buf[0..@intCast(h.len)];
                c.in.readSliceAll(payload) catch |err| return c.fail(err);
                if (h.mask) |m| applyMask(payload, m, 0);
                switch (h.opcode) {
                    .ping => {
                        try writeFrame(c.out, .pong, payload, c.mask());
                        try c.out.flush();
                    },
                    .connection_close => {
                        // Echo the status code, as RFC 6455 asks.
                        writeFrame(c.out, .connection_close, payload[0..@min(payload.len, 2)], c.mask()) catch {};
                        c.out.flush() catch {};
                        c.broken = true;
                        return error.ConnectionClosed;
                    },
                    else => {}, // pong
                }
                continue;
            }
            if ((h.opcode == .continuation) != started) return c.fail(error.ProtocolError);
            if (h.opcode != .continuation and h.opcode != .binary and h.opcode != .text) return c.fail(error.ProtocolError);
            started = true;
            if (h.len > max_message_len - data.items.len) return c.fail(error.MessageTooLong);
            const dest = try data.addManyAsSlice(gpa, @intCast(h.len));
            c.in.readSliceAll(dest) catch |err| return c.fail(err);
            if (h.mask) |m| applyMask(dest, m, 0);
            if (h.fin) return data.toOwnedSlice(gpa);
        }
    }

    fn fail(c: *Client, err: (Io.Reader.Error || error{ ProtocolError, MessageTooLong })) Error {
        c.broken = true;
        return switch (err) {
            error.EndOfStream => error.ConnectionClosed,
            else => |e| e,
        };
    }

    /// For a failed send or receive: the connection may be mid-frame, so it
    /// is given up. Replaces the stream reader's and writer's generic
    /// failures with the socket's own error (ConnectionResetByPeer, ...).
    fn ioError(c: *Client, err: Error) Error {
        c.broken = true;
        const conn = c.conn orelse return err;
        const e: Error = switch (err) {
            error.ReadFailed => conn.reader.err orelse err,
            error.WriteFailed => conn.writer.err orelse err,
            else => err,
        };
        if (e == error.Timeout) c.setError("{s}", .{c.timeoutText()});
        return e;
    }

    /// Starts the current request's clock (`timeout`).
    fn arm(c: *Client) void {
        const conn = c.conn orelse return;
        conn.deadline = if (c.timeout) |d| (Io.Timeout{ .duration = .{ .raw = d, .clock = .awake } }).toDeadline(c.io) else .none;
    }

    fn timeoutText(c: *Client) []const u8 {
        const conn = c.conn orelse return "";
        const ms = @divTrunc((c.timeout orelse Io.Duration.zero).nanoseconds, std.time.ns_per_ms);
        const node = conn.node_buf[0..conn.node_len];
        return (if (ms < 1000 or @rem(ms, 1000) != 0)
            std.fmt.bufPrint(&c.timeout_buf, "the node at {s} didn't answer in {d} ms", .{ node, ms })
        else
            std.fmt.bufPrint(&c.timeout_buf, "the node at {s} didn't answer in {d} s", .{ node, @divTrunc(ms, 1000) })) catch "the node didn't answer in time";
    }

    fn setError(c: *Client, comptime fmt: []const u8, args: anytype) void {
        c.error_len = if (std.fmt.bufPrint(&c.error_buf, fmt, args)) |s| s.len else |_| c.error_buf.len;
    }
};

// ---- the socket, with the request's deadline ----

/// `io.operateTimeout`, or, where the `Io` can't time a socket operation, the
/// plain operation on a task of its own that is canceled at the deadline.
/// Zig 0.17's `Io.Threaded` on Windows is such an `Io`: it returns
/// `error.ConcurrencyUnavailable` for a timed net read or write (a TODO in
/// `Io/Threaded.zig`). Canceling the task cancels its pending read or write
/// (`NtCancelIoFileEx` on Windows, a signal on POSIX). Either way a missed
/// deadline is `error.Timeout`. Drop the fallback once Zig times socket
/// operations on Windows.
fn operateTimed(io: Io, operation: Io.Operation, deadline: Io.Timeout) Io.OperateTimeoutError!Io.Operation.Result {
    if (deadline == .none) return io.operate(operation);
    if (!(builtin.is_test and test_watched)) {
        if (io.operateTimeout(operation, deadline)) |done| return done else |err| switch (err) {
            error.ConcurrencyUnavailable => {},
            else => |e| return e,
        }
    }
    const Done = union(enum) {
        operation: Io.Cancelable!Io.Operation.Result,
        deadline: Io.Cancelable!void,
    };
    var buffer: [2]Done = undefined;
    var select: Io.Select(Done) = .init(io, &buffer);
    defer select.cancelDiscard(); // the other task; waits until it has stopped
    try select.concurrent(.operation, Io.operate, .{ io, operation });
    try select.concurrent(.deadline, Io.Timeout.sleep, .{ deadline, io });
    return switch (try select.await()) {
        .operation => |result| result,
        .deadline => |slept| {
            try slept;
            return error.Timeout;
        },
    };
}

/// Tests set it to run `operateTimed`'s fallback on any system.
var test_watched = false;

/// `Io.net.Stream.Reader`, but each read waits at most until the
/// connection's deadline (`operateTimed`).
const SocketReader = struct {
    io: Io,
    conn: *Client.Conn,
    interface: Io.Reader,
    err: ?ReadError = null,

    pub const ReadError = Io.Operation.NetRead.Error || Io.OperateTimeoutError;

    fn init(conn: *Client.Conn, io: Io, buffer: []u8) SocketReader {
        return .{ .io = io, .conn = conn, .interface = .{
            .vtable = &.{ .stream = stream, .readVec = readVec },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        } };
    }

    fn stream(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn readVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const r: *SocketReader = @alignCast(@fieldParentPtr("interface", io_r));
        var iovecs: [8][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs, data);
        const done = operateTimed(r.io, .{ .net_read = .{
            .socket_handle = r.conn.stream.socket.handle,
            .data = iovecs[0..dest_n],
        } }, r.conn.deadline) catch |err| {
            r.err = err;
            return error.ReadFailed;
        };
        const result = done.net_read catch |err| {
            r.err = err;
            return error.ReadFailed;
        };
        if (result.data_len == 0) return error.EndOfStream;
        if (result.data_len > data_size) {
            io_r.end += result.data_len - data_size;
            return data_size;
        }
        return result.data_len;
    }
};

/// `Io.net.Stream.Writer`, but each write waits at most until the
/// connection's deadline (a node that stops reading mid-put).
const SocketWriter = struct {
    io: Io,
    conn: *Client.Conn,
    interface: Io.Writer,
    err: ?WriteError = null,

    pub const WriteError = Io.Operation.NetWrite.Error || Io.OperateTimeoutError;

    fn init(conn: *Client.Conn, io: Io, buffer: []u8) SocketWriter {
        return .{ .io = io, .conn = conn, .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const w: *SocketWriter = @alignCast(@fieldParentPtr("interface", io_w));
        const done = operateTimed(w.io, .{ .net_write = .{
            .socket_handle = w.conn.stream.socket.handle,
            .header = io_w.buffered(),
            .data = data,
            .splat = splat,
        } }, w.conn.deadline) catch |err| {
            w.err = err;
            return error.WriteFailed;
        };
        const n = done.net_write catch |err| {
            w.err = err;
            return error.WriteFailed;
        };
        return io_w.consume(n);
    }
};

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r\n");
}

/// Sec-WebSocket-Accept for a Sec-WebSocket-Key (RFC 6455 4.2.2).
fn acceptKey(key: []const u8) [28]u8 {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    sha1.final(&digest);
    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &digest);
    return out;
}

// ---- frames (RFC 6455 5.2) ----

const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    connection_close = 8,
    ping = 9,
    pong = 10,
    _,

    fn isControl(op: Opcode) bool {
        return @backingInt(op) >= 8;
    }
};

const Header = struct {
    fin: bool,
    opcode: Opcode,
    len: u64,
    mask: ?[4]u8,
};

fn readHeader(in: *Io.Reader) !Header {
    const b = try in.takeArray(2);
    if (b[0] & 0x70 != 0) return error.ProtocolError; // RSV bits: no extension was negotiated
    var h: Header = .{
        .fin = b[0] & 0x80 != 0,
        .opcode = @fromBackingInt(@as(u4, @truncate(b[0]))),
        .len = b[1] & 0x7f,
        .mask = null,
    };
    switch (h.len) {
        126 => h.len = std.mem.readInt(u16, try in.takeArray(2), .big),
        127 => {
            h.len = std.mem.readInt(u64, try in.takeArray(8), .big);
            if (h.len >> 63 != 0) return error.ProtocolError;
        },
        else => {},
    }
    if (b[1] & 0x80 != 0) h.mask = (try in.takeArray(4)).*;
    if (h.opcode.isControl() and (!h.fin or h.len > 125)) return error.ProtocolError;
    return h;
}

fn writeHeader(out: *Io.Writer, opcode: Opcode, fin: bool, len: u64, mask: [4]u8) Io.Writer.Error!void {
    var b: [14]u8 = undefined;
    b[0] = @as(u8, if (fin) 0x80 else 0) | @backingInt(opcode);
    var n: usize = 2;
    if (len < 126) {
        b[1] = 0x80 | @as(u8, @intCast(len));
    } else if (len <= 0xffff) {
        b[1] = 0x80 | 126;
        std.mem.writeInt(u16, b[2..4], @intCast(len), .big);
        n = 4;
    } else {
        b[1] = 0x80 | 127;
        std.mem.writeInt(u64, b[2..10], len, .big);
        n = 10;
    }
    @memcpy(b[n..][0..4], &mask);
    try out.writeAll(b[0 .. n + 4]);
}

/// Writes `data` masked, as if it started `offset` bytes into the payload.
fn writeMasked(out: *Io.Writer, data: []const u8, mask: [4]u8, offset: usize) Io.Writer.Error!void {
    var buf: [4096]u8 = undefined;
    var i: usize = 0;
    while (i < data.len) {
        const n = @min(buf.len, data.len - i);
        @memcpy(buf[0..n], data[i..][0..n]);
        applyMask(buf[0..n], mask, offset + i);
        try out.writeAll(buf[0..n]);
        i += n;
    }
}

/// One unfragmented, masked frame (client to server).
fn writeFrame(out: *Io.Writer, opcode: Opcode, payload: []const u8, mask: [4]u8) Io.Writer.Error!void {
    try writeHeader(out, opcode, true, payload.len, mask);
    try writeMasked(out, payload, mask, 0);
}

fn applyMask(data: []u8, mask: [4]u8, offset: usize) void {
    for (data, offset..) |*b, i| b.* ^= mask[i % 4];
}

// ---- responses ----

/// What a delegate sent back for one message (`Client.sendToDelegate`).
pub const DelegateReply = struct {
    /// Its replies (`OutboundDelegateMsg::ApplicationMessage` payloads), in order.
    payloads: []const []const u8,
    /// Its questions for the user that the node didn't show itself (a node in
    /// local mode hands them to the client): answer with `respondToDelegate`.
    prompts: []const Prompt,

    pub const Prompt = struct {
        request_id: u32,
        message: []const u8,
        /// The answers offered, as the delegate named them.
        labels: []const []const u8,
    };

    pub fn deinit(r: DelegateReply, gpa: Allocator) void {
        for (r.payloads) |p| gpa.free(p);
        gpa.free(r.payloads);
        for (r.prompts) |p| {
            gpa.free(p.message);
            for (p.labels) |l| gpa.free(l);
            gpa.free(p.labels);
        }
        gpa.free(r.prompts);
    }

    /// Decodes a Vec<OutboundDelegateMsg>, as freenet.js does: replies and
    /// prompts; it stops at any other variant (none is meant for the client).
    fn decode(gpa: Allocator, values: []const u8) (bincode.Error || Allocator.Error)!DelegateReply {
        var arena: std.heap.ArenaAllocator = .init(gpa); // only for the lists while decoding
        defer arena.deinit();
        var payloads: std.ArrayList([]const u8) = .empty;
        var prompts: std.ArrayList(Prompt) = .empty;
        errdefer {
            const partial: DelegateReply = .{ .payloads = payloads.items, .prompts = prompts.items };
            for (partial.payloads) |p| gpa.free(p);
            for (partial.prompts) |p| {
                gpa.free(p.message);
                for (p.labels) |l| gpa.free(l);
                gpa.free(p.labels);
            }
        }
        var r: bincode.Reader = .init(values);
        const n = try r.int(u64);
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            switch (try r.tag()) {
                0 => { // ApplicationMessage { payload, context, processed }
                    const payload = try r.bytes();
                    _ = try r.bytes();
                    _ = try r.int(u8);
                    try payloads.ensureUnusedCapacity(arena.allocator(), 1);
                    payloads.appendAssumeCapacity(try gpa.dupe(u8, payload));
                },
                1 => { // RequestUserInput { request_id, message, responses: Vec<ClientResponse> }
                    const request_id = try r.int(u32);
                    const message = try r.bytes();
                    const count = try r.int(u64);
                    if (count > r.remaining() / 8) return error.EndOfStream;
                    const labels = try gpa.alloc([]const u8, @intCast(count));
                    var made: usize = 0;
                    errdefer {
                        for (labels[0..made]) |l| gpa.free(l);
                        gpa.free(labels);
                    }
                    while (made < labels.len) : (made += 1) labels[made] = try gpa.dupe(u8, try r.bytes());
                    const msg_copy = try gpa.dupe(u8, message);
                    errdefer gpa.free(msg_copy);
                    try prompts.append(arena.allocator(), .{ .request_id = request_id, .message = msg_copy, .labels = labels });
                },
                else => break,
            }
        }
        const out_payloads = try gpa.dupe([]const u8, payloads.items);
        errdefer gpa.free(out_payloads);
        const out_prompts = try gpa.dupe(Prompt, prompts.items);
        return .{ .payloads = out_payloads, .prompts = out_prompts };
    }
};

/// A `ClientError` from the node, as freenet.js names it: `kind` is the
/// node's variant name.
const Failure = struct {
    kind: []const u8,
    contract: ?[32]u8 = null,
    cause: []const u8 = "",

    /// The node's ways of saying it doesn't have the contract.
    fn isNotFound(f: Failure, id: [32]u8) bool {
        if (f.contract) |k| if (!std.mem.eql(u8, &k, &id)) return false;
        return std.mem.eql(u8, f.kind, "MissingContract") or
            (std.mem.eql(u8, f.kind, "Get") and std.ascii.findIgnoreCase(f.cause, "not found") != null);
    }

    fn format(f: Failure, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll(f.kind);
        if (f.contract) |k| {
            var buf: [64]u8 = undefined;
            try w.print(" {s}", .{types.encodeBase58(&buf, &k)});
        }
        if (f.cause.len > 0) try w.print(": {s}", .{f.cause});
    }
};

const error_kinds = [_][]const u8{ "ChannelClosed", "DeserializationError", "Disconnect", "IncorrectState", "NodeUnavailable", "TransportProtocolDisconnect", "Unhandled", "UnknownClient", "RequestError", "OperationError", "FailedOperation", "Shutdown", "EmptyRing", "PeerNotJoined" };

/// `Result<HostResponse, ClientError>`: the parts the client uses. Slices
/// point into `msg`.
fn decodeResponse(msg: []const u8) bincode.Error!Client.Response {
    var r: bincode.Reader = .init(msg);
    if (try r.tag() != 0) return .{ .failure = decodeClientError(&r) catch .{ .kind = "Unknown" } };
    switch (try r.tag()) {
        0 => {}, // ContractResponse, below
        1 => { // DelegateResponse { key: DelegateKey { key, code_hash }, values }
            const key = try r.array(32);
            _ = try r.raw(32);
            return .{ .delegate = .{ .key = key, .values = r.buf[r.pos..] } };
        },
        3 => return .ok,
        else => return .other,
    }
    switch (try r.tag()) {
        0 => { // GetResponse { key, contract: Option<ContractContainer>, state }
            const key = try decodeKey(&r);
            switch (try r.int(u8)) {
                0 => {},
                1 => { // ContractContainer::Wasm(V1(WrappedContract { data, params, key }))
                    _ = try r.tag();
                    _ = try r.tag();
                    _ = try r.bytes();
                    _ = try r.raw(32);
                    _ = try r.bytes();
                    _ = try r.raw(64);
                },
                else => return error.InvalidOption,
            }
            return .{ .get = .{ .key = key, .state = try r.bytes() } };
        },
        1 => return .{ .put = try decodeKey(&r) }, // PutResponse { key }
        3 => { // UpdateResponse { key, summary }
            const key = try decodeKey(&r);
            return .{ .updated = .{ .key = key, .summary = try r.bytes() } };
        },
        5 => return .{ .not_found = try r.array(32) }, // NotFound { instance_id }
        else => return .other,
    }
}

fn decodeKey(r: *bincode.Reader) bincode.Error!Client.Key {
    return .{ .id = try r.array(32), .code_hash = try r.array(32) };
}

fn decodeClientError(r: *bincode.Reader) bincode.Error!Failure {
    const tag = try r.tag();
    var f: Failure = .{ .kind = if (tag < error_kinds.len) error_kinds[tag] else "Unknown" };
    switch (tag) {
        1, 6, 9 => f.cause = try r.bytes(), // { cause }
        3 => f.contract = (try decodeKey(r)).id, // IncorrectState(ContractKey)
        8 => switch (try r.tag()) { // RequestError
            0 => { // ContractError
                const v = try r.tag();
                if (v <= 3) { // Get / Put / Update / Subscribe { key: ContractKey, cause }
                    f.kind = ([_][]const u8{ "Get", "Put", "Update", "Subscribe" })[v];
                    f.contract = (try decodeKey(r)).id;
                    f.cause = try r.bytes();
                } else if (v <= 6) { // ContractStackOverflow / MissingRelated / MissingContract { key: ContractInstanceId }
                    f.kind = ([_][]const u8{ "ContractStackOverflow", "MissingRelated", "MissingContract" })[v - 4];
                    f.contract = try r.array(32);
                } else f.kind = "ContractError";
            },
            1 => switch (try r.tag()) { // DelegateError, named as freenet.js names them
                0 => { // RegisterError(DelegateKey { key, code_hash })
                    f.kind = "RegisterError";
                    f.contract = try r.array(32);
                    _ = try r.raw(32);
                },
                1 => { // ExecutionError(cause): the delegate's own message
                    f.kind = "DelegateExecutionError";
                    f.cause = try r.bytes();
                },
                2 => { // Missing(DelegateKey { key, code_hash })
                    f.kind = "MissingDelegate";
                    f.contract = try r.array(32);
                    _ = try r.raw(32);
                },
                3 => { // MissingSecret { key: DelegateKey, secret }
                    f.kind = "MissingSecret";
                    f.contract = try r.array(32);
                    _ = try r.raw(32);
                    f.cause = try r.bytes();
                },
                else => f.kind = "DelegateError",
            },
            2 => f.kind = "Disconnect",
            3 => f.kind = "Timeout",
            else => {},
        },
        else => {},
    }
    return f;
}

/// Streamed responses being put back together, by stream id.
const Reassembly = struct {
    streams: std.ArrayList(Stream) = .empty,

    const Stream = struct {
        id: u32,
        parts: []?[]u8,
        received: u32 = 0,
        bytes: usize = 0,
    };

    const max_streams = 8;
    const max_chunks = 1 << 16;

    fn deinit(a: *Reassembly, gpa: Allocator) void {
        for (a.streams.items) |*s| freeStream(gpa, s);
        a.streams.deinit(gpa);
    }

    fn freeStream(gpa: Allocator, s: *Stream) void {
        for (s.parts) |p| if (p) |b| gpa.free(b);
        gpa.free(s.parts);
    }

    /// Adds a chunk; returns the whole serialized response (caller owns it)
    /// once every chunk is in.
    fn add(a: *Reassembly, gpa: Allocator, id: u32, index: u32, total: u32, data: []const u8) !?[]u8 {
        if (total == 0 or total > max_chunks or index >= total) return error.BadResponse;
        const s = for (a.streams.items) |*s| {
            if (s.id == id) break s;
        } else blk: {
            if (a.streams.items.len == max_streams) return error.BadResponse;
            const parts = try gpa.alloc(?[]u8, total);
            @memset(parts, null);
            errdefer gpa.free(parts);
            try a.streams.append(gpa, .{ .id = id, .parts = parts });
            break :blk &a.streams.items[a.streams.items.len - 1];
        };
        if (s.parts.len != total) return error.BadResponse;
        if (s.parts[index] != null) return null; // a repeat
        if (data.len > max_message_len - s.bytes) return error.MessageTooLong;
        s.parts[index] = try gpa.dupe(u8, data);
        s.received += 1;
        s.bytes += data.len;
        if (s.received < total) return null;

        const whole = try gpa.alloc(u8, s.bytes);
        var off: usize = 0;
        for (s.parts) |p| {
            @memcpy(whole[off..][0..p.?.len], p.?);
            off += p.?.len;
        }
        freeStream(gpa, s);
        _ = a.streams.swapRemove(@intCast(s - a.streams.items.ptr));
        return whole;
    }
};

// ---- tests (frames; the request and response bytes are in tests.zig) ----

const testing = std.testing;

test "timeout: a node that accepts and never answers" {
    try acceptsAndNeverAnswers();
}

test "timeout: a request whose answer never comes" {
    try answerNeverComes();
}

test "timeout without timed socket operations (Windows): the task is canceled at the deadline" {
    test_watched = true;
    defer test_watched = false;
    try acceptsAndNeverAnswers();
    try answerNeverComes(); // the handshake's write and reads go through the fallback too
}

fn acceptsAndNeverAnswers() !void {
    const io = std.testing.io;
    var addr: Io.net.IpAddress = try .parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    // the kernel completes the TCP handshake from the backlog: nobody accepts or answers
    const port = server.socket.address.getPort();
    const t0 = Io.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Timeout, Client.connectWith(std.testing.allocator, io, "127.0.0.1", port, .{ .timeout = .fromMilliseconds(300) }));
    const ms = Io.Timestamp.now(io, .awake).toMilliseconds() - t0.toMilliseconds();
    try std.testing.expect(ms >= 250 and ms < 5000);
}

fn answerNeverComes() !void {
    const io = std.testing.io;
    var addr: Io.net.IpAddress = try .parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();
    // answer the handshake, then stay silent
    const Node = struct {
        fn run(srv: *Io.net.Server, io_: Io) void {
            const s = srv.accept(io_) catch return;
            var rbuf: [4096]u8 = undefined;
            var r = s.reader(io_, &rbuf);
            var key: []const u8 = "";
            var key_buf: [64]u8 = undefined;
            while (r.interface.takeDelimiterInclusive('\n')) |line| {
                const l = trimLine(line);
                if (l.len == 0) break;
                if (std.ascii.startsWithIgnoreCase(l, "sec-websocket-key:")) {
                    const v = std.mem.trim(u8, l["sec-websocket-key:".len..], " ");
                    @memcpy(key_buf[0..v.len], v);
                    key = key_buf[0..v.len];
                }
            } else |_| return;
            var wbuf: [512]u8 = undefined;
            var w = s.writer(io_, &wbuf);
            w.interface.print("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{&acceptKey(key)}) catch return;
            w.interface.flush() catch return;
            io_.sleep(.fromSeconds(3), .awake) catch {};
            s.close(io_);
        }
    };
    var node = try io.concurrent(Node.run, .{ &server, io });
    defer node.cancel(io);
    var c = try Client.connectWith(std.testing.allocator, io, "127.0.0.1", port, .{ .timeout = .fromMilliseconds(300) });
    defer c.close();
    const t0 = Io.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Timeout, c.get(std.testing.allocator, @splat(7)));
    const ms = Io.Timestamp.now(io, .awake).toMilliseconds() - t0.toMilliseconds();
    try std.testing.expect(ms >= 250 and ms < 2000); // at the deadline, not when the node hangs up (3 s)
    try std.testing.expect(std.mem.endsWith(u8, c.lastError(), "didn't answer in 300 ms"));
    try std.testing.expectError(error.ConnectionClosed, c.get(std.testing.allocator, @splat(7))); // given up
}

test "acceptKey: the RFC 6455 example" {
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &acceptKey("dGhlIHNhbXBsZSBub25jZQ=="));
}

test "frame header: masking and the 7-, 16- and 64-bit lengths" {
    const m: [4]u8 = .{ 0x37, 0xfa, 0x21, 0x3d };
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeFrame(&w, .text, "Hello", m);
    // RFC 6455 5.7: a masked "Hello"
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 }, w.buffered());

    w = .fixed(&buf);
    try writeHeader(&w, .binary, true, 126, m);
    try testing.expectEqualSlices(u8, &([_]u8{ 0x82, 0xfe, 0x00, 0x7e } ++ m), w.buffered());
    w = .fixed(&buf);
    try writeHeader(&w, .binary, false, 0x10000, m);
    try testing.expectEqualSlices(u8, &([_]u8{ 0x02, 0xff, 0, 0, 0, 0, 0, 1, 0, 0 } ++ m), w.buffered());

    for ([_]u64{ 0, 125, 126, 0xffff, 0x10000, 1 << 40 }) |len| {
        w = .fixed(&buf);
        try writeHeader(&w, .binary, true, len, m);
        var r: Io.Reader = .fixed(w.buffered());
        const h = try readHeader(&r);
        try testing.expectEqual(len, h.len);
        try testing.expectEqual(Opcode.binary, h.opcode);
        try testing.expectEqualSlices(u8, &m, &h.mask.?);
    }
}

test "masking across part boundaries matches masking the whole" {
    const m: [4]u8 = .{ 1, 2, 3, 4 };
    var data: [10000]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 7);
    var whole: [10000]u8 = data;
    applyMask(&whole, m, 0);
    var buf: [10000]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeMasked(&w, data[0..4099], m, 0);
    try writeMasked(&w, data[4099..], m, 4099);
    try testing.expectEqualSlices(u8, &whole, w.buffered());
}

test "readHeader rejects bad frames" {
    var r: Io.Reader = .fixed(&.{ 0xc2, 0x00 }); // RSV1
    try testing.expectError(error.ProtocolError, readHeader(&r));
    r = .fixed(&.{ 0x09, 0x00 }); // fragmented ping
    try testing.expectError(error.ProtocolError, readHeader(&r));
    r = .fixed(&.{ 0x89, 0x7e, 0x00, 0x7e }); // ping over 125 bytes
    try testing.expectError(error.ProtocolError, readHeader(&r));
    r = .fixed(&.{ 0x82, 0x7f, 0x80, 0, 0, 0, 0, 0, 0, 0 }); // 64-bit length with the top bit set
    try testing.expectError(error.ProtocolError, readHeader(&r));
}

/// Unmasked server frame.
fn serverFrame(comptime fin: bool, comptime opcode: u4, comptime payload: []const u8) [2 + payload.len]u8 {
    comptime std.debug.assert(payload.len < 126);
    return [_]u8{ @as(u8, if (fin) 0x80 else 0) | opcode, payload.len } ++ payload[0..payload.len].*;
}

test "readMessage: fragments joined, pings answered in between, a 16-bit length" {
    const big: [300]u8 = @splat(0xab);
    const input = serverFrame(false, 2, "ab") ++
        serverFrame(true, 9, "hi") ++ // ping between fragments
        serverFrame(false, 0, "cd") ++
        [_]u8{ 0x80, 126, 0x01, 0x2c } ++ big; // final continuation, 300 bytes
    var in: Io.Reader = .fixed(&input);
    var out_buf: [64]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    var c: Client = .init(testing.allocator, testing.io, &in, &out);
    c.fixed_mask = .{ 0, 0, 0, 0 };
    const msg = try c.readMessage(testing.allocator);
    defer testing.allocator.free(msg);
    try testing.expectEqualSlices(u8, "abcd" ++ big, msg);
    try testing.expectEqualSlices(u8, &.{ 0x8a, 0x82, 0, 0, 0, 0, 'h', 'i' }, out.buffered()); // the pong
}

test "readMessage: a close frame is echoed and ends the connection" {
    var in: Io.Reader = .fixed(&serverFrame(true, 8, &.{ 0x03, 0xe9, 'b', 'y', 'e' }));
    var out_buf: [64]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    var c: Client = .init(testing.allocator, testing.io, &in, &out);
    c.fixed_mask = .{ 0, 0, 0, 0 };
    try testing.expectError(error.ConnectionClosed, c.readMessage(testing.allocator));
    try testing.expectEqualSlices(u8, &.{ 0x88, 0x82, 0, 0, 0, 0, 0x03, 0xe9 }, out.buffered());
    try testing.expectError(error.ConnectionClosed, c.get(testing.allocator, @splat(0)));
}

test "readMessage: a continuation without a start, and a truncated stream" {
    var in: Io.Reader = .fixed(&serverFrame(true, 0, "x"));
    var out_buf: [64]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    var c: Client = .init(testing.allocator, testing.io, &in, &out);
    try testing.expectError(error.ProtocolError, c.readMessage(testing.allocator));

    in = .fixed(&.{ 0x82, 10, 'a' });
    c = .init(testing.allocator, testing.io, &in, &out);
    try testing.expectError(error.ConnectionClosed, c.readMessage(testing.allocator));
}

test "handshake response: accepted, and refused" {
    const ok = "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\n" ++
        "sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n" ++ serverFrame(true, 2, "x");
    var in: Io.Reader = .fixed(ok);
    var out_buf: [64]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    var c: Client = .init(testing.allocator, testing.io, &in, &out);
    try c.readHandshakeResponse("dGhlIHNhbXBsZSBub25jZQ==");
    const msg = try c.readMessage(testing.allocator); // the bytes after the headers stay readable
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings("x", msg);

    in = .fixed("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: wrong\r\n\r\n");
    try testing.expectError(error.HandshakeFailed, c.readHandshakeResponse("dGhlIHNhbXBsZSBub25jZQ=="));

    in = .fixed("HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\n\r\n");
    try testing.expectError(error.HandshakeFailed, c.readHandshakeResponse("dGhlIHNhbXBsZSBub25jZQ=="));
    try testing.expectEqualStrings("HTTP/1.1 404 Not Found", c.lastError());
}

test "reassembly: chunks out of order, repeats ignored" {
    var a: Reassembly = .{};
    defer a.deinit(testing.allocator);
    try testing.expect(try a.add(testing.allocator, 7, 1, 3, "bb") == null);
    try testing.expect(try a.add(testing.allocator, 9, 0, 2, "x") == null); // another stream
    try testing.expect(try a.add(testing.allocator, 7, 1, 3, "bb") == null);
    try testing.expect(try a.add(testing.allocator, 7, 0, 3, "a") == null);
    const whole = (try a.add(testing.allocator, 7, 2, 3, "ccc")).?;
    defer testing.allocator.free(whole);
    try testing.expectEqualStrings("abbccc", whole);
    try testing.expectEqual(@as(usize, 1), a.streams.items.len);
    try testing.expectError(error.BadResponse, a.add(testing.allocator, 9, 2, 2, "y"));
}

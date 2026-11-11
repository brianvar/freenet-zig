# Internals

How the library maps onto Freenet's low-level interfaces. You need this only to
extend the library or debug at the byte level.

Sources of truth:

- the raw ABI: <https://freenet.org/build/manual/contract-abi>
- the types: `freenet-stdlib` (`rust/src/delegate_interface.rs`, `contract_interface/`, `client_api/`)
- the runtime: `freenet-core` (`crates/core/src/wasm_runtime/`)

## Module layout

| File | |
|---|---|
| `src/freenet.zig` | public API (re-exports) |
| `src/abi.zig` | buffers, result structs, allocator, export name lists |
| `src/bincode.zig` | bincode 1.x encoder/decoder |
| `src/delegate.zig` | delegate types, wire codecs, `exportDelegate` |
| `src/contract.zig` | contract types, wire codecs, `exportContract` |
| `src/host.zig` | node imports (random, log, context, secrets) and their native stand-ins |
| `src/types.zig` | ids, key derivation (BLAKE3), base58 |
| `src/webapp.zig` | web-app state layout, tar, stored xz, signed-site metadata (CBOR) and verification |
| `src/webcontainer.zig` | the built-in signed web contract |
| `src/testing.zig` | the native harness (and the codecs only tests need) |
| `src/client.zig` | native WebSocket client for the node's API (`get`, `update`, `put`; delegates: `registerDelegate`, `sendToDelegate`, `respondToDelegate`, whose messages a delegate sees with origin `none`, so `requireApp` refuses them), for tools beside the node; an optional per-request timeout (`connectWith(..., .{ .timeout = ... })`; on Windows, where Zig 0.17 can't time socket operations, each read and write runs on a task canceled at the deadline) |
| `src/tests.zig` | byte-exact wire-format tests |
| `tools/` | `freenet-pack`, `freenet-check-wasm` |
| `js/freenet.js` | browser client |
| `js/test.html` | browser tests for the client (open the file; fake WebSocket) |

## The Wasm ABI

**Memory.** The module exports `memory`. Pointers are wasm32 offsets widened to
`i64`.

**Buffers.** For each input, the node calls `__frnt__initiate_buffer(len)`. The
module allocates a `BufferBuilder` and returns its address:

```
offset 0  start      i64  pointer to the data
offset 8  capacity   u32
offset 16 last_read  i64  pointer to a u32
offset 24 last_write i64  pointer to a u32: bytes written by the host
```

The node copies the payload to `start` and sets `*last_write`. `abi.input(ptr)`
reads it back.

**Results.** Entry points return a pointer to a result struct:

```
contract: { ptr: i64, kind: i32, size: u32 }   kind: 0 validate, 2 update, 3 summarize, 4 delta
delegate: { ptr: i64, size: u32, _pad: u32 }
```

`ptr`/`size` point at a bincode payload.

**Memory management.** Nothing is freed. The node drops the instance after each
call, so `abi.allocator` (Wasm's page allocator) never frees.

**Instance id.** The node calls `__frnt_set_id(id)` after instantiating. The
`freenet_rand`, `freenet_log` and `freenet_time` imports take that id; the
delegate context and secrets imports don't.

### Exports

| Kind | Exports |
|---|---|
| delegate | `process(params, origin, inbound) -> i64`, `__frnt__initiate_buffer`, `__frnt_set_id`, `memory` |
| contract | `validate_state(params, state, related)`, `update_state(params, state, updates)`, `summarize_state(params, state)`, `get_state_delta(params, state, summary)` (all `-> i64`), `__frnt__initiate_buffer`, `__frnt_set_id`, `memory` |

The build helpers export exactly these through `export_symbol_names`
(`--export=` to wasm-ld) rather than `rdynamic`. `rdynamic` also exports
toolchain globals such as `__stack_pointer`.

### Imports

| Module | Functions |
|---|---|
| `freenet_rand` | `__frnt__rand__rand_bytes(id: i64, ptr: i64, len: u32)` |
| `freenet_log` | `__frnt__logger__info(id: i64, ptr: i64, len: i32)` |
| `freenet_delegate_ctx` | `ctx_len() -> i32`, `ctx_read(ptr, len) -> i32`, `ctx_write(ptr, len) -> i32` (0 = ok) |
| `freenet_delegate_secrets` | `get_secret_len(k, kl) -> i32` (<0: missing), `get_secret(k, kl, out, ol) -> i32`, `set_secret(...) -> i32` (0 = ok), `has_secret -> i32` (1 = yes), `remove_secret -> i32` (0 = ok), `list_secrets_len`, `list_secrets` (records: `[u32 LE len][key]`) |

All names are prefixed `__frnt__` (delegate ones `__frnt__delegate__`). An
import is only emitted if your code uses the feature. A delegate that imports
`freenet_delegate_contracts` or `freenet_delegate_management` would switch the
node to its async V2 path; this library doesn't use them.

## Bincode

bincode 1.x legacy config:

- integers are fixed-width little-endian
- `Vec<u8>` and `String` are a u64 length plus the bytes
- arrays have no length prefix
- enum variants are a u32 index
- `Option` is a u8 flag; `bool` is a u8

## Wire types used

**Delegate inbound:** `InboundDelegateMsg`. Tag 0 is
`ApplicationMessage { payload: Vec<u8>, context: Bytes, processed: bool }`;
tag 1 is `UserResponse(UserInputResponse { request_id: u32, response:
ClientResponse (Bytes), context: Bytes })`; other tags are passed through as
`.unsupported`. The variant list is
append-only: 1 UserResponse, 2-6 contract responses/notifications,
7 DelegateMessage, 8 UnsubscribeContractResponse, 9 WakeupFired, 10 Lifecycle.

**Delegate origin:** empty, or `MessageOrigin`: 0 `WebApp([u8;32])`,
1 `Delegate(DelegateKey { key: [u8;32], code_hash: [u8;32] })`.

**Delegate result:** `Result<Vec<OutboundDelegateMsg>, DelegateError>`.
The library emits outbound 0, `ApplicationMessage` (sent with
`processed: true`), one per reply, then outbound 1, `RequestUserInput(
UserInputRequest { request_id: u32, message: NotificationMessage (Bytes),
responses: Vec<ClientResponse (Bytes)> })`, one per prompt; `setContext` uses the `ctx_write` host function rather
than outbound 2, `ContextUpdated`, which freenet-stdlib marks for removal.
`DelegateError` is 0 `Deser(String)` (malformed input), 1 `Other(String)`.

**Contract inputs:**

- `parameters`, `state` and `summary` are raw bytes.
- `related` is `RelatedContracts`: a u64 count, then `[u8;32]` id +
  `Option<Bytes>` per entry.
- `updates` is `Vec<UpdateData>`: 0 State, 1 Delta, 2 StateAndDelta,
  3 RelatedState, 4 RelatedDelta, 5 RelatedStateAndDelta (the related ones
  start with a `[u8;32]` id).

**Contract results:**

- validate: `Result<ValidateResult, ContractError>`, where `ValidateResult` is
  0 Valid, 1 Invalid, 2 RequestRelated(`Vec<[u8;32]>`).
- update: `Result<UpdateModification { new_state: Option<Bytes>, related: Vec<{ [u8;32], RelatedMode u32 }> }, ContractError>`.
- summarize and delta: `Result<Bytes, ContractError>`.
- `ContractError`: 0 Deser(String), 1 InvalidUpdate, 2 InvalidUpdateWithInfo{String},
  3 InvalidState, 4 InvalidDelta, 5 Other(String).

**Client API** (`freenet.js`, WebSocket `?encodingProtocol=native`):

Requests are a `ClientRequest`:

- `DelegateOp`(0)
  - `ApplicationMessages`(0){ key: DelegateKey, params, inbound: Vec }
  - `RegisterDelegate`(1){ `DelegateContainer::Wasm`(0)(`V1`(0)(Delegate { parameters, data: { data, code_hash }, key })), cipher [32], nonce [24] }.
    The node ignores `cipher` and `nonce` and derives the delegate's key itself.
- `ContractOp`(1)
  - `Put`(0){ `ContractContainer::Wasm`(0)(`V1`(0)(WrappedContract { data: { data, code_hash }, params, key: ContractKey })), state, related_contracts (map), subscribe: bool, blocking_subscribe: bool }
  - `Update`(1){ key: ContractKey { instance [32], code [32] }, data: UpdateData }
  - `Get`(2){ key: instance [32], return_contract_code, subscribe, blocking_subscribe }
  - `Subscribe`(3){ key: instance [32], summary: Option }

Responses are a `Result<HostResponse, ClientError>`:

- `ContractResponse`(0)
  - `GetResponse`(0){ key, contract: Option, state }
  - `PutResponse`(1){ key }
  - `UpdateNotification`(2){ key, update: UpdateData }
  - `UpdateResponse`(3){ key, summary }
  - `SubscribeResponse`(4){ key, subscribed }
  - `NotFound`(5){ instance_id }
- `DelegateResponse`(1){ key, values }
- `Ok`(3)
- `StreamChunk`(4){ stream_id, index, total, data }
- `StreamHeader`(5)

How the client handles responses:

- **Matching replies.** Replies carry no request id, so the client sends one
  request at a time. A response is matched to the waiting request by kind and
  key, so unsolicited extras, such as a `SubscribeResponse` after a subscribing
  `Get`, are ignored. A request that times out fails alone and is kept for
  5 minutes as an orphan: a later reply only it expects is its late answer,
  and is dropped. An error goes to the request in flight, unless it names a
  timed-out request's contract and not the one in flight's.
- **Lanes.** A connection carries one request at a time, so contract `Get`,
  `Put` and `Update` requests go out on up to `lanes` (4) extra connections,
  each a `FreenetClient` of its own with `lanes: 0`, named `lane N` (its own
  queue, timeout, orphans and liveness probe). A lane doesn't reconnect: one
  the node drops leaves its slot, the next request opens a new one, and a
  `Get` that was out on it is sent again once (`_contractRequest`'s `retry`;
  writes aren't repeated). The lane is the
  contract id's first byte modulo the lane count: ids are BLAKE3 hashes, so
  contracts spread evenly, and one contract's requests stay in order on one
  lane. Subscriptions belong to the connection that made them, so
  `Subscribe`, a `Get`/`Put` with `subscribe`, delegate traffic and
  notifications stay on the main connection. A lane opens on first use,
  closes after `FreenetClient.laneIdleMs` (60 s) idle, and a request whose
  lane can't open goes out on the main connection.
- **Keepalive and catch-up.** The main connection (not lanes) runs a timer:
  after `keepAliveMs` (30 s) with nothing sent or received and no request in
  flight, a `NodeQueries(ConnectedPeers)` probe through the queue; no answer
  within `probeMs` closes the socket (and reconnects). After a reconnect,
  `onopen` re-registers delegates and re-subscribes as before, then
  `_catchUp` reads every contract with listeners (on its lane) and calls them
  with `{ state, catchUp: true }`: notifications missed while disconnected
  aren't replayed by the node.
- **Liveness.** On a network node a `Get` for a contract nobody has put yet
  can go unanswered, so a timeout alone doesn't mean the node is gone. Before
  the next request after a timeout, the client checks: anything the node sent
  since says it's there; otherwise it sends `NodeQueries(ConnectedPeers)`,
  which the node answers at once (any answer counts, an error too). Nothing
  within `FreenetClient.probeMs` (10 s): the connection is closed (and
  reconnects, if enabled) and the request waits for the new one.
  Subscriptions on the connection survive a timeout.
- **Notifications** (`UpdateNotification`) go to subscribers.
- **Large responses.** Responses over 512 KiB arrive as `StreamChunk`s of the
  serialized response, optionally preceded by a `StreamHeader`; the client
  concatenates the chunks and parses the result. Requests up to 100 MB are
  accepted unchunked.
- **Contract ids in the browser.** `freenet.js` includes BLAKE3 (checked against
  the official BLAKE3 test vectors across chunk and tree boundaries, in
  `js/test.html`) to derive instance ids from code hash and parameters.
- **The sandbox.** freenet-core serves pages in an iframe without
  `allow-same-origin` and injects a WebSocket shim before `</head>` that
  routes the socket through the shell page, which adds the auth token the
  node uses to attest `MessageOrigin::WebApp`. The client only touches
  `WebSocket` when `connect()` runs, so it works wherever the script tag is.

## Keys

- code hash = BLAKE3(wasm)
- contract instance id = BLAKE3(code hash ‖ parameters)
- delegate key = BLAKE3(code hash ‖ parameters)

Keys are printed in base58 (Bitcoin alphabet).

## Compatibility

freenet-stdlib's own wire-format rules (WIRE-FORMAT.md) only *append* enum
variants, so unknown variants appear here as `.unsupported` or errors, not
misreads. Appending a field to an existing struct would break this library,
just as it would break older Rust delegates. `src/tests.zig` pins every layout
the library relies on, so a format change shows up as a failing test once the
expectations are updated.

# Delegates

A delegate is a Wasm module that runs **only on the user's own node**. Use one
for anything private or local:

- holding keys and signing with them
- storing per-user data
- doing work the page shouldn't do itself
- using randomness, which contracts can't use

Web apps talk to their delegates through the node.

## The handler

```zig
const freenet = @import("freenet");

comptime {
    freenet.exportDelegate(@This());
}

pub fn handle(d: *freenet.Delegate, msg: freenet.Inbound) !void {
    // ...
}
```

`exportDelegate(T)` requires `pub fn handle(*freenet.Delegate, freenet.Inbound) !void`
on `T`, and exports `process`, `__frnt__initiate_buffer` and `__frnt_set_id`.
It does nothing in native builds, so the same file works in tests.

The node creates a fresh instance for each call. Globals don't survive between
messages; use [secrets](#secrets) for anything persistent.

## Inbound messages

```zig
pub const Inbound = union(enum) {
    application: ApplicationMessage, // from a web app (or another client)
    user_response: UserResponse,     // an answer to a prompt, see below
    contract_state: ContractState,   // a contract's state you asked for, see below
    unsupported: struct { tag: u32, raw: []const u8 },
};

pub const ApplicationMessage = struct {
    payload: []const u8,  // app-defined bytes
    context: []const u8,  // delegate context sent along (usually empty)
    processed: bool,
};
```

`payload` is whatever the page sent: text, JSON, or your own binary format.
`user_response` is covered under [Asking the user](#asking-the-user),
`contract_state` under [Reading a contract](#reading-a-contract).
`unsupported` covers the node's other message kinds (other contract responses,
notifications) that the library doesn't decode yet. Handle it with `=> {}` or
`=> return`, and the node gets an empty reply. (Lifecycle and wake-up events
are sent only to delegates that declare them in a manifest, which this library
can't emit yet, so they never arrive.)

## Replying

```zig
try d.reply("plain bytes");
try d.replyFmt("{d} items", .{n});
```

Each reply becomes an `ApplicationMessage` delivered back to the app. A call
can reply zero, one or several times; the page receives all of them, in order.

## Asking the user

A delegate can ask the node to show the user a prompt, drawn by the node's
own page outside every app's sandboxed page, so an app can't fake it or
hide it:

```zig
const id = try freenet.random.int(u32);
try d.secrets().set("pending", ...); // what the prompt is for, and `id`
try d.requestUserInput(id, "Send 30 to 6b34…f93d?", &.{ "Cancel", "Send 30" });
```

The node shows the message and one button per response (a response's bytes
are its label), waits for a click (60 s on current nodes), then calls the
delegate again with `.user_response`:

```zig
pub const UserResponse = struct {
    request_id: u32,
    response: []const u8, // the chosen response's bytes; empty: refused or timed out
    context: []const u8,  // always empty; use d.context() or secrets
};
```

Replies from both calls go back to the app's original request, so the page
gets one answer. While the prompt is open the node holds back other messages
to this delegate (they wait, up to the timeout). The page needs a longer
timeout for such a message: `handle.send(bytes, { timeoutMs: 90000 })`.

**A `.user_response` is not proof the user clicked.** Current nodes let a web
app send `UserResponse` messages itself, with any id and any bytes. So:

- Use a random `request_id` (the app never sees the prompt, so it can't
  learn it), and save the pending action with its id in a secret *before*
  returning the prompt.
- Accept an answer only if its id matches the saved one and its bytes equal
  the approving label. Remove the saved action on *every* answer, matching
  or not, so a guess costs the attacker the request.
- Put the safe choice first: test prompters answer with the first response.

**Only network nodes prompt.** A node in local mode (`freenet local`, as of
0.2.154) skips prompts: it returns the `RequestUserInput` to the app with the
reply, id and labels included, and never calls the delegate back. The app
can then answer it itself (freenet.js: `PromptNotShown`, `respond`), so on
such a node a prompt is only as trustworthy as the page. The delegate can't
tell the two kinds of node apart.

Limits: 1 to 10 responses of 1 to 64 bytes, and a message of at most 2048
bytes. `requestUserInput` fails beyond them, because the node would cut the
text silently. The message is shown as UTF-8 text (or a JSON string, if it
parses as one); control characters other than newlines are dropped.

## Reading a contract

A delegate can read a contract's current state, for example to check a request
against what the network holds rather than what the page says:

```zig
const nonce = ...; // random bytes, saved in a secret with what the read is for
try d.secrets().set("pending-read", ...);
try d.getContract(contract_id, &nonce); // the context comes back unchanged
```

The node looks in its own store first, then on the network, and calls the
delegate again with `.contract_state`:

```zig
pub const ContractState = struct {
    contract_id: ContractInstanceId,
    state: ?[]const u8, // null: not found, or the node's request failed (it doesn't say which)
    context: []const u8, // what you passed to getContract
};
```

The request is sent after the call's replies and prompts (the node handles it
once the call returns); the context is at most 400 KiB
(`DelegateContext::MAX_SIZE`).

**What nodes do with it (checked 2026-11-06, freenet 0.2.155).** A network
node calls the delegate back within milliseconds for a contract it holds (and
with a null state for one it can't find), and replies made in that call reach
the app's original request: the app gets one answer, as with prompts (checked
on a network-mode gateway with no peers, in Hive's node tests). A node in
local mode (`freenet local`) never calls back: it answers the app's request
as soon as the first call returns, with that call's replies only, and drops
the request. So a delegate that reads a contract before replying gives a
local node's app an empty answer, and the app should have a fallback.

**A `.contract_state` is not proof the node sent it**: an app can send this
message itself, with any state. Put a random value in the context, save it
before returning, accept an answer only with that value, and clear it on every
answer. The id of a contract is `BLAKE3(code hash ‖ parameters)`: a delegate
that must read one particular contract computes it from that contract's code
hash, not from an id the page passes.

In tests, `freenet.testing.contractRequests()` lists what the last call asked
for, and `freenet.testing.contractState(Impl, request, state, .{})` answers.

## Subscribing to a contract

A delegate can ask its node to keep a contract:

```zig
try d.subscribeContract(contract_id); // sent after the call's replies and reads
```

**What the node does with it (checked 2026-11-12 in freenet-core `201a62bc`,
0.2.156; paths under `crates/core/src/`).** The subscription counts as local
demand exactly like a connected client's (`contract.rs`,
`record_delegate_demand`), so the node keeps hosting the contract and renews
it on the network. Unlike a client's, it never ends: it outlives the app's
connection, is stored, and is restored when the node restarts
(`wasm_runtime/delegate_subscriptions.rs`, #5493). There is no unsubscribe
yet (#5600: the node fails a call that sends `UnsubscribeContractRequest`).
Subscribing again to a contract already subscribed changes nothing.

- **The node answers in a new call**: a `SubscribeContractResponse`, which
  reaches `handle` as `.unsupported` with tag 5. Every later change of the
  contract calls the delegate with its new state, a `ContractNotification`
  (tag 6). Both can be ignored; a delegate subscribed to busy contracts runs
  on each change.
- **Subscribe only to contracts the node holds.** For one it holds, the call's
  replies go out at once. For one it doesn't, the node fetches it from the
  network first and, until that finishes (up to about a minute for one that
  isn't there), holds back the call's replies and queues every other message
  to the delegate (`contract/delegate_park.rs`). At most 4 such network
  subscriptions per call; the rest are refused.
- **256 contracts per delegate** (`MAX_CONTRACT_SUBSCRIPTIONS_PER_DELEGATE`).
  Past that, the node drops the subscription it notified least recently,
  silently; a contract that never changes keeps the time it was subscribed,
  so the oldest such one goes first. Subscribing again doesn't refresh it.

The same rule as for reading applies: compute the id from the contract's code
hash and parameters yourself rather than taking it from a page, or any page
of the app can spend the delegate's 256 subscriptions.

In tests, `freenet.testing.subscriptions()` lists what the last call
subscribed to.

## Origin: who's asking

```zig
switch (d.origin) {
    .web_app => |contract_id| {}, // the web app's contract instance id
    .delegate => |key| {},        // another delegate (key + code hash)
    .none => {},                  // no origin given
    .unknown => |tag| {},
}
```

The node attests the origin, so you can trust it.

**Any site on the user's node can message your delegate.** Its key is printed in
`site.txt` and embedded in your page, so another web app can register it and
send it anything. So check where a message comes from before you do anything
sensitive, such as signing or revealing a secret:

```zig
try d.requireApp();   // fails the call unless the message is from this delegate's own web app
```

This works because `freenet-pack` sets each embedded delegate's
`d.parameters` to its web app's contract id (32 bytes), and the node attests
the sender's id in `d.origin`. `requireApp` compares the two, and fails closed:
no parameters, another site, another delegate or no origin are all refused.
Another site can register your delegate's code with its own parameters, but
then it is a different delegate (the key includes the parameters) with its own,
empty secrets.

Delegates not built through `addWebApp` have no app id; check `d.origin`
yourself.

## Upgrades

A delegate's key is BLAKE3(code hash ‖ parameters), so any change to its Wasm
(your code, this library, the Zig version) makes a new delegate with empty
secrets. The old one is still on the users' nodes with its secrets, and its
parameters are the app's id, which stays the same across builds as long as
the signing key and the web container do. So a new build can carry the
secrets over: keep the code hash of each released build of the delegate, and
in the page ask each earlier one, by `client.delegateAt(codeHash)`, for what
it holds (with messages it already answers), then hand that to the new one.
The earlier delegate's `requireApp` lets the new page in, since it is the same
app.

Record in the new delegate which earlier builds are done, and only once
everything has arrived; treat an error or no answer as "try again next
time", never as "empty" (a node that doesn't have the delegate answers with an
error). Keep the messages the earlier builds answer, and their encoding,
working in your page for as long as users may have those builds.

## Errors

Any error returned from `handle` fails the call. The app receives
`DelegateError::Other(message)`, and `freenet.js` throws a
`FreenetClient.Error` whose `message` is that message:

- `return d.fail("insufficient balance")` sends that message.
- Any other error (`return error.Overflow`) sends its name, `"Overflow"`.
- Malformed input never reaches `handle`; the app gets
  `DelegateError::Deser("EndOfStream")` or similar.

## Randomness

```zig
const n = try freenet.random.intRange(u32, 1, 6); // inclusive, unbiased
const x = try freenet.random.int(u64);
var key: [32]u8 = undefined;
try freenet.random.bytes(&key);
```

The node supplies cryptographically secure bytes. `error.RandUnavailable` means
the node never sent this instance its id, which shouldn't happen on a real node;
returning the error is better than silently using zeros.

## Secrets

Persistent, encrypted key/value storage on the user's node, private to this
delegate:

```zig
const s = d.secrets();
try s.set("signing-key", key_bytes);
if (try s.get("signing-key")) |key| { ... }  // ?[]const u8
const exists = s.has("signing-key");
_ = s.remove("signing-key");                 // true if it existed
const keys = try s.list("room:");            // keys with this prefix
```

Secrets are tied to the delegate's key, which is a hash of its Wasm code. **A
rebuilt delegate is a new delegate and can't see the old one's secrets.** That
includes rebuilding the same source with another Zig version or optimize mode.
Plan releases accordingly, for example by keeping the delegate's code stable.

Two apps that embed the same delegate binary share one delegate, and so one
set of secrets.

## Context

Scratch state that lives for one batch of messages, not across calls:

```zig
const ctx = try d.context(); // read
try d.setContext("step-2");  // replace
```

Both go through the node's context functions, so in tests `freenet.testing`
sees the same context (`t.context()`).

## Allocation

`d.allocator` is valid for the whole call and is freed by the node when the call
ends. Allocate freely and never free.

## Logging

```zig
freenet.log.info("received a message");
freenet.log.print("payload is {d} bytes", .{app.payload.len});
```

Output appears in the node's log.

## Parameters

`d.parameters` holds the delegate's parameters, which are part of its key.
Delegates embedded with `addWebApp` get their web app's contract id (32
bytes) as parameters; see [Origin](#origin-whos-asking).

## Limits and notes

- Calls are synchronous and should be short; the node enforces a time limit.
- Reading a contract (`getContract`) and subscribing to one
  (`subscribeContract`) are wrapped; the other outbound requests
  (`PutContractRequest`, `UpdateContractRequest`, `SendDelegateMessage`)
  aren't yet.
- See [testing.md](testing.md) to test all of this natively.

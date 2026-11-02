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
    unsupported: struct { tag: u32, raw: []const u8 },
};

pub const ApplicationMessage = struct {
    payload: []const u8,  // app-defined bytes
    context: []const u8,  // delegate context sent along (usually empty)
    processed: bool,
};
```

`payload` is whatever the page sent: text, JSON, or your own binary format.
`unsupported` covers the node's other message kinds (contract responses,
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
- Outbound requests to contracts and other delegates
  (`GetContractRequest`, `SendDelegateMessage`, ...) aren't wrapped yet.
- See [testing.md](testing.md) to test all of this natively.

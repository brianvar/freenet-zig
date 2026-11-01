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
notifications, lifecycle events) that the library doesn't decode yet. Handle it
with `=> {}` or `=> return`, and the node gets an empty reply.

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
    .none => {},                  // e.g. lifecycle events
    .unknown => |tag| {},
}
```

The node attests the origin, so you can trust it. For example, compare
`contract_id` with your own app's id so that only your page can use a signing
delegate.

## Errors

Any error returned from `handle` fails the call. The app receives
`DelegateError::Other(message)`, and `freenet.js` throws it as an `Error`:

- `return d.fail("insufficient balance")` sends that message.
- Any other error (`return error.Overflow`) sends its name, `"Overflow"`.
- Malformed input never reaches `handle`; the app gets `"EndOfStream"` or similar.

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
rebuilt delegate is a new delegate and can't see the old one's secrets.** Plan
releases accordingly, for example by keeping the delegate's code stable.

## Context

Scratch state that lives for one batch of messages, not across calls:

```zig
const ctx = try d.context(); // read
try d.setContext("step-2");  // replace (emits ContextUpdated)
```

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
Delegates built with `addDelegate` and embedded with `addWebApp` have empty
parameters.

## Limits and notes

- Calls are synchronous and should be short; the node enforces a time limit.
- Outbound requests to contracts and other delegates
  (`GetContractRequest`, `SendDelegateMessage`, ...) aren't wrapped yet.
- See [testing.md](testing.md) to test all of this natively.

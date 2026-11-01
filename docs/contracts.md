# Contracts

A contract defines a piece of **shared state** on the network: which states are
valid, and how updates merge. Every peer that stores the contract runs its code.
The contract's key is `BLAKE3(BLAKE3(code) || parameters)`, so code and
parameters together identify one instance.

You don't need to write a contract for a simple web app: `addWebApp` uses the
built-in [web container](web-apps.md#the-web-container). Write one when your app
has shared state, such as a chat room, a counter or a document.

## The four functions

```zig
const freenet = @import("freenet");

comptime {
    freenet.exportContract(@This());
}

pub fn validateState(c: *freenet.Contract, state: []const u8, related: freenet.RelatedContracts) !freenet.ValidateResult
pub fn updateState(c: *freenet.Contract, state: []const u8, updates: *freenet.Updates) !freenet.UpdateResult
pub fn summarizeState(c: *freenet.Contract, state: []const u8) ![]const u8
pub fn getStateDelta(c: *freenet.Contract, state: []const u8, summary: []const u8) ![]const u8
```

Build it with `freenet.addContract(b, dep, .{ .name = ..., .root_source_file = ... })`.

`c.parameters` holds the instance's parameters, and `c.allocator` is valid for
the call and never needs freeing. The state format is up to you: JSON, your own
binary format, or anything else.

### validateState

Is this state acceptable? Return `.valid`, `.invalid`, or
`.{ .request_related = ids }` to have the node fetch other contracts and call
you again with their states in `related`:

```zig
if (related.get(owner_registry_id)) |entry| {
    const registry = entry.state orelse return .invalid; // null: the node couldn't find it
    // ...
}
return .{ .request_related = try c.allocator.dupe(freenet.ContractInstanceId, &.{owner_registry_id}) };
```

### updateState

Merge updates into `state` and return the result:

```zig
var counter = try parse(state);
while (try updates.next()) |u| switch (u) {
    .delta => |d| counter += try parseDelta(d),
    .state => |s| counter = @max(counter, try parse(s)),
    .state_and_delta => |x| counter = @max(counter, try parse(x.state)),
    .related_state, .related_delta, .related_state_and_delta => {},
};
return .{ .new_state = try format(c.allocator, counter) };
```

Return `.{ .requires = &.{ .{ .id = other, .mode = .state_once } } }` if you need
another contract's state first. `.state_then_subscribe` keeps you updated as it
changes.

**The merge must be commutative.** Peers receive updates in different orders,
and must still end up with the same state. Prefer set unions, max/min, and
CRDT-style merges; avoid "last write wins" based on arrival order. The node
deprioritizes contracts whose replicas don't converge.

### summarizeState and getStateDelta

These make syncing efficient. `summarizeState` returns a small digest of what a
peer has, such as a hash, a version number or a set of message ids.
`getStateDelta(state, their_summary)` returns what that peer is missing. The
node then applies it on their side as an `Update.delta`. Keep summaries much
smaller than states; the node checks.

## Errors

Returned errors become a `ContractError` on the node:

| You return | Node sees |
|---|---|
| `c.fail("reason")` in `updateState` | `InvalidUpdateWithInfo { reason }` |
| `c.fail("reason")` elsewhere | `Other(reason)` |
| `error.InvalidUpdate` / `InvalidState` / `InvalidDelta` | the same-named variant |
| malformed input (decoding failed) | `Deser(name)` |
| any other error | `Other(error name)` |

## Determinism

Never use `freenet.random`, the clock, or anything that differs between peers
in a contract. Same inputs must give the same output everywhere.

## Example

`src/webcontainer.zig` in this library is a complete contract (about 40 lines)
with tests. The tests in `src/tests.zig` include a counter contract using
related contracts.

## Publishing and updating

```sh
fdev publish --code zig-out/bin/my_contract.wasm --parameters params.bin contract --state state.bin
```

From a web page, use the `freenet.js` contract API: `put`, `get`, `update` and
`subscribe` (see [web-apps.md](web-apps.md#contracts)). Pass the contract to
`addWebApp`'s `.contracts` so the page can create instances. Each update goes
through the node, which runs your `updateState` and propagates the result.
`examples/counter` is a complete app: a commutative counter contract plus a
page.

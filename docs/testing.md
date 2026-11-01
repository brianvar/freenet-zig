# Testing

`freenet.testing` runs delegates and contracts **natively**, without a node.

The harness plays the node's part exactly as freenet-core does. It asks the
module for buffers through `__frnt__initiate_buffer`, writes your input and sets
`last_write`, calls the generated entry point, and decodes the result struct.
Host functions go to an in-memory fake node:

- `freenet.random`: deterministic, from a fixed seed
- `freenet.log`: discarded unless you capture it
- secrets: an in-memory map
- context: an in-memory buffer

Your code is the same code that runs on Freenet; only the host behind it changes.

## Delegates

```zig
const t = freenet.testing;

test "random replies are in range" {
    t.reset();                                     // fresh fake node
    const replies = try t.ask(@This(), "random", .{});
    const n = try std.fmt.parseInt(u32, replies[0], 10);
    try std.testing.expect(n >= 1 and n <= 1000);
}
```

| Function | |
|---|---|
| `reset()` | fresh fake node: seeded random, no secrets, empty context, instance id set |
| `ask(Impl, payload, opts) ![]const []const u8` | send an `ApplicationMessage` and return the reply payloads. Fails with `error.DelegateReturnedError` (printing the message) if the delegate errored |
| `send(Impl, inbound, opts) !delegate.Result` | send any `Inbound`. Result is `.ok` (outbound messages, including `.context_updated`) or `.err` (the error message) |
| `setRandom(fn ([]u8) void)` | control randomness |
| `clearInstanceId()` | simulate a node that never called `__frnt_set_id` |
| `setLog(fn ([]const u8) void)` | capture log output |
| `putSecret(key, value)` / `secret(key)` | seed or inspect the secret store |

`opts` is `SendOptions{ .origin = ..., .parameters = ... }`. The default origin
is a web app whose id is 32 bytes of `7`.

### Forcing edge cases

```zig
test "lowest value" {
    t.reset();
    t.setRandom(struct {
        fn f(buf: []u8) void { @memset(buf, 0); }
    }.f);
    try std.testing.expectEqualStrings("1", (try t.ask(@This(), "random", .{}))[0]);
}
```

### Errors

```zig
const res = try t.send(@This(), .{ .application = .{ .payload = "bad" } }, .{});
try std.testing.expectEqualStrings("insufficient balance", res.err);
```

## Contracts

```zig
test "merges deltas" {
    const res = try t.update(@This(), params, "40", &.{ .{ .delta = "+1" }, .{ .delta = "+1" } });
    try std.testing.expectEqualStrings("42", res.ok.new_state);
}
```

| Function | Returns |
|---|---|
| `validate(Impl, params, state, related)` | `Outcome(ValidateResult)` |
| `update(Impl, params, state, []const Update)` | `Outcome(UpdateResult)` |
| `summarize(Impl, params, state)` | `Outcome([]const u8)` |
| `delta(Impl, params, state, summary)` | `Outcome([]const u8)` |

`Outcome(T)` is `.ok: T` or `.err: ContractError`, where `ContractError` is a
union of `deser`, `invalid_update`, `invalid_update_with_info`, `invalid_state`,
`invalid_delta` and `other`.

A good property test for any contract is to apply the same updates in different
orders and assert the states are equal.

## Wire-level tests

`t.raw.callDelegate(Impl, params, origin, inbound)` and
`t.raw.callContract(Impl, kind, params, state, third)` take pre-encoded bytes
and return the raw result bytes. The library's own `src/tests.zig` uses them
with hand-written expected bytes.

## Wiring into build.zig

```zig
const tests = freenet.addTests(b, dep, .{
    .sources = &.{b.path("src/delegate.zig")},
    .delegates = &.{my_delegate},
    .contracts = &.{app.contract},
});
b.step("test", "Run tests").dependOn(tests);
```

Besides your tests, this runs `freenet-check-wasm` on the compiled modules. See
[build.md](build.md#freenet-check-wasm).

## What native tests don't cover

- The page's JavaScript: test it in a browser against a local node.
- The real node's behavior. See [internals.md](internals.md#verification-status)
  for what has run on a live node.

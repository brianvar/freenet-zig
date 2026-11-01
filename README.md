# freenet-zig

Write [Freenet](https://freenet.org) delegates, contracts and web apps in Zig.

> **Unofficial.** This is a community project, not made, endorsed or supported by
> The Freenet Project. It follows the wire formats of the official Rust SDK
> (freenet-stdlib) and node (freenet-core) but is not part of them. If something
> doesn't work, check here before reporting it to Freenet.

Freenet apps are WebAssembly modules plus a web page. Freenet itself only ships
a Rust SDK. This library covers the same ground for Zig:

- **Delegates and contracts:** you write plain Zig functions, and
  `exportDelegate` / `exportContract` generate the raw Wasm ABI for them.
- **Host functions:** randomness, logging, and a delegate's secrets and context.
- **Web apps:** one `build.zig` call packs your page, delegates and a built-in
  web-container contract into a publishable site. No tar, xz, npm or Rust needed.
- **Browser client:** `freenet.js`, which lets your page message delegates and
  put, get, update and subscribe to contracts.
- **Testing:** `freenet.testing` runs your delegate or contract natively and
  plays the node's part, so `zig build test` works without a node.

Requires **Zig 0.17**.

## Example

A delegate that answers `random` with a number from 1 to 1000:

```zig
// src/delegate.zig
const std = @import("std");
const freenet = @import("freenet");

comptime {
    freenet.exportDelegate(@This());
}

pub fn handle(d: *freenet.Delegate, msg: freenet.Inbound) !void {
    const app = switch (msg) {
        .application => |a| a,
        .unsupported => return,
    };
    if (std.mem.eql(u8, app.payload, "random")) {
        try d.replyFmt("{d}", .{try freenet.random.intRange(u32, 1, 1000)});
    } else {
        try d.reply("error: unknown request");
    }
}
```

The page that calls it:

```html
<script src="freenet.js"></script>
<script>
  (async () => {
    const client = await FreenetClient.connect();
    const random = await client.delegate("random");
    const [n] = await random.sendText("random");   // "742"
  })();
</script>
```

The build:

```zig
// build.zig
const std = @import("std");
const freenet = @import("freenet");

pub fn build(b: *std.Build) void {
    const dep = b.dependencyFromBuildZig(freenet, .{});
    const random = freenet.addDelegate(b, dep, .{ .name = "random", .root_source_file = b.path("src/delegate.zig") });
    const app = freenet.addWebApp(b, dep, .{
        .page = b.path("web/index.html"),
        .signing_key = "my-app", // the key made by `fdev website init my-app`
        .delegates = &.{random},
    });
    b.getInstallStep().dependOn(app.install);
}
```

Then:

```sh
fdev website init my-app   # once: your signing key (keep it private)
zig build
fdev publish --code zig-out/site/web_container.wasm --parameters zig-out/site/params.bin \
  contract --state zig-out/site/state.bin
cat zig-out/site/site.txt     # the URL to open
```

For shared state, give the page a contract. The page then creates, reads,
updates and subscribes to it:

```js
const counter = client.contract("counter");          // from addWebApp's .contracts
if ((await counter.getText()) === null) await counter.put("counter-v1\n");
await counter.subscribe(async () => render(await counter.getText()));
await counter.update(`${me}:${clicks}\n`);            // merged by the contract's updateState
```

Examples:

- [examples/counter](examples/counter): a shared counter. A contract with a
  commutative merge, a delegate that keeps each visitor's id, and a page that
  uses both.
- [freenet-zig-random](../freenet-zig-random): a page plus a delegate that
  generates random numbers.

## Install

Source: <https://github.com/brianvar/freenet-zig>. Add it to your project with:

```sh
zig fetch --save git+https://github.com/brianvar/freenet-zig
```

which adds the dependency to your `build.zig.zon` (`.freenet = .{ .url = ..., .hash = ... }`).

## Documentation

| | |
|---|---|
| [docs/getting-started.md](docs/getting-started.md) | From an empty folder to a running app on a local node |
| [docs/delegates.md](docs/delegates.md) | Delegate API: messages, replies, origin, secrets, context, errors |
| [docs/contracts.md](docs/contracts.md) | Contract API: validate, update/merge, sync, related contracts |
| [docs/web-apps.md](docs/web-apps.md) | `addWebApp`, the page, `freenet.js` client API, the web container |
| [docs/build.md](docs/build.md) | All build helpers and the `freenet-pack` / `freenet-check-wasm` tools |
| [docs/testing.md](docs/testing.md) | Native unit tests with `freenet.testing` |
| [docs/internals.md](docs/internals.md) | Wasm ABI, wire formats and compatibility |


## Compatibility

The wire formats follow freenet-stdlib and freenet-core as of November 2026.

License: [AGPL-3.0](LICENSE)

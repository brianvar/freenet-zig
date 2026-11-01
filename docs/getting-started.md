# Getting started

This guide builds a small web app, a page with a delegate behind it, and runs
it on a private local Freenet node. It assumes Zig 0.17.

## What you're building

A Freenet web app has up to three parts:

| Part | Runs where | Written in |
|---|---|---|
| **Contract** | On every peer that stores it | Zig (Wasm) |
| **Delegate** | Only on the user's own node | Zig (Wasm) |
| **Page** | The user's browser, served by their node | HTML/JS |

For a simple app you only write the delegate and the page. `addWebApp` brings a
ready-made contract that stores your page, the "web container".

## 1. Project layout

```
my-app/
├── build.zig
├── build.zig.zon
├── src/delegate.zig
└── web/index.html
```

`build.zig.zon`:

```zig
.{
    .name = .my_app,
    .version = "0.1.0",
    .fingerprint = 0x0, // `zig build` prints the value to put here
    .minimum_zig_version = "0.17.0",
    .dependencies = .{
        .freenet = .{ .path = "../freenet-zig" },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src", "web" },
}
```

## 2. The delegate

A delegate receives messages and replies to them. This one greets:

```zig
// src/delegate.zig
const std = @import("std");
const freenet = @import("freenet");

comptime {
    freenet.exportDelegate(@This());
}

pub fn handle(d: *freenet.Delegate, msg: freenet.Inbound) !void {
    switch (msg) {
        .application => |app| try d.replyFmt("hello, {s}!", .{app.payload}),
        .unsupported => {},
    }
}
```

`exportDelegate` generates the Wasm entry points Freenet calls. `handle` runs
once per message; whatever you `reply` goes back to the page.

## 3. The page

```html
<!-- web/index.html -->
<!doctype html>
<meta charset="utf-8">
<input id="name" value="world"> <button id="go">Greet</button>
<p id="out"></p>

<script src="freenet.js"></script>
<script>
  (async () => {
    const client = await FreenetClient.connect();
    const greeter = await client.delegate("greeter");
    document.getElementById("go").onclick = async () => {
      const [reply] = await greeter.sendText(document.getElementById("name").value);
      document.getElementById("out").textContent = reply;
    };
  })();
</script>
```

You don't provide `freenet.js` yourself. At build time that tag is replaced with
the client library and your compiled delegate, so the published page is one
self-contained HTML file.

## 4. The build

```zig
// build.zig
const std = @import("std");
const freenet = @import("freenet");

pub fn build(b: *std.Build) void {
    const dep = b.dependencyFromBuildZig(freenet, .{});

    const greeter = freenet.addDelegate(b, dep, .{
        .name = "greeter", // the name the page uses in client.delegate(...)
        .root_source_file = b.path("src/delegate.zig"),
    });

    const app = freenet.addWebApp(b, dep, .{
        .page = b.path("web/index.html"),
        .delegates = &.{greeter},
    });
    b.getInstallStep().dependOn(app.install);
}
```

Run `zig build`. You get:

```
zig-out/bin/greeter.wasm          the delegate (also embedded in the page)
zig-out/bin/web_container.wasm    the contract that stores the site
zig-out/site/state.bin            the site, as the contract's state
zig-out/site/params.bin           the contract's parameters
zig-out/site/web.tar.xz           the site's files (for inspection)
zig-out/site/site.txt             contract key, local URL, delegate keys
```

## 5. Run it on a local node

Install the node and its developer CLI: `cargo install freenet fdev`, or use the
installer from freenet.org.

Start a node in **local mode**. It never joins the network, and keeps its data
apart from a normal node's:

```sh
freenet local
```

> **macOS with the Freenet app installed:** the app already runs a node on port
> 7509, and the `freenet` command may point at the app's launcher, which ignores
> arguments. Run the real binary on another port instead:
>
> ```sh
> /Applications/Freenet.app/Contents/MacOS/freenet-bin local --ws-api-port 7510
> ```
>
> and add `--port 7510` to `fdev`, e.g. `fdev --port 7510 publish ...`.

Load the site into it:

```sh
fdev publish \
  --code zig-out/bin/web_container.wasm \
  --parameters zig-out/site/params.bin \
  contract --state zig-out/site/state.bin
```

Open the URL from `zig-out/site/site.txt`, changing the port if you used 7510.

Every change gives the site a new key, because the contract is
content-addressed. After editing, run `zig build`, publish again, and open the
new URL.

## 6. Test without a node

Add tests next to your delegate:

```zig
test "greets" {
    freenet.testing.reset();
    const replies = try freenet.testing.ask(@This(), "Zig", .{});
    try std.testing.expectEqualStrings("hello, Zig!", replies[0]);
}
```

and wire them up in `build.zig`:

```zig
const tests = freenet.addTests(b, dep, .{
    .sources = &.{b.path("src/delegate.zig")},
    .delegates = &.{greeter},
    .contracts = &.{app.contract},
});
b.step("test", "Run tests").dependOn(tests);
```

`zig build test` runs your tests natively and checks the compiled Wasm against
Freenet's ABI. See [testing.md](testing.md).

## Next

- [delegates.md](delegates.md): secrets, context, origins, errors
- [web-apps.md](web-apps.md): the `freenet.js` API, multiple files
- [contracts.md](contracts.md): writing your own contracts for shared state
- `examples/counter`: a page and a contract sharing state between visitors

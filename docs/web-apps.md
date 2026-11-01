# Web apps

On Freenet, a website is the **state of a contract**. The user's node fetches
that state, unpacks it, and serves it at
`http://127.0.0.1:7509/v1/contract/web/<contract key>/`. The page runs in a
sandboxed iframe and reaches the network only through the node's WebSocket API.

## addWebApp

```zig
const app = freenet.addWebApp(b, dep, .{
    .page = b.path("web/index.html"),           // becomes index.html
    .delegates = &.{random, wallet},            // from addDelegate; embedded in the page
    .contracts = &.{chat_room},                 // from addContract; code embedded for client.contract(...)
    .files = &.{                                // optional extra files
        .{ .name = "style.css", .path = b.path("web/style.css") },
        .{ .name = "img/logo.png", .path = b.path("web/logo.png") },
    },
    .install_dir = "site",                      // default
});
b.getInstallStep().dependOn(app.install);
```

It builds the web-container contract, runs `freenet-pack`, and installs:

| Output | What |
|---|---|
| `zig-out/site/state.bin` | the contract state (your site) |
| `zig-out/site/params.bin` | the contract parameters |
| `zig-out/site/web.tar.xz` | the archive inside the state |
| `zig-out/site/site.txt` | contract key, local URL, delegate keys |
| `zig-out/bin/web_container.wasm` | the contract |
| `zig-out/bin/<delegate>.wasm` | each delegate |
| `zig-out/bin/<contract>.wasm` | each embedded contract |

The returned `WebApp` has `.contract` (for `addTests`), `.output` (the output
directory as a `LazyPath`) and `.install`.

## The page

Put this tag in your HTML exactly as written:

```html
<script src="freenet.js"></script>
```

`freenet-pack` replaces it, in every `.html` file, with the client library,
your delegates (Wasm in base64, plus their keys), and your contracts' code. The
published page needs no other files.

Extra files go into the archive as they are. Reference them with relative
paths (`<link rel="stylesheet" href="style.css">`).

## freenet.js API

```js
const client = await FreenetClient.connect(options?);
```

Connects to the node that served the page. Options:

| Option | Default | |
|---|---|---|
| `url` | the page's host + `/v1/contract/command?encodingProtocol=native` | WebSocket URL |
| `reconnect` | `true` | reconnect after 2 s; delegates are re-registered automatically |
| `onStatus(s)` | no-op | called with `"connecting"`, `"open"` or `"closed"` |

Rejects if the first connection fails.

```js
const d = await client.delegate("name");
```

Registers the embedded delegate named `name` (the `.name` from `addDelegate`)
with the node, once, and returns a handle.

```js
const replies = await d.send(bytesOrString);   // Uint8Array[]
const texts   = await d.sendText("hello");     // string[]
```

Sends one `ApplicationMessage` and resolves with the payloads of the
delegate's replies. Rejects with the delegate's error message if it failed (see
[delegates.md](delegates.md#errors)).

### Contracts

```js
const room = client.contract("chat", parameters?);    // embedded contract (from addWebApp's .contracts)
const other = client.contractAt("4sh72F4U...", codeHash?); // any existing instance, by id
```

`client.contract` returns a handle synchronously. The instance id is computed
in the browser as BLAKE3(code hash ‖ parameters), the same derivation Freenet
uses. `parameters` is a `Uint8Array` or string (default empty), so one contract
can have many instances, such as one chat room per owner key. `handle.id` is
the 32-byte id; `handle.idString` is the base58 form Freenet prints.

`client.contractAt` addresses an instance you didn't embed, for example
another app's contract. `codeHash` (hex, base58 or bytes) is needed only for
updates, and is also learned from `get()`.

| Method | |
|---|---|
| `await h.get({ subscribe? })` | current state as `Uint8Array`, or `null` if the network doesn't have it |
| `await h.getText({ subscribe? })` | same, decoded as UTF-8 |
| `await h.put(state, { subscribe? })` | create the instance with an initial state (needs the code: embedded contracts only). The node runs your `validateState` first |
| `await h.update(delta)` | send `UpdateData::Delta`; your `updateState` merges it. Resolves to the new summary |
| `await h.updateState(state)` | send `UpdateData::State`, a whole proposed state |
| `const off = await h.subscribe(fn)` | call `fn({ state?, delta? })` (Uint8Arrays) on every change; `off()` removes `fn` |

`state` and `delta` arguments may be strings or `Uint8Array`s.

The usual page flow:

```js
const counter = client.contract("counter");
let state = await counter.getText();
if (state === null) {                 // nobody created it yet
  await counter.put("counter-v1\n");
  state = await counter.getText();
}
await counter.subscribe(async () => render(await counter.getText()));
button.onclick = () => counter.update(`${me}:${n + 1}\n`);
```

`examples/counter` is the complete version.

### Behavior

- **Ordering.** Requests go out one at a time over one connection. Calling
  methods concurrently is fine: calls queue and resolve in order. Each waits up
  to 30 s for the node.
- **Notifications** arrive at any time and go to `subscribe` callbacks, never to
  the request waiting for a reply.
- **Large responses** (over 512 KiB) are reassembled transparently.
- **Reconnecting** re-registers delegates and renews subscriptions.
- **Errors.** Node errors, such as a contract rejecting an update, reject the
  promise with the node's message.

```js
client.close();
```

## The web container

`addWebApp` uses `freenet.WebContainer` (`src/webcontainer.zig`), a
**content-addressed** contract:

- parameters = BLAKE3(state), so the contract key commits to the exact bytes
- `validateState` accepts only that state, and only if it has the web-app layout
- `updateState` accepts only that same state, so nobody can replace the site

Consequences:

- Every change to the page or a delegate gives a **new key and URL**. Old
  versions stay reachable at their old keys.
- Nobody, not even you, can deface a published version.

For a site that updates in place under one key, write your own contract: put a
public key in the parameters, and accept a new state only with a valid
signature. freenet-core's `fdev website` does this in Rust. The layout helpers
in `freenet.webapp` (`pack`, `buildState`, `parseState`) help with the state
format.

## State layout

```
[u64 BE metadata length][metadata][u64 BE archive length][archive: tar.xz with index.html at the root]
```

The archive is a valid `.xz` that stores the data uncompressed. Zig has no xz
encoder, and this keeps the build free of external tools. Sites are a little
larger as a result; the limit is far above what a page needs.

## Publishing

```sh
fdev publish --code zig-out/bin/web_container.wasm --parameters zig-out/site/params.bin \
  contract --state zig-out/site/state.bin
```

Against a node started with `freenet local`, this stays on your machine. Against
a normal node, the site is public and permanent. See
[getting-started.md](getting-started.md#5-run-it-on-a-local-node).

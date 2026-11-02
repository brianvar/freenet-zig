# Web apps

On Freenet, a website is the **state of a contract**. The user's node fetches
that state, unpacks it, and serves it at
`http://127.0.0.1:7509/v1/contract/web/<contract key>/`. The page runs in a
sandboxed iframe and reaches the network only through the node's WebSocket API.

## addWebApp

```zig
const app = freenet.addWebApp(b, dep, .{
    .page = b.path("web/index.html"),           // becomes index.html
    .signing_key = "my-app",                    // key name from `fdev website init`; see "The signing key"
    .version = null,                            // release number; default: build time
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
| `zig-out/site/web_container.wasm` | the contract |
| `zig-out/site/state.bin` | the contract state (your site) |
| `zig-out/site/params.bin` | the contract parameters (the public key) |
| `zig-out/site/web.tar.xz` | the archive inside the state |
| `zig-out/site/site.txt` | contract key, local URL, release, delegate keys |
| `zig-out/bin/<delegate>.wasm` | each delegate |
| `zig-out/bin/<contract>.wasm` | each embedded contract |

The returned `WebApp` has `.contract` (for `addTests`), `.output` (the output
directory as a `LazyPath`) and `.install`.

## The page

Load the client with:

```html
<script src="freenet.js"></script>
```

`freenet-pack` generates `freenet.js` into the archive: the client library,
your delegates (Wasm in base64, plus their keys and parameters), and your
contracts' code. It
defines one global, `FreenetClient`; other names in your scripts can't clash
with it.

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
| `reconnect` | `true` | after losing the connection (or a request timing out), reconnect every 2 s; delegates are re-registered automatically |
| `onStatus(s)` | no-op | called with `"connecting"`, `"open"` or `"closed"` |

Rejects if the first connection fails; nothing is retried in that case.

```js
const d = await client.delegate("name");
```

Registers the embedded delegate named `name` (the `.name` from `addDelegate`)
with the node, once (concurrent calls share the registration), and returns a
handle.

```js
const replies = await d.send(bytesOrString);   // Uint8Array[]
const texts   = await d.sendText("hello");     // string[]
```

Sends one `ApplicationMessage` and resolves with the payloads of the
delegate's replies. Rejects with the delegate's error message if it failed (see
[delegates.md](delegates.md#errors)).

```js
const earlier = client.delegateAt(codeHash, parameters?); // a delegate already on the node
```

Returns a handle, synchronously, to a delegate the page doesn't embed: its key
is BLAKE3(code hash ‖ parameters), computed in the browser. `codeHash` is hex,
base58 or 32 bytes; `parameters` (a `Uint8Array` or string) defaults to this
app's id, `FreenetClient.appId` (hex, written by `freenet-pack`), the
parameters of every delegate the app embeds. Nothing is registered (the page
doesn't have the code), so it answers only if the node already has that
delegate; otherwise `send` rejects with a `FreenetClient.Error`. Its use is
upgrades: a delegate from an earlier build of this app, still on the node,
keeps its secrets and still passes `requireApp`, so the new build can read them
and carry them over (see [delegates.md](delegates.md#upgrades)).

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
updates, and is also learned from `get()`. Both must be 32 bytes; anything
else throws a `TypeError`.

| Method | |
|---|---|
| `await h.get({ subscribe? })` | current state as `Uint8Array`, or `null` if the network doesn't have it |
| `await h.getText({ subscribe? })` | same, decoded as UTF-8 |
| `await h.put(state, { subscribe? })` | create the instance with an initial state (needs the code: embedded contracts only). The node runs your `validateState` first |
| `await h.update(delta)` | send `UpdateData::Delta`; your `updateState` merges it. Resolves to the new summary |
| `await h.updateState(state)` | send `UpdateData::State`, a whole proposed state |
| `const off = await h.subscribe(fn)` | call `fn({ state?, delta? })` (Uint8Arrays) on every change; resolves once the node confirmed; `off()` removes `fn` |

`state` and `delta` arguments may be strings, `Uint8Array`s (or other typed
arrays) or `ArrayBuffer`s.

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

### Helpers

`FreenetClient.util` has the functions the client uses for ids, for pages that
need them too: `blake3(bytes)` (32 bytes), `base58Encode`, `base58Decode`,
`hexToBytes`, `bytesToHex` and `concatBytes`. Nothing else from the client is
global.

### Behavior

- **Ordering.** Requests go out one at a time over one connection. Calling
  methods concurrently is fine: calls queue and resolve in order. Each waits up
  to 30 s for the node. The node's replies carry no request id, so after a
  timeout the client drops the connection (and reconnects, if enabled) rather
  than risk taking a late reply as the answer to the next request.
- **Notifications** arrive at any time and go to `subscribe` callbacks, never to
  the request waiting for a reply.
- **Large responses** (over 512 KiB) are reassembled transparently.
- **Reconnecting** re-registers delegates and renews subscriptions. Changes
  made while disconnected are not replayed; call `get()` if you need them.
- **Errors.** Refusals from the node, such as a contract rejecting an update,
  reject with a `FreenetClient.Error` whose `kind` names the node's error
  (`"MissingContract"`, `"Update"`, `"DelegateExecutionError"`, ...), with
  `cause`, `contract` or `delegate` where the node gives them. For a delegate
  failure, `message` is the delegate's own message. Connection problems
  (`"not connected"`, `"timed out ..."`, `"connection closed"`) reject with a
  plain `Error`.
- **Sandbox.** Pages run in an iframe without `allow-same-origin`, so
  `localStorage`, cookies and IndexedDB are unavailable. Keep per-user data in a
  delegate's secrets (`examples/counter` keeps its visitor id that way).

```js
client.close();
```

## The signing key

A site is signed by its publisher, and the key decides the app's identity. Use
freenet's own tool to make the key:

```sh
fdev website init my-app
```

It writes `my-app.toml` into freenet's config directory (Linux:
`~/.config/freenet/website-keys/`; macOS: `~/Library/Application Support/freenet/website-keys/`),
and prints the app's address for freenet's own container. In `build.zig` you
give only the name, `.signing_key = "my-app"`, exactly as `fdev website
publish --key my-app` does. `freenet-pack` finds the file itself, so the
build file is the same on every machine that has the key, and the key never
enters the repository.

For CI you can pass a file path instead of a name (a value containing `/` or
`\`, or ending in `.toml` or `.key`). The file is an `fdev` key file or just the
32-byte seed as 64 hex characters (`openssl rand -hex 32`).

**Keep it private and back it up**: whoever has it can replace your site, and
if you lose it you can never update the site again. Don't commit it. The
address `fdev` prints is for freenet's container; this library's container has
its own code, so the app's key (in `site.txt`) differs.

Because the key is read from outside the project, `zig build` packs the site
again on every build instead of reusing a cached result.

Each build is a *release*, numbered by the Unix time of the build (or
`.version = n`). The container accepts only a release higher than the current
one, so republishing needs a later build, never an earlier one.

## The web container

`addWebApp` uses `freenet.WebContainer` (`src/webcontainer.zig`), a **signed
site** contract, modelled on freenet-core's `fdev website`:

- parameters = the publisher's Ed25519 public key
- `validateState` accepts a state only if its metadata (CBOR: version and
  signature) verifies against that key over `version ‖ archive`
- `updateState` accepts a state only if it is signed by the same key and has a
  higher version; the same state again is a no-op

States are byte-compatible with `fdev website`, so either tool's output is
valid for either contract.

Consequences:

- The app's id is BLAKE3(BLAKE3(container code) ‖ public key). It does **not**
  depend on the site, so every release keeps the **same key and URL**, and
  the id is known before the site is built.
- Whoever holds the signing key can change the site. Nobody else can.
- The id depends on the compiled container, so building with a different Zig
  version (or optimize mode) changes it, even with the same key. Publishing
  that build is a different app. Keep the toolchain the same for an app's
  lifetime, or publish with a stored `web_container.wasm`.
- `freenet-pack` gives each delegate the app's id as its **parameters**, so a
  delegate can tell whether a message comes from its own app:
  `try d.requireApp()` (see [delegates.md](delegates.md#origin-whos-asking)).
  Users of other sites on the same node can't use your delegates.

The layout helpers in `freenet.webapp` (`tar`, `xzStore`, `buildState`,
`parseState`, `signState`, `verifyState`) help if you write your own container.

## State layout

```
[u64 BE metadata length][metadata][u64 BE archive length][archive: tar.xz with index.html at the root]
```

The archive is a valid `.xz` that stores the data uncompressed. Zig has no xz
encoder, and this keeps the build free of external tools. Sites are larger as
a result, and embedded Wasm grows by a third as base64. The node stores at most
50 MiB per state; `freenet-pack` fails above that.

## Publishing

```sh
fdev publish --code zig-out/site/web_container.wasm --parameters zig-out/site/params.bin \
  contract --state zig-out/site/state.bin
```

Against a node started with `freenet local`, this stays on your machine. Against
a normal node, the site is public and permanent. See
[getting-started.md](getting-started.md#5-run-it-on-a-local-node).

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
| `reconnect` | `true` | after losing the connection (or the node not answering at all after a request timed out), reconnect every 2 s; delegates are re-registered automatically |
| `onStatus(s)` | no-op | called with `"connecting"`, `"open"` or `"closed"` (the main connection) |
| `lanes` | `FreenetClient.lanes` (4) | extra connections for contract gets, puts and updates, so a slow one holds up only its own lane (see Ordering); 0 sends everything on the main connection |
| `keepAliveMs` | `FreenetClient.keepAliveMs` (30 s) | when nothing went over the main connection for this long, a quick query keeps it from being dropped as idle (no answer within `FreenetClient.probeMs` reconnects); 0: never |

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
`send(payload, { timeoutMs })` waits longer than the default 30 s, for a
message the delegate answers only after a prompt to the user.

**A prompt the node didn't show.** A node in local mode (`freenet local`)
never shows a delegate's prompt (`requestUserInput`); it hands it back with
the reply. `send` then rejects with a `FreenetClient.Error` of kind
`"PromptNotShown"`, with `prompts` (`[{ requestId, message, labels }]`) and
any `payloads`. The page can answer one itself with
`d.respond(requestId, label)`, which resolves like `send`. On such a node
the page sees the id, so the prompt protects nothing there: show the
message to the person and answer only with their choice.

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
| `await h.get({ subscribe?, timeoutMs? })` | current state as `Uint8Array`, or `null` if the network doesn't have it (a network node may instead not answer: the request times out, default 30 s) |
| `await h.getText({ subscribe?, timeoutMs? })` | same, decoded as UTF-8 |
| `await h.put(state, { subscribe? })` | create the instance with an initial state (needs the code: embedded contracts only). The node runs your `validateState` first |
| `await h.update(delta)` | send `UpdateData::Delta`; your `updateState` merges it. Resolves to the new summary |
| `await h.updateState(state)` | send `UpdateData::State`, a whole proposed state |
| `const off = await h.subscribe(fn)` | call `fn({ state?, delta? })` (Uint8Arrays) on every change; resolves once the node confirmed; `off()` removes `fn`. The node sends the whole state each time |
| `const f = await h.follow(fn, { resubscribeMs })` | keep a copy of the state in the page, updated by deltas: `fn(state)` (Uint8Array) now and after every change; `f.state()` is the copy, `f.stop()` removes `fn`. `resubscribeMs` (default 0): the shortest time between two Subscribes with a new summary (see below). Embedded contracts only |

`state` and `delta` arguments may be strings, `Uint8Array`s (or other typed
arrays) or `ArrayBuffer`s.

The usual page flow:

```js
const counter = client.contract("counter");
if ((await counter.get()) === null) await counter.put("counter-v1\n"); // nobody created it yet
await counter.follow((state) => render(new TextDecoder().decode(state)));
button.onclick = () => counter.update(`${me}:${n + 1}\n`);
```

**`follow` or `subscribe`.** The node sends a subscribed client a delta only
against a summary of what that client holds, so with `subscribe` every change
brings the whole state, and a page that then calls `get()` downloads it twice.
For a state that grows, use `follow`: the page keeps its own copy, merges each
delta into it with your contract's `updateState` (the contract's own Wasm, run
in the page as the node runs it, so the copy is exactly the node's), computes
its summary with your `summarizeState`, and subscribes again with that summary
after each change (once per burst). Your `getStateDelta` then decides what
travels. A merge that fails in the page falls back to a `get()`. The contract
may log; any other import makes the merge fail (and fall back). One copy per
contract and client, shared by every `follow` on it.

A contract that changes several times a second would get a Subscribe after
nearly every change. `follow(fn, { resubscribeMs: 10000 })` sends at most one
every 10 s: changes still arrive at once, as deltas against a summary at most
that old, so each delta may repeat lines the copy already has (your merge must
take them again harmlessly, as a commutative, idempotent merge does). Followers
of one contract share the copy, and the smallest `resubscribeMs` counts.

`examples/counter` is the complete version.

### Helpers

`FreenetClient.util` has the functions the client uses for ids, for pages that
need them too: `blake3(bytes)` (32 bytes), `base58Encode`, `base58Decode`,
`hexToBytes`, `bytesToHex` and `concatBytes`. Nothing else from the client is
global.

### Behavior

- **Ordering.** A connection answers one request at a time (replies carry
  no request id). Contract gets, puts and updates go out on lanes: up to
  `lanes` (default 4) extra connections, opened when first needed and closed
  after `FreenetClient.laneIdleMs` (60 s) with nothing to do. A contract's id
  picks its lane, so every get, put and update of one contract stays in the
  order the page made them (a write and a later read can't pass each other),
  while different contracts go out at once: on a network node one lookup of
  a contract nobody has (seconds) no longer holds up the rest. A browser
  opens only so many WebSockets to one host and holds the rest in
  CONNECTING, so a lane not open within `FreenetClient.laneOpenMs` (3 s) is
  given up: its request goes out on the main connection, and the client
  opens no lanes for `FreenetClient.laneBackoffMs` (60 s). A page with
  several clients (or a connection that only subscribes) should pass
  `lanes: 0` to all but one. Delegate
  messages, subscriptions and a `get`/`put` with `subscribe: true` go out on
  the main connection, one at a time; notifications arrive there. Calling
  methods concurrently is fine: calls queue and resolve in order. Each waits up
  to 30 s for the node (`get({ timeoutMs })` sets another wait). A request that
  times out fails alone, with an `Error` whose `timedOut` is true; its late
  answer, if one comes, is recognized and dropped. On a network node a `get`
  for a contract nobody has put yet can go unanswered rather than come back
  `null`, so give lookups of contracts that may not exist yet a shorter wait,
  and treat a timeout as "not there yet". The connection is dropped (and
  reconnects, if enabled) only if the node then answers nothing at all, not
  even a quick query, within `FreenetClient.probeMs` (10 s); subscriptions
  survive a timeout.
- **Idle and reconnects.** The main connection sends the same quick query
  after `keepAliveMs` (30 s) with nothing else going over it, so a node
  doesn't drop it as idle and a node that is gone is noticed. After a
  reconnect the client subscribes again and reads every subscribed contract
  again: `subscribe` callbacks get `{ state, catchUp: true }` (and `follow`
  copies take the state), so a change made while disconnected shows. A lane
  the node drops is replaced when next needed, and a `get` that was out on it
  is sent once more. Warnings name the connection: `freenet.js (main)` or
  `freenet.js (lane N)`.
- **Notifications** arrive at any time and go to `subscribe` callbacks, never to
  the request waiting for a reply.
- **Large responses** (over 512 KiB) are reassembled transparently.
- **Reconnecting** re-registers delegates and renews subscriptions (a
  `follow`'s with the summary of its copy, so the next delta brings what it
  missed). For a plain `subscribe`, changes made while disconnected are not
  replayed; call `get()` if you need them. A
  request made while the client reconnects waits for the new connection (up to
  its timeout) instead of failing; one in flight when the connection drops
  rejects with `"connection closed"`.
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
- **Links.** The node injects a click handler into the page that hands every
  same-site link to its shell page, which closes the page's WebSockets and
  loads the link into the iframe. For a link that only changes the hash
  (`href="#/profile"`, hash routing) the iframe doesn't reload, so the page
  keeps running with its connection closed. Mark such links
  `data-freenet-no-intercept` (the node leaves those to the browser), or
  mark them as they're clicked with a capturing `click` listener on `window`,
  which runs before the node's on `document` (Hive's `web/app.js` does).
- **Routes.** The address bar shows the shell page, not the iframe, so a
  hash route (`#/profile`) is lost on reload unless the page hands it to the
  shell. `FreenetClient.syncHash()` does that: called once (no connection
  needed), it sends the page's hash to the shell now and on every
  `hashchange`, and follows the hash the shell sends back on back/forward or
  an edited address. The shell replaces its address (no history entry) and,
  on reload, loads the iframe with that hash. After changing the hash with
  `history.replaceState` (no `hashchange`), call `FreenetClient.shareHash()`.
  Outside a shell both do nothing.

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

In every packed `.html` file, `src="name"` and `href="name"` that name a file
of the site (`freenet.js` too) become `name?v=<release>`. The node serves the
page itself uncached but the files it loads with only `etag` and
`last-modified`, so after an update a browser could otherwise keep an old
stylesheet beside a new script. Only exact names are changed: absolute and
external URLs, values that already have a query or fragment, and other
attributes (`data-src`) stay as written. A file a page loads some other way
(`fetch`, a script that builds a URL) isn't versioned; add `?v=` yourself if
it can change between releases.

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

The same container signs other files at a fixed address too: `addSignedArchive`
(see [build.md](build.md#addsignedarchive)) for downloads or a static page,
with a key of its own.

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

# AGENTS.md: freenet-zig

Write [Freenet](https://freenet.org) delegates, contracts and web apps in Zig.
Freenet itself only ships a Rust SDK (freenet-stdlib); this library covers the
same ground for Zig. Users: README.md and docs/. This file is for agents (and
people) changing the library. Pixie (`../Pixie`) is the biggest app built on it.

## Constraints

- **Zig 0.17.** Version-sensitive std APIs have bitten before (see Gotchas).
- **No Node.js, npm, Rust or other build tools in the project.** Everything
  builds and tests with `zig build`; the browser client is tested by opening
  `js/test.html` in a browser.
- **Commutative, idempotent merges** in contracts: peers must reach the same state
  whatever order updates arrive in.
- **Byte-exact wire formats** (bincode, CBOR, the Wasm ABI). `src/tests.zig`
  writes the expected bytes out by hand from the freenet-stdlib type definitions,
  independently of the encoder.
- Wasm modules are built **stripped** (the node rejects debug sections) and with
  **`.safe`** by default (traps instead of undefined behaviour on bad input).

## Files

```
src/freenet.zig         public API (re-exports)
src/abi.zig             buffers, result structs, allocator, export name lists
src/bincode.zig         bincode 1.x encoder/decoder
src/delegate.zig        Delegate, Secrets, requireApp, exportDelegate, wire codecs
src/contract.zig        Contract, Updates, exportContract, error mapping
src/host.zig            node imports (random, log, context, secrets) + native stand-ins for tests
src/types.zig           ids, key derivation (BLAKE3), base58
src/webapp.zig          web-app state layout, tar, stored xz, signed-site metadata (CBOR), verify/sign
src/webcontainer.zig    the built-in signed web contract used by addWebApp
src/testing.zig         native harness for apps' tests (+ the codecs only tests need)
src/tests.zig           byte-exact wire-format tests
tools/pack.zig          freenet-pack: page + delegates -> signed, publishable site
tools/check_wasm.zig    freenet-check-wasm: exports/imports of built Wasm against the ABI
js/freenet.js           browser client (WebSocket API, bincode, BLAKE3, base58); no dependencies
js/test.html            browser tests for the client (open the file; fake WebSocket)
build.zig               the module, tools, tests, and helpers apps call
docs/                   guides (getting-started, delegates, contracts, web-apps, build, testing, internals)
examples/counter/       a contract + delegate + page
CHANGELOG.md            what changed, and what breaks
```

## Commands

```sh
zig build test      # library unit + wire-format tests, and an ABI check of the web container
# open js/test.html in a browser for the client's tests
```

`zig build` in an app needs the app's signing key (`fdev website init <name>`, see
below); `zig build test` does not.

## Sources of truth

- Wire types: freenet-stdlib (`rust/src/delegate_interface.rs`, `contract_interface/`,
  `client_api/client_events.rs`, `WIRE-FORMAT.md`, `host_imports.rs`).
- Behaviour: freenet-core (`crates/core/src/wasm_runtime/`, `client_events/websocket.rs`,
  `server/path_handlers*`, and `crates/fdev` + `crates/website-contract` for signed sites).
- The Zig files here are the source of truth for what this library does; docs/internals.md
  has the byte layouts.

## Decisions and why

- **The web container is a signed site** (parameters = publisher's Ed25519 public
  key; a state is valid if signed over `version ‖ archive` and a version above the
  current one), the same design and state format as freenet-core's `fdev website`.
  Why: the old content-addressed container gave the app an id that depended on the
  site's bytes, which include the delegate's code, so a delegate could never know its
  own app's id and any site on the node could use it. Now the id is
  BLAKE3(BLAKE3(container code) ‖ public key), independent of the site.
  Cost: whoever holds the key can change the site (a lost key means no more updates).
  Apps that want immutable content-addressed contracts (Pixie's images) carry that
  logic themselves (Pixie's `src/addressed.zig`).
- **Delegates get the app id as their parameters** (set by freenet-pack), and
  `d.requireApp()` fails the call unless the node-attested `d.origin` is that app.
  It fails closed. Another site can register the same delegate code with different
  parameters, but that is a different delegate with its own empty secrets.
- **`client.delegateAt(codeHash)` reaches a delegate the page doesn't embed**
  (key computed from the code hash and, by default, `FreenetClient.appId`, which
  freenet-pack writes). Why: a new build of a delegate starts with empty secrets,
  but the earlier one is still on the node and accepts the same app, so a page
  carries its secrets over by asking it (docs/delegates.md, "Upgrades"). No
  registration, since the page doesn't have the old code.
- **The signing key is a name, not a path.** `addWebApp(.signing_key = "pixie")` is
  looked up where `fdev` keeps it (`<config dir>/freenet/website-keys/<name>.toml`,
  `signing_key = "<hex seed>"`), so build files don't hold machine paths and the key
  stays out of the repo. A value with a separator, or ending `.toml`/`.key`, is a path
  (for CI). The pack step has side effects (reads outside the build), so the site is
  repacked on every build; each build is a release numbered by Unix time.
- **State-compatible with `fdev website`**: metadata is CBOR `{"version","signature"}`.
  We write the signature as a byte string and accept the byte-string or 64-integer
  array form. Vectors in `src/webapp.zig` were produced independently and accepted
  by freenet-core's own contract.
- **freenet.js is a file in the site archive** (generated by freenet-pack with the
  embedded delegates and contracts), not inlined into pages. Apps that need it
  inlined (Pixie's viewers) inline the library's file themselves.
- **freenet.js defines one global, `FreenetClient`** (an IIFE). Helpers are in
  `FreenetClient.util`; the error class is `FreenetClient.Error`. Don't add globals:
  page scripts that reuse a name would break.
- **Replies carry no request id**, so requests go out one at a time, an error goes to
  the request in flight, and a timeout closes the connection (a late reply could
  otherwise answer the next request).
- **The test harness plays the node** (buffers via `__frnt__initiate_buffer`,
  `last_write`, result structs) and host functions go to an in-memory fake, so app
  code is the same in tests and on the node. `setContext` writes through the
  context host function, like a real delegate.
- **Test-only codecs live in testing.zig**, not in delegate.zig/contract.zig, so the
  runtime modules hold only what apps call.

## Gotchas

- **Never discard an error value in Zig 0.17:** `_ = d.fail("x")` doesn't compile
  ("error set is discarded"). `d.fail()` / `c.fail()` return an error value; use
  `return d.fail(..)`, or set `d.failure` in tests that simulate a recovered failure.
- **Version-sensitive std APIs** used by the tools: `Io.Clock.real.now(io)` (no `try`),
  `init.environ_map`, `Build ... .strip`, `Ed25519.Signature.verifier/KeyPair.sign`.
  If a new Zig breaks the build, look there first.
- **A contract's id depends on the compiled Wasm**, so a different Zig version (or
  optimize/strip setting, or any library change the module uses) gives different ids
  for the container, and for contracts and delegates built with it. Keep one
  toolchain per app, or publish from a stored `zig-out/site/web_container.wasm`.
- **Changing `js/freenet.js` changes things pinned to its bytes**, such as Pixie's
  encrypted viewer hash and so its contract keys.
- **The node limits** (freenet-core): contract state 50 MiB; gateway web-app
  metadata 1 kB; WebSocket message 100 MiB (responses over 512 KiB arrive as
  `StreamChunk`s). Pages run in a sandboxed iframe without `allow-same-origin`: no
  `localStorage`, cookies or IndexedDB.
- **Contracts must not use randomness** (every peer must compute the same result);
  freenet-check-wasm rejects a contract that imports `freenet_rand`.
- **Delegates not built through `addWebApp` have no app id**; `requireApp` refuses
  them. Check `d.origin` yourself.
- **Lifecycle and wake-up events never arrive**: the node sends them only to
  delegates with a manifest custom section, which this library can't emit.
- **`freenet-pack` reads the key by name**; `zig build` (not `test`) fails with
  `cannot read the signing key` until `fdev website init <name>` has been run on that
  machine. The address `fdev website init` prints is for Freenet's own container;
  ours differs (use `site.txt`).


## Not done / ideas

- Delegate outbound requests (contracts, other delegates) and delegate manifests.
- Making `abi`, `bincode` and `host` private; one code-hash format in `contractAt`.
- Dropping `freenet-check-wasm` or the JS BLAKE3 (each ~200 / ~70 lines) if the
  surface should shrink.
- A `--container` option for freenet-pack to publish with a stored container (keeps
  the app id when the toolchain changes).

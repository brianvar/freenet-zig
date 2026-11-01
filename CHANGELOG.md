# Changelog

## Unreleased

Fixes from the November 2026 review. Rebuilt sites and delegates get new keys
(the default optimize mode changed), so publish again after upgrading.

### Security: delegates can now tell their own app from other sites

Any site on a user's node could register and message your delegates, and the
delegate had no way to check it was talking to its own page: the old web
container's id depended on the site's bytes, which include the delegate.

- The web container is now a **signed site**, as in freenet-core's
  `fdev website`: its parameters are the publisher's Ed25519 public key, and a
  state is accepted only if signed by that key with a higher version. The app's
  id no longer depends on the site's content, so it is stable across releases
  (and so is the URL).
- `freenet-pack` gives each embedded delegate the app's id as its parameters,
  and `d.requireApp()` fails the call unless the message comes from that app.
  `examples/counter/src/visitor.zig` uses it.
- The trade-off: whoever holds the signing key can change the site (the old
  container made a published site immutable). The key must be kept private and
  backed up; a lost key means no more updates.

### Breaking

- `addWebApp` needs `.signing_key`: the *name* of a key made by freenet's own
  `fdev website init <name>`, looked up in the user's freenet config like
  `fdev website publish --key <name>` does, so `build.zig` has no machine-specific
  paths. The site is packed again on every build.
  New `.version` option; the default release number is the build's Unix time.
  Sites published with the old container are a different contract; publish
  again (you get a new key once, then it stays).
- Embedded delegates have the app id as their parameters, so their keys differ
  from before, and their secrets start empty.
- `freenet.js`'s embedded delegate table has a `parameters` field.
- `freenet.WebContainer` is the signed container; the content-addressed one is
  gone. `webapp.buildState` takes the metadata again.

- `addTests(b, dep, step, options)` now takes the step to add to, and returns
  nothing: `freenet.addTests(b, dep, b.step("test", "Run tests"), .{ ... })`.
- Wasm modules are built stripped (the node rejects ones with debug sections,
  which `.safe` would otherwise keep).
- `addDelegate` / `addContract` default to `.optimize = .safe` (was `.small`),
  and the web container is built with `.safe`. Bugs in Wasm code now trap
  instead of being undefined behaviour.
- `freenet-pack` writes `freenet.js` into the site archive instead of inlining
  it into each page. Pages keep `<script src="freenet.js"></script>`.
- The web container is now written to `zig-out/<install_dir>/web_container.wasm`
  (was `zig-out/bin/`): `fdev publish --code zig-out/site/web_container.wasm ...`.
- `freenet-check-wasm` rejects contracts that import the node's randomness.
- `d.setContext` uses the node's context functions and returns
  `error{ContextWriteFailed}!void`. The `Outbound` type is gone.
- Malformed delegate input now fails with `DelegateError::Deser` (was `Other`).
- Test-only codecs moved to `freenet.testing`: `freenet.contract.ContractError`
  is now `freenet.testing.ContractError`, and `testing.send` returns
  `testing.Result` (`.ok` is the list of reply payloads).
- `webapp.pack` was removed (use `tar`, `xzStore`, `signState`).
- `freenet.js` defines only the global `FreenetClient` (its helpers used to
  leak as globals). Its error class is `FreenetClient.Error`.

### Fixed

- `freenet.js`: a failed first connect no longer leaves a reconnect loop
  running; a timeout closes the connection so a late reply can't answer the
  next request; concurrent `delegate()` and `subscribe()` calls share one
  registration or subscription; transport and node errors are told apart by
  type, not message text; invalid ids, hex and byte arguments throw
  `TypeError`s instead of producing malformed requests.
- A `d.fail()` / `c.fail()` message no longer sticks to an unrelated later
  error.
- Lengths returned by the node are clamped to the buffer given to it.
- `freenet-pack` rejects names with empty, `.` or `..` parts, and sites larger
  than the node's 50 MiB state limit.
- `examples/counter`: visitor ids are kept by a new `visitor` delegate (pages
  are sandboxed without `localStorage`, so every load used to be a new
  visitor and the counter filled up); merging is O(n log n).

### Added

- `FreenetClient.util`: blake3, base58, hex and concat helpers for pages (they
  are no longer globals).
- `js/test.html`: tests for the browser client. Open it in a browser (no Node.js, no server).
- `freenet.testing.context()`.
- `webapp.max_state_size`.
- `Delegate.requireApp()`,
  `webapp.signState` / `verifyState` / `parseMetadata`.
- Docs on delegate origins: any site on the node can message a delegate.

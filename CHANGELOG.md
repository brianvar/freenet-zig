# Changelog

What changed, and what breaks. Newest first.

## Unreleased

- **freenet-pack versions a page's own files.** In each packed `.html`
  file, `src="name"` and `href="name"` naming a file of the site
  (`freenet.js` included) become `name?v=<release>`
  (`webapp.versionRefs`). The node serves a page with `cache-control:
  no-store` but its files with only validators, so after an update Safari
  kept an old stylesheet beside a new script. External and absolute URLs,
  values with a query or fragment, and other attributes are left alone. The
  web container is unchanged (same code, same app id), and the same release
  number still gives the same bytes. Nothing breaks.

- **Native client: the timeout works on Windows.** Zig 0.17's `Io.Threaded`
  can't time a socket read or write on Windows (`error.ConcurrencyUnavailable`
  from `operateTimeout`), so there each read and write runs on a task of its
  own that is canceled at the deadline. A missed deadline is `error.Timeout`
  with the same `lastError()` text as elsewhere. Other systems keep the timed
  operations. Not yet run on Windows itself: the tests force this path on any
  system (run on macOS), and the client cross-compiles for x86_64- and
  aarch64-windows. Nothing breaks.
- **Native client: a request timeout.** `Client.connectWith(gpa, io, host,
  port, .{ .timeout = .fromSeconds(60) })` (or setting `c.timeout`) makes the
  WebSocket handshake and each `get`, `update` and `put` give up after that
  long, sending included, with `error.Timeout`; `lastError()` then says "the
  node at <host:port> didn't answer in <n> s". The connection is given up
  after a timeout (later calls: `error.ConnectionClosed`). `connect` keeps
  its signature and still waits forever. The TCP connect itself is left to
  the system: Zig 0.17's `ConnectOptions.timeout` isn't implemented on
  POSIX. Native only; Wasm modules are unaffected. Nothing breaks.

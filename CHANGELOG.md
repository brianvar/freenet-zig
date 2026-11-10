# Changelog

What changed, and what breaks. Newest first.

## Unreleased

- **freenet.js: several requests at once (lanes).** A connection answers one
  request at a time (replies carry no request id), so on a network node one
  `get` of a contract nobody had (6–8 s) held up every request behind it.
  Contract gets, puts and updates now go out on up to `lanes` extra
  connections (`FreenetClient.connect({ lanes })`, default
  `FreenetClient.lanes` = 4), picked by the contract id: one contract's
  requests keep their order, different contracts go out at once.
  Subscriptions (and a `get`/`put` with `subscribe: true`), notifications
  and delegates stay on the main connection. Lanes open on first use and
  close after `FreenetClient.laneIdleMs` (60 s) idle. A local node accepts
  the extra connections from one page (checked). Breaks: a page now opens up
  to 5 WebSocket connections; `lanes: 0` keeps the old single connection.

- **freenet.js: a request that times out fails alone.** Before, a timeout
  closed the connection (a late reply could have answered the next
  request), so on a network node one `get` of a contract nobody had put yet
  stalled the page for 30 s and then dropped every request in flight. Now
  the timed-out request rejects (an `Error` with `timedOut: true`) and is
  kept as an orphan whose late answer is dropped; requests name their
  contract, so a late error naming it is dropped too. Before the next
  request, the client checks the node is there (anything it sent, or a
  `NodeQueries(ConnectedPeers)` probe) and reconnects only if nothing comes
  within `FreenetClient.probeMs` (10 s). `get`/`getText` take `timeoutMs`.
  Subscriptions survive a timeout. Breaks: a timeout no longer reconnects
  by itself; code that relied on that (none known) now sees the probe
  decide.

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

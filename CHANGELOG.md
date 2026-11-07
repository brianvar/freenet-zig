# Changelog

What changed, and what breaks. Newest first.

## Unreleased

- **Native client: a request timeout.** `Client.connectWith(gpa, io, host,
  port, .{ .timeout = .fromSeconds(60) })` (or setting `c.timeout`) makes the
  WebSocket handshake and each `get`, `update` and `put` give up after that
  long, sending included, with `error.Timeout`; `lastError()` then says "the
  node at <host:port> didn't answer in <n> s". The connection is given up
  after a timeout (later calls: `error.ConnectionClosed`). `connect` keeps
  its signature and still waits forever. The TCP connect itself is left to
  the system: Zig 0.17's `ConnectOptions.timeout` isn't implemented on
  POSIX. Native only; Wasm modules are unaffected. Nothing breaks.

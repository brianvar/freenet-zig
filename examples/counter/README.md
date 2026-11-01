# Shared counter

A Freenet web app with shared state: every visitor's clicks add up, live.

- `src/counter.zig`: the contract. Its state is a grow-only counter (each
  visitor's count, merged by taking the maximum per visitor). The merge is
  commutative and idempotent, so peers converge whatever order updates arrive in.
  It's tested natively.
- `web/index.html`: the page. It uses `client.contract("counter")`: `get`, or
  `put` if nobody created it yet; then `subscribe`, and `update` on each click.

```sh
zig build test   # contract tests + ABI checks
zig build        # -> zig-out/site, zig-out/bin/{web_container,counter}.wasm
```

Publish the site (the web container) as in the
[getting-started guide](../../docs/getting-started.md#5-run-it-on-a-local-node).
The counter contract doesn't need publishing: the first visitor's page creates
it with `put`. Open the URL in two browser profiles to see the clicks add up.

A demo, not a secure design: anyone can claim any visitor id. A real app
would have each visitor sign their entry with a key held in a delegate.

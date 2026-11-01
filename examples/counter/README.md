# Shared counter

A Freenet web app with shared state: every visitor's clicks add up, live.

- `src/counter.zig`: the contract. Its state is a grow-only counter (each
  visitor's count, merged by taking the maximum per visitor). The merge is
  commutative and idempotent, so peers converge whatever order updates arrive in.
  It's tested natively.
- `src/visitor.zig`: a delegate that gives each visitor a stable id, kept in
  its secrets on the visitor's own node (pages run sandboxed, without
  `localStorage`). It only answers the counter app itself (`d.requireApp()`),
  so other sites can't read the id.
- `web/index.html`: the page. It asks the delegate for the visitor id, then
  uses `client.contract("counter")`: `get`, or `put` if nobody created it yet;
  then `subscribe`, and `update` on each click.

```sh
fdev website init counter-example   # once per machine: the key that signs the site
zig build test   # contract and delegate tests + ABI checks
zig build        # -> zig-out/site (incl. web_container.wasm), zig-out/bin/{counter,visitor}.wasm
```

Publish the site (the web container) as in the
[getting-started guide](../../docs/getting-started.md#5-run-it-on-a-local-node).
The counter contract doesn't need publishing: the first visitor's page creates
it with `put`. Open the URL in two browser profiles to see the clicks add up.

A demo, not a secure design: anyone can claim any visitor id, and anyone can
fill the counter with made-up ids up to its limit of 10,000, after which it
accepts no new visitors. A real app would have each visitor sign their entry
with a key held in a delegate.

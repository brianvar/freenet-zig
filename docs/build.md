# Build helpers and tools

Import the library's `build.zig` in your own:

```zig
const freenet = @import("freenet");

pub fn build(b: *std.Build) void {
    const dep = b.dependencyFromBuildZig(freenet, .{});
    // ...
}
```

## Helpers

### addDelegate / addContract

```zig
const d = freenet.addDelegate(b, dep, .{
    .name = "random",                          // artifact name; page uses client.delegate("random")
    .root_source_file = b.path("src/delegate.zig"),
    .optimize = .small,                        // default
});
const c = freenet.addContract(b, dep, .{ .name = "counter", .root_source_file = b.path("src/counter.zig") });
```

These compile for `wasm32-freestanding`, with the `freenet` module importable,
and export exactly the ABI functions plus `memory`. The root file must call
`exportDelegate` or `exportContract`.

Both return a normal `*std.Build.Step.Compile`. Install it with
`b.installArtifact(d)` to get `zig-out/bin/random.wasm`.

### addWebApp

Packs a page, delegates and contract code with the built-in web container. See
[web-apps.md](web-apps.md#addwebapp).

### addTests

```zig
const tests = freenet.addTests(b, dep, .{
    .sources = &.{ b.path("src/delegate.zig") },   // native tests (freenet.testing)
    .delegates = &.{d},                           // ABI-check these Wasm modules...
    .contracts = &.{app.contract, c},             // ...and these
});
b.step("test", "Run tests").dependOn(tests);
```

`addWebApp` and `addTests` each create a named top-level step (`install-site`,
`freenet-tests`), so call each once per build. For several web apps, give each
its own `install_dir`.

## Tools

Both are built from this package. The helpers run them for you; you can also
run them by hand: `zig build` in this repository installs them to `zig-out/bin`.

### freenet-pack

```
freenet-pack --web-contract <web_container.wasm> --client <freenet.js> --out-dir <dir>
             --file index.html=<path> [--file <name>=<path>]...
             [--delegate <name>=<delegate.wasm>]...
             [--embed-contract <name>=<contract.wasm>]...
```

1. In `.html` files, replaces the script tag for `freenet.js` with the inlined
   client plus `FreenetClient.embedded = { name: { wasm, key, codeHash } }`
   (delegates) and `FreenetClient.contracts = { name: { wasm, codeHash } }`.
2. Packs the files into `web.tar.xz`, then the web-app state.
3. Sets the parameters to BLAKE3(state) and computes the contract key.

It writes `state.bin`, `params.bin`, `web.tar.xz` and `site.txt`. It fails if
`index.html` is missing, or if delegates or contracts are given but no page
includes the client.

### freenet-check-wasm

```
freenet-check-wasm --delegate <a.wasm> ... --contract <b.wasm> ...
```

For each module it checks two things:

- **Exports** must be exactly the ABI for its kind, plus `memory`.
  - Delegates: `process`, `__frnt__initiate_buffer`, `__frnt_set_id`.
  - Contracts: `validate_state`, `update_state`, `summarize_state`,
    `get_state_delta`, `__frnt__initiate_buffer`, `__frnt_set_id`.
- **Imports** must come from what the node provides for that kind: random, log
  and time for both; context and secrets for delegates only.

This catches problems that would otherwise surface as a cryptic load failure on
the node, such as a typo in an export or a leaked toolchain symbol like
`__stack_pointer`.

## Library development

```sh
zig build test   # library unit + wire-format tests, and an ABI check of the web container
```

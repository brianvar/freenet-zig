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
    .optimize = .safe,                         // default; .small drops safety checks
});
const c = freenet.addContract(b, dep, .{ .name = "counter", .root_source_file = b.path("src/counter.zig") });
```

These compile for `wasm32-freestanding`, with the `freenet` module importable,
and export exactly the ABI functions plus `memory`. The root file must call
`exportDelegate` or `exportContract`.

The default, `.safe` (ReleaseSafe), keeps bounds, overflow and `unreachable`
checks: a bug traps instead of silently corrupting the result. Contracts run on
every peer with input from strangers, so keep it unless size really matters.
With `.small` those bugs are undefined behaviour. Debug info is always
stripped from the Wasm: the node refuses modules that contain it.

Both return a normal `*std.Build.Step.Compile`. Install it with
`b.installArtifact(d)` to get `zig-out/bin/random.wasm`.

### addWebApp

Packs a page, delegates and contract code with the built-in signed web
container. Needs a `signing_key`. See [web-apps.md](web-apps.md#addwebapp).

### addAppId

```zig
const app_id = freenet.addAppId(b, dep, "myapp"); // LazyPath: a text file with the base58 id
```

The id `addWebApp` will give the app signed with that key, available before the
page is built (it depends only on the key and the web container). Use it to put
a link back to the app (`/v1/contract/web/<id>/`) into content the app creates.
Needs the key, like `addWebApp`.

### addTests

```zig
freenet.addTests(b, dep, b.step("test", "Run tests"), .{
    .sources = &.{ b.path("src/delegate.zig") },   // native tests (freenet.testing)
    .delegates = &.{d},                           // ABI-check these Wasm modules...
    .contracts = &.{app.contract, c},             // ...and these
});
```

`addTests` adds everything to the step you pass, so it can be called more than
once. `addWebApp` creates a named step (`install-<install_dir>`); for several
web apps, give each its own `install_dir`.

## Tools

Both are built from this package. The helpers run them for you; you can also
run them by hand: `zig build` in this repository installs them to `zig-out/bin`.

### freenet-pack

```
freenet-pack --web-contract <web_container.wasm> --client <freenet.js> --out-dir <dir>
             --key <key name> [--version <n>]
             --file index.html=<path> [--file <name>=<path>]...
             [--delegate <name>=<delegate.wasm>]...
             [--embed-contract <name>=<contract.wasm>]...
freenet-pack --web-contract <web_container.wasm> --key <key name> --app-id-out <file>
```

The second form only writes the app's id (base58) to `<file>` (`addAppId`).

1. Reads the signing key and computes the app's id: the contract key,
   BLAKE3(BLAKE3(web container code) ‖ public key).
2. Writes the archive file `freenet.js`: the client plus
   `FreenetClient.embedded = { name: { wasm, key, codeHash, parameters } }`
   (delegates; `parameters` is the app id, which is also part of `key`) and
   `FreenetClient.contracts = { name: { wasm, codeHash } }`.
3. Packs the files and `freenet.js` into `web.tar.xz`, signs it as release
   `--version` (default: the Unix time) and builds the web-app state.

`--key` is the name of a key made by `fdev website init <name>`, found in
freenet's config directory like `fdev` does, or a file path (see
[web-apps.md](web-apps.md#the-signing-key)).

It writes `web_container.wasm` (a copy of the contract), `state.bin`,
`params.bin` (the public key), `web.tar.xz` and `site.txt`. It fails if the key
is missing or malformed; if `index.html` is missing;
if a name isn't a plain relative path (letters, digits, `_`, `-`, `.`, `/`; no
empty, `.` or `..` parts); if a file is itself named `freenet.js`; if
delegates or contracts are given but no page mentions `freenet.js`; or if the
state is larger than the node accepts (50 MiB).

### freenet-check-wasm

```
freenet-check-wasm --delegate <a.wasm> ... --contract <b.wasm> ...
```

For each module it checks two things:

- **Exports** must be exactly the ABI for its kind, plus `memory`.
  - Delegates: `process`, `__frnt__initiate_buffer`, `__frnt_set_id`.
  - Contracts: `validate_state`, `update_state`, `summarize_state`,
    `get_state_delta`, `__frnt__initiate_buffer`, `__frnt_set_id`.
- **Imports** must come from what the node provides for that kind: log and
  time for both; random, context and secrets for delegates only. (The node
  does give contracts randomness, but a contract must compute the same result
  on every peer, so the checker treats it as a bug.)

This catches problems that would otherwise surface as a cryptic load failure on
the node, such as a typo in an export or a leaked toolchain symbol like
`__stack_pointer`.

## Library development

```sh
zig build test      # library unit + wire-format tests, and an ABI check of the web container
# and open js/test.html in a browser: tests for the browser client
```

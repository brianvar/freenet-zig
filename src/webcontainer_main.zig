//! Root file for building `WebContainer` as a Wasm contract.
const freenet = @import("freenet");

comptime {
    freenet.exportContract(freenet.WebContainer);
}

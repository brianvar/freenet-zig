const std = @import("std");
const freenet = @import("freenet");

pub fn build(b: *std.Build) void {
    const dep = b.dependencyFromBuildZig(freenet, .{});

    const counter = freenet.addContract(b, dep, .{
        .name = "counter",
        .root_source_file = b.path("src/counter.zig"),
    });
    const visitor = freenet.addDelegate(b, dep, .{
        .name = "visitor",
        .root_source_file = b.path("src/visitor.zig"),
    });

    const app = freenet.addWebApp(b, dep, .{
        .page = b.path("web/index.html"),
        .signing_key = "counter-example", // `fdev website init counter-example`
        .delegates = &.{visitor},
        .contracts = &.{counter},
    });
    b.getInstallStep().dependOn(app.install);

    freenet.addTests(b, dep, b.step("test", "Run unit tests and Wasm ABI checks"), .{
        .sources = &.{ b.path("src/counter.zig"), b.path("src/visitor.zig") },
        .delegates = &.{visitor},
        .contracts = &.{ counter, app.contract },
    });
}

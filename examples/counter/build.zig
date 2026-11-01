const std = @import("std");
const freenet = @import("freenet");

pub fn build(b: *std.Build) void {
    const dep = b.dependencyFromBuildZig(freenet, .{});

    const counter = freenet.addContract(b, dep, .{
        .name = "counter",
        .root_source_file = b.path("src/counter.zig"),
    });

    const app = freenet.addWebApp(b, dep, .{
        .page = b.path("web/index.html"),
        .contracts = &.{counter},
    });
    b.getInstallStep().dependOn(app.install);

    const tests = freenet.addTests(b, dep, .{
        .sources = &.{b.path("src/counter.zig")},
        .contracts = &.{ counter, app.contract },
    });
    b.step("test", "Run unit tests and Wasm ABI checks").dependOn(tests);
}

//! freenet-zig build: the `freenet` module, the `freenet-pack` and
//! `freenet-check-wasm` tools, and helpers apps call from their build.zig:
//!
//!     const freenet = @import("freenet");
//!     const dep = b.dependencyFromBuildZig(freenet, .{});
//!     const my_delegate = freenet.addDelegate(b, dep, .{ .name = "random", .root_source_file = b.path("src/delegate.zig") });
//!     const app = freenet.addWebApp(b, dep, .{ .page = b.path("web/index.html"), .delegates = &.{my_delegate} });
//!     b.getInstallStep().dependOn(app.install);
//!
//! See docs/build.md.

const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});

    const mod = b.addModule("freenet", .{ .root_source_file = b.path("src/freenet.zig") });

    const pack = tool(b, mod, "freenet-pack", "tools/pack.zig", target);
    const check = tool(b, mod, "freenet-check-wasm", "tools/check_wasm.zig", target);
    b.installArtifact(pack);
    b.installArtifact(check);

    // Library tests (native) + the built-in web container checked as Wasm.
    const test_step = b.step("test", "Run the library's tests");
    for ([_][]const u8{ "src/freenet.zig", "tools/pack.zig", "tools/check_wasm.zig" }) |path| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .imports = &.{.{ .name = "freenet", .module = mod }},
        }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    const webcontainer = wasmCompile(b, mod, "web_container", b.path("src/webcontainer_main.zig"), .small, &@import("src/abi.zig").contract_exports);
    const run_check = b.addRunArtifact(check);
    run_check.addArg("--contract");
    run_check.addArtifactArg2(webcontainer, .{});
    test_step.dependOn(&run_check.step);
}

fn tool(b: *Build, mod: *Build.Module, name: []const u8, path: []const u8, target: Build.ResolvedTarget) *Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = .safe,
            .imports = &.{.{ .name = "freenet", .module = mod }},
        }),
    });
}

fn wasmCompile(
    b: *Build,
    freenet_module: *Build.Module,
    name: []const u8,
    root: Build.LazyPath,
    optimize: std.lang.Optimize,
    exports: []const []const u8,
) *Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = root,
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = optimize,
            .imports = &.{.{ .name = "freenet", .module = freenet_module }},
        }),
    });
    exe.entry = .disabled; // a set of exports, no _start
    // Export exactly the ABI (`memory` is always exported). `rdynamic` would
    // also leak toolchain symbols such as `__stack_pointer`.
    exe.root_module.export_symbol_names = exports;
    return exe;
}

// ---- helpers for apps ----------------------------------------------------------

pub const ModuleOptions = struct {
    /// Artifact name; for delegates also the name the page uses:
    /// `client.delegate("<name>")`.
    name: []const u8,
    root_source_file: Build.LazyPath,
    optimize: std.lang.Optimize = .small,
};

/// Compiles a delegate to Wasm. The root file imports `freenet` and calls
/// `freenet.exportDelegate(@This())`.
pub fn addDelegate(b: *Build, dep: *Build.Dependency, options: ModuleOptions) *Build.Step.Compile {
    return wasmCompile(b, dep.module("freenet"), options.name, options.root_source_file, options.optimize, &@import("src/abi.zig").delegate_exports);
}

/// Compiles a contract to Wasm. The root file imports `freenet` and calls
/// `freenet.exportContract(@This())`.
pub fn addContract(b: *Build, dep: *Build.Dependency, options: ModuleOptions) *Build.Step.Compile {
    return wasmCompile(b, dep.module("freenet"), options.name, options.root_source_file, options.optimize, &@import("src/abi.zig").contract_exports);
}

pub const File = struct { name: []const u8, path: Build.LazyPath };

pub const WebAppOptions = struct {
    /// The page, packed as `index.html`. Put `<script src="freenet.js"></script>`
    /// in it to get the client and the embedded delegates.
    page: Build.LazyPath,
    /// Delegates (from `addDelegate`) to embed, by artifact name:
    /// `client.delegate("<name>")`.
    delegates: []const *Build.Step.Compile = &.{},
    /// Contracts (from `addContract`) whose code the page needs, by artifact
    /// name: `client.contract("<name>", parameters)`.
    contracts: []const *Build.Step.Compile = &.{},
    /// More files for the archive (CSS, images, more pages).
    files: []const File = &.{},
    /// Directory under the install prefix for the publishable output.
    install_dir: []const u8 = "site",
};

pub const WebApp = struct {
    /// The web-app contract (the built-in content-addressed web container).
    contract: *Build.Step.Compile,
    /// Output directory: state.bin, params.bin, web.tar.xz, site.txt.
    output: Build.LazyPath,
    /// Installs `output` to `<prefix>/<install_dir>` and the Wasm modules to `<prefix>/bin`.
    install: *Build.Step,
};

/// Packs a page and its delegates into a publishable web app using the
/// built-in web-container contract.
pub fn addWebApp(b: *Build, dep: *Build.Dependency, options: WebAppOptions) WebApp {
    const contract = wasmCompile(b, dep.module("freenet"), "web_container", dep.path("src/webcontainer_main.zig"), .small, &@import("src/abi.zig").contract_exports);

    const run = b.addRunArtifact(dep.artifact("freenet-pack"));
    run.addArg("--web-contract");
    run.addArtifactArg2(contract, .{});
    run.addArg("--client");
    run.addFileArg(dep.path("js/freenet.js"));
    run.addArg("--file");
    run.addFileArg2(options.page, .{ .prefix = "index.html=" });
    for (options.files) |f| {
        run.addArg("--file");
        run.addFileArg2(f.path, .{ .prefix = b.fmt("{s}=", .{f.name}) });
    }
    for (options.delegates) |d| {
        run.addArg("--delegate");
        run.addArtifactArg2(d, .{ .prefix = b.fmt("{s}=", .{d.name}) });
    }
    for (options.contracts) |c| {
        run.addArg("--embed-contract");
        run.addArtifactArg2(c, .{ .prefix = b.fmt("{s}=", .{c.name}) });
    }
    run.addArg("--out-dir");
    const output = run.addOutputDirectoryArg2("site", .{});

    const install = b.step(b.fmt("install-{s}", .{options.install_dir}), "Install the packed web app");
    install.dependOn(&b.addInstallDirectory(.{ .source_dir = output, .install_dir = .prefix, .install_subdir = options.install_dir }).step);
    install.dependOn(&b.addInstallArtifact(contract, .{}).step);
    for (options.delegates) |d| install.dependOn(&b.addInstallArtifact(d, .{}).step);
    for (options.contracts) |c| install.dependOn(&b.addInstallArtifact(c, .{}).step);

    return .{ .contract = contract, .output = output, .install = install };
}

pub const TestOptions = struct {
    /// Native unit tests: Zig files whose tests use `freenet.testing`.
    sources: []const Build.LazyPath = &.{},
    /// Compiled delegates to check against the ABI.
    delegates: []const *Build.Step.Compile = &.{},
    /// Compiled contracts to check against the ABI.
    contracts: []const *Build.Step.Compile = &.{},
};

/// Native unit tests for your delegates/contracts plus ABI checks of the
/// compiled Wasm. Add the returned step to your `test` step.
pub fn addTests(b: *Build, dep: *Build.Dependency, options: TestOptions) *Build.Step {
    const step = b.step("freenet-tests", "Freenet unit tests and Wasm ABI checks");
    for (options.sources) |src| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = src,
            .target = b.graph.host,
            .imports = &.{.{ .name = "freenet", .module = dep.module("freenet") }},
        }) });
        step.dependOn(&b.addRunArtifact(t).step);
    }
    if (options.delegates.len + options.contracts.len > 0) {
        const check = b.addRunArtifact(dep.artifact("freenet-check-wasm"));
        if (options.delegates.len > 0) check.addArg("--delegate");
        for (options.delegates) |d| check.addArtifactArg2(d, .{});
        if (options.contracts.len > 0) check.addArg("--contract");
        for (options.contracts) |c| check.addArtifactArg2(c, .{});
        step.dependOn(&check.step);
    }
    return step;
}

//! freenet-pack: turns a web page (plus delegates) into a publishable, signed
//! web app. Needs nothing but Zig. Normally invoked through `addWebApp` in
//! build.zig.
//!
//!   freenet-pack --web-contract <web_container.wasm> --client <freenet.js> --out-dir <dir>
//!                --key <key file> [--version <n>]
//!                --file index.html=<path> [--file <name>=<path>]...
//!                [--delegate <name>=<delegate.wasm>]...
//!                [--embed-contract <name>=<contract.wasm>]...
//!   freenet-pack --web-contract <web_container.wasm> --key <key file> --app-id-out <file>
//!   freenet-pack --web-contract <web_container.wasm> --key <key file> [--version <n>]
//!                --archive <web.tar.xz> --out-dir <dir>
//!
//! * `--key` is the *name* of a key made by `fdev website init <name>`
//!   (freenet-core's own tool). It is looked up where `fdev` keeps it,
//!   `<config dir>/freenet/website-keys/<name>.toml`, so projects name a key
//!   and each machine has its own copy. A value with a `/` or `\` or ending in
//!   `.toml` or `.key` is taken as a file path instead (for CI), either an
//!   `fdev` file or just the 32-byte Ed25519 seed as 64 hex characters.
//! * The client plus the embedded delegates (Wasm + key + parameters),
//!   contracts (Wasm + code hash) and the app's id become the archive file `freenet.js`, which
//!   pages load with `<script src="freenet.js"></script>`.
//! * A delegate's parameters are the web app's contract id, so that it can
//!   check `d.origin` (`Delegate.requireApp`). The id is
//!   BLAKE3(BLAKE3(web container code) ‖ public key): it does not depend on
//!   the site, so it stays the same across releases.
//! * The files are packed into `web.tar.xz`, signed with the key as release
//!   `--version` (default: the current Unix time) and stored as the state.
//! * In the `.html` files, `src="name"` and `href="name"` that name a packed
//!   file (freenet.js included) become `name?v=<release>`: the node serves a
//!   page uncached but its files with validators only, so without a new URL a
//!   browser may keep an old stylesheet beside a new script after an update.
//!   Parameters = the public key (what the built-in web container expects).
//!
//! Writes to <dir>: web_container.wasm, state.bin, params.bin, web.tar.xz, site.txt
//!
//! With `--app-id-out`, it only writes the app's id (base58, as in URLs) to
//! that file. The id doesn't depend on the site, so a build can know it before
//! the page exists (`addAppId`), for instance to link to the app from elsewhere.
//!
//! With `--archive`, it signs an archive the build made itself (a stored .xz
//! around a tar, as `webapp.xzStore(webapp.tar(...))` writes it) as it is: no
//! `freenet.js`, no `?v=` references, so the archive's bytes, and a hash of
//! them, don't depend on the release number (`addSignedArchive`). For files
//! that aren't an app: downloads, a static page. Writes web_container.wasm,
//! state.bin, params.bin and site.txt.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const Ed25519 = std.crypto.sign.Ed25519;
const freenet = @import("freenet");

const client_name = "freenet.js";
const max_file = 64 * 1024 * 1024;

const Named = struct { name: []const u8, path: []const u8 };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var contract_path: ?[]const u8 = null;
    var key_path: ?[]const u8 = null;
    var version: ?u32 = null;
    var client_path: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var app_id_out: ?[]const u8 = null;
    var archive_path: ?[]const u8 = null;
    var files: std.ArrayList(Named) = .empty;
    var delegates: std.ArrayList(Named) = .empty;
    var contracts: std.ArrayList(Named) = .empty;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (i + 1 >= args.len) return usage("missing value for {s}", .{arg});
        const value = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, arg, "--web-contract")) {
            contract_path = value;
        } else if (std.mem.eql(u8, arg, "--client")) {
            client_path = value;
        } else if (std.mem.eql(u8, arg, "--out-dir")) {
            out_dir = value;
        } else if (std.mem.eql(u8, arg, "--key")) {
            key_path = value;
        } else if (std.mem.eql(u8, arg, "--app-id-out")) {
            app_id_out = value;
        } else if (std.mem.eql(u8, arg, "--archive")) {
            archive_path = value;
        } else if (std.mem.eql(u8, arg, "--version")) {
            version = std.fmt.parseInt(u32, value, 10) catch return usage("--version must be a whole number above 0, got {s}", .{value});
            if (version.? == 0) return usage("--version must be above 0", .{});
        } else if (std.mem.eql(u8, arg, "--file")) {
            try files.append(arena, try splitNamed(value));
        } else if (std.mem.eql(u8, arg, "--delegate")) {
            try delegates.append(arena, try splitNamed(value));
        } else if (std.mem.eql(u8, arg, "--embed-contract")) {
            try contracts.append(arena, try splitNamed(value));
        } else return usage("unknown option {s}", .{arg});
    }
    if (app_id_out != null) {
        if (contract_path == null or key_path == null) return usage("--app-id-out needs --web-contract and --key", .{});
    } else if (archive_path != null) {
        if (contract_path == null or out_dir == null or key_path == null) return usage("--archive needs --web-contract, --key and --out-dir", .{});
        if (client_path != null or files.items.len + delegates.items.len + contracts.items.len > 0)
            return usage("--archive signs the archive as it is: no --client, --file, --delegate or --embed-contract", .{});
    } else if (contract_path == null or client_path == null or out_dir == null or key_path == null)
        return usage("--web-contract, --client, --key and --out-dir are required", .{});

    const cwd = Io.Dir.cwd();
    const read = struct {
        fn f(io_: Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
            return Io.Dir.cwd().readFileAlloc(io_, path, gpa, .limited(max_file)) catch |err| {
                std.debug.print("freenet-pack: cannot read {s}: {t}\n", .{ path, err });
                return err;
            };
        }
    }.f;

    // The signing key, and the web app's id (see the module comment).
    const key_pair = try readKey(io, arena, init.environ_map, key_path.?);
    const public_key = key_pair.public_key.toBytes();
    const contract_wasm = try read(io, arena, contract_path.?);
    const app_id = freenet.types.contractInstanceId(contract_wasm, &public_key);
    if (app_id_out) |path| {
        var id_b58: [64]u8 = undefined;
        return Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = freenet.types.encodeBase58(&id_b58, &app_id) });
    }
    if (archive_path) |path| {
        const release = version orelse try unixTime(io);
        const state = signArchive(arena, key_pair, release, try read(io, arena, path)) catch |err| switch (err) {
            error.NotXz => return usage("{s} isn't an .xz archive (webapp.xzStore writes one)", .{path}),
            error.TooLarge => return usage("{s} makes a state over the {d} bytes the node stores", .{ path, freenet.webapp.max_state_size }),
            else => |e| return e,
        };
        var b58: [64]u8 = undefined;
        const key = freenet.types.encodeBase58(&b58, &app_id);
        try cwd.createDirPath(io, out_dir.?);
        var dir = try cwd.openDir(io, out_dir.?, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "web_container.wasm", .data = contract_wasm });
        try dir.writeFile(io, .{ .sub_path = "state.bin", .data = state });
        try dir.writeFile(io, .{ .sub_path = "params.bin", .data = &public_key });
        try dir.writeFile(io, .{ .sub_path = "site.txt", .data = try arena.print(
            \\contract key: {s}
            \\local URL:    http://127.0.0.1:7509/v1/contract/web/{s}/
            \\release:      {d}
            \\state size:   {d} bytes
            \\
        , .{ key, key, release, state.len }) });
        return;
    }

    // freenet.js = the client + the embedded delegates and contracts.
    var client_js: Io.Writer.Allocating = .init(arena);
    const cw = &client_js.writer;
    try cw.writeAll(try read(io, arena, client_path.?));
    var key_lines: Io.Writer.Allocating = .init(arena);
    try cw.writeAll("\nFreenetClient.embedded = {");
    for (delegates.items, 0..) |d, n| {
        const wasm = try read(io, arena, d.path);
        const key = freenet.types.delegateKey(wasm, &app_id);
        try cw.print("{s}\n  \"{s}\": {{ wasm: \"{s}\", key: \"{s}\", codeHash: \"{s}\", parameters: \"{s}\" }}", .{
            if (n == 0) "" else ",",              d.name,                                           try base64(arena, wasm),
            &std.fmt.bytesToHex(key.key, .lower), &std.fmt.bytesToHex(key.code_hash, .lower), &std.fmt.bytesToHex(app_id, .lower),
        });
        var b58: [64]u8 = undefined;
        try key_lines.writer.print("delegate {s}: {s}\n", .{ d.name, freenet.types.encodeBase58(&b58, &key.key) });
    }
    try cw.writeAll("\n};\nFreenetClient.contracts = {");
    for (contracts.items, 0..) |c, n| {
        const wasm = try read(io, arena, c.path);
        const code_hash = freenet.types.codeHash(wasm);
        try cw.print("{s}\n  \"{s}\": {{ wasm: \"{s}\", codeHash: \"{s}\" }}", .{
            if (n == 0) "" else ",", c.name, try base64(arena, wasm), &std.fmt.bytesToHex(code_hash, .lower),
        });
        var b58: [64]u8 = undefined;
        try key_lines.writer.print("contract code {s}: {s}\n", .{ c.name, freenet.types.encodeBase58(&b58, &code_hash) });
    }
    try cw.writeAll("\n};\n");
    try cw.print("FreenetClient.appId = \"{s}\";\n", .{&std.fmt.bytesToHex(app_id, .lower)});

    // The archive: the given files plus freenet.js.
    const release = version orelse try unixTime(io);
    var packed_files: std.ArrayList(freenet.webapp.File) = .empty;
    var has_index = false;
    var loads_client = false;
    for (files.items) |f| {
        if (std.mem.eql(u8, f.name, client_name))
            return usage("{s} is generated; don't pass a file with that name", .{client_name});
        const data = try read(io, arena, f.path);
        if (std.mem.endsWith(u8, f.name, ".html"))
            loads_client = loads_client or std.mem.indexOf(u8, data, client_name) != null;
        has_index = has_index or std.mem.eql(u8, f.name, "index.html");
        try packed_files.append(arena, .{ .name = f.name, .data = data });
    }
    if (!has_index) return usage("the web app needs a file named index.html", .{});
    if (delegates.items.len + contracts.items.len > 0 and !loads_client)
        return usage("delegates/contracts were given but no .html file loads {s}", .{client_name});
    try packed_files.append(arena, .{ .name = client_name, .data = client_js.written() });

    // Pages load the site's own files as `name?v=<release>`, so a browser
    // never keeps an old stylesheet or script beside a new page
    // (`webapp.versionRefs`).
    const names = try arena.alloc([]const u8, packed_files.items.len);
    for (packed_files.items, names) |f, *n| n.* = f.name;
    for (packed_files.items) |*f| {
        if (std.mem.endsWith(u8, f.name, ".html")) f.data = try freenet.webapp.versionRefs(arena, f.data, names, release);
    }

    const archive = try freenet.webapp.xzStore(arena, try freenet.webapp.tar(arena, packed_files.items));
    const state = try freenet.webapp.signState(arena, key_pair, release, archive);
    if (state.len > freenet.webapp.max_state_size)
        return usage("the site is {d} bytes; the node stores at most {d} (archives are not compressed)", .{ state.len, freenet.webapp.max_state_size });
    var b58: [64]u8 = undefined;
    const key = freenet.types.encodeBase58(&b58, &app_id);

    try cwd.createDirPath(io, out_dir.?);
    var dir = try cwd.openDir(io, out_dir.?, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "web_container.wasm", .data = contract_wasm });
    try dir.writeFile(io, .{ .sub_path = "state.bin", .data = state });
    try dir.writeFile(io, .{ .sub_path = "params.bin", .data = &public_key });
    try dir.writeFile(io, .{ .sub_path = "web.tar.xz", .data = archive });
    try dir.writeFile(io, .{ .sub_path = "site.txt", .data = try arena.print(
        \\contract key: {s}
        \\local URL:    http://127.0.0.1:7509/v1/contract/web/{s}/
        \\release:      {d}
        \\state size:   {d} bytes
        \\{s}
    , .{ key, key, release, state.len, key_lines.written() }) });
}

/// The web-container state for `archive` as it is (`--archive`): signed as
/// release `version`, nothing added. Only a stored .xz (by its magic; the node
/// reads it), and no larger than the node stores.
pub fn signArchive(gpa: std.mem.Allocator, key_pair: Ed25519.KeyPair, version: u32, archive: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, archive, "\xFD7zXZ\x00")) return error.NotXz;
    const state = try freenet.webapp.signState(gpa, key_pair, version, archive);
    if (state.len > freenet.webapp.max_state_size) {
        gpa.free(state);
        return error.TooLarge;
    }
    return state;
}

test "signArchive: the archive as it is, valid for the web container with the key as parameters" {
    const a = std.testing.allocator;
    const kp = try Ed25519.KeyPair.generateDeterministic(@splat(3));
    const tar = try freenet.webapp.tar(a, &.{ .{ .name = "install.sh", .data = "#!/bin/sh\n" }, .{ .name = "tool-linux", .data = "\x7fELF" } });
    defer a.free(tar);
    const archive = try freenet.webapp.xzStore(a, tar);
    defer a.free(archive);
    const state = try signArchive(a, kp, 7, archive);
    defer a.free(state);
    const parsed = try freenet.webapp.parseState(state);
    try std.testing.expectEqualSlices(u8, archive, parsed.archive); // nothing added or rewritten
    try std.testing.expectEqual(@as(u32, 7), (try freenet.webapp.verifyState(kp.public_key.toBytes(), state)).version);
    try std.testing.expectError(error.NotXz, signArchive(a, kp, 7, tar));
}

/// Where `fdev website init` keeps key `name`: `dirs::config_dir()` +
/// `freenet/website-keys/<name>.toml`.
fn keyFilePath(arena: std.mem.Allocator, env: anytype, name: []const u8) ![]const u8 {
    const home = env.get("HOME") orelse "";
    const dir = switch (builtin.os.tag) {
        .macos => try arena.print("{s}/Library/Application Support", .{home}),
        .windows => env.get("APPDATA") orelse return fail("APPDATA is not set, so the signing key {s} can't be found; pass a file path", .{name}),
        else => if (env.get("XDG_CONFIG_HOME")) |xdg| xdg else try arena.print("{s}/.config", .{home}),
    };
    return arena.print("{s}/freenet/website-keys/{s}.toml", .{ dir, name });
}

/// The key `name` (see the module comment), as an `fdev website init` file
/// (`signing_key = "<hex>"`) or the 32-byte seed as 64 hex characters.
fn readKey(io: Io, arena: std.mem.Allocator, env: anytype, name: []const u8) !Ed25519.KeyPair {
    const is_path = std.mem.indexOfAny(u8, name, "/\\") != null or std.mem.endsWith(u8, name, ".toml") or std.mem.endsWith(u8, name, ".key");
    const path = if (is_path) name else try keyFilePath(arena, env, name);
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch |err| {
        std.debug.print("freenet-pack: cannot read the signing key {s} ({s}): {t}. Create it with `fdev website init {s}`.\n", .{ name, path, err, name });
        return err;
    };
    var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
    const hex = if (std.mem.indexOf(u8, text, "signing_key")) |at| quoted: {
        const open = std.mem.indexOfScalarPos(u8, text, at, '"') orelse return fail("{s}: signing_key has no value", .{path});
        const close = std.mem.indexOfScalarPos(u8, text, open + 1, '"') orelse return fail("{s}: signing_key has no value", .{path});
        break :quoted text[open + 1 .. close];
    } else std.mem.trim(u8, text, " \t\r\n");
    if (hex.len != seed.len * 2) return fail("{s} is not a signing key (expected 64 hex characters)", .{path});
    _ = std.fmt.hexToBytes(&seed, hex) catch return fail("{s} is not a signing key (expected 64 hex characters)", .{path});
    return Ed25519.KeyPair.generateDeterministic(seed) catch return fail("{s} is not a usable signing key", .{path});
}

fn fail(comptime fmt: []const u8, args: anytype) error{InvalidKey} {
    std.debug.print("freenet-pack: " ++ fmt ++ "\n", args);
    return error.InvalidKey;
}

/// Seconds since the Unix epoch: the default release number, which grows with
/// every build (the container only accepts a higher number than the current one).
fn unixTime(io: Io) !u32 {
    const now = Io.Clock.real.now(io);
    return std.math.cast(u32, now.toSeconds()) orelse return fail("the system clock is out of range; pass --version", .{});
}

fn base64(gpa: std.mem.Allocator, data: []const u8) ![]const u8 {
    const out = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(data.len));
    return std.base64.standard.Encoder.encode(out, data);
}

/// `name=path`. The name is an archive path (or a delegate/contract name):
/// `/`-separated segments of letters, digits, `_`, `-` and `.`, with no empty,
/// `.` or `..` segments.
fn splitNamed(value: []const u8) !Named {
    const eq = std.mem.indexOfScalar(u8, value, '=') orelse return usage("expected name=path, got {s}", .{value});
    const name = value[0..eq];
    for (name) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '/' => {},
        else => return usage("unsupported character in name {s}", .{name}),
    };
    var segments = std.mem.splitScalar(u8, name, '/');
    while (segments.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, ".."))
            return usage("name {s} must be a relative path without empty, . or .. parts", .{name});
    }
    return .{ .name = name, .path = value[eq + 1 ..] };
}

fn usage(comptime fmt: []const u8, args: anytype) error{InvalidArgs} {
    std.debug.print("freenet-pack: " ++ fmt ++ "\n", args);
    std.debug.print(
        \\usage: freenet-pack --web-contract <wasm> --client <freenet.js> --out-dir <dir>
        \\                    --key <key file> [--version <n>]
        \\                    --file index.html=<path> [--file <name>=<path>]...
        \\                    [--delegate <name>=<wasm>]... [--embed-contract <name>=<wasm>]...
        \\       freenet-pack --web-contract <wasm> --key <key file> --app-id-out <file>
        \\       freenet-pack --web-contract <wasm> --key <key file> [--version <n>] --archive <web.tar.xz> --out-dir <dir>
        \\
    , .{});
    return error.InvalidArgs;
}

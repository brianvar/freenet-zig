//! freenet-pack: turns a web page (plus delegates) into a publishable web app.
//! Needs nothing but Zig. Normally invoked through `addWebApp` in build.zig.
//!
//!   freenet-pack --web-contract <web_container.wasm> --client <freenet.js> --out-dir <dir>
//!                --file index.html=<path> [--file <name>=<path>]...
//!                [--delegate <name>=<delegate.wasm>]...
//!                [--embed-contract <name>=<contract.wasm>]...
//!
//! * In every `.html` file, `<script src="freenet.js"></script>` is replaced
//!   with the inlined client plus the embedded delegates (Wasm + keys) and
//!   contracts (Wasm + code hash).
//! * The files are packed into `web.tar.xz` and the web-app state.
//! * Parameters = BLAKE3(state) (what the built-in web container expects).
//!
//! Writes to <dir>: state.bin, params.bin, web.tar.xz, site.txt

const std = @import("std");
const Io = std.Io;
const freenet = @import("freenet");

const script_tag = "<script src=\"freenet.js\"></script>";
const max_file = 64 * 1024 * 1024;

const Named = struct { name: []const u8, path: []const u8 };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var contract_path: ?[]const u8 = null;
    var client_path: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, arg, "--file")) {
            try files.append(arena, try splitNamed(value));
        } else if (std.mem.eql(u8, arg, "--delegate")) {
            try delegates.append(arena, try splitNamed(value));
        } else if (std.mem.eql(u8, arg, "--embed-contract")) {
            try contracts.append(arena, try splitNamed(value));
        } else return usage("unknown option {s}", .{arg});
    }
    if (contract_path == null or client_path == null or out_dir == null)
        return usage("--web-contract, --client and --out-dir are required", .{});

    const cwd = Io.Dir.cwd();
    const read = struct {
        fn f(io_: Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
            return Io.Dir.cwd().readFileAlloc(io_, path, gpa, .limited(max_file)) catch |err| {
                std.debug.print("freenet-pack: cannot read {s}: {t}\n", .{ path, err });
                return err;
            };
        }
    }.f;

    // Delegates: Wasm + keys, rendered as a JS object for the client.
    var embedded: Io.Writer.Allocating = .init(arena);
    const ew = &embedded.writer;
    try ew.writeAll("FreenetClient.embedded = {");
    var delegate_lines: Io.Writer.Allocating = .init(arena);
    for (delegates.items, 0..) |d, n| {
        const wasm = try read(io, arena, d.path);
        const key = freenet.types.delegateKey(wasm, "");
        const b64 = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(wasm.len));
        _ = std.base64.standard.Encoder.encode(b64, wasm);
        try ew.print("{s}\n  \"{s}\": {{ wasm: \"{s}\", key: \"{s}\", codeHash: \"{s}\" }}", .{
            if (n == 0) "" else ",",              d.name,                                     b64,
            &std.fmt.bytesToHex(key.key, .lower), &std.fmt.bytesToHex(key.code_hash, .lower),
        });
        var b58: [64]u8 = undefined;
        try delegate_lines.writer.print("delegate {s}: {s}\n", .{ d.name, freenet.types.encodeBase58(&b58, &key.key) });
    }
    try ew.writeAll("\n};\nFreenetClient.contracts = {");
    for (contracts.items, 0..) |c, n| {
        const wasm = try read(io, arena, c.path);
        const b64 = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(wasm.len));
        _ = std.base64.standard.Encoder.encode(b64, wasm);
        try ew.print("{s}\n  \"{s}\": {{ wasm: \"{s}\", codeHash: \"{s}\" }}", .{
            if (n == 0) "" else ",", c.name, b64, &std.fmt.bytesToHex(freenet.types.codeHash(wasm), .lower),
        });
        var b58: [64]u8 = undefined;
        try delegate_lines.writer.print("contract code {s}: {s}\n", .{ c.name, freenet.types.encodeBase58(&b58, &freenet.types.codeHash(wasm)) });
    }
    try ew.writeAll("\n};\n");

    const client = try read(io, arena, client_path.?);
    if (std.mem.indexOf(u8, client, "</script") != null) return usage("client script must not contain </script", .{});
    const inline_script = try std.mem.concat(arena, u8, &.{ "<script>\n", client, "\n", embedded.written(), "</script>" });

    // Files, with the client inlined into HTML pages.
    var packed_files: std.ArrayList(freenet.webapp.File) = .empty;
    var has_index = false;
    var inlined: usize = 0;
    for (files.items) |f| {
        var data: []const u8 = try read(io, arena, f.path);
        if (std.mem.endsWith(u8, f.name, ".html")) {
            const count = std.mem.count(u8, data, script_tag);
            if (count > 0) data = try std.mem.replaceOwned(u8, arena, data, script_tag, inline_script);
            inlined += count;
        }
        has_index = has_index or std.mem.eql(u8, f.name, "index.html");
        try packed_files.append(arena, .{ .name = f.name, .data = data });
    }
    if (!has_index) return usage("the web app needs a file named index.html", .{});
    if (delegates.items.len + contracts.items.len > 0 and inlined == 0)
        return usage("delegates/contracts were given but no .html file contains {s}", .{script_tag});

    const archive = try freenet.webapp.xzStore(arena, try freenet.webapp.tar(arena, packed_files.items));
    const state = try freenet.webapp.buildState(arena, "", archive);
    const params = freenet.types.blake3(&.{state});
    const contract_wasm = try read(io, arena, contract_path.?);
    var b58: [64]u8 = undefined;
    const key = freenet.types.encodeBase58(&b58, &freenet.types.contractInstanceId(contract_wasm, &params));

    try cwd.createDirPath(io, out_dir.?);
    var dir = try cwd.openDir(io, out_dir.?, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "state.bin", .data = state });
    try dir.writeFile(io, .{ .sub_path = "params.bin", .data = &params });
    try dir.writeFile(io, .{ .sub_path = "web.tar.xz", .data = archive });
    try dir.writeFile(io, .{ .sub_path = "site.txt", .data = try arena.print(
        \\contract key: {s}
        \\local URL:    http://127.0.0.1:7509/v1/contract/web/{s}/
        \\state size:   {d} bytes
        \\{s}
    , .{ key, key, state.len, delegate_lines.written() }) });
}

fn splitNamed(value: []const u8) !Named {
    const eq = std.mem.indexOfScalar(u8, value, '=') orelse return usage("expected name=path, got {s}", .{value});
    const name = value[0..eq];
    if (name.len == 0) return usage("empty name in {s}", .{value});
    for (name) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '/' => {},
        else => return usage("unsupported character in name {s}", .{name}),
    };
    return .{ .name = name, .path = value[eq + 1 ..] };
}

fn usage(comptime fmt: []const u8, args: anytype) error{InvalidArgs} {
    std.debug.print("freenet-pack: " ++ fmt ++ "\n", args);
    std.debug.print(
        \\usage: freenet-pack --web-contract <wasm> --client <freenet.js> --out-dir <dir>
        \\                    --file index.html=<path> [--file <name>=<path>]...
        \\                    [--delegate <name>=<wasm>]... [--embed-contract <name>=<wasm>]...
        \\
    , .{});
    return error.InvalidArgs;
}

//! freenet-check-wasm: verifies compiled modules against the Freenet ABI.
//! Normally run through `addWasmCheck` / `addTests` in build.zig.
//!
//!   freenet-check-wasm --delegate <file.wasm> ... --contract <file.wasm> ...
//!
//! * exports must be exactly the ABI for the kind (plus `memory`)
//! * imports must come from what the node provides for that kind
//!
//! Catches mistakes that would otherwise only show as a load failure on the
//! node: a missing export, a leaked toolchain export, an unknown import.

const std = @import("std");
const Io = std.Io;
const freenet = @import("freenet");

const Kind = enum { delegate, contract };

const common_imports = [_][]const u8{
    "freenet_rand.__frnt__rand__rand_bytes",
    "freenet_log.__frnt__logger__info",
    "freenet_time.__frnt__time__utc_now",
};

const delegate_only_imports = [_][]const u8{
    "freenet_delegate_ctx.__frnt__delegate__ctx_len",
    "freenet_delegate_ctx.__frnt__delegate__ctx_read",
    "freenet_delegate_ctx.__frnt__delegate__ctx_write",
    "freenet_delegate_secrets.__frnt__delegate__get_secret",
    "freenet_delegate_secrets.__frnt__delegate__get_secret_len",
    "freenet_delegate_secrets.__frnt__delegate__set_secret",
    "freenet_delegate_secrets.__frnt__delegate__has_secret",
    "freenet_delegate_secrets.__frnt__delegate__remove_secret",
    "freenet_delegate_secrets.__frnt__delegate__list_secrets_len",
    "freenet_delegate_secrets.__frnt__delegate__list_secrets",
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.debug.print("usage: freenet-check-wasm (--delegate|--contract) <file.wasm> ...\n", .{});
        return error.InvalidArgs;
    }
    var kind: ?Kind = null;
    var ok = true;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--delegate")) {
            kind = .delegate;
        } else if (std.mem.eql(u8, arg, "--contract")) {
            kind = .contract;
        } else {
            const k = kind orelse {
                std.debug.print("freenet-check-wasm: say --delegate or --contract before {s}\n", .{arg});
                return error.InvalidArgs;
            };
            const bytes = try Io.Dir.cwd().readFileAlloc(init.io, arg, arena, .limited(64 * 1024 * 1024));
            ok = check(arena, arg, k, bytes) and ok;
        }
    }
    if (!ok) return error.WasmAbiMismatch;
}

fn check(arena: std.mem.Allocator, path: []const u8, kind: Kind, bytes: []const u8) bool {
    const found = parse(arena, bytes) catch |err| {
        std.debug.print("{s}: not a valid Wasm module ({t})\n", .{ path, err });
        return false;
    };
    var ok = true;

    const abi_exports: []const []const u8 = switch (kind) {
        .delegate => &freenet.abi.delegate_exports,
        .contract => &freenet.abi.contract_exports,
    };
    var want: std.ArrayList([]const u8) = .empty;
    want.appendSlice(arena, abi_exports) catch return false;
    want.append(arena, "memory") catch return false;
    if (!sameSet(found.exports, want.items)) {
        std.debug.print("{s}: exports don't match the {t} ABI\n", .{ path, kind });
        printList("  got: ", found.exports);
        printList("  want:", want.items);
        ok = false;
    }

    for (found.imports) |imp| {
        const allowed = contains(&common_imports, imp) or (kind == .delegate and contains(&delegate_only_imports, imp));
        if (!allowed) {
            std.debug.print("{s}: import {s} is not provided to a {t} by the node\n", .{ path, imp, kind });
            ok = false;
        }
    }
    return ok;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

fn sameSet(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a) |x| if (!contains(b, x)) return false;
    return true;
}

fn printList(label: []const u8, items: []const []const u8) void {
    std.debug.print("{s}", .{label});
    for (items) |item| std.debug.print(" {s}", .{item});
    std.debug.print("\n", .{});
}

pub const Found = struct { exports: []const []const u8, imports: []const []const u8 };

/// Reads the import (id 2) and export (id 7) sections of a Wasm binary.
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) !Found {
    var r: Reader = .{ .b = bytes };
    if (!std.mem.eql(u8, try r.take(8), "\x00asm\x01\x00\x00\x00")) return error.NotWasm;
    var exports: std.ArrayList([]const u8) = .empty;
    var imports: std.ArrayList([]const u8) = .empty;
    while (r.pos < bytes.len) {
        const id = (try r.take(1))[0];
        var s: Reader = .{ .b = try r.take(try r.leb()) };
        switch (id) {
            2 => for (0..try s.leb()) |_| {
                const module = try s.name();
                const field = try s.name();
                try imports.append(arena, try std.mem.concat(arena, u8, &.{ module, ".", field }));
                switch ((try s.take(1))[0]) {
                    0 => _ = try s.leb(), // func: type index
                    1 => { // table: reftype + limits
                        _ = try s.take(1);
                        try s.limits();
                    },
                    2 => try s.limits(), // memory
                    3 => _ = try s.take(2), // global: valtype + mutability
                    else => return error.UnknownImportKind,
                }
            },
            7 => for (0..try s.leb()) |_| {
                try exports.append(arena, try s.name());
                _ = try s.take(1); // kind
                _ = try s.leb(); // index
            },
            else => {},
        }
    }
    return .{ .exports = exports.items, .imports = imports.items };
}

const Reader = struct {
    b: []const u8,
    pos: usize = 0,

    fn take(r: *Reader, n: usize) ![]const u8 {
        if (r.b.len - r.pos < n) return error.Truncated;
        defer r.pos += n;
        return r.b[r.pos..][0..n];
    }

    fn leb(r: *Reader) !usize {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const byte = (try r.take(1))[0];
            result |= @as(u64, byte & 0x7f) << shift;
            if (byte & 0x80 == 0) return @intCast(result);
            shift = std.math.add(u6, shift, 7) catch return error.BadLeb;
        }
    }

    fn name(r: *Reader) ![]const u8 {
        return r.take(try r.leb());
    }

    fn limits(r: *Reader) !void {
        const flags = (try r.take(1))[0];
        _ = try r.leb();
        if (flags & 1 != 0) _ = try r.leb();
    }
};

test "parses a hand-made module" {
    // (module (import "env" "f" (func)) (memory (export "memory") 1))
    const wasm = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x04\x01\x60\x00\x00" ++ // type section: () -> ()
        "\x02\x09\x01\x03env\x01f\x00\x00" ++ // import env.f
        "\x05\x03\x01\x00\x01" ++ // memory section: 1 page
        "\x07\x0a\x01\x06memory\x02\x00"; // export "memory"
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const found = try parse(arena.allocator(), wasm);
    try std.testing.expectEqualStrings("env.f", found.imports[0]);
    try std.testing.expectEqualStrings("memory", found.exports[0]);
}

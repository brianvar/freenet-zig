//! The raw Freenet Wasm ABI: buffers, result structs and the allocator.
//! You normally don't use this directly; `exportDelegate`/`exportContract`
//! wrap it. Reference: https://freenet.org/build/manual/contract-abi
//!
//! * The host asks the module for buffers via `__frnt__initiate_buffer`,
//!   writes the payload at `start` and stores its length in `*last_write`.
//! * Entry points return a pointer to a small result struct that points at a
//!   bincode-encoded payload.
//! * Nothing is ever freed: the host discards the whole instance after each
//!   call, so `allocator` simply never frees.

const std = @import("std");
const builtin = @import("builtin");

pub const is_wasm = builtin.cpu.arch.isWasm();

/// Allocator for everything that lives during one host call. On Freenet this
/// is Wasm linear memory, reclaimed when the node drops the instance. Native
/// builds (tests) use a general purpose allocator and also never free.
pub const allocator: std.mem.Allocator = if (is_wasm) std.heap.wasm_allocator else std.heap.smp_allocator;

/// Mirrors `freenet_stdlib::memory::buf::BufferBuilder` (32 bytes, align 8).
pub const BufferBuilder = extern struct {
    start: i64,
    capacity: u32,
    _pad: u32 = 0,
    /// Pointer to a u32 read position.
    last_read: i64,
    /// Pointer to a u32 write position (= bytes the host wrote).
    last_write: i64,
};

/// Mirrors `ContractInterfaceResult` (16 bytes, align 8).
pub const ContractResult = extern struct {
    ptr: i64,
    kind: i32,
    size: u32,
};

/// Mirrors `DelegateInterfaceResult` (16 bytes, align 8).
pub const DelegateResult = extern struct {
    ptr: i64,
    size: u32,
    _pad: u32 = 0,
};

/// `ContractInterfaceResult.kind`. (1 was `ValidateDelta`, which the node
/// no longer calls.)
pub const ResultKind = enum(i32) {
    validate_state = 0,
    update_state = 2,
    summarize_state = 3,
    state_delta = 4,
};

comptime {
    std.debug.assert(@sizeOf(BufferBuilder) == 32);
    std.debug.assert(@sizeOf(ContractResult) == 16);
    std.debug.assert(@sizeOf(DelegateResult) == 16);
}

pub fn ptrToI64(p: anytype) i64 {
    return @intCast(@intFromPtr(p));
}

pub fn i64ToPtr(comptime T: type, v: i64) T {
    return @ptrFromInt(@as(usize, @intCast(v)));
}

fn oom() noreturn {
    @trap();
}

/// Implementation of the `__frnt__initiate_buffer` export.
pub fn initiateBuffer(capacity: u32) callconv(.c) i64 {
    const data = allocator.alloc(u8, @max(capacity, 1)) catch oom();
    const counters = allocator.alloc(u32, 2) catch oom();
    counters[0] = 0;
    counters[1] = 0;
    const builder = allocator.create(BufferBuilder) catch oom();
    builder.* = .{
        .start = ptrToI64(data.ptr),
        .capacity = capacity,
        .last_read = ptrToI64(&counters[0]),
        .last_write = ptrToI64(&counters[1]),
    };
    return ptrToI64(builder);
}

/// The bytes the host wrote into the buffer behind `ptr`.
pub fn input(ptr: i64) []const u8 {
    const builder = i64ToPtr(*const BufferBuilder, ptr);
    const len = i64ToPtr(*const u32, builder.last_write).*;
    if (len == 0) return &.{};
    return i64ToPtr([*]const u8, builder.start)[0..len];
}

pub fn contractResult(kind: ResultKind, payload: []const u8) i64 {
    const res = allocator.create(ContractResult) catch oom();
    res.* = .{ .ptr = ptrToI64(payload.ptr), .kind = @backingInt(kind), .size = @intCast(payload.len) };
    return ptrToI64(res);
}

pub fn delegateResult(payload: []const u8) i64 {
    const res = allocator.create(DelegateResult) catch oom();
    res.* = .{ .ptr = ptrToI64(payload.ptr), .size = @intCast(payload.len) };
    return ptrToI64(res);
}

/// The export names each module kind must provide (plus `memory`, which the
/// linker exports automatically). Used by the build helpers and the checker.
pub const delegate_exports = [_][]const u8{ "process", "__frnt__initiate_buffer", "__frnt_set_id" };
pub const contract_exports = [_][]const u8{
    "validate_state", "update_state", "summarize_state", "get_state_delta", "__frnt__initiate_buffer", "__frnt_set_id",
};

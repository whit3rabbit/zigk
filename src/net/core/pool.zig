// Shared network packet memory pool.
// Centralizes TX buffers and reassembly allocations under a single budget.

const std = @import("std");
const sync = @import("../sync.zig");

const TX_POOL_SIZE = 64;
const TX_BUF_SIZE = 2048;
const TX_POOL_BYTES: usize = TX_POOL_SIZE * TX_BUF_SIZE;
pub const DEFAULT_MAX_MEMORY: usize = 512 * 1024 + TX_POOL_BYTES;

var tx_pool: [TX_POOL_SIZE][TX_BUF_SIZE]u8 = undefined;
var tx_pool_bitmap: u64 = 0xFFFFFFFFFFFFFFFF; // 1 = free
var tx_pool_lock: sync.Spinlock = .{};

var alloc_lock: sync.Spinlock = .{};
var reassembly_allocator: std.mem.Allocator = undefined;
var max_usage: usize = 0;
var current_usage: usize = 0;
var initialized: bool = false;

pub fn init(allocator: std.mem.Allocator, max_total_memory: usize) void {
    reassembly_allocator = allocator;
    max_usage = max_total_memory;
    current_usage = TX_POOL_BYTES;
    initialized = true;
}

pub fn allocTxBuffer() ?[]u8 {
    const held = tx_pool_lock.acquire();
    defer held.release();

    if (tx_pool_bitmap == 0) return null;

    const idx = @ctz(tx_pool_bitmap);
    tx_pool_bitmap &= ~(@as(u64, 1) << @intCast(idx));
    return &tx_pool[idx];
}

pub fn freeTxBuffer(buf: []u8) void {
    const start = @intFromPtr(&tx_pool[0]);
    const addr = @intFromPtr(buf.ptr);

    // Validate range
    if (addr < start or addr >= start + (TX_POOL_SIZE * TX_BUF_SIZE)) {
        return;
    }

    const offset = addr - start;
    const idx = offset / TX_BUF_SIZE;

    const held = tx_pool_lock.acquire();
    defer held.release();

    // SECURITY: Check for double-free before setting the bit.
    const mask = @as(u64, 1) << @intCast(idx);
    if (tx_pool_bitmap & mask != 0) {
        return; // Already free - double-free detected
    }
    tx_pool_bitmap |= mask;
}

pub fn allocReassemblyBuffer(len: usize) ?[]u8 {
    if (!initialized) return null;

    {
        const held = alloc_lock.acquire();
        defer held.release();

        const projected = std.math.add(usize, current_usage, len) catch return null;
        if (projected > max_usage) {
            return null;
        }
        current_usage = projected;
    }

    const buf = reassembly_allocator.alloc(u8, len) catch {
        const held = alloc_lock.acquire();
        defer held.release();
        if (current_usage >= len) {
            current_usage -= len;
        } else {
            std.log.warn("packet pool accounting underflow: current={} freed={}", .{ current_usage, len });
            current_usage = 0;
        }
        return null;
    };

    return buf;
}

pub fn freeReassemblyBuffer(buf: []u8) void {
    if (!initialized or buf.len == 0) return;

    reassembly_allocator.free(buf);

    const held = alloc_lock.acquire();
    defer held.release();

    if (current_usage >= buf.len) {
        current_usage -= buf.len;
    } else {
        std.log.warn("packet pool accounting underflow: current={} freed={}", .{ current_usage, buf.len });
        current_usage = 0;
    }
}

pub fn reallocReassemblyBuffer(buf: []u8, new_len: usize) ?[]u8 {
    if (!initialized) return null;
    if (new_len == buf.len) return buf;

    if (new_len < buf.len) {
        const new_buf = reassembly_allocator.realloc(buf, new_len) catch return null;
        const held = alloc_lock.acquire();
        defer held.release();
        const delta = buf.len - new_len;
        if (current_usage >= delta) {
            current_usage -= delta;
        } else {
            std.log.warn("packet pool accounting underflow: current={} freed={}", .{ current_usage, delta });
            current_usage = 0;
        }
        return new_buf;
    }

    const delta = new_len - buf.len;
    {
        const held = alloc_lock.acquire();
        defer held.release();
        const projected = std.math.add(usize, current_usage, delta) catch return null;
        if (projected > max_usage) {
            return null;
        }
        current_usage = projected;
    }

    const new_buf = reassembly_allocator.realloc(buf, new_len) catch {
        const held = alloc_lock.acquire();
        defer held.release();
        if (current_usage >= delta) {
            current_usage -= delta;
        } else {
            std.log.warn("packet pool accounting underflow: current={} freed={}", .{ current_usage, delta });
            current_usage = 0;
        }
        return null;
    };

    return new_buf;
}

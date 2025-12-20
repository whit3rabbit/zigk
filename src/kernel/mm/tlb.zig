//! TLB Shootdown Protocol
//!
//! Coordinates TLB invalidation across all CPUs when page tables are modified.
//! Without shootdown, other CPUs may continue using stale TLB entries, leading
//! to memory corruption or security vulnerabilities.
//!
//! Protocol:
//! 1. Initiating CPU acquires shootdown lock
//! 2. Sets up request (start address, page count)
//! 3. Atomically sets pending counter to number of other CPUs
//! 4. Broadcasts TLB_SHOOTDOWN IPI
//! 5. Waits for pending counter to reach 0
//! 6. Releases lock
//!
//! On receiving CPU:
//! 1. Reads request info
//! 2. Invalidates local TLB entries
//! 3. Atomically decrements pending counter
//!
//! Usage:
//! ```zig
//! // Single page shootdown
//! tlb.shootdown(virt_addr);
//!
//! // Range shootdown
//! tlb.shootdownRange(start_addr, page_count);
//! ```

const std = @import("std");
const sync = @import("sync");

// HAL imports
const is_freestanding = @import("builtin").os.tag == .freestanding;
const hal = if (is_freestanding) @import("hal") else undefined;
const apic = if (is_freestanding) hal.apic else undefined;
const cpu = if (is_freestanding) hal.cpu else undefined;
const paging = if (is_freestanding) hal.paging else undefined;
const smp = if (is_freestanding) hal.smp else undefined;

/// Maximum number of pages to invalidate individually before flushing entire TLB
const INVLPG_THRESHOLD: usize = 32;

/// Shootdown request structure
const ShootdownRequest = struct {
    /// Start virtual address (page-aligned)
    start_addr: u64 = 0,

    /// Number of pages to invalidate
    page_count: usize = 0,

    /// Number of CPUs that still need to process
    pending: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

/// Global shootdown request (protected by shootdown_lock)
var request: ShootdownRequest = .{};

/// Lock to serialize shootdown requests
var shootdown_lock: sync.Spinlock = .{};

/// Shootdown a single page across all CPUs
pub fn shootdown(virt_addr: u64) void {
    shootdownRange(virt_addr, 1);
}

/// Shootdown a range of pages across all CPUs
pub fn shootdownRange(start_addr: u64, page_count: usize) void {
    if (!is_freestanding) {
        return; // No-op in tests
    }

    // Single CPU optimization
    const ap_count = smp.getBootedApCount();
    if (ap_count == 0) {
        // Only BSP is running - just invalidate locally
        invalidateLocal(start_addr, page_count);
        return;
    }

    // Acquire shootdown lock
    const held = shootdown_lock.acquire();
    defer held.release();

    // Set up request
    request.start_addr = start_addr;
    request.page_count = page_count;

    // Set pending to AP count (we'll invalidate locally ourselves)
    // The .release ordering ensures all prior writes (start_addr, page_count)
    // are visible before the store completes
    request.pending.store(ap_count, .seq_cst);

    // Broadcast TLB shootdown IPI to all other CPUs
    apic.ipi.broadcast(.tlb_shootdown);

    // Invalidate locally while waiting
    invalidateLocal(start_addr, page_count);

    // Wait for all CPUs to complete
    while (request.pending.load(.acquire) != 0) {
        cpu.pause();
    }
}

/// Handle TLB shootdown IPI on receiving CPU
pub fn handleShootdownIpi(frame: *hal.idt.InterruptFrame) void {
    _ = frame;

    // Read request info
    const start = request.start_addr;
    const count = request.page_count;

    // Invalidate locally
    invalidateLocal(start, count);

    // Signal completion
    _ = request.pending.fetchSub(1, .release);
}

/// Invalidate TLB entries locally
fn invalidateLocal(start_addr: u64, page_count: usize) void {
    if (!is_freestanding) {
        return;
    }

    if (page_count > INVLPG_THRESHOLD) {
        // Flush entire TLB by reloading CR3
        cpu.flushTlb();
    } else {
        // Invalidate individual pages
        var addr = start_addr;
        for (0..page_count) |_| {
            cpu.invlpg(addr);
            addr += 4096;
        }
    }
}

/// Initialize TLB shootdown subsystem
/// Must be called after IPI infrastructure is initialized
pub fn init() void {
    if (is_freestanding) {
        // Register our handler for TLB shootdown IPIs
        apic.ipi.registerHandler(.tlb_shootdown, handleShootdownIpi);
    }
}

// Unit tests for non-freestanding builds
test "tlb shootdown single page (stub)" {
    // Just verify it compiles and doesn't crash on non-freestanding
    shootdown(0x1000);
}

test "tlb shootdown range (stub)" {
    shootdownRange(0x1000, 4);
}

const std = @import("std");
const idt = @import("../idt.zig");

/// Re-export InterruptFrame for convenience
pub const InterruptFrame = idt.InterruptFrame;

/// Console output writer callback
pub var console_writer: ?*const fn ([]const u8) void = null;

/// Keyboard IRQ handler callback
pub var keyboard_handler: ?*const fn () void = null;

/// Mouse IRQ handler callback
pub var mouse_handler: ?*const fn () void = null;

/// Serial IRQ handler callback
pub var serial_handler: ?*const fn () void = null;

/// Timer IRQ handler callback
pub var timer_handler: ?*const fn (*idt.InterruptFrame) *idt.InterruptFrame = null;

/// Guard page fault info struct
pub const GuardPageInfo = struct {
    thread_id: u32,
    thread_name: []const u8,
    stack_base: u64,
    stack_top: u64,
};

/// Guard page fault checker callback
pub var guard_page_checker: ?*const fn (u64) ?GuardPageInfo = null;

/// #NM (Device Not Available) handler callback
pub var fpu_access_handler: ?*const fn () bool = null;

/// User crash handler callback
pub var crash_handler: ?*const fn (u8, u64) noreturn = null;

/// User page fault handler callback
pub var page_fault_handler: ?*const fn (u64, u64) bool = null;

/// Generic IRQ handlers (for userspace drivers/IPC)
pub var generic_irq_handlers: [16]?*const fn (u8) void = [_]?*const fn (u8) void{null} ** 16;

/// Rate-limited logging state
pub var unexpected_irq_count: u32 = 0;
pub var last_unexpected_irq: u8 = 0xFF;

// MSI-X State
pub const MSIX_VECTOR_START: u8 = 64;
pub const MSIX_VECTOR_END: u8 = 128;
pub const MSIX_VECTOR_COUNT: u8 = MSIX_VECTOR_END - MSIX_VECTOR_START;

/// Bitmap tracking allocated MSI-X vectors
pub var msix_allocated: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// MSI-X handler callbacks
pub var msix_handlers: [MSIX_VECTOR_COUNT]?*const fn (*idt.InterruptFrame) void = [_]?*const fn (*idt.InterruptFrame) void{null} ** MSIX_VECTOR_COUNT;

/// Result of MSI-X vector allocation
pub const MsixVectorAllocation = struct {
    first_vector: u8,
    count: u8,
};

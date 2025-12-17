//! Inter-Processor Interrupt (IPI) Infrastructure
//!
//! Provides high-level IPI primitives for cross-CPU communication.
//! Uses vectors in the high range (0xF0-0xFF) to avoid conflicts with
//! hardware interrupts and exceptions.
//!
//! Usage:
//! ```zig
//! // Register a handler for TLB shootdown
//! ipi.registerHandler(.tlb_shootdown, handleTlbShootdown);
//!
//! // Send to specific CPU
//! ipi.sendTo(cpu_id, .tlb_shootdown);
//!
//! // Broadcast to all other CPUs
//! ipi.broadcast(.tlb_shootdown);
//! ```

const lapic = @import("lapic.zig");
const idt = @import("../idt.zig");

/// IPI vector assignments
/// Using high range (0xF0-0xFF) to avoid conflicts with:
/// - Exceptions (0x00-0x1F)
/// - Legacy IRQs (0x20-0x2F)
/// - MSI/MSI-X (0x30-0xEF)
pub const Vector = enum(u8) {
    /// TLB shootdown - invalidate TLB entries on other CPUs
    tlb_shootdown = 0xF0,

    /// Reschedule - trigger scheduler check on target CPU
    reschedule = 0xF1,

    /// Halt - stop CPU (for panic/shutdown)
    halt = 0xF2,

    /// Call function - execute a function on target CPU
    call_function = 0xF3,

    pub fn toU8(self: Vector) u8 {
        return @intFromEnum(self);
    }
};

/// IPI handler function type
pub const Handler = *const fn (*idt.InterruptFrame) void;

/// Registered handlers for each IPI vector
var handlers: [@typeInfo(Vector).@"enum".fields.len]?Handler = [_]?Handler{null} ** @typeInfo(Vector).@"enum".fields.len;

/// Get index for a vector in the handlers array
fn vectorIndex(vec: Vector) usize {
    return @intFromEnum(vec) - @intFromEnum(Vector.tlb_shootdown);
}

/// Register a handler for an IPI vector
/// The handler will be called when the IPI is received
pub fn registerHandler(vec: Vector, handler: Handler) void {
    handlers[vectorIndex(vec)] = handler;
    // Register with IDT so the interrupt is dispatched
    idt.registerHandler(vec.toU8(), ipiDispatcher);
}

/// Unregister an IPI handler
pub fn unregisterHandler(vec: Vector) void {
    handlers[vectorIndex(vec)] = null;
    idt.unregisterHandler(vec.toU8());
}

/// Send an IPI to a specific CPU by APIC ID
pub fn sendTo(dest_apic_id: u32, vec: Vector) void {
    lapic.sendIpi(dest_apic_id, vec.toU8(), .fixed, .none);
}

/// Broadcast an IPI to all CPUs except self
pub fn broadcast(vec: Vector) void {
    lapic.sendIpi(0, vec.toU8(), .fixed, .all_excluding_self);
}

/// Broadcast an IPI to all CPUs including self
pub fn broadcastAll(vec: Vector) void {
    lapic.sendIpi(0, vec.toU8(), .fixed, .all_including_self);
}

/// Send an IPI to self
pub fn sendSelf(vec: Vector) void {
    lapic.sendSelfIpi(vec.toU8());
}

/// Common IPI dispatcher - routes to registered handlers
fn ipiDispatcher(frame: *idt.InterruptFrame) void {
    const vector: u8 = @truncate(frame.vector);

    // Find which IPI this is
    inline for (@typeInfo(Vector).@"enum".fields) |field| {
        if (field.value == vector) {
            const vec: Vector = @enumFromInt(field.value);
            if (handlers[vectorIndex(vec)]) |handler| {
                handler(frame);
            }
            break;
        }
    }

    // Send EOI to LAPIC
    lapic.sendEoi();
}

/// Initialize IPI infrastructure
/// Called during APIC setup to prepare IPI vectors
pub fn init() void {
    // Pre-register all IPI vectors with the IDT using the dispatcher
    // Actual handlers are registered later by subsystems
    inline for (@typeInfo(Vector).@"enum".fields) |field| {
        idt.registerHandler(field.value, ipiDispatcher);
    }
}

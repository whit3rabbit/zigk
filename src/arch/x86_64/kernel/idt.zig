// Interrupt Descriptor Table (IDT) for x86_64
//
// Sets up the 256-entry IDT for handling CPU exceptions and hardware interrupts.
//
// Vector Layout:
//   0-31:   CPU Exceptions (divide error, page fault, etc.)
//   32-47:  Hardware IRQs (remapped from PIC)
//   48-255: Available for software interrupts
//
// Each IDT entry is 16 bytes in long mode (unlike 8 bytes in protected mode).

const gdt = @import("gdt.zig");
const apic = @import("apic/root.zig");

// Maximum CPUs for per-CPU data (must match gdt.MAX_CPUS)
const MAX_CPUS: usize = gdt.MAX_CPUS;

// Number of IDT entries
pub const IDT_ENTRIES: usize = 256;

// Interrupt vector numbers for CPU exceptions
pub const Exception = enum(u8) {
    DivideError = 0,
    Debug = 1,
    NMI = 2,
    Breakpoint = 3,
    Overflow = 4,
    BoundRange = 5,
    InvalidOpcode = 6,
    DeviceNotAvailable = 7,
    DoubleFault = 8,
    CoprocessorSegment = 9, // Reserved
    InvalidTSS = 10,
    SegmentNotPresent = 11,
    StackSegment = 12,
    GeneralProtection = 13,
    PageFault = 14,
    // 15 reserved
    X87FloatingPoint = 16,
    AlignmentCheck = 17,
    MachineCheck = 18,
    SIMDFloatingPoint = 19,
    Virtualization = 20,
    ControlProtection = 21,
    // 22-27 reserved
    HypervisorInjection = 28,
    VMMCommunication = 29,
    Security = 30,
    // 31 reserved
};

// IRQ numbers (after PIC remapping to vectors 32-47)
pub const IRQ_BASE: u8 = 32;

pub const Irq = enum(u8) {
    Timer = 0,
    Keyboard = 1,
    Cascade = 2, // Used internally by PICs
    COM2 = 3,
    COM1 = 4,
    LPT2 = 5,
    Floppy = 6,
    LPT1 = 7, // Spurious
    RTC = 8,
    Free1 = 9,
    Free2 = 10,
    Free3 = 11,
    Mouse = 12,
    FPU = 13,
    PrimaryATA = 14,
    SecondaryATA = 15,

    pub fn toVector(self: Irq) u8 {
        return @intFromEnum(self) + IRQ_BASE;
    }
};

// IDT Gate Types
const GateType = enum(u4) {
    Interrupt = 0xE, // Clears IF (interrupts disabled during handler)
    Trap = 0xF, // Keeps IF unchanged
};

// IDT Gate Descriptor (16 bytes in long mode)
pub const IdtGate = packed struct(u128) {
    offset_low: u16,
    selector: u16,
    ist: u3 = 0, // Interrupt Stack Table index (0 = don't switch stacks)
    reserved0: u5 = 0,
    gate_type: u4,
    zero: u1 = 0,
    dpl: u2, // Descriptor Privilege Level
    present: bool,
    offset_mid: u16,
    offset_high: u32,
    reserved1: u32 = 0,

    const Self = @This();

    /// Create a null/empty gate
    pub fn empty() Self {
        return @bitCast(@as(u128, 0));
    }

    /// Create an interrupt gate (clears IF)
    pub fn interrupt(handler: u64, dpl: u2) Self {
        return makeGate(handler, GateType.Interrupt, dpl, 0);
    }

    /// Create an interrupt gate with IST
    pub fn interruptWithIst(handler: u64, dpl: u2, ist: u3) Self {
        return makeGate(handler, GateType.Interrupt, dpl, ist);
    }

    /// Create a trap gate (preserves IF)
    pub fn trap(handler: u64, dpl: u2) Self {
        return makeGate(handler, GateType.Trap, dpl, 0);
    }

    fn makeGate(handler: u64, gate_type: GateType, dpl: u2, ist: u3) Self {
        return .{
            .offset_low = @truncate(handler),
            .selector = gdt.KERNEL_CODE,
            .ist = ist,
            .gate_type = @intFromEnum(gate_type),
            .dpl = dpl,
            .present = true,
            .offset_mid = @truncate(handler >> 16),
            .offset_high = @truncate(handler >> 32),
        };
    }

    // Compile-time verification of struct size for hardware compatibility
    comptime {
        if (@sizeOf(Self) != 16) @compileError("IdtGate must be exactly 16 bytes in long mode");
    }
};

// IDT pointer for LIDT instruction
const IdtPtr = packed struct(u80) {
    limit: u16,
    base: u64,
};

// Interrupt frame pushed by CPU on interrupt/exception
// This is the minimal frame; handlers may push additional registers
// Layout must match asm_helpers.S:isr_common
pub const InterruptFrame = extern struct {
    // Pushed by our stub
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,

    // Pushed by stub (vector number and error code)
    vector: u64,
    error_code: u64,

    // Pushed by CPU
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,

    // 22 u64 fields = 176 bytes
    comptime {
        if (@sizeOf(InterruptFrame) != 176) @compileError("InterruptFrame must be 176 bytes (must match asm_helpers.S)");
        // Verify cs is at offset 144 as expected by assembly
        if (@offsetOf(InterruptFrame, "cs") != 144) @compileError("cs must be at offset 144");
        if (@offsetOf(InterruptFrame, "ss") != 168) @compileError("ss must be at offset 168");
        if (@offsetOf(InterruptFrame, "vector") != 120) @compileError("vector must be at offset 120");
        if (@offsetOf(InterruptFrame, "rax") != 112) @compileError("rax must be at offset 112");
    }
};

// Static IDT
var idt_table: [IDT_ENTRIES]IdtGate = [_]IdtGate{IdtGate.empty()} ** IDT_ENTRIES;

// Interrupt handler function type
pub const InterruptHandler = *const fn (*InterruptFrame) void;

// Handler table for dispatching interrupts
// SECURITY: Use atomic operations for handler registration to prevent torn reads
// during concurrent access from interrupt context and registration context
var handlers: [IDT_ENTRIES]?InterruptHandler = [_]?InterruptHandler{null} ** IDT_ENTRIES;

// ISR Stubs - defined in asm_helpers.S
// Each stub: pushes error/dummy, pushes vector, saves regs, calls dispatcher
// All 256 stubs are generated using comptime @extern

const std = @import("std");

// Get stub pointer by vector number using comptime extern references
fn getStubPtr(comptime vec: usize) *const fn () callconv(.c) void {
    const stub_name = std.fmt.comptimePrint("isr_stub_{d}", .{vec});
    return @extern(*const fn () callconv(.c) void, .{ .name = stub_name });
}

// Stub table for IDT setup - generated at comptime from assembly stubs
const stub_table = blk: {
    @setEvalBranchQuota(100000);
    var table: [IDT_ENTRIES]*const fn () callconv(.c) void = undefined;
    for (0..IDT_ENTRIES) |i| {
        table[i] = getStubPtr(i);
    }
    break :blk table;
};

/// Initialize the IDT with exception, IRQ, and MSI-X handlers
pub fn init() void {
    // Set up exception handlers (vectors 0-31)
    for (0..32) |i| {
        const handler_addr = @intFromPtr(stub_table[i]);
        if (i == @intFromEnum(Exception.DoubleFault)) {
            // Double fault uses IST1 (separate stack)
            idt_table[i] = IdtGate.interruptWithIst(handler_addr, 0, 1);
        } else {
            idt_table[i] = IdtGate.interrupt(handler_addr, 0);
        }
    }

    // Set up IRQ handlers (vectors 32-47)
    for (32..48) |i| {
        const handler_addr = @intFromPtr(stub_table[i]);
        idt_table[i] = IdtGate.interrupt(handler_addr, 0);
    }

    // Set up MSI/MSI-X handlers (vectors 48-255)
    // These are available for PCI devices using Message Signaled Interrupts
    for (48..IDT_ENTRIES) |i| {
        const handler_addr = @intFromPtr(stub_table[i]);
        idt_table[i] = IdtGate.interrupt(handler_addr, 0);
    }

    // Load IDT
    const idt_ptr = IdtPtr{
        .limit = @sizeOf(@TypeOf(idt_table)) - 1,
        .base = @intFromPtr(&idt_table),
    };

    loadIdt(&idt_ptr);
}

/// Register a handler for a specific interrupt vector
/// SECURITY: Uses atomic store with release ordering to ensure handler
/// pointer is fully visible before it can be read by interrupt dispatch
pub fn registerHandler(vector: u8, handler: InterruptHandler) void {
    // Convert pointer to usize for atomic operations
    const handler_addr: usize = @intFromPtr(handler);
    const ptr: *usize = @ptrCast(&handlers[vector]);
    @atomicStore(usize, ptr, handler_addr, .release);
}

/// Unregister a handler
/// SECURITY: Uses atomic store with release ordering
pub fn unregisterHandler(vector: u8) void {
    const ptr: *usize = @ptrCast(&handlers[vector]);
    @atomicStore(usize, ptr, 0, .release);
}

/// Register an IRQ handler
pub fn registerIrqHandler(irq: Irq, handler: InterruptHandler) void {
    registerHandler(irq.toVector(), handler);
}

/// Common interrupt dispatcher (called from assembly stubs)
/// Must be exported as 'dispatch_interrupt' to match the assembly call
/// Returns the interrupt frame pointer to restore (may be different for context switch)
export fn dispatch_interrupt(frame: *InterruptFrame) callconv(.c) *InterruptFrame {
    const vector: u8 = @truncate(frame.vector);

    // SECURITY: Use atomic load with acquire ordering to pair with
    // release ordering in registerHandler - prevents reading stale/torn pointer
    const ptr: *const usize = @ptrCast(&handlers[vector]);
    const handler_addr = @atomicLoad(usize, ptr, .acquire);
    if (handler_addr != 0) {
        const handler: InterruptHandler = @ptrFromInt(handler_addr);
        handler(frame);
    }

    // Check if we need to switch to a different frame (context switch)
    // Uses per-CPU storage to avoid race conditions in SMP systems
    var ret_frame = frame;
    const cpu_id = getCpuIndex();
    if (per_cpu_new_frame[cpu_id]) |nf| {
        per_cpu_new_frame[cpu_id] = null;
        ret_frame = nf;
    }

    // If we are returning to user mode (CS RPL == 3), check for pending signals
    // SECURITY: Use atomic getter to prevent torn pointer reads
    if ((ret_frame.cs & 3) == 3) {
        if (getSignalChecker()) |checker| {
            ret_frame = checker(ret_frame);
        }
    }

    return ret_frame;
}

/// Per-CPU new frame pointer for context switch
/// Set by timer handler to indicate we should switch to a different thread
/// Using per-CPU storage to avoid race conditions in SMP systems
/// SECURITY: Fixes race condition where multiple CPUs could corrupt new_frame
var per_cpu_new_frame: [MAX_CPUS]?*InterruptFrame = [_]?*InterruptFrame{null} ** MAX_CPUS;

/// Set the new frame for context switch (called by scheduler)
/// Uses current CPU's LAPIC ID to index per-CPU storage
pub fn setNewFrame(frame: *InterruptFrame) void {
    const cpu_id = getCpuIndex();
    per_cpu_new_frame[cpu_id] = frame;
}

/// Get CPU index for per-CPU data access
/// SECURITY: Panics if LAPIC ID exceeds MAX_CPUS to prevent per-CPU array overflow.
/// Returning 0 for OOB IDs would cause multiple CPUs to share per_cpu_new_frame[0],
/// leading to context corruption and potential privilege escalation.
inline fn getCpuIndex() usize {
    if (apic.isActive()) {
        const lapic_id = apic.lapic.getId();
        if (lapic_id >= MAX_CPUS) {
            // SECURITY: OOB LAPIC ID detected. This indicates either:
            // 1. A system with more CPUs than MAX_CPUS (configuration error)
            // 2. APIC ID spoofing attack from hypervisor
            // Either way, we cannot safely proceed - halt this CPU.
            @panic("LAPIC ID exceeds MAX_CPUS - cannot safely access per-CPU data");
        }
        return lapic_id;
    }
    return 0; // BSP during early boot
}

// Signal checker hook (set by scheduler/interrupts module)
// Called before returning to user mode to check for pending signals
// Returns potentially modified frame (if signal delivery set up)
// SECURITY: Uses atomic operations to prevent torn reads during concurrent access
var signal_checker: ?*const fn (*InterruptFrame) *InterruptFrame = null;

/// Set the signal checker hook
/// SECURITY: Uses atomic store with release ordering to ensure the function pointer
/// is fully visible before it can be called from interrupt context
pub fn setSignalChecker(checker: *const fn (*InterruptFrame) *InterruptFrame) void {
    const checker_addr: usize = @intFromPtr(checker);
    const ptr: *usize = @ptrCast(&signal_checker);
    @atomicStore(usize, ptr, checker_addr, .release);
}

/// Get the signal checker hook atomically
/// SECURITY: Uses atomic load with acquire ordering to pair with setSignalChecker
fn getSignalChecker() ?*const fn (*InterruptFrame) *InterruptFrame {
    const ptr: *const usize = @ptrCast(&signal_checker);
    const checker_addr = @atomicLoad(usize, ptr, .acquire);
    if (checker_addr == 0) return null;
    return @ptrFromInt(checker_addr);
}

// Assembly helper defined in asm_helpers.S
extern fn _asm_lidt(ptr: *const IdtPtr) void;

/// Load IDT using LIDT instruction
fn loadIdt(idt_ptr: *const IdtPtr) void {
    _asm_lidt(idt_ptr);
}

/// Get the current IDT base address (for debugging)
pub fn getIdtBase() u64 {
    var idt_ptr: IdtPtr = undefined;
    asm volatile ("sidt %[ptr]"
        : [ptr] "=m" (idt_ptr),
    );
    return idt_ptr.base;
}

/// Reload IDT (for AP boot)
/// Uses the already-initialized IDT from BSP
pub fn reload() void {
    const idt_ptr = IdtPtr{
        .limit = @sizeOf(@TypeOf(idt_table)) - 1,
        .base = @intFromPtr(&idt_table),
    };
    loadIdt(&idt_ptr);
}

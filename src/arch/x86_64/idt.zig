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
};

// IDT pointer for LIDT instruction
const IdtPtr = packed struct {
    limit: u16,
    base: u64,
};

// Interrupt frame pushed by CPU on interrupt/exception
// This is the minimal frame; handlers may push additional registers
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
};

// Static IDT
var idt_table: [IDT_ENTRIES]IdtGate = [_]IdtGate{IdtGate.empty()} ** IDT_ENTRIES;

// Interrupt handler function type
pub const InterruptHandler = *const fn (*InterruptFrame) void;

// Handler table for dispatching interrupts
var handlers: [IDT_ENTRIES]?InterruptHandler = [_]?InterruptHandler{null} ** IDT_ENTRIES;

// ISR Stubs - defined in asm_helpers.S
// Each stub: pushes error/dummy, pushes vector, saves regs, calls dispatcher

// External references to the assembly stubs
extern fn isr_stub_0() callconv(.c) void;
extern fn isr_stub_1() callconv(.c) void;
extern fn isr_stub_2() callconv(.c) void;
extern fn isr_stub_3() callconv(.c) void;
extern fn isr_stub_4() callconv(.c) void;
extern fn isr_stub_5() callconv(.c) void;
extern fn isr_stub_6() callconv(.c) void;
extern fn isr_stub_7() callconv(.c) void;
extern fn isr_stub_8() callconv(.c) void;
extern fn isr_stub_9() callconv(.c) void;
extern fn isr_stub_10() callconv(.c) void;
extern fn isr_stub_11() callconv(.c) void;
extern fn isr_stub_12() callconv(.c) void;
extern fn isr_stub_13() callconv(.c) void;
extern fn isr_stub_14() callconv(.c) void;
extern fn isr_stub_15() callconv(.c) void;
extern fn isr_stub_16() callconv(.c) void;
extern fn isr_stub_17() callconv(.c) void;
extern fn isr_stub_18() callconv(.c) void;
extern fn isr_stub_19() callconv(.c) void;
extern fn isr_stub_20() callconv(.c) void;
extern fn isr_stub_21() callconv(.c) void;
extern fn isr_stub_22() callconv(.c) void;
extern fn isr_stub_23() callconv(.c) void;
extern fn isr_stub_24() callconv(.c) void;
extern fn isr_stub_25() callconv(.c) void;
extern fn isr_stub_26() callconv(.c) void;
extern fn isr_stub_27() callconv(.c) void;
extern fn isr_stub_28() callconv(.c) void;
extern fn isr_stub_29() callconv(.c) void;
extern fn isr_stub_30() callconv(.c) void;
extern fn isr_stub_31() callconv(.c) void;
extern fn isr_stub_32() callconv(.c) void;
extern fn isr_stub_33() callconv(.c) void;
extern fn isr_stub_34() callconv(.c) void;
extern fn isr_stub_35() callconv(.c) void;
extern fn isr_stub_36() callconv(.c) void;
extern fn isr_stub_37() callconv(.c) void;
extern fn isr_stub_38() callconv(.c) void;
extern fn isr_stub_39() callconv(.c) void;
extern fn isr_stub_40() callconv(.c) void;
extern fn isr_stub_41() callconv(.c) void;
extern fn isr_stub_42() callconv(.c) void;
extern fn isr_stub_43() callconv(.c) void;
extern fn isr_stub_44() callconv(.c) void;
extern fn isr_stub_45() callconv(.c) void;
extern fn isr_stub_46() callconv(.c) void;
extern fn isr_stub_47() callconv(.c) void;

// Stub table for IDT setup
const stub_table = [_]*const fn () callconv(.c) void{
    isr_stub_0,  isr_stub_1,  isr_stub_2,  isr_stub_3,
    isr_stub_4,  isr_stub_5,  isr_stub_6,  isr_stub_7,
    isr_stub_8,  isr_stub_9,  isr_stub_10, isr_stub_11,
    isr_stub_12, isr_stub_13, isr_stub_14, isr_stub_15,
    isr_stub_16, isr_stub_17, isr_stub_18, isr_stub_19,
    isr_stub_20, isr_stub_21, isr_stub_22, isr_stub_23,
    isr_stub_24, isr_stub_25, isr_stub_26, isr_stub_27,
    isr_stub_28, isr_stub_29, isr_stub_30, isr_stub_31,
    isr_stub_32, isr_stub_33, isr_stub_34, isr_stub_35,
    isr_stub_36, isr_stub_37, isr_stub_38, isr_stub_39,
    isr_stub_40, isr_stub_41, isr_stub_42, isr_stub_43,
    isr_stub_44, isr_stub_45, isr_stub_46, isr_stub_47,
};

/// Initialize the IDT with exception and IRQ handlers
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

    // Load IDT
    const idt_ptr = IdtPtr{
        .limit = @sizeOf(@TypeOf(idt_table)) - 1,
        .base = @intFromPtr(&idt_table),
    };

    loadIdt(&idt_ptr);
}

/// Register a handler for a specific interrupt vector
pub fn registerHandler(vector: u8, handler: InterruptHandler) void {
    handlers[vector] = handler;
}

/// Unregister a handler
pub fn unregisterHandler(vector: u8) void {
    handlers[vector] = null;
}

/// Register an IRQ handler
pub fn registerIrqHandler(irq: Irq, handler: InterruptHandler) void {
    registerHandler(irq.toVector(), handler);
}

/// Common interrupt dispatcher (called from assembly stubs)
/// Must be exported as 'dispatch_interrupt' to match the assembly call
export fn dispatch_interrupt(frame: *InterruptFrame) callconv(.c) void {
    const vector: u8 = @truncate(frame.vector);

    if (handlers[vector]) |handler| {
        handler(frame);
    } else {
        // Unhandled interrupt - for now just return
        // In a real kernel, we might want to log or panic
    }
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

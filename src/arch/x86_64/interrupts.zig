// Interrupt Handlers for x86_64
//
// Contains exception handlers and IRQ handlers.
// These are registered with the IDT during initialization.

const idt = @import("idt.zig");
const pic = @import("pic.zig");
const cpu = @import("cpu.zig");
const debug = @import("debug.zig");
const apic = @import("apic/root.zig");
const console = @import("console");

// Import console for output (will be set up during init)
var console_writer: ?*const fn ([]const u8) void = null;

// Keyboard IRQ handler callback (set by keyboard driver)
// This allows the HAL to call into the keyboard driver without importing it
var keyboard_handler: ?*const fn () void = null;

// Mouse IRQ handler callback (set by mouse driver)
// This allows the HAL to call into the mouse driver without importing it
var mouse_handler: ?*const fn () void = null;

// Timer IRQ handler callback (set by scheduler)
// Returns a new frame pointer for context switching
// This allows the scheduler to perform preemptive context switches
var timer_handler: ?*const fn (*idt.InterruptFrame) *idt.InterruptFrame = null;

// Guard page fault handler callback (set by scheduler/thread module)
// Called when a page fault might be a stack overflow
// Returns thread info if the fault is in a guard page: (tid, name, stack_base, stack_top)
// Returns null if not a guard page fault
pub const GuardPageInfo = struct {
    thread_id: u32,
    thread_name: []const u8,
    stack_base: u64,
    stack_top: u64,
};
var guard_page_checker: ?*const fn (u64) ?GuardPageInfo = null;

// #NM (Device Not Available) handler callback for lazy FPU switching
// Called when a thread attempts to use FPU/SSE with CR0.TS set
// Returns true if handled (FPU state restored), false if not handled
var fpu_access_handler: ?*const fn () bool = null;

// User crash handler callback (set by scheduler)
// Called when a user thread causes an exception (e.g. Page Fault)
// Args: vector, error_code
var crash_handler: ?*const fn (u8, u64) noreturn = null;

/// Exception names for debugging
const exception_names = [_][]const u8{
    "Divide Error (#DE)",
    "Debug (#DB)",
    "Non-Maskable Interrupt",
    "Breakpoint (#BP)",
    "Overflow (#OF)",
    "Bound Range Exceeded (#BR)",
    "Invalid Opcode (#UD)",
    "Device Not Available (#NM)",
    "Double Fault (#DF)",
    "Coprocessor Segment Overrun",
    "Invalid TSS (#TS)",
    "Segment Not Present (#NP)",
    "Stack-Segment Fault (#SS)",
    "General Protection Fault (#GP)",
    "Page Fault (#PF)",
    "Reserved",
    "x87 FPU Error (#MF)",
    "Alignment Check (#AC)",
    "Machine Check (#MC)",
    "SIMD Floating-Point (#XM)",
    "Virtualization Exception (#VE)",
    "Control Protection (#CP)",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Hypervisor Injection (#HV)",
    "VMM Communication (#VC)",
    "Security Exception (#SX)",
    "Reserved",
};

/// Initialize interrupt handlers
/// Must be called after IDT is set up
pub fn init() void {
    // Register exception handlers
    for (0..32) |i| {
        idt.registerHandler(@truncate(i), exceptionHandler);
    }

    // Register IRQ handlers (vectors 32-47)
    for (32..48) |i| {
        idt.registerHandler(@truncate(i), irqHandler);
    }

    // Register LAPIC Timer handler (vector 48)
    // We reuse irqHandler logic or direct dispatch?
    // irqHandler handles EOI logic based on vector.
    // Vector 48 is not an IRQ (IRQ0-15 map to 32-47).
    // So we should register a specific handler or use a generic one.
    // However, for consistency with `timerTick` callback, let's use a specific handler.
    idt.registerHandler(apic.lapic.TIMER_VECTOR, lapicTimerHandler);
}

/// Set the console writer for debug output
pub fn setConsoleWriter(writer: *const fn ([]const u8) void) void {
    console_writer = writer;
    // Also set up debug module console writer
    debug.setConsoleWriter(writer);
}

/// Set the keyboard handler callback
/// This allows the keyboard driver to register its IRQ handler
pub fn setKeyboardHandler(handler: *const fn () void) void {
    keyboard_handler = handler;
}

/// Set the mouse handler callback
/// This allows the mouse driver to register its IRQ handler
pub fn setMouseHandler(handler: *const fn () void) void {
    mouse_handler = handler;
}

/// Set the crash handler callback
pub fn setCrashHandler(handler: *const fn (u8, u64) noreturn) void {
    crash_handler = handler;
}

/// Set the timer handler callback
/// This allows the scheduler to register its timer tick handler
/// The handler receives the current frame and returns the frame to restore
/// (may be different for context switch)
pub fn setTimerHandler(handler: *const fn (*idt.InterruptFrame) *idt.InterruptFrame) void {
    timer_handler = handler;
}

/// Set the guard page checker callback
/// This allows the scheduler/thread module to provide thread info for stack overflow detection
/// The callback is called with a fault address and returns thread info if in a guard page
pub fn setGuardPageChecker(checker: *const fn (u64) ?GuardPageInfo) void {
    guard_page_checker = checker;
}

/// Set the FPU access handler callback for lazy FPU switching
/// This allows the scheduler to handle #NM exceptions when threads access FPU
pub fn setFpuAccessHandler(handler: *const fn () bool) void {
    fpu_access_handler = handler;
}

/// Generic exception handler
fn exceptionHandler(frame: *idt.InterruptFrame) void {
    const vector: u8 = @truncate(frame.vector);

    // Handle #NM (Device Not Available) for lazy FPU switching
    // This is not an error - it's how we implement lazy FPU save/restore
    if (vector == 7) {
        if (fpu_access_handler) |handler| {
            if (handler()) {
                // FPU state restored, thread can continue
                return;
            }
        }
        // If no handler or handler failed, fall through to error handling
    }

    // For user mode exceptions, dump debug info before invoking crash handler (noreturn)
    if ((frame.cs & 3) == 3) {
        console.printUnsafe("\n!!! USER EXCEPTION: ");
        if (vector < exception_names.len) {
            console.printUnsafe(exception_names[vector]);
        } else {
            console.printUnsafe("Unknown");
        }
        console.printUnsafe(" !!!\n");

        if (vector == 14) {
            debug.dumpPageFaultInfo(frame);
        } else {
            debug.dumpRegisters(frame);
        }

        if (crash_handler) |handler| {
            handler(vector, frame.error_code);
        }
    }

    // Print exception info
    console.printUnsafe("\n!!! EXCEPTION: ");
    if (vector < exception_names.len) {
        console.printUnsafe(exception_names[vector]);
    }
    console.printUnsafe(" !!!\n");

    // Print register state
    // Note: printFrame might use console.print? Check debug module.
    // For now, let's assume debug module uses safer printing or we can't fix it easily here.
    // But printUnsafe ensures the header gets out.
    printFrame(frame);

    // For certain exceptions, print additional info
    switch (vector) {
        14 => {
            // Page fault - CR2 contains faulting address
            const cr2 = cpu.readCr2();

            // Check if we are in a safe copy region
            const rip = frame.rip;
            if (rip >= @intFromPtr(&_asm_copy_user_start) and rip < @intFromPtr(&_asm_copy_user_end)) {
                // Redirect to fixup handler
                frame.rip = @intFromPtr(&_asm_copy_user_fixup);
                return;
            }

            // Check if this is a stack guard page fault
            if (guard_page_checker) |checker| {
                if (checker(cr2)) |guard_info| {
                    // This is a stack overflow - print detailed diagnostic
                    debug.printStackOverflowDiagnostic(
                        guard_info.thread_id,
                        guard_info.thread_name,
                        cr2,
                        guard_info.stack_base,
                        guard_info.stack_top,
                    );
                    // Use debug module for full register dump
                    debug.dumpRegisters(frame);
                    debug.dumpControlRegisters();
                    console.printUnsafe("\nSystem halted due to stack overflow.\n");
                    cpu.halt();
                    return;
                }
            }

            // Regular page fault - use debug module for detailed output
            debug.dumpPageFaultInfo(frame);
            debug.dumpControlRegisters();
        },
        8 => {
            // Double fault - always fatal
            console.printUnsafe("DOUBLE FAULT - System halted\n");
        },
        13 => {
            // Handle non-canonical pointers during user copy (#GP instead of #PF)
            const rip = frame.rip;
            if (rip >= @intFromPtr(&_asm_copy_user_start) and rip < @intFromPtr(&_asm_copy_user_end)) {
                frame.rip = @intFromPtr(&_asm_copy_user_fixup);
                return;
            }

            // General protection fault
            if (frame.error_code != 0) {
                 console.printUnsafe("GPF Error Code: ");
                 // printHex need to use unsafe? 
                 // It's likely local helper.
                 // let's just print basic info
            }
        },
        else => {},
    }

    // Halt on exception (for now)
    // In a real kernel, we might kill the faulting process instead
    console.printUnsafe("System halted.\n");
    cpu.halt();
}

// External symbols for safe copy fixup
extern const _asm_copy_user_start: anyopaque;
extern const _asm_copy_user_end: anyopaque;
extern const _asm_copy_user_fixup: anyopaque;

/// LAPIC Timer handler
fn lapicTimerHandler(frame: *idt.InterruptFrame) void {
    // Delegate to scheduler
    if (timer_handler) |handler| {
        const returned_frame = handler(frame);
        if (returned_frame != frame) {
            idt.setNewFrame(returned_frame);
        }
    }

    // Send EOI
    apic.lapic.sendEoi();
}

/// Generic IRQ handler
fn irqHandler(frame: *idt.InterruptFrame) void {
    const vector: u8 = @truncate(frame.vector);
    const irq = vector - pic.IRQ_OFFSET;

    // In APIC mode, we use LAPIC vectors directly
    // In PIC mode, check for spurious IRQ
    if (!apic.isActive()) {
        if (pic.isSpurious(irq)) {
            return;
        }
    }

    // Handle specific IRQs
    switch (irq) {
        0 => {
            // Timer IRQ - delegate to scheduler for preemption
            if (timer_handler) |handler| {
                // The handler returns the frame to restore (possibly different thread)
                const returned_frame = handler(frame);
                // Signal dispatch_interrupt to use this frame instead
                if (returned_frame != frame) {
                    idt.setNewFrame(returned_frame);
                }
            }
            // If no timer handler, just acknowledge and continue
        },
        1 => {
            // Keyboard IRQ - delegate to keyboard driver
            if (keyboard_handler) |handler| {
                handler();
            } else {
                // Fallback: read scancode to acknowledge (prevents keyboard lockup)
                _ = @import("io.zig").inb(0x60);
            }
        },
        12 => {
            // Mouse IRQ - delegate to mouse driver
            if (mouse_handler) |handler| {
                handler();
            } else {
                // Fallback: read data to acknowledge (prevents mouse lockup)
                _ = @import("io.zig").inb(0x60);
            }
        },
        else => {
            // Unhandled IRQ - log for debugging (rate-limited)
            logUnexpectedIrq(irq);
        },
    }

    // Send EOI - use APIC or PIC depending on mode
    if (apic.isActive()) {
        apic.lapic.sendEoi();
    } else {
        pic.sendEoi(irq);
    }
}

/// Print interrupt frame (register dump)
fn printFrame(frame: *idt.InterruptFrame) void {
    console.printUnsafe("Registers:\n");
    console.printUnsafe("  RAX=");
    printHex(frame.rax);
    console.printUnsafe(" RBX=");
    printHex(frame.rbx);
    console.printUnsafe(" RCX=");
    printHex(frame.rcx);
    console.printUnsafe("\n");

    console.printUnsafe("  RDX=");
    printHex(frame.rdx);
    console.printUnsafe(" RSI=");
    printHex(frame.rsi);
    console.printUnsafe(" RDI=");
    printHex(frame.rdi);
    console.printUnsafe("\n");

    console.printUnsafe("  RBP=");
    printHex(frame.rbp);
    console.printUnsafe(" RSP=");
    printHex(frame.rsp);
    console.printUnsafe("\n");

    console.printUnsafe("  R8 =");
    printHex(frame.r8);
    console.printUnsafe("  R9 =");
    printHex(frame.r9);
    console.printUnsafe(" R10=");
    printHex(frame.r10);
    console.printUnsafe("\n");

    console.printUnsafe("  R11=");
    printHex(frame.r11);
    console.printUnsafe(" R12=");
    printHex(frame.r12);
    console.printUnsafe(" R13=");
    printHex(frame.r13);
    console.printUnsafe("\n");

    console.printUnsafe("  R14=");
    printHex(frame.r14);
    console.printUnsafe(" R15=");
    printHex(frame.r15);
    console.printUnsafe("\n");

    console.printUnsafe("  RIP=");
    printHex(frame.rip);
    console.printUnsafe(" CS =");
    printHex(frame.cs);
    console.printUnsafe("\n");

    console.printUnsafe("  RFLAGS=");
    printHex(frame.rflags);
    console.printUnsafe("\n");

    console.printUnsafe("  Error code=");
    printHex(frame.error_code);
    console.printUnsafe(" Vector=");
    printHex(frame.vector);
    console.printUnsafe("\n");
}

/// Print a 64-bit value in hex
fn printHex(value: u64) void {
    const hex_chars = "0123456789ABCDEF";
    var buf: [18]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';

    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const shift: u6 = @truncate(60 - i * 4);
        const nibble: u4 = @truncate(value >> shift);
        buf[2 + i] = hex_chars[nibble];
    }

    console.printUnsafe(&buf);
}

// Rate-limited logging for unexpected IRQs
var unexpected_irq_count: u32 = 0;
var last_unexpected_irq: u8 = 0xFF;

fn logUnexpectedIrq(irq: u8) void {
    unexpected_irq_count +%= 1;

    // Log first occurrence of each IRQ, then rate-limit
    if (irq != last_unexpected_irq or unexpected_irq_count <= 1) {
        last_unexpected_irq = irq;
        if (console_writer) |write| {
            write("[WARN] Unexpected IRQ: ");
            const hex_chars = "0123456789ABCDEF";
            var buf: [2]u8 = undefined;
            buf[0] = hex_chars[irq >> 4];
            buf[1] = hex_chars[irq & 0x0F];
            write(&buf);
            write("\n");
        }
    }
}

// =============================================================================
// MSI-X Vector Allocator
// =============================================================================
// Manages allocation of interrupt vectors for MSI-X devices.
// Vectors 64-127 are the primary MSI-X range (64 vectors available).
// Vectors 128-255 are reserved for future expansion.

/// First vector available for MSI-X allocation
pub const MSIX_VECTOR_START: u8 = 64;

/// Last vector available for MSI-X allocation (exclusive)
pub const MSIX_VECTOR_END: u8 = 128;

/// Maximum number of MSI-X vectors available
pub const MSIX_VECTOR_COUNT: u8 = MSIX_VECTOR_END - MSIX_VECTOR_START;

/// Bitmap tracking allocated MSI-X vectors (64 vectors = 1 u64)
var msix_allocated: u64 = 0;

/// MSI-X handler callbacks indexed by vector offset (0-63 maps to vectors 64-127)
var msix_handlers: [MSIX_VECTOR_COUNT]?*const fn (*idt.InterruptFrame) void = [_]?*const fn (*idt.InterruptFrame) void{null} ** MSIX_VECTOR_COUNT;

/// Allocation result for MSI-X vectors
pub const MsixVectorAllocation = struct {
    /// First allocated vector number
    first_vector: u8,
    /// Number of vectors allocated
    count: u8,
};

/// Allocate one or more contiguous MSI-X vectors
/// Returns null if not enough contiguous vectors are available
pub fn allocateMsixVectors(count: u8) ?MsixVectorAllocation {
    if (count == 0 or count > MSIX_VECTOR_COUNT) {
        return null;
    }

    // Find 'count' contiguous free vectors
    const mask: u64 = (@as(u64, 1) << @truncate(count)) - 1;

    var offset: u6 = 0;
    while (offset <= MSIX_VECTOR_COUNT - count) : (offset += 1) {
        const shifted_mask = mask << offset;
        if ((msix_allocated & shifted_mask) == 0) {
            // Found free slot - mark as allocated
            msix_allocated |= shifted_mask;
            return MsixVectorAllocation{
                .first_vector = MSIX_VECTOR_START + offset,
                .count = count,
            };
        }
    }

    return null; // No contiguous block available
}

/// Allocate a single MSI-X vector
pub fn allocateMsixVector() ?u8 {
    const alloc = allocateMsixVectors(1) orelse return null;
    return alloc.first_vector;
}

/// Free previously allocated MSI-X vectors
pub fn freeMsixVectors(first_vector: u8, count: u8) void {
    if (first_vector < MSIX_VECTOR_START or first_vector >= MSIX_VECTOR_END) {
        return;
    }

    const offset: u6 = @truncate(first_vector - MSIX_VECTOR_START);
    const actual_count = @min(count, MSIX_VECTOR_END - first_vector);
    const mask: u64 = (@as(u64, 1) << @truncate(actual_count)) - 1;

    // Clear allocation bits
    msix_allocated &= ~(mask << offset);

    // Clear handlers
    for (offset..offset + actual_count) |i| {
        msix_handlers[i] = null;
    }
}

/// Free a single MSI-X vector
pub fn freeMsixVector(vector: u8) void {
    freeMsixVectors(vector, 1);
}

/// Register a handler for an MSI-X vector
/// The vector must have been previously allocated
pub fn registerMsixHandler(vector: u8, handler: *const fn (*idt.InterruptFrame) void) bool {
    if (vector < MSIX_VECTOR_START or vector >= MSIX_VECTOR_END) {
        return false;
    }

    const offset: u6 = @truncate(vector - MSIX_VECTOR_START);

    // Check that vector is allocated
    if ((msix_allocated & (@as(u64, 1) << offset)) == 0) {
        return false;
    }

    msix_handlers[offset] = handler;

    // Also register with IDT
    idt.registerHandler(vector, msixHandler);

    return true;
}

/// Unregister an MSI-X handler
pub fn unregisterMsixHandler(vector: u8) void {
    if (vector < MSIX_VECTOR_START or vector >= MSIX_VECTOR_END) {
        return;
    }

    const offset: u6 = @truncate(vector - MSIX_VECTOR_START);
    msix_handlers[offset] = null;
    idt.unregisterHandler(vector);
}

/// Generic MSI-X interrupt handler
/// Dispatches to device-specific handlers and sends EOI
fn msixHandler(frame: *idt.InterruptFrame) void {
    const vector: u8 = @truncate(frame.vector);

    if (vector >= MSIX_VECTOR_START and vector < MSIX_VECTOR_END) {
        const offset: u6 = @truncate(vector - MSIX_VECTOR_START);
        if (msix_handlers[offset]) |handler| {
            handler(frame);
        }
    }

    // Send EOI to LAPIC (MSI-X always uses APIC)
    apic.lapic.sendEoi();
}

/// Get the number of free MSI-X vectors
pub fn getFreeMsixVectorCount() u8 {
    var count: u8 = 0;
    var remaining = ~msix_allocated;
    while (remaining != 0) : (remaining &= remaining - 1) {
        count += 1;
    }
    // Only count vectors in our range
    return @min(count, MSIX_VECTOR_COUNT);
}

/// Check if a specific vector is allocated
pub fn isMsixVectorAllocated(vector: u8) bool {
    if (vector < MSIX_VECTOR_START or vector >= MSIX_VECTOR_END) {
        return false;
    }
    const offset: u6 = @truncate(vector - MSIX_VECTOR_START);
    return (msix_allocated & (@as(u64, 1) << offset)) != 0;
}

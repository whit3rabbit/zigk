# HAL Interface Contract

**Feature Branch**: `003-microkernel-userland-networking`
**Created**: 2025-12-04

## Overview

This document defines the Hardware Abstraction Layer (HAL) interface. Per Constitution Principle VI (Strict Layering), all hardware access MUST flow through these interfaces. Higher-level kernel code (networking, scheduler, filesystem) MUST NOT directly access CPU registers, port I/O, or memory-mapped hardware.

---

## Module Structure

```
src/hal/
├── hal.zig           # Unified HAL interface (re-exports all modules)
├── x86_64/
│   ├── cpu.zig       # CPU control (CR registers, MSRs)
│   ├── port_io.zig   # Port I/O (inb, outb, inw, outw, inl, outl)
│   ├── gdt.zig       # GDT/TSS management
│   ├── idt.zig       # IDT management
│   ├── pic.zig       # 8259 PIC control
│   ├── pit.zig       # Programmable Interval Timer
│   └── pci.zig       # PCI bus enumeration
└── drivers/
    ├── e1000.zig     # E1000 network driver
    ├── keyboard.zig  # PS/2 keyboard driver
    └── serial.zig    # Serial port driver
```

---

## CPU Control (`hal/x86_64/cpu.zig`)

### Control Registers

```zig
/// Read CR0 (system control flags)
pub fn readCR0() u64;

/// Write CR0
pub fn writeCR0(value: u64) void;

/// Read CR2 (page fault linear address)
pub fn readCR2() u64;

/// Read CR3 (page table base)
pub fn readCR3() u64;

/// Write CR3 (switch page tables, flushes TLB)
pub fn writeCR3(value: u64) void;

/// Read CR4 (architectural extensions)
pub fn readCR4() u64;

/// Write CR4
pub fn writeCR4(value: u64) void;
```

### Model-Specific Registers

```zig
/// Read MSR
pub fn readMSR(msr: u32) u64;

/// Write MSR
pub fn writeMSR(msr: u32, value: u64) void;

// Common MSR addresses
pub const IA32_EFER: u32 = 0xC0000080;
pub const IA32_STAR: u32 = 0xC0000081;
pub const IA32_LSTAR: u32 = 0xC0000082;
pub const IA32_FMASK: u32 = 0xC0000084;
pub const IA32_FS_BASE: u32 = 0xC0000100;
pub const IA32_GS_BASE: u32 = 0xC0000101;
pub const IA32_KERNEL_GS_BASE: u32 = 0xC0000102;
```

### Interrupt Control

```zig
/// Enable interrupts (STI)
pub fn enableInterrupts() void;

/// Disable interrupts (CLI)
pub fn disableInterrupts() void;

/// Check if interrupts enabled
pub fn interruptsEnabled() bool;

/// Halt CPU until next interrupt
pub fn halt() void;

/// Invalidate TLB entry for address
pub fn invlpg(addr: u64) void;
```

---

## Port I/O (`hal/x86_64/port_io.zig`)

```zig
/// Read byte from port
pub fn inb(port: u16) u8;

/// Write byte to port
pub fn outb(port: u16, value: u8) void;

/// Read word from port
pub fn inw(port: u16) u16;

/// Write word to port
pub fn outw(port: u16, value: u16) void;

/// Read dword from port
pub fn inl(port: u16) u32;

/// Write dword to port
pub fn outl(port: u16, value: u32) void;

/// I/O wait (short delay)
pub fn io_wait() void;
```

---

## GDT Management (`hal/x86_64/gdt.zig`)

```zig
/// GDT entry structure
pub const GDTEntry = packed struct(u64) { ... };

/// TSS structure
pub const TSS = packed struct { ... };

/// Initialize GDT with kernel/user segments and TSS
pub fn init() void;

/// Load GDT register (LGDT)
pub fn load(gdt: *const GDT) void;

/// Load task register (LTR)
pub fn loadTSS(selector: u16) void;

/// Set kernel stack for Ring 3 -> Ring 0 transitions
pub fn setKernelStack(rsp0: u64) void;

/// Segment selectors
pub const KERNEL_CS: u16 = 0x08;
pub const KERNEL_DS: u16 = 0x10;
pub const USER_DS: u16 = 0x18 | 3;
pub const USER_CS: u16 = 0x20 | 3;
pub const TSS_SEL: u16 = 0x28;
```

---

## IDT Management (`hal/x86_64/idt.zig`)

```zig
/// IDT gate descriptor
pub const GateDescriptor = packed struct(u128) { ... };

/// Gate types
pub const GateType = enum(u4) {
    Interrupt = 0xE,  // Clears IF
    Trap = 0xF,       // Preserves IF
};

/// Interrupt handler function type
pub const InterruptHandler = *const fn (*InterruptContext) void;

/// Initialize IDT
pub fn init() void;

/// Load IDT register (LIDT)
pub fn load(idt: *const IDT) void;

/// Set interrupt handler for vector
pub fn setHandler(vector: u8, handler: InterruptHandler, dpl: u2) void;

/// Remove handler for vector
pub fn removeHandler(vector: u8) void;

/// Exception vectors
pub const DIVIDE_ERROR: u8 = 0;
pub const DEBUG: u8 = 1;
pub const NMI: u8 = 2;
pub const BREAKPOINT: u8 = 3;
pub const OVERFLOW: u8 = 4;
pub const BOUND_RANGE: u8 = 5;
pub const INVALID_OPCODE: u8 = 6;
pub const DEVICE_NOT_AVAILABLE: u8 = 7;
pub const DOUBLE_FAULT: u8 = 8;
pub const INVALID_TSS: u8 = 10;
pub const SEGMENT_NOT_PRESENT: u8 = 11;
pub const STACK_FAULT: u8 = 12;
pub const GENERAL_PROTECTION: u8 = 13;
pub const PAGE_FAULT: u8 = 14;
pub const X87_FPU_ERROR: u8 = 16;
pub const ALIGNMENT_CHECK: u8 = 17;
pub const MACHINE_CHECK: u8 = 18;
pub const SIMD_EXCEPTION: u8 = 19;

/// IRQ vectors (after PIC remap)
pub const IRQ_TIMER: u8 = 0x20;
pub const IRQ_KEYBOARD: u8 = 0x21;
pub const IRQ_CASCADE: u8 = 0x22;
pub const IRQ_COM2: u8 = 0x23;
pub const IRQ_COM1: u8 = 0x24;
pub const IRQ_LPT2: u8 = 0x25;
pub const IRQ_FLOPPY: u8 = 0x26;
pub const IRQ_LPT1: u8 = 0x27;
pub const IRQ_RTC: u8 = 0x28;
pub const IRQ_FREE1: u8 = 0x29;
pub const IRQ_FREE2: u8 = 0x2A;
pub const IRQ_FREE3: u8 = 0x2B;
pub const IRQ_MOUSE: u8 = 0x2C;
pub const IRQ_FPU: u8 = 0x2D;
pub const IRQ_ATA1: u8 = 0x2E;
pub const IRQ_ATA2: u8 = 0x2F;
```

---

## PIC Control (`hal/x86_64/pic.zig`)

```zig
/// Initialize and remap PIC
/// Maps IRQ0-7 to vectors 0x20-0x27
/// Maps IRQ8-15 to vectors 0x28-0x2F
pub fn init() void;

/// Send End of Interrupt
pub fn sendEOI(irq: u8) void;

/// Mask (disable) an IRQ
pub fn maskIRQ(irq: u8) void;

/// Unmask (enable) an IRQ
pub fn unmaskIRQ(irq: u8) void;

/// Get current IRQ mask
pub fn getMask() u16;

/// Set IRQ mask
pub fn setMask(mask: u16) void;

/// Check if IRQ is masked
pub fn isIRQMasked(irq: u8) bool;

/// Disable all IRQs
pub fn disableAll() void;

/// Enable all IRQs
pub fn enableAll() void;
```

---

## Timer Control (`hal/x86_64/pit.zig`)

```zig
/// Initialize PIT at specified frequency
pub fn init(hz: u32) void;

/// Get current tick count
pub fn getTicks() u64;

/// Get elapsed milliseconds since boot
pub fn getMilliseconds() u64;

/// Sleep for specified ticks (blocking)
pub fn sleep(ticks: u64) void;

/// Register timer callback
pub fn setCallback(callback: *const fn (u64) void) void;

/// Default timer frequency
pub const DEFAULT_HZ: u32 = 100;
```

---

## PCI Bus (`hal/x86_64/pci.zig`)

```zig
/// PCI device address
pub const PCIAddress = struct {
    bus: u8,
    device: u5,
    function: u3,
};

/// PCI configuration read
pub fn configRead8(addr: PCIAddress, offset: u8) u8;
pub fn configRead16(addr: PCIAddress, offset: u8) u16;
pub fn configRead32(addr: PCIAddress, offset: u8) u32;

/// PCI configuration write
pub fn configWrite8(addr: PCIAddress, offset: u8, value: u8) void;
pub fn configWrite16(addr: PCIAddress, offset: u8, value: u16) void;
pub fn configWrite32(addr: PCIAddress, offset: u8, value: u32) void;

/// Enumerate all PCI devices
pub fn enumerate(callback: *const fn (PCIAddress, u16, u16) void) void;

/// Find device by vendor/device ID
pub fn findDevice(vendor_id: u16, device_id: u16) ?PCIAddress;

/// Get BAR address
pub fn getBAR(addr: PCIAddress, bar: u3) u64;

/// Enable bus mastering
pub fn enableBusMaster(addr: PCIAddress) void;

/// PCI configuration space offsets
pub const VENDOR_ID: u8 = 0x00;
pub const DEVICE_ID: u8 = 0x02;
pub const COMMAND: u8 = 0x04;
pub const STATUS: u8 = 0x06;
pub const CLASS_CODE: u8 = 0x0B;
pub const SUBCLASS: u8 = 0x0A;
pub const BAR0: u8 = 0x10;
pub const BAR1: u8 = 0x14;
pub const BAR2: u8 = 0x18;
pub const BAR3: u8 = 0x1C;
pub const BAR4: u8 = 0x20;
pub const BAR5: u8 = 0x24;
pub const INTERRUPT_LINE: u8 = 0x3C;
```

---

## E1000 Driver (`hal/drivers/e1000.zig`)

```zig
/// E1000 device instance
pub const E1000 = struct {
    mmio_base: [*]volatile u32,
    mac_addr: [6]u8,
    rx_ring: *RxRing,
    tx_ring: *TxRing,
};

/// Initialize E1000 device
pub fn init() !*E1000;

/// Send packet
pub fn transmit(dev: *E1000, data: []const u8) !void;

/// Receive packet (returns null if none available)
pub fn receive(dev: *E1000) ?[]u8;

/// Handle E1000 interrupt
pub fn handleInterrupt(dev: *E1000) void;

/// Get MAC address
pub fn getMACAddress(dev: *E1000) [6]u8;

/// Get link status
pub fn isLinkUp(dev: *E1000) bool;

/// E1000 vendor/device IDs
pub const VENDOR_ID: u16 = 0x8086;
pub const DEVICE_ID: u16 = 0x100E;
```

---

## Keyboard Driver (`hal/drivers/keyboard.zig`)

```zig
/// Initialize keyboard
pub fn init() void;

/// Read character from buffer (non-blocking)
pub fn getchar() ?u8;

/// Check if character available
pub fn hasChar() bool;

/// Handle keyboard interrupt
pub fn handleInterrupt() void;

/// Keyboard buffer size
pub const BUFFER_SIZE: usize = 256;
```

---

## Serial Driver (`hal/drivers/serial.zig`)

```zig
/// Initialize COM1 at specified baud rate
pub fn init(baud: u32) void;

/// Write byte to serial port
pub fn writeByte(byte: u8) void;

/// Write string to serial port
pub fn writeString(str: []const u8) void;

/// Read byte from serial port (blocking)
pub fn readByte() u8;

/// Check if data available
pub fn hasData() bool;

/// Handle serial interrupt
pub fn handleInterrupt() void;

/// COM port addresses
pub const COM1: u16 = 0x3F8;
pub const COM2: u16 = 0x2F8;
```

---

## Unified HAL Interface (`hal/hal.zig`)

```zig
// Re-export all HAL modules
pub const cpu = @import("x86_64/cpu.zig");
pub const port = @import("x86_64/port_io.zig");
pub const gdt = @import("x86_64/gdt.zig");
pub const idt = @import("x86_64/idt.zig");
pub const pic = @import("x86_64/pic.zig");
pub const pit = @import("x86_64/pit.zig");
pub const pci = @import("x86_64/pci.zig");

pub const e1000 = @import("drivers/e1000.zig");
pub const keyboard = @import("drivers/keyboard.zig");
pub const serial = @import("drivers/serial.zig");

/// Initialize all HAL subsystems
pub fn init() !void {
    gdt.init();
    idt.init();
    pic.init();
    pit.init(100); // 100Hz
    serial.init(115200);
    try e1000.init();
    keyboard.init();
}
```

---

## Usage Example

```zig
const hal = @import("hal/hal.zig");

pub fn kernelMain() void {
    // Initialize HAL
    hal.init() catch @panic("HAL init failed");

    // Set up timer interrupt handler
    hal.idt.setHandler(hal.idt.IRQ_TIMER, timerHandler, 0);
    hal.pic.unmaskIRQ(0);

    // Enable interrupts
    hal.cpu.enableInterrupts();

    // Get network device
    const net = hal.e1000.init() catch @panic("E1000 init failed");

    // Main loop
    while (true) {
        if (hal.e1000.receive(net)) |packet| {
            processPacket(packet);
        }
        hal.cpu.halt();
    }
}

fn timerHandler(ctx: *hal.idt.InterruptContext) void {
    scheduler.tick();
    hal.pic.sendEOI(0);
}
```

---

## Constitution Compliance

Per **Principle VI: Strict Layering**:

**Permitted in HAL only**:
- Inline assembly (`asm volatile`)
- Port I/O (`in`, `out`)
- Control register access (CR0-CR4)
- MSR read/write
- Memory-mapped I/O (via volatile pointers)

**Prohibited in kernel/net/proc layers**:
- Direct `asm volatile` for hardware
- Direct port I/O
- Direct register manipulation
- Raw memory addresses for hardware

**Verification**:
Code reviews MUST verify that files outside `hal/` do not contain:
- `asm volatile` with hardware instructions
- Port addresses (0x20, 0x3F8, etc.)
- CR/MSR register names
- MMIO address literals

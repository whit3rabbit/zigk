// 8259 Programmable Interrupt Controller (PIC) Driver
//
// The 8259 PIC manages hardware interrupts on legacy x86 systems.
// There are two PICs: master (IRQ 0-7) and slave (IRQ 8-15).
//
// By default, PIC IRQs conflict with CPU exceptions (IRQ 0 = vector 0 = #DE).
// We remap IRQs to vectors 32-47 to avoid this conflict.
//
// Note: Modern systems use APIC, but PIC is still needed for:
//   - Legacy hardware compatibility
//   - Systems without APIC
//   - Initial boot before APIC is configured

const io = @import("io.zig");

// PIC I/O ports
const PIC1_COMMAND: u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_COMMAND: u16 = 0xA0;
const PIC2_DATA: u16 = 0xA1;

// ICW1 (Initialization Command Word 1)
const ICW1_ICW4: u8 = 0x01; // ICW4 needed
const ICW1_SINGLE: u8 = 0x02; // Single (cascade) mode
const ICW1_INTERVAL4: u8 = 0x04; // Call address interval 4
const ICW1_LEVEL: u8 = 0x08; // Level triggered mode
const ICW1_INIT: u8 = 0x10; // Initialization

// ICW4 (Initialization Command Word 4)
const ICW4_8086: u8 = 0x01; // 8086/88 mode
const ICW4_AUTO: u8 = 0x02; // Auto EOI
const ICW4_BUF_SLAVE: u8 = 0x08; // Buffered mode/slave
const ICW4_BUF_MASTER: u8 = 0x0C; // Buffered mode/master
const ICW4_SFNM: u8 = 0x10; // Special fully nested

// OCW2 (Operation Command Word 2) - EOI commands
const OCW2_EOI: u8 = 0x20; // Non-specific EOI
const OCW2_SPECIFIC_EOI: u8 = 0x60; // Specific EOI (OR with IRQ number)

// OCW3 (Operation Command Word 3)
const OCW3_READ_IRR: u8 = 0x0A; // Read IRR (Interrupt Request Register)
const OCW3_READ_ISR: u8 = 0x0B; // Read ISR (In-Service Register)

// Vector offset for remapped IRQs
pub const IRQ_OFFSET: u8 = 32;

// Track the interrupt mask (1 = masked/disabled, 0 = enabled)
var pic1_mask: u8 = 0xFF; // All IRQs initially masked
var pic2_mask: u8 = 0xFF;

/// Initialize both PICs with remapped vectors
/// Master PIC: IRQ 0-7 -> vectors 32-39
/// Slave PIC: IRQ 8-15 -> vectors 40-47
pub fn init() void {
    // Start initialization sequence (ICW1)
    io.outb(PIC1_COMMAND, ICW1_INIT | ICW1_ICW4);
    ioWait();
    io.outb(PIC2_COMMAND, ICW1_INIT | ICW1_ICW4);
    ioWait();

    // ICW2: Set vector offsets
    io.outb(PIC1_DATA, IRQ_OFFSET); // Master: vectors 32-39
    ioWait();
    io.outb(PIC2_DATA, IRQ_OFFSET + 8); // Slave: vectors 40-47
    ioWait();

    // ICW3: Configure cascading
    io.outb(PIC1_DATA, 0x04); // Master: slave on IRQ2 (bit 2)
    ioWait();
    io.outb(PIC2_DATA, 0x02); // Slave: cascade identity (2)
    ioWait();

    // ICW4: Set 8086 mode
    io.outb(PIC1_DATA, ICW4_8086);
    ioWait();
    io.outb(PIC2_DATA, ICW4_8086);
    ioWait();

    // Set initial masks: all IRQs masked except cascade (IRQ2)
    pic1_mask = 0xFB; // Unmask IRQ2 (cascade from slave)
    pic2_mask = 0xFF; // Mask all slave IRQs
    io.outb(PIC1_DATA, pic1_mask);
    io.outb(PIC2_DATA, pic2_mask);
}

/// Disable PIC (typically done when switching to APIC)
pub fn disable() void {
    // Mask all IRQs
    io.outb(PIC1_DATA, 0xFF);
    io.outb(PIC2_DATA, 0xFF);
}

/// Send End of Interrupt (EOI) for the given IRQ
/// Must be called at the end of every IRQ handler
pub fn sendEoi(irq: u8) void {
    if (irq >= 8) {
        // IRQ came from slave PIC, send EOI to both
        io.outb(PIC2_COMMAND, OCW2_EOI);
    }
    // Always send EOI to master
    io.outb(PIC1_COMMAND, OCW2_EOI);
}

/// Enable (unmask) a specific IRQ
pub fn enableIrq(irq: u8) void {
    if (irq < 8) {
        pic1_mask &= ~(@as(u8, 1) << @truncate(irq));
        io.outb(PIC1_DATA, pic1_mask);
    } else if (irq < 16) {
        pic2_mask &= ~(@as(u8, 1) << @truncate(irq - 8));
        io.outb(PIC2_DATA, pic2_mask);
    }
}

/// Disable (mask) a specific IRQ
pub fn disableIrq(irq: u8) void {
    if (irq < 8) {
        pic1_mask |= @as(u8, 1) << @truncate(irq);
        io.outb(PIC1_DATA, pic1_mask);
    } else if (irq < 16) {
        pic2_mask |= @as(u8, 1) << @truncate(irq - 8);
        io.outb(PIC2_DATA, pic2_mask);
    }
}

/// Check if an IRQ is masked
pub fn isIrqMasked(irq: u8) bool {
    if (irq < 8) {
        return (pic1_mask & (@as(u8, 1) << @truncate(irq))) != 0;
    } else if (irq < 16) {
        return (pic2_mask & (@as(u8, 1) << @truncate(irq - 8))) != 0;
    }
    return true;
}

/// Get current IRQ mask for master PIC
pub fn getMasterMask() u8 {
    return pic1_mask;
}

/// Get current IRQ mask for slave PIC
pub fn getSlaveMask() u8 {
    return pic2_mask;
}

/// Read the Interrupt Request Register (IRR)
/// Shows which IRQs are pending
pub fn readIrr() u16 {
    io.outb(PIC1_COMMAND, OCW3_READ_IRR);
    io.outb(PIC2_COMMAND, OCW3_READ_IRR);
    return (@as(u16, io.inb(PIC2_COMMAND)) << 8) | io.inb(PIC1_COMMAND);
}

/// Read the In-Service Register (ISR)
/// Shows which IRQs are currently being serviced
pub fn readIsr() u16 {
    io.outb(PIC1_COMMAND, OCW3_READ_ISR);
    io.outb(PIC2_COMMAND, OCW3_READ_ISR);
    return (@as(u16, io.inb(PIC2_COMMAND)) << 8) | io.inb(PIC1_COMMAND);
}

/// Check if an IRQ is spurious
/// Spurious IRQs can occur due to electrical noise or timing issues
/// IRQ 7 (master) and IRQ 15 (slave) are most common
pub fn isSpurious(irq: u8) bool {
    // Check ISR - if the bit is not set, it's spurious
    const isr = readIsr();

    if (irq == 7) {
        // Master spurious - check if bit 7 is set
        return (isr & 0x80) == 0;
    } else if (irq == 15) {
        // Slave spurious - check if bit 15 is set
        // Note: Still need to send EOI to master for cascade
        if ((isr & 0x8000) == 0) {
            io.outb(PIC1_COMMAND, OCW2_EOI);
            return true;
        }
    }
    return false;
}

/// Small delay for PIC operations
/// Some old hardware needs time between I/O operations
fn ioWait() void {
    // Write to unused port 0x80 (POST code port)
    // This causes a small delay without side effects
    io.outb(0x80, 0);
}

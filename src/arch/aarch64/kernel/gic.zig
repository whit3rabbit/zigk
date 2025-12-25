// AArch64 Generic Interrupt Controller (GICv2) Driver

const GICD_BASE = 0x08000000;
const GICC_BASE = 0x08010000;

// Distributor Registers
const GICD_CTLR = 0x000;
const GICD_TYPER = 0x004;
const GICD_ISENABLER = 0x100;
const GICD_ICENABLER = 0x180;
const GICD_IPRIORITYR = 0x400;
const GICD_ITARGETSR = 0x800;
const GICD_ICFGR = 0xC00;

// CPU Interface Registers
const GICC_CTLR = 0x000;
const GICC_PMR = 0x004;
const GICC_IAR = 0x00C;
const GICC_EOIR = 0x010;

fn writeGicd(offset: u32, val: u32) void {
    const addr: *volatile u32 = @ptrFromInt(GICD_BASE + offset);
    addr.* = val;
}

fn readGicd(offset: u32) u32 {
    const addr: *volatile u32 = @ptrFromInt(GICD_BASE + offset);
    return addr.*;
}

fn writeGicc(offset: u32, val: u32) void {
    const addr: *volatile u32 = @ptrFromInt(GICC_BASE + offset);
    addr.* = val;
}

fn readGicc(offset: u32) u32 {
    const addr: *volatile u32 = @ptrFromInt(GICC_BASE + offset);
    return addr.*;
}

pub fn init() void {
    // Disable Distributor
    writeGicd(GICD_CTLR, 0);

    // Get number of supported interrupts
    const typer = readGicd(GICD_TYPER);
    const it_lines = ((typer & 0x1F) + 1) * 32;

    // Disable all interrupts
    var i: u32 = 0;
    while (i < it_lines) : (i += 32) {
        writeGicd(GICD_ICENABLER + (i / 32) * 4, 0xFFFFFFFF);
    }

    // Set processor target for all interrupts to CPU 0
    i = 32; // Skip SGIs and PPIs
    while (i < it_lines) : (i += 4) {
        writeGicd(GICD_ITARGETSR + i, 0x01010101);
    }

    // Set priority for all interrupts
    i = 0;
    while (i < it_lines) : (i += 4) {
        writeGicd(GICD_IPRIORITYR + i, 0xA0A0A0A0);
    }

    // Enable Distributor
    writeGicd(GICD_CTLR, 1);

    // Initialize CPU Interface
    writeGicc(GICC_PMR, 0xF0); // Priority mask
    writeGicc(GICC_CTLR, 1);   // Enable CPU Interface
}

pub fn enableIrq(irq: u32) void {
    const reg = GICD_ISENABLER + (irq / 32) * 4;
    const bit = @as(u32, 1) << @truncate(irq % 32);
    writeGicd(reg, bit);
}

pub fn disableIrq(irq: u32) void {
    const reg = GICD_ICENABLER + (irq / 32) * 4;
    const bit = @as(u32, 1) << @truncate(irq % 32);
    writeGicd(reg, bit);
}

pub fn acknowledgeIrq() u32 {
    return readGicc(GICC_IAR) & 0x3FF;
}

pub fn endOfInterrupt(irq: u32) void {
    writeGicc(GICC_EOIR, irq & 0x3FF);
}

pub fn sendIpi(target_cpu_mask: u32, sgi_id: u8) void {
    const sgi_val = (@as(u32, target_cpu_mask) << 16) | (sgi_id & 0xF);
    writeGicd(0xF00, sgi_val); // GICD_SGIR
}

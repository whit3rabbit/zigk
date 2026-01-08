// Intel HDA Initialization

const std = @import("std");
const hal = @import("hal");
const pci = @import("pci");
const pmm = @import("pmm");
const heap = @import("heap");
const console = @import("console");
const types = @import("types.zig");
const regs = @import("regs.zig");
const sync = @import("sync");

pub fn init(pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) !*types.Hda {
    _ = pci_access;
    console.info("HDA: Initializing Intel High Definition Audio...", .{});

    // Check BAR0 (Memory Mapped IO)
    // HDA registers span at least 0x180 bytes; require 4KB minimum for safety
    const bar0 = pci_dev.bar[0];
    if (!bar0.isValid() or !bar0.is_mmio) {
        console.err("HDA: Invalid BAR0 (must be MMIO)", .{});
        return error.InvalidDevice;
    }
    if (bar0.size < 0x1000) {
        console.err("HDA: BAR0 too small (0x{x} < 0x1000)", .{bar0.size});
        return error.InvalidDevice;
    }

    // Allocate driver instance
    // Security note: Heap allocation is safe here because the Hda struct itself is NOT
    // a DMA target - it only holds pointers to DMA buffers. The actual DMA buffers
    // (CORB/RIRB rings) are allocated from PMM below with pmm.allocZeroedPage().
    // Hardware never accesses this struct directly; it only accesses the PMM-allocated
    // physical addresses stored in corb_phys/rirb_phys fields.
    const driver = try heap.allocator().create(types.Hda);
    errdefer heap.allocator().destroy(driver);

    driver.* = types.Hda{
        .mmio_base = bar0.base,
        .mmio_size = bar0.size,
        .corb_phys = 0,
        .corb_virt = undefined,
        .corb_entries = 256,
        .rirb_phys = 0,
        .rirb_virt = undefined,
        .rirb_entries = 256,
        .codecs_found = 0,
        .irq_line = pci_dev.irq_line,
        .lock = sync.Spinlock{},
    };

    // 1. Reset Controller
    try resetController(driver);

    // 2. Setup CORB (Command Ring)
    try setupCorb(driver);

    // 3. Setup RIRB (Response Ring)
    try setupRirb(driver);

    // 4. Start DMA Engines for CORB/RIRB
    startCorbRirb(driver);

    // 5. Detect Codecs using STATESTS
    detectCodecs(driver);

    console.info("HDA: Init complete. Codecs found: 0x{x}", .{driver.codecs_found});

    return driver;
}

fn resetController(self: *types.Hda) !void {
    const gctl_addr = self.mmio_base + regs.GCTL;
    var gctl = hal.mmio.read32(gctl_addr);

    // Clear CRST bit to enter reset
    hal.mmio.write32(gctl_addr, gctl & ~regs.GCTL_CRST);

    // Wait for bit to clear
    var timeout: usize = 1000;
    while ((hal.mmio.read32(gctl_addr) & regs.GCTL_CRST) != 0) : (timeout -= 1) {
        if (timeout == 0) return error.ResetTimeout;
        hal.cpu.stall(10);
    }

    // Set CRST bit to exit reset
    gctl = hal.mmio.read32(gctl_addr);
    hal.mmio.write32(gctl_addr, gctl | regs.GCTL_CRST);

    // Wait for bit to set
    timeout = 1000;
    while ((hal.mmio.read32(gctl_addr) & regs.GCTL_CRST) == 0) : (timeout -= 1) {
        if (timeout == 0) return error.ResetTimeout;
        hal.cpu.stall(10);
    }
    
    // Wait for codecs to report status (specification recommends delay)
    hal.cpu.stall(1000);
}

fn setupCorb(self: *types.Hda) !void {
    // Allocate 1KB page for CORB (256 entries * 4 bytes = 1024 bytes)
    // We align to 128 bytes as per spec, but page alignment is safer.
    const page = pmm.allocZeroedPage() orelse return error.OutOfMemory;
    self.corb_phys = page;
    self.corb_virt = @ptrCast(@alignCast(hal.paging.physToVirt(page)));

    // Stop CORB DMA
    const ctl_addr = self.mmio_base + regs.CORBCTL;
    hal.mmio.write8(ctl_addr, 0);

    // Set Address
    hal.mmio.write32(self.mmio_base + regs.CORBLBASE, @truncate(self.corb_phys));
    hal.mmio.write32(self.mmio_base + regs.CORBUBASE, @truncate(self.corb_phys >> 32));

    // Set Size (0x02 = 256 entries)
    hal.mmio.write8(self.mmio_base + regs.CORBSIZE, 0x02);

    // Reset Read/Write Pointers
    hal.mmio.write16(self.mmio_base + regs.CORBRP, 0x8000); // Set RST bit to reset
    // Ensure write pointer is cleared
    hal.mmio.write16(self.mmio_base + regs.CORBWP, 0);
    
    // Wait for reset to complete
    hal.cpu.stall(100);
    hal.mmio.write16(self.mmio_base + regs.CORBRP, 0); // Clear RST bit
}

fn setupRirb(self: *types.Hda) !void {
    // Allocate 2KB for RIRB (256 entries * 8 bytes = 2048 bytes)
    // We use a full 4KB page.
    const page = pmm.allocZeroedPage() orelse return error.OutOfMemory;
    self.rirb_phys = page;
    self.rirb_virt = @ptrCast(@alignCast(hal.paging.physToVirt(page)));

    // Stop RIRB DMA
    const ctl_addr = self.mmio_base + regs.RIRBCTL;
    hal.mmio.write8(ctl_addr, 0);

    // Set Address
    hal.mmio.write32(self.mmio_base + regs.RIRBLBASE, @truncate(self.rirb_phys));
    hal.mmio.write32(self.mmio_base + regs.RIRBUBASE, @truncate(self.rirb_phys >> 32));

    // Set Size (0x02 = 256 entries)
    hal.mmio.write8(self.mmio_base + regs.RIRBSIZE, 0x02);

    // Reset Write Pointer (Read pointer is SW owned)
    hal.mmio.write16(self.mmio_base + regs.RIRBWP, 0x8000); 
    
    // Wait
    hal.cpu.stall(100);
    hal.mmio.write16(self.mmio_base + regs.RIRBWP, 0);
}

fn startCorbRirb(self: *const types.Hda) void {
    // Enable CORB DMA
    hal.mmio.write8(self.mmio_base + regs.CORBCTL, regs.CORBCTL_DMA_RUN);

    // Enable RIRB DMA and Interrupt
    hal.mmio.write8(self.mmio_base + regs.RIRBCTL, regs.RIRBCTL_DMA_RUN | regs.RIRBCTL_INT_EN);
}

fn detectCodecs(self: *types.Hda) void {
    // Read STATESTS (State Change Status) - Bits 0-14 indicate codec presence
    // Note: This register is technically for state changes, but often reflects presence after reset.
    // A more robust way is scanning, but reading GSTS usually works.
    const statests = hal.mmio.read16(self.mmio_base + regs.STATESTS);

    // Mask to valid codec bits (0-14). Bit 15 is reserved.
    // 0xFFFF typically indicates unimplemented register or hardware issue.
    const valid_mask: u16 = 0x7FFF;
    self.codecs_found = statests & valid_mask;

    if (statests == 0xFFFF) {
        console.warn("HDA: STATESTS returned 0xFFFF - register may be unimplemented", .{});
    }

    // Clear status bits (W1C)
    hal.mmio.write16(self.mmio_base + regs.STATESTS, statests);
}

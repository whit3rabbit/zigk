const std = @import("std");
const hal = @import("hal");
const pci = @import("pci");
const pmm = @import("pmm");
const heap = @import("heap");
const console = @import("console");
const sync = @import("sync");
const kernel_io = @import("io");
const types = @import("types.zig");
const regs = @import("regs.zig");
const sound = @import("uapi").sound;

const port_io = hal.io;

pub fn init(pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) !*types.Ac97 {
    console.info("AC97: Initializing...", .{});

    // BAR0: NAMBAR (Mixer), BAR1: NABMBAR (Bus Master)
    const nam_bar = pci_dev.bar[0];
    const nabm_bar = pci_dev.bar[1];

    if (!nam_bar.isValid() or !nabm_bar.isValid()) {
        console.err("AC97: Invalid BARs", .{});
        return error.InvalidDevice;
    }

    // Enable Bus Master (required for DMA) and IO Space
    pci_access.enableBusMaster(pci_dev.bus, pci_dev.device, pci_dev.func);
    pci_access.enableMemorySpace(pci_dev.bus, pci_dev.device, pci_dev.func);

    // Allocate instance
    // Security note: Heap allocation is safe here because the Ac97 struct itself is NOT
    // a DMA target - it only holds pointers to DMA buffers. The actual DMA buffers
    // (BDL and audio buffers) are allocated from PMM below with pmm.allocZeroedPage().
    // Hardware accesses only the physical addresses (bdl_phys, buffers_phys), not this struct.
    const driver = try heap.allocator().create(types.Ac97);
    errdefer heap.allocator().destroy(driver);
    driver.* = types.Ac97{
        .nam_base = @truncate(nam_bar.base),
        .nabm_base = @truncate(nabm_bar.base),
        .irq_line = pci_dev.irq_line,
        .bdl_phys = 0,
        .bdl = undefined,
        .buffers = undefined,
        .buffers_phys = [_]u64{0} ** types.BDL_ENTRY_COUNT,
        .current_buffer = 0,
        .last_completed = 0,
        .sample_rate = 48000,
        .channels = 2,
        .format = sound.AFMT_S16_LE,
        .vra_supported = false,
        .lock = sync.Spinlock{},
        .wait_queue = null,
        .pending_requests = [_]?*kernel_io.IoRequest{null} ** types.BDL_ENTRY_COUNT,
        .pending_queue_head = null,
        .pending_queue_tail = null,
        .irq_enabled = false,
    };

    // Allocate BDL
    const bdl_phys = pmm.allocZeroedPage() orelse return error.OutOfMemory;
    errdefer pmm.freePage(bdl_phys);

    if (bdl_phys > 0xFFFFFFFF) {
        console.err("AC97: BDL address 0x{x} exceeds 32-bit DMA limit", .{bdl_phys});
        pmm.freePage(bdl_phys);
        return error.DmaAddressOutOfRange;
    }

    driver.bdl_phys = bdl_phys;
    driver.bdl = @ptrCast(@alignCast(hal.paging.physToVirt(bdl_phys)));

    // Allocate Buffers
    var allocated_buffers: usize = 0;
    errdefer {
        for (0..allocated_buffers) |i| {
            pmm.freePage(driver.buffers_phys[i]);
        }
    }

    for (0..types.BDL_ENTRY_COUNT) |i| {
        const buf_phys = pmm.allocZeroedPage() orelse return error.OutOfMemory;

        if (buf_phys > 0xFFFFFFFF) {
            console.err("AC97: Buffer {} address 0x{x} exceeds 32-bit DMA limit", .{ i, buf_phys });
            pmm.freePage(buf_phys);
            return error.DmaAddressOutOfRange;
        }

        driver.buffers_phys[i] = buf_phys;
        driver.buffers[i] = hal.paging.physToVirt(buf_phys);
        allocated_buffers += 1;

        driver.bdl[i] = types.BdlEntry{
            .ptr = @truncate(buf_phys),
            .ioc = true,
            .bup = true,
            .len = 0,
        };
    }

    reset(driver);

    return driver;
}

pub fn reset(self: *types.Ac97) void {
    // Cold Reset via Global Control
    port_io.outb(self.nabm_base + regs.NABM_GLOB_CNT, 0x02);

    // Reset Mixer
    port_io.outw(self.nam_base + regs.NAM_RESET, 0xFFFF);

    // Setup BDL Address
    port_io.outl(self.nabm_base + regs.NABM_PO_BDBAR, @truncate(self.bdl_phys));

    // Set Last Valid Index to 0 initially
    port_io.outb(self.nabm_base + regs.NABM_PO_LVI, 0);

    // Set Master Volume
    port_io.outw(self.nam_base + regs.NAM_MASTER_VOL, 0x0202);
    port_io.outw(self.nam_base + regs.NAM_PCM_OUT_VOL, 0x0202);

    // Detect and Enable VRA
    const ext_id = port_io.inw(self.nam_base + regs.NAM_EXT_AUDIO_ID);
    if ((ext_id & regs.EAI_VRA) != 0) {
        const ext_ctrl = port_io.inw(self.nam_base + regs.NAM_EXT_AUDIO_CTRL);
        port_io.outw(self.nam_base + regs.NAM_EXT_AUDIO_CTRL, ext_ctrl | regs.EAC_VRA);
        self.vra_supported = true;
        console.info("AC97: VRA enabled", .{});
    }

    // Set sample rate
    port_io.outw(self.nam_base + regs.NAM_PCM_FRONT_DAC_RATE, 48000);
    const actual = port_io.inw(self.nam_base + regs.NAM_PCM_FRONT_DAC_RATE);
    self.sample_rate = actual;
}

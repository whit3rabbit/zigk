// Intel 82801AA AC'97 Audio Driver
//
// Implements a driver for the AC'97 Audio Controller.
// Supports playback via /dev/dsp (OSS-compatible).

const std = @import("std");
const hal = @import("hal");
const pci = @import("pci");
const pmm = @import("pmm");
const vmm = @import("vmm");
const console = @import("console");
const uapi = @import("uapi");
const fd = @import("fd");
const sync = @import("sync");
const heap = @import("heap");
const sched = @import("sched");
const thread = @import("thread");

const io = hal.io;
const sound = uapi.sound;

// AC97 Native Audio Mixer (NAM) Registers (IO Space)
const NAM_RESET: u16 = 0x00;
const NAM_MASTER_VOL: u16 = 0x02;
const NAM_PCM_OUT_VOL: u16 = 0x18;
const NAM_EXT_AUDIO_ID: u16 = 0x28;
const NAM_EXT_AUDIO_CTRL: u16 = 0x2A;
const NAM_PCM_FRONT_DAC_RATE: u16 = 0x2C;
const NAM_PCM_SURR_DAC_RATE: u16 = 0x2E;
const NAM_PCM_LFE_DAC_RATE: u16 = 0x30;

// AC97 Native Audio Bus Master (NABM) Registers (IO Space)
const NABM_PO_BDBAR: u16 = 0x10; // PCM Out Buffer Descriptor Base Address
const NABM_PO_CIV: u16 = 0x14;   // Current Index Value
const NABM_PO_LVI: u16 = 0x15;   // Last Valid Index
const NABM_PO_SR: u16 = 0x16;    // Status Register
const NABM_PO_PICB: u16 = 0x18;  // Position In Current Buffer
const NABM_PO_CR: u16 = 0x1B;    // Control Register
const NABM_GLOB_CNT: u16 = 0x2C; // Global Control
const NABM_GLOB_STA: u16 = 0x30; // Global Status

// NABM Status Register Bits
const SR_DCH: u16 = 1 << 0;   // DMA Controller Halted
const SR_CELV: u16 = 1 << 1;  // Current Equals Last Valid
const SR_LVBCI: u16 = 1 << 2; // Last Valid Buffer Completion Interrupt
const SR_BCIS: u16 = 1 << 3;  // Buffer Completion Interrupt Status
const SR_FIFO: u16 = 1 << 4;  // FIFO Error

// NABM Control Register Bits
const CR_RPBM: u8 = 1 << 0;   // Run/Pause Bus Master
const CR_RR: u8 = 1 << 1;     // Reset Registers
const CR_LVBIE: u8 = 1 << 2;  // Last Valid Buffer Interrupt Enable
const CR_FEIE: u8 = 1 << 3;   // FIFO Error Interrupt Enable
const CR_IOCE: u8 = 1 << 4;   // Interrupt On Completion Enable

// Buffer Descriptor List (BDL) Constants
const BDL_ENTRY_COUNT: usize = 32;
const BUFFER_SIZE: usize = 0x1000; // 4KB per buffer

// BDL Entry Structure (Hardware format)
const BdlEntry = packed struct {
    ptr: u32,             // Physical address of buffer
    ioc: bool = true,     // Interrupt On Completion
    bup: bool = true,     // Buffer Underrun Policy (play last sample vs zero)
    reserved: u14 = 0,
    len: u16,             // Number of samples (not bytes)
};

// Driver Instance
pub const Ac97 = struct {
    nam_base: u16,       // Mixer Base Address (NAMBAR)
    nabm_base: u16,      // Bus Master Base Address (NABMBAR)
    irq_line: u8,

    bdl_phys: u64,       // Physical address of BDL
    bdl: *[BDL_ENTRY_COUNT]BdlEntry, // Virtual address of BDL

    buffers: [BDL_ENTRY_COUNT][*]u8, // Virtual addresses of buffers
    buffers_phys: [BDL_ENTRY_COUNT]u64, // Physical addresses

    current_buffer: usize, // Software write pointer (buffer index)

    // PCM State
    sample_rate: u32,
    channels: u32,
    format: u32, // AFMT_*

    lock: sync.Spinlock,
    wait_queue: ?*thread.Thread, // Single waiter for now (simple blocking)

    const Self = @This();

    // Init
    pub fn init(pci_dev: *const pci.PciDevice, ecam: *const pci.Ecam) !*Self {
        console.info("AC97: Initializing...", .{});

        // Get BARs
        // BAR0: NAMBAR (Mixer), BAR1: NABMBAR (Bus Master)
        const nam_bar = pci_dev.bar[0];
        const nabm_bar = pci_dev.bar[1];

        if (!nam_bar.isValid() or !nabm_bar.isValid()) {
            console.err("AC97: Invalid BARs", .{});
            return error.InvalidDevice;
        }

        // Enable Bus Master (required for DMA) and IO Space via ECAM
        ecam.enableBusMaster(pci_dev.bus, pci_dev.device, pci_dev.func);
        ecam.enableMemorySpace(pci_dev.bus, pci_dev.device, pci_dev.func);

        // Allocate instance
        const driver = try heap.allocator().create(Self);
        driver.* = Self{
            .nam_base = @truncate(nam_bar.base),
            .nabm_base = @truncate(nabm_bar.base),
            .irq_line = pci_dev.irq_line,
            .bdl_phys = 0,
            .bdl = undefined,
            .buffers = undefined,
            .buffers_phys = [_]u64{0} ** BDL_ENTRY_COUNT,
            .current_buffer = 0,
            .sample_rate = 48000,
            .channels = 2,
            .format = sound.AFMT_S16_LE,
            .lock = sync.Spinlock{},
            .wait_queue = null,
        };

        // Allocate BDL
        const bdl_phys = pmm.allocZeroedPage() orelse return error.OutOfMemory;
        driver.bdl_phys = bdl_phys;
        driver.bdl = @ptrCast(@alignCast(hal.paging.physToVirt(bdl_phys)));

        // Allocate Buffers
        for (0..BDL_ENTRY_COUNT) |i| {
            const buf_phys = pmm.allocZeroedPage() orelse return error.OutOfMemory;
            driver.buffers_phys[i] = buf_phys;
            driver.buffers[i] = hal.paging.physToVirt(buf_phys);

            // Setup BDL Entry
            driver.bdl[i] = BdlEntry{
                .ptr = @truncate(buf_phys),
                .ioc = true, // Interrupt when this buffer is done
                .bup = true,
                .len = 0, // Initially empty
            };
        }

        // Reset Controller
        driver.reset();

        return driver;
    }

    fn reset(self: *Self) void {
        // Cold Reset via Global Control
        io.outb(self.nabm_base + NABM_GLOB_CNT, 0x02); // Cold Reset
        // Wait?

        // Reset Mixer
        io.outw(self.nam_base + NAM_RESET, 0xFFFF); // Write anything to reset

        // Setup BDL Address
        io.outl(self.nabm_base + NABM_PO_BDBAR, @truncate(self.bdl_phys));

        // Set Last Valid Index to 0 initially (one buffer)
        // Wait, LVI is the index of the last valid descriptor.
        // We want the hardware to wrap around.
        // If we set LVI = 31, it will play all 32 buffers then stop or wrap?
        // It wraps if we update LVI or if it's circular?
        // AC97 is not automatically circular. It stops at LVI.
        // We need to update LVI as we fill buffers.
        io.outb(self.nabm_base + NABM_PO_LVI, 0); // Start with nothing valid?

        // Set Master Volume (0 is max, 0x1F is min/mute)
        // 0x0202 = 0dB attenuation (max volume)
        io.outw(self.nam_base + NAM_MASTER_VOL, 0x0202);
        io.outw(self.nam_base + NAM_PCM_OUT_VOL, 0x0202);

        // Set sample rate (try 48kHz)
        // Check if VRA is supported (Extended Audio ID)
        // For simplicity, we assume 48kHz fixed for now unless requested.
        io.outw(self.nam_base + NAM_PCM_FRONT_DAC_RATE, 48000);
    }

    // DevFS Operations

    pub fn write(self: *Self, data: []const u8) isize {
        // We need to copy data to buffers and update LVI.
        // If all buffers are full, wait.

        // Calculate bytes per sample frame (stereo 16-bit = 4 bytes)
        const frame_size: usize = 4;

        var written: usize = 0;

        while (written < data.len) {
            // Find current hardware position
            var civ = io.inb(self.nabm_base + NABM_PO_CIV);
            const lvi = io.inb(self.nabm_base + NABM_PO_LVI);
            _ = lvi; // Used for debugging; hardware uses ring buffer

            // Check if we have space.
            // We can write to any buffer that is NOT currently being played.
            // civ is the buffer currently being played.
            // We want to write to self.current_buffer.
            // If self.current_buffer == civ, we might be overwriting what is playing (bad).
            // But we treat it as a ring.

            // Strategy: Fill buffers ahead of CIV.
            // If self.current_buffer == civ, we are too fast (caught up to hardware read pointer from behind).
            // Or hardware is stopped.

            // Wait, hardware stops at LVI.
            // If we are at LVI, we should advance LVI.

            // Let's simplified logic:
            // current_buffer is where we want to write next.
            // We can write if current_buffer != civ.
            // Wait, if LVI is far ahead, civ moves towards it.

            // Actually, correct check is:
            // available = (civ + BDL_ENTRY_COUNT - current_buffer) % BDL_ENTRY_COUNT? No.

            // Let's use:
            // Software Write Ptr: current_buffer
            // Hardware Read Ptr: civ

            if (self.current_buffer == civ) {
                 // Check if hardware is actually running
                 var sr = io.inw(self.nabm_base + NABM_PO_SR);
                 while ((sr & SR_DCH) == 0 and self.current_buffer == civ) {
                     // DMA is running and pointing to our buffer. We are full.
                     // Poll until hardware advances or stops.
                     sched.yield();
                     civ = io.inb(self.nabm_base + NABM_PO_CIV);
                     sr = io.inw(self.nabm_base + NABM_PO_SR);
                 }
                 // If halted (SR_DCH) or civ moved, we can write.
            }

            const chunk_size = @min(BUFFER_SIZE, data.len - written);

            // Copy data
            const buf = self.buffers[self.current_buffer];
            @memcpy(buf[0..chunk_size], data[written..][0..chunk_size]);

            // Update BDL entry
            // Length is in samples.
            const samples = chunk_size / frame_size;
            self.bdl[self.current_buffer].len = @truncate(samples);

            written += chunk_size;

            // Advance software pointer
            const next_buffer = (self.current_buffer + 1) % BDL_ENTRY_COUNT;
            self.current_buffer = next_buffer;

            // Update LVI to point to the buffer we just filled (or keep it ahead)
            // If we just filled buffer N, we set LVI to N.
            io.outb(self.nabm_base + NABM_PO_LVI, @truncate(self.current_buffer));

            // Ensure DMA is running
            const cr = io.inb(self.nabm_base + NABM_PO_CR);
            if ((cr & CR_RPBM) == 0) {
                // Start (Run, no interrupts for polling mode)
                io.outb(self.nabm_base + NABM_PO_CR, CR_RPBM);
            }
        }

        return @intCast(written);
    }

    pub fn ioctl(self: *Self, cmd: u32, arg: usize) isize {
        _ = self;
        // Handle SNDCTL_DSP_SPEED etc.
        // For now, just return success or the value requested (mimic behavior)
        switch (cmd) {
             sound.SNDCTL_DSP_SPEED => {
                 if (arg > 0x0000_7FFF_FFFF_FFFF) return -14; // EFAULT
                 const ptr = @as(*u32, @ptrFromInt(arg));
                 ptr.* = 48000;
                 return 0;
             },
             sound.SNDCTL_DSP_STEREO => {
                 if (arg > 0x0000_7FFF_FFFF_FFFF) return -14; // EFAULT
                 const ptr = @as(*u32, @ptrFromInt(arg));
                 ptr.* = 1; // Stereo
                 return 0;
             },
             sound.SNDCTL_DSP_SETFMT => {
                 if (arg > 0x0000_7FFF_FFFF_FFFF) return -14; // EFAULT
                 const ptr = @as(*u32, @ptrFromInt(arg));
                 ptr.* = sound.AFMT_S16_LE;
                 return 0;
             },
             else => return 0,
        }
    }
};

// Global Instance
var ac97_driver: ?*Ac97 = null;

// File Ops
fn dspWrite(fd_ctx: *fd.FileDescriptor, buf: []const u8) isize {
    _ = fd_ctx;
    if (ac97_driver) |drv| {
        return drv.write(buf);
    }
    return -1;
}

fn dspIoctl(fd_ctx: *fd.FileDescriptor, cmd: u64, arg: u64) isize {
    _ = fd_ctx;
    if (ac97_driver) |drv| {
        return drv.ioctl(@truncate(cmd), arg);
    }
    return -1;
}

pub const dsp_ops = fd.FileOps{
    .read = null, // Playback only for now
    .write = dspWrite,
    .close = null,
    .seek = null,
    .stat = null,
    .ioctl = dspIoctl,
    .mmap = null,
};

pub fn initFromPci(pci_dev: *const pci.PciDevice, ecam: *const pci.Ecam) !void {
    ac97_driver = try Ac97.init(pci_dev, ecam);
}

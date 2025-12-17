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
const user_mem = @import("user_mem");
const kernel_io = @import("io"); // Kernel async I/O

const port_io = hal.io;
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

    // Async I/O support
    // Track pending IoRequest per buffer slot for IRQ-driven completion
    pending_requests: [BDL_ENTRY_COUNT]?*kernel_io.IoRequest,
    pending_queue_head: ?*kernel_io.IoRequest, // FIFO queue of waiting requests
    pending_queue_tail: ?*kernel_io.IoRequest,
    irq_enabled: bool,

    const Self = @This();

    // Init
    pub fn init(pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) !*Self {
        console.info("AC97: Initializing...", .{});

        // Get BARs
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
        const driver = try heap.allocator().create(Self);
        errdefer heap.allocator().destroy(driver);
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
            .pending_requests = [_]?*kernel_io.IoRequest{null} ** BDL_ENTRY_COUNT,
            .pending_queue_head = null,
            .pending_queue_tail = null,
            .irq_enabled = false,
        };

        // Allocate BDL
        const bdl_phys = pmm.allocZeroedPage() orelse return error.OutOfMemory;
        errdefer pmm.freePage(bdl_phys);
        driver.bdl_phys = bdl_phys;
        driver.bdl = @ptrCast(@alignCast(hal.paging.physToVirt(bdl_phys)));

        // Allocate Buffers - track count for cleanup on failure
        var allocated_buffers: usize = 0;
        errdefer {
            for (0..allocated_buffers) |i| {
                pmm.freePage(driver.buffers_phys[i]);
            }
        }

        for (0..BDL_ENTRY_COUNT) |i| {
            const buf_phys = pmm.allocZeroedPage() orelse return error.OutOfMemory;
            driver.buffers_phys[i] = buf_phys;
            driver.buffers[i] = hal.paging.physToVirt(buf_phys);
            allocated_buffers += 1;

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
        port_io.outb(self.nabm_base + NABM_GLOB_CNT, 0x02); // Cold Reset
        // Wait?

        // Reset Mixer
        port_io.outw(self.nam_base + NAM_RESET, 0xFFFF); // Write anything to reset

        // Setup BDL Address
        port_io.outl(self.nabm_base + NABM_PO_BDBAR, @truncate(self.bdl_phys));

        // Set Last Valid Index to 0 initially (one buffer)
        // Wait, LVI is the index of the last valid descriptor.
        // We want the hardware to wrap around.
        // If we set LVI = 31, it will play all 32 buffers then stop or wrap?
        // It wraps if we update LVI or if it's circular?
        // AC97 is not automatically circular. It stops at LVI.
        // We need to update LVI as we fill buffers.
        port_io.outb(self.nabm_base + NABM_PO_LVI, 0); // Start with nothing valid?

        // Set Master Volume (0 is max, 0x1F is min/mute)
        // 0x0202 = 0dB attenuation (max volume)
        port_io.outw(self.nam_base + NAM_MASTER_VOL, 0x0202);
        port_io.outw(self.nam_base + NAM_PCM_OUT_VOL, 0x0202);

        // Set sample rate (try 48kHz)
        // Check if VRA is supported (Extended Audio ID)
        // For simplicity, we assume 48kHz fixed for now unless requested.
        port_io.outw(self.nam_base + NAM_PCM_FRONT_DAC_RATE, 48000);
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
            var civ = port_io.inb(self.nabm_base + NABM_PO_CIV);
            const lvi = port_io.inb(self.nabm_base + NABM_PO_LVI);
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
                var sr = port_io.inw(self.nabm_base + NABM_PO_SR);
                while ((sr & SR_DCH) == 0 and self.current_buffer == civ) {
                    // DMA is running and pointing to our buffer. We are full.
                    // Poll until hardware advances or stops.
                    sched.yield();
                    civ = port_io.inb(self.nabm_base + NABM_PO_CIV);
                    sr = port_io.inw(self.nabm_base + NABM_PO_SR);
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
            port_io.outb(self.nabm_base + NABM_PO_LVI, @truncate(self.current_buffer));

            // Ensure DMA is running
            const cr = port_io.inb(self.nabm_base + NABM_PO_CR);
            if ((cr & CR_RPBM) == 0) {
                // Start (Run, no interrupts for polling mode)
                port_io.outb(self.nabm_base + NABM_PO_CR, CR_RPBM);
            }
        }

        return @intCast(written);
    }

    pub fn ioctl(self: *Self, cmd: u32, arg: usize) isize {
        // Handle SNDCTL_DSP_SPEED etc.
        // These ioctls read/write a u32 value at the user-provided address.
        const user_ptr = user_mem.UserPtr.from(arg);

        switch (cmd) {
            sound.SNDCTL_DSP_SPEED => {
                // Read requested rate from user, return actual rate
                const requested = user_ptr.readValue(u32) catch return -14; // EFAULT
                _ = requested; // TODO: Support variable sample rates via VRA
                const actual_rate: u32 = self.sample_rate;
                user_ptr.writeValue(actual_rate) catch return -14;
                return 0;
            },
            sound.SNDCTL_DSP_STEREO => {
                // Read mono/stereo request, return actual channel config
                const requested = user_ptr.readValue(u32) catch return -14;
                _ = requested; // TODO: Support mono playback
                const stereo: u32 = if (self.channels == 2) 1 else 0;
                user_ptr.writeValue(stereo) catch return -14;
                return 0;
            },
            sound.SNDCTL_DSP_SETFMT => {
                // Read requested format, return actual format
                const requested = user_ptr.readValue(u32) catch return -14;
                _ = requested; // TODO: Support format conversion
                user_ptr.writeValue(self.format) catch return -14;
                return 0;
            },
            sound.SNDCTL_DSP_GETOSPACE => {
                // Return available buffer space info
                // ospace struct: fragments, fragstotal, fragsize, bytes
                const civ = port_io.inb(self.nabm_base + NABM_PO_CIV);

                // SECURITY FIX: Validate current_buffer before using in arithmetic.
                // If current_buffer was corrupted (e.g., memory corruption, previous race),
                // wrapping arithmetic could produce values > BDL_ENTRY_COUNT, misleading
                // userspace into thinking more buffer space is available than exists.
                // This could cause applications to write more data than the kernel can
                // handle, potentially overwriting other kernel memory.
                const current_buf = self.current_buffer;
                if (current_buf >= BDL_ENTRY_COUNT) {
                    // Hardware state inconsistent - return EIO to signal error
                    return -5; // EIO
                }

                // Calculate free buffers with modular arithmetic.
                // This gives the number of buffer slots between hardware read (civ)
                // and software write (current_buffer) pointers in the ring buffer.
                const free_buffers = (civ +% BDL_ENTRY_COUNT -% current_buf) % BDL_ENTRY_COUNT;

                // Sanity check: free_buffers must be within valid range
                if (free_buffers > BDL_ENTRY_COUNT) {
                    return -5; // EIO - should not happen with valid inputs
                }

                const info = [4]u32{
                    @intCast(free_buffers), // fragments available (safe: <= 32)
                    BDL_ENTRY_COUNT, // total fragments
                    BUFFER_SIZE, // fragment size
                    @intCast(free_buffers * BUFFER_SIZE), // bytes available (max 32*4096 = 128KB, fits u32)
                };
                const bytes = std.mem.asBytes(&info);
                if (user_mem.copyToUser(arg, bytes) != 0) return -14;
                return 0;
            },
            else => return 0,
        }
    }

    // =========================================================================
    // Async I/O Support
    // =========================================================================

    /// Enable interrupt-driven async mode.
    /// Call this after init to enable IRQ-based buffer completion.
    ///
    /// SECURITY FIX: The HAL registerHandler() API only accepts (vector, handler).
    /// It does NOT support a context pointer. The original code passed a third
    /// argument that would cause compilation failure or undefined behavior.
    /// We use the global ac97_driver variable instead, which is safe because:
    /// 1. Only one AC97 driver instance exists (hardware constraint)
    /// 2. The global is set before enableAsyncMode() is called
    pub fn enableAsyncMode(self: *Self) void {
        if (self.irq_enabled) return;

        // Register IRQ handler using the correct 2-argument HAL API.
        // The handler uses the global ac97_driver since the IDT does not
        // support per-handler context pointers.
        hal.interrupts.registerHandler(
            @as(u8, self.irq_line) + 32, // IRQ offset for PIC/APIC
            ac97IrqHandler,
        );

        // Enable buffer completion interrupts
        const cr = port_io.inb(self.nabm_base + NABM_PO_CR);
        port_io.outb(self.nabm_base + NABM_PO_CR, cr | CR_IOCE);

        self.irq_enabled = true;
        console.info("AC97: Async mode enabled (IRQ {})", .{self.irq_line});
    }

    /// Submit an async audio write request.
    /// Returns immediately. The request will be completed when the buffer
    /// finishes playing (via IRQ) or when space becomes available.
    ///
    /// The caller must have already copied data to request.buf_ptr (kernel buffer)
    /// and set request.buf_len.
    pub fn writeAsync(self: *Self, request: *kernel_io.IoRequest) void {
        const held = self.lock.acquire();
        defer held.release();

        // Check if we can submit immediately (buffers available)
        const civ = port_io.inb(self.nabm_base + NABM_PO_CIV);
        const sr = port_io.inw(self.nabm_base + NABM_PO_SR);
        const dma_halted = (sr & SR_DCH) != 0;
        const buffers_available = dma_halted or (self.current_buffer != civ);

        if (buffers_available) {
            // Submit immediately
            self.submitBuffer(request);
        } else {
            // Queue for later submission when IRQ fires
            self.enqueueRequest(request);
        }
    }

    /// Internal: Submit a buffer to DMA.
    ///
    /// SECURITY: Only accepts data from validated bounce buffers. Raw buf_ptr values
    /// are rejected to prevent arbitrary kernel memory reads. An attacker who can
    /// control an IoRequest with a crafted buf_ptr could read sensitive kernel data
    /// (page tables, credentials) into the DMA buffer.
    fn submitBuffer(self: *Self, request: *kernel_io.IoRequest) void {
        const frame_size: usize = 4; // stereo 16-bit = 4 bytes
        const buf_idx = self.current_buffer;

        // Copy data to DMA buffer (max BUFFER_SIZE per submission)
        const chunk_size = @min(BUFFER_SIZE, request.buf_len);
        const buf = self.buffers[buf_idx];

        if (request.bounce_buf) |bounce| {
            // SAFE: Data is in kernel-allocated bounce buffer that was validated
            // when the IoRequest was created. The io_uring layer copies user data
            // into this bounce buffer after validation.
            @memcpy(buf[0..chunk_size], bounce[0..chunk_size]);
        } else {
            // SECURITY FIX: Reject requests without bounce buffers.
            // Raw buf_ptr could point to arbitrary kernel memory. We cannot
            // safely validate all possible kernel addresses, so we require
            // the caller to use bounce buffers for async audio writes.
            // This prevents information disclosure via DMA buffer contents.
            _ = request.complete(.{ .err = error.EFAULT });
            return;
        }

        // Update BDL entry
        const samples = chunk_size / frame_size;
        self.bdl[buf_idx].len = @truncate(samples);

        // Track this request for IRQ completion
        self.pending_requests[buf_idx] = request;
        _ = request.compareAndSwapState(.pending, .in_progress);

        // Advance software pointer
        self.current_buffer = (self.current_buffer + 1) % BDL_ENTRY_COUNT;

        // Update LVI
        port_io.outb(self.nabm_base + NABM_PO_LVI, @truncate(self.current_buffer));

        // Ensure DMA is running
        const cr = port_io.inb(self.nabm_base + NABM_PO_CR);
        if ((cr & CR_RPBM) == 0) {
            port_io.outb(self.nabm_base + NABM_PO_CR, cr | CR_RPBM | CR_IOCE);
        }
    }

    /// Internal: Add request to pending queue.
    fn enqueueRequest(self: *Self, request: *kernel_io.IoRequest) void {
        request.next = null;
        if (self.pending_queue_tail) |tail| {
            tail.next = request;
            self.pending_queue_tail = request;
        } else {
            self.pending_queue_head = request;
            self.pending_queue_tail = request;
        }
    }

    /// Internal: Remove and return head of pending queue.
    fn dequeueRequest(self: *Self) ?*kernel_io.IoRequest {
        const head = self.pending_queue_head orelse return null;
        self.pending_queue_head = head.next;
        if (self.pending_queue_head == null) {
            self.pending_queue_tail = null;
        }
        head.next = null;
        return head;
    }

    /// Handle buffer completion interrupt.
    /// Called from IRQ context.
    ///
    /// SECURITY: Must hold spinlock to prevent race conditions with writeAsync().
    /// The IRQ handler and process context both modify pending_requests, current_buffer,
    /// and the pending queue. Without locking, concurrent access can cause:
    /// - Double-completion of requests (use-after-free on IoRequest)
    /// - Corrupted queue pointers leading to lost requests
    /// - Buffer index corruption causing DMA to incorrect memory
    pub fn handleInterrupt(self: *Self) void {
        // SECURITY FIX: Acquire lock to prevent race with writeAsync() in process context.
        // Spinlock.acquire() disables interrupts, which is safe here since we're already
        // in IRQ context (interrupts disabled). This serializes access to shared state.
        const held = self.lock.acquire();
        defer held.release();

        // Read status register
        const sr = port_io.inw(self.nabm_base + NABM_PO_SR);

        // Check for buffer completion interrupt
        if ((sr & SR_BCIS) != 0) {
            // Clear the interrupt by writing 1 to BCIS
            port_io.outw(self.nabm_base + NABM_PO_SR, SR_BCIS);

            // Find which buffer(s) completed
            const civ = port_io.inb(self.nabm_base + NABM_PO_CIV);

            // Complete any requests for buffers that have been consumed
            // Buffers from the last completed index up to (but not including) CIV
            // have finished playing.
            for (self.pending_requests, 0..) |maybe_req, i| {
                if (maybe_req) |request| {
                    // This buffer slot had a pending request
                    // Check if hardware has moved past it
                    // Simple heuristic: if i != civ and request was in_progress
                    if (i != civ and request.getState() == .in_progress) {
                        self.pending_requests[i] = null;
                        _ = request.complete(.{ .success = request.buf_len });
                    }
                }
            }

            // Submit queued requests if space available
            while (self.dequeueRequest()) |queued| {
                const new_civ = port_io.inb(self.nabm_base + NABM_PO_CIV);
                if (self.current_buffer == new_civ) {
                    // Still full, put it back at HEAD (not tail) so it's processed first.
                    //
                    // SECURITY FIX: Ensure queue invariant is maintained when re-enqueueing.
                    // The invariant: (head == null) == (tail == null). If this is violated,
                    // we have queue corruption that could cause lost requests or infinite loops.
                    //
                    // Re-enqueue at head: queued becomes new head, points to old head.
                    // If queue was empty, queued is also the new tail.
                    // If queue was non-empty, tail stays unchanged.
                    queued.next = self.pending_queue_head;
                    self.pending_queue_head = queued;

                    // Maintain invariant: if queue was empty (head was null before we set it),
                    // then tail must also be set. The old head being null means tail should be null too.
                    if (queued.next == null) {
                        // Queue was empty, so queued is both head and tail
                        self.pending_queue_tail = queued;
                    }
                    // If queued.next != null, queue was non-empty and tail already points
                    // to the last element, so we leave it unchanged.

                    break;
                }
                self.submitBuffer(queued);
            }
        }

        // Handle Last Valid Buffer Completion
        if ((sr & SR_LVBCI) != 0) {
            port_io.outw(self.nabm_base + NABM_PO_SR, SR_LVBCI);
            // All submitted buffers played - could signal underrun if queue empty
        }

        // Handle FIFO error
        if ((sr & SR_FIFO) != 0) {
            port_io.outw(self.nabm_base + NABM_PO_SR, SR_FIFO);
            console.warn("AC97: FIFO error", .{});
        }
    }
};

// Global Instance
var ac97_driver: ?*Ac97 = null;

const idt = hal.idt;

/// IRQ Handler for AC97 buffer completion interrupts.
///
/// SECURITY FIX: Uses correct HAL InterruptHandler signature (*InterruptFrame -> void).
/// The original code expected a context pointer which the IDT dispatch does not provide.
/// We use the global ac97_driver instead, which is safe for a singleton hardware driver.
/// The InterruptFrame is unused but required by the HAL API contract.
fn ac97IrqHandler(frame: *idt.InterruptFrame) void {
    _ = frame; // Frame unused; we only care about the hardware status registers
    if (ac97_driver) |driver| {
        driver.handleInterrupt();
    }
    // If no driver, silently ignore (should not happen in normal operation)
}

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
    .poll = null,
};

pub fn initFromPci(pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) !void {
    ac97_driver = try Ac97.init(pci_dev, pci_access);
    // Enable async mode for io_uring support
    if (ac97_driver) |drv| {
        drv.enableAsyncMode();
    }
}

/// Get the global AC97 driver instance.
/// Returns null if no AC97 device was found or initialized.
pub fn getDriver() ?*Ac97 {
    return ac97_driver;
}

/// Submit an async audio write via io_uring.
/// This is the entry point for IORING_OP_WRITE on audio file descriptors.
///
/// The request should have:
/// - buf_ptr/buf_len pointing to kernel bounce buffer with audio data
/// - op set to .audio_write
/// - user_data set for CQE identification
///
/// Returns true if the request was accepted, false if no driver available.
pub fn submitAsyncWrite(request: *kernel_io.IoRequest) bool {
    const driver = ac97_driver orelse return false;
    driver.writeAsync(request);
    return true;
}

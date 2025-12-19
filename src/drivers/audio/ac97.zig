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

// AC97 Extended Audio ID/Ctrl Bits
const EAI_VRA: u16 = 1 << 0;
const EAC_VRA: u16 = 1 << 0;

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
    vra_supported: bool,

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
            .vra_supported = false,
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

        // Detect and Enable VRA (Variable Rate Audio)
        const ext_id = port_io.inw(self.nam_base + NAM_EXT_AUDIO_ID);
        if ((ext_id & EAI_VRA) != 0) {
            // VRA supported, enable it
            const ext_ctrl = port_io.inw(self.nam_base + NAM_EXT_AUDIO_CTRL);
            port_io.outw(self.nam_base + NAM_EXT_AUDIO_CTRL, ext_ctrl | EAC_VRA);
            self.vra_supported = true;
            console.info("AC97: VRA enabled", .{});
        }

        // Set sample rate (try 48kHz default)
        port_io.outw(self.nam_base + NAM_PCM_FRONT_DAC_RATE, 48000);
        // Verify what we got
        const actual = port_io.inw(self.nam_base + NAM_PCM_FRONT_DAC_RATE);
        self.sample_rate = actual;
    }


    /// Process audio data from user format to hardware format (S16_LE Stereo).
    /// Returns number of bytes consumed from src and written to dst.
    fn processAudio(self: *Self, dst: []u8, src: []const u8) struct { consumed: usize, written: usize } {
        var s_off: usize = 0;
        var d_off: usize = 0;
        
        // Limits
        const s_max = src.len;
        const d_max = dst.len;

        // Optimization: 1:1 Copy (Stereo S16LE -> Stereo S16LE)
        if (self.channels == 2 and self.format == sound.AFMT_S16_LE) {
            const copy_len = @min(s_max, d_max);
            // Must align to frame size (4 bytes)
            const aligned_len = copy_len & ~@as(usize, 3);
            @memcpy(dst[0..aligned_len], src[0..aligned_len]);
            return .{ .consumed = aligned_len, .written = aligned_len };
        }

        while (s_off < s_max and d_off < d_max) {
            // Determine input frame size
            const bytes_per_sample: usize = if (self.format == sound.AFMT_U8) 1 else 2;
            const input_frame_size = bytes_per_sample * self.channels;

            // Check if we have a full frame in src
            if (s_off + input_frame_size > s_max) break;
            // Check if we have space for stereo S16 frame (4 bytes) in dst
            if (d_off + 4 > d_max) break;
            
            // Read L/R samples, normalized to i16
            var left: i16 = 0;
            var right: i16 = 0;
            
            if (self.format == sound.AFMT_U8) {
                 // U8 is unsigned 0..255, bias 128. 
                 // Conversion to i16: (u8 - 128) * 256
                 const l_val: i16 = @as(i16, src[s_off]) - 128;
                 left = l_val * 256;
                 
                 if (self.channels == 2) {
                     const r_val: i16 = @as(i16, src[s_off+1]) - 128;
                     right = r_val * 256;
                 } else {
                     right = left;
                 }
            } else {
                 // S16_LE
                 const l_low = src[s_off];
                 const l_high = src[s_off+1];
                 left = @as(i16, @bitCast(@as(u16, l_low) | (@as(u16, l_high) << 8)));
                 
                 if (self.channels == 2) {
                     const r_low = src[s_off+2];
                     const r_high = src[s_off+3];
                     right = @as(i16, @bitCast(@as(u16, r_low) | (@as(u16, r_high) << 8)));
                 } else {
                     right = left;
                 }
            }
            
            // Write to DST (S16_LE Stereo)
            const u_l = @as(u16, @bitCast(left));
            dst[d_off] = @truncate(u_l);
            dst[d_off+1] = @truncate(u_l >> 8);
            
            const u_r = @as(u16, @bitCast(right));
            dst[d_off+2] = @truncate(u_r);
            dst[d_off+3] = @truncate(u_r >> 8);
            
            s_off += input_frame_size;
            d_off += 4;
        }
        return .{ .consumed = s_off, .written = d_off };
    }

    // DevFS Operations

    pub fn write(self: *Self, data: []const u8) isize {
        // We need to copy data to buffers and update LVI.
        // If all buffers are full, wait.

        // Hardware is always Stereo 16-bit = 4 bytes/frame
        const hw_frame_size: usize = 4;

        var written: usize = 0;

        while (written < data.len) {
            // Find current hardware position
            var civ = port_io.inb(self.nabm_base + NABM_PO_CIV);
            const lvi = port_io.inb(self.nabm_base + NABM_PO_LVI);
            _ = lvi; // Used for debugging

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
            }

            // Fill the current buffer with as much compatible data as possible
            // Destination: full 4KB buffer
            // Source: remaining user data
            
            const dst_slice = self.buffers[self.current_buffer][0..BUFFER_SIZE];
            const src_slice = data[written..];
            
            const res = self.processAudio(dst_slice, src_slice);
            
            // If we consumed nothing but had input, we might be stuck (frame alignment issue?)
            if (res.consumed == 0 and src_slice.len > 0) {
                 // Should not happen if inputs are aligned. 
                 // If unaligned data at end, we just drop/ignore or break.
                 break;
            }

            // Update BDL entry
            // Length is in samples (stereo sample = 1 frame? No, AC97 BDL len is samples per channel or total samples?)
            // "Number of samples to be played"
            // AC97 spec: "The number of samples to be fetched... For 16-bit stereo, this is the number of sample pairs."
            // NOTE: QEMU/RealHW usually treats this as "number of samples per channel"?
            // Or total samples?
            // "If the stream is stereo, 16-bit, then each sample is 4 bytes. If B.L. = 20, then 20 sample pairs (80 bytes) are fetched."
            // So: Length = bytes / 4.
            const samples = res.written / hw_frame_size;
            self.bdl[self.current_buffer].len = @truncate(samples);

            written += res.consumed;

            // Advance software pointer
            const next_buffer = (self.current_buffer + 1) % BDL_ENTRY_COUNT;
            self.current_buffer = next_buffer;

            // Update LVI 
            port_io.outb(self.nabm_base + NABM_PO_LVI, @truncate(self.current_buffer));

            // Ensure DMA is running
            const cr = port_io.inb(self.nabm_base + NABM_PO_CR);
            if ((cr & CR_RPBM) == 0) {
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
                // Read requested rate from user
                const requested = user_ptr.readValue(u32) catch return -14; // EFAULT
                
                if (self.vra_supported) {
                    // Clamp to AC97 safe range (usually 8000-48000)
                    var rate = requested;
                    if (rate < 8000) rate = 8000;
                    if (rate > 48000) rate = 48000;
                    
                    port_io.outw(self.nam_base + NAM_PCM_FRONT_DAC_RATE, @truncate(rate));
                    // Read back what the hardware actually accepted
                    rate = port_io.inw(self.nam_base + NAM_PCM_FRONT_DAC_RATE);
                    self.sample_rate = rate;
                }
                
                user_ptr.writeValue(self.sample_rate) catch return -14;
                return 0;
            },
            sound.SNDCTL_DSP_STEREO => {
                // Read mono/stereo request, return actual channel config
                const requested = user_ptr.readValue(u32) catch return -14;
                
                // Allow 1 (Mono) or 2 (Stereo). Treat 0 as Stereo query?
                // DOOM passes 0 for mono? No, 0 usually means false (mono), 1 true (stereo) in some APIs.
                // Linux ioctl: argument is "0=mono, 1=stereo" ?
                // OSS Spec: "Argument is 0 (mono) or 1 (stereo). The driver returns the actual mode."
                // Wait, some docs say argument is *channels* (1 or 2).
                // Let's assume argument is 0/1 boolean for stereo-ness for SNDCTL_DSP_STEREO.
                // For SNDCTL_DSP_CHANNELS, argument is number of channels.
                
                // Let's support both interpretations.
                // If val > 1, treat as channel count?
                // Standard says SNDCTL_DSP_STEREO takes 0 or 1.
                
                var new_channels: u32 = 2;
                if (requested == 0) {
                    new_channels = 1;
                } else {
                    new_channels = 2;
                }
                self.channels = new_channels;
                
                // Return 1 if stereo (channels==2), 0 if mono
                const result: u32 = if (self.channels == 2) 1 else 0;
                user_ptr.writeValue(result) catch return -14;
                return 0;
            },
            sound.SNDCTL_DSP_CHANNELS => {
                 const requested = user_ptr.readValue(u32) catch return -14;
                 if (requested == 1) self.channels = 1;
                 if (requested == 2) self.channels = 2;
                 user_ptr.writeValue(self.channels) catch return -14;
                 return 0;
            },
            sound.SNDCTL_DSP_SETFMT => {
                // Read requested format, return actual format
                const requested = user_ptr.readValue(u32) catch return -14;
                
                // Check if we support it
                if (requested == sound.AFMT_U8) {
                    self.format = sound.AFMT_U8;
                } else if (requested == sound.AFMT_S16_LE) {
                    self.format = sound.AFMT_S16_LE;
                }
                // default keep existing if unsupported
                
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

        // Copy data to DMA buffer with format conversion
        const buf = self.buffers[buf_idx];

        var src_consumed: usize = 0;
        var dst_written: usize = 0;

        if (request.bounce_buf) |bounce| {
            // SAFE: Data is in kernel-allocated bounce buffer that was validated
            const res = self.processAudio(buf[0..BUFFER_SIZE], bounce[0..request.buf_len]);
            src_consumed = res.consumed;
            dst_written = res.written;
        } else {
            // SECURITY FIX: Reject requests without bounce buffers.
            _ = request.complete(.{ .err = error.EFAULT });
            return;
        }

        // Update BDL entry
        const samples = dst_written / frame_size;
        self.bdl[buf_idx].len = @truncate(samples);

        // Track this request for IRQ completion
        self.pending_requests[buf_idx] = request;
        _ = request.compareAndSwapState(.pending, .in_progress);
        
        // NOTE: We only consumed src_consumed bytes.
        // If Request was larger, we rely on the caller to handle short writes?
        // But IoRequest infrastructure doesn't easily support "partial completion then continue".
        // We act like a short write system call: we completed X bytes.
        // We store the partial amount in the request result?
        // Actually, we complete it LATER in IRQ.
        // But we need to say HOW MUCH was written.
        // We can squirrel that away in the request or just assume we'll report src_consumed.
        // However, standard IoRequest completion just says "success".
        // The `result` field is u64. We can store bytes there.
        // When IRQ fires, we do: `request.complete(.{ .success = THE_BYTES })`.
        // But IRQ handler doesn't know src_consumed unless we store it.
        // A hack: Store src_consumed in `request.result` NOW (while in progress),
        // and read it back in IRQ.
        request.result = .{ .success = src_consumed }; 

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
                        // Retrieve the bytes-consumed we stored earlier
                        const written = switch (request.result) {
                            .success => |val| val,
                            else => 0,
                        };
                        _ = request.complete(.{ .success = written });
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

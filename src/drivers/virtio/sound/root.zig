// VirtIO-Sound Driver
//
// Provides audio playback and capture via the VirtIO Sound protocol.
// Implements OSS-compatible /dev/dsp interface for legacy applications.
//
// Usage:
//   const virtio_sound = @import("virtio_sound");
//   var driver = try virtio_sound.initFromPci(pci_dev, pci_access);
//   driver.write(audio_data);
//
// Reference: VirtIO Specification 1.2, Section 5.14

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const pci = @import("pci");
const vmm = @import("vmm");
const pmm = @import("pmm");
const heap = @import("heap");
const sync_mod = @import("sync");
const virtio = @import("virtio");
const devfs = @import("devfs");

pub const config = @import("config.zig");
pub const request = @import("request.zig");
pub const queue = @import("queue.zig");
pub const pcm = @import("pcm.zig");
pub const irq = @import("irq.zig");
pub const dsp = @import("dsp.zig");

// =============================================================================
// Error Types
// =============================================================================

pub const SoundError = error{
    NotVirtioSound,
    InvalidBar,
    MappingFailed,
    CapabilityNotFound,
    ResetFailed,
    FeatureNegotiationFailed,
    QueueAllocationFailed,
    AllocationFailed,
    CommandTimeout,
    CommandFailed,
    InvalidParameter,
    StreamNotFound,
    InvalidFormat,
    InvalidRate,
    DeviceBusy,
    BufferFull,
    NotInitialized,
};

// =============================================================================
// Driver State
// =============================================================================

/// VirtIO-Sound Driver
pub const VirtioSoundDriver = struct {
    /// VirtIO common configuration MMIO
    common_cfg: *volatile virtio.VirtioPciCommonCfg,

    /// Notify register base address
    notify_base: u64,

    /// Notify offset multiplier
    notify_off_mult: u32,

    /// ISR register address
    isr_addr: u64,

    /// Device-specific configuration
    device_cfg: *volatile config.VirtioSoundConfig,

    /// Queue set (control, event, TX, RX)
    queues: queue.SoundQueueSet,

    /// PCM stream manager
    streams: pcm.StreamManager,

    /// Device configuration (cached)
    sound_config: config.VirtioSoundConfig,

    /// Negotiated features
    features: u64,

    /// PCI device reference
    pci_dev: *const pci.PciDevice,

    /// MSI-X vectors
    msix_vectors: [8]?u8,

    /// Whether driver is initialized
    initialized: bool,

    /// OSS compatibility state
    oss_format: u32,
    oss_channels: u32,
    oss_sample_rate: u32,

    /// DMA buffer pool for audio transfers
    buffer_pool_phys: u64,
    buffer_pool_virt: [*]u8,
    buffer_pool_size: usize,

    /// Transfer header/status buffers (DMA)
    xfer_hdr_phys: u64,
    xfer_hdr_virt: *request.PcmXferHdr,
    xfer_status_phys: u64,
    xfer_status_virt: *volatile request.PcmXferStatus,

    /// Control request/response buffers (DMA)
    ctl_req_phys: u64,
    ctl_req_virt: [*]u8,
    ctl_resp_phys: u64,
    ctl_resp_virt: [*]u8,

    /// Lock for driver access
    lock: sync_mod.Spinlock,

    const Self = @This();

    // =========================================================================
    // Initialization
    // =========================================================================

    /// Initialize driver from PCI device
    pub fn init(self: *Self, pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) SoundError!void {
        self.pci_dev = pci_dev;
        self.initialized = false;
        self.features = 0;
        self.lock = .{};

        // Initialize arrays
        for (&self.msix_vectors) |*v| v.* = null;
        self.queues = queue.SoundQueueSet.init();
        self.streams = pcm.StreamManager.init();

        // OSS defaults
        self.oss_format = @import("uapi").sound.AFMT_S16_LE;
        self.oss_channels = 2;
        self.oss_sample_rate = 48000;

        // Verify VirtIO-Sound device
        if (!isVirtioSound(pci_dev)) {
            return error.NotVirtioSound;
        }

        // Get ECAM access
        const ecam = switch (pci_access) {
            .ecam => |e| e,
            .legacy => {
                console.err("VirtIO-Sound: Legacy PCI access not supported", .{});
                return error.InvalidBar;
            },
        };

        // Enable bus mastering and memory space
        ecam.enableBusMaster(pci_dev.bus, pci_dev.device, pci_dev.func);
        ecam.enableMemorySpace(pci_dev.bus, pci_dev.device, pci_dev.func);

        // Parse VirtIO capabilities and map MMIO regions
        try self.parseCapabilities(pci_dev, ecam);

        // Allocate DMA buffers
        try self.allocateDmaBuffers();

        // Initialize device per VirtIO spec
        try self.initializeDevice();

        // Query PCM stream info
        self.queryStreams() catch |err| {
            console.warn("VirtIO-Sound: Stream query failed: {}", .{err});
        };

        self.initialized = true;
        console.info("VirtIO-Sound: Driver initialized, {} streams", .{self.streams.stream_count});
    }

    /// Allocate DMA buffers for transfers
    /// SECURITY NOTE: All DMA buffers are allocated with pmm.allocZeroedPages which
    /// zero-initializes memory, preventing kernel memory leaks to device. Response
    /// buffers are re-zeroed before each operation in queryStreams/sendPcmControl/etc.
    fn allocateDmaBuffers(self: *Self) SoundError!void {
        // Allocate buffer pool (16KB for audio data)
        const pool_pages = 4;
        const pool_phys = pmm.allocZeroedPages(pool_pages) orelse return error.AllocationFailed;
        self.buffer_pool_phys = pool_phys;
        self.buffer_pool_virt = @ptrCast(hal.paging.physToVirt(pool_phys));
        self.buffer_pool_size = pool_pages * 4096;

        // Allocate control buffers (1 page for request/response)
        const ctl_phys = pmm.allocZeroedPages(1) orelse {
            pmm.freePages(pool_phys, pool_pages);
            return error.AllocationFailed;
        };
        const ctl_virt = hal.paging.physToVirt(ctl_phys);
        self.ctl_req_phys = ctl_phys;
        self.ctl_req_virt = @ptrCast(ctl_virt);
        self.ctl_resp_phys = ctl_phys + 2048;
        self.ctl_resp_virt = @ptrCast(@as([*]u8, @ptrCast(ctl_virt)) + 2048);

        // Allocate transfer header/status (within control page)
        self.xfer_hdr_phys = ctl_phys + 3072;
        self.xfer_hdr_virt = @ptrFromInt(@intFromPtr(ctl_virt) + 3072);
        self.xfer_status_phys = ctl_phys + 3080;
        self.xfer_status_virt = @ptrFromInt(@intFromPtr(ctl_virt) + 3080);
    }

    /// Parse VirtIO PCI capabilities and map MMIO regions
    fn parseCapabilities(self: *Self, pci_dev: *const pci.PciDevice, ecam: pci.Ecam) SoundError!void {
        const status = ecam.read16(pci_dev.bus, pci_dev.device, pci_dev.func, 0x06);
        if ((status & 0x10) == 0) {
            return SoundError.CapabilityNotFound;
        }

        var cap_ptr = ecam.read8(pci_dev.bus, pci_dev.device, pci_dev.func, 0x34);
        cap_ptr &= 0xFC;

        var common_found = false;
        var notify_found = false;
        var device_found = false;

        // BAR mapping cache
        var bar_mapped: [6]bool = .{ false, false, false, false, false, false };
        var bar_virt: [6]u64 = .{ 0, 0, 0, 0, 0, 0 };

        while (cap_ptr != 0) {
            const cap_id = ecam.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr);
            const next_ptr = ecam.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 1);

            if (cap_id == 0x09) { // VirtIO vendor-specific capability
                const cfg_type = ecam.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 3);
                const bar_idx = ecam.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 4);
                const offset = ecam.read32(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 8);
                const cap_length = ecam.read32(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 12);

                if (bar_idx > 5) {
                    cap_ptr = next_ptr;
                    continue;
                }
                const bar_index: u3 = @truncate(bar_idx);

                // Map BAR if not already mapped
                if (!bar_mapped[bar_index]) {
                    const bar_val = ecam.readBar(pci_dev.bus, pci_dev.device, pci_dev.func, bar_index);
                    if (bar_val == 0) {
                        cap_ptr = next_ptr;
                        continue;
                    }

                    const bar_phys = bar_val & 0xFFFFFFF0;
                    const bar = pci_dev.bar[bar_index];
                    const bar_size = bar.size;

                    if (bar_size == 0) {
                        cap_ptr = next_ptr;
                        continue;
                    }

                    // Map BAR to virtual memory
                    const pages = @as(u64, (bar_size + 4095) / 4096);
                    const virt = vmm.mapMmioExplicit(bar_phys, pages) catch {
                        cap_ptr = next_ptr;
                        continue;
                    };

                    bar_virt[bar_index] = virt;
                    bar_mapped[bar_index] = true;
                }

                const base_virt = bar_virt[bar_index];
                if (base_virt == 0) {
                    cap_ptr = next_ptr;
                    continue;
                }

                // SECURITY: Validate offset + length stays within mapped BAR region
                // Prevents device-controlled arbitrary memory access
                const bar_size = pci_dev.bar[bar_index].size;
                const end_offset = std.math.add(u32, offset, cap_length) catch {
                    cap_ptr = next_ptr;
                    continue;
                };
                if (end_offset > bar_size) {
                    console.warn("VirtIO-Sound: Capability offset 0x{x}+0x{x} exceeds BAR size 0x{x}", .{ offset, cap_length, bar_size });
                    cap_ptr = next_ptr;
                    continue;
                }

                // Process capability type
                switch (cfg_type) {
                    1 => { // VIRTIO_PCI_CAP_COMMON_CFG
                        self.common_cfg = @ptrFromInt(base_virt + offset);
                        common_found = true;
                    },
                    2 => { // VIRTIO_PCI_CAP_NOTIFY_CFG
                        self.notify_base = base_virt + offset;
                        self.notify_off_mult = ecam.read32(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 16);
                        notify_found = true;
                    },
                    3 => { // VIRTIO_PCI_CAP_ISR_CFG
                        self.isr_addr = base_virt + offset;
                    },
                    4 => { // VIRTIO_PCI_CAP_DEVICE_CFG
                        self.device_cfg = @ptrFromInt(base_virt + offset);
                        device_found = true;
                    },
                    else => {},
                }
            }

            cap_ptr = next_ptr;
        }

        if (!common_found or !notify_found or !device_found) {
            return SoundError.CapabilityNotFound;
        }
    }

    /// Initialize device following VirtIO spec 3.1.1
    fn initializeDevice(self: *Self) SoundError!void {
        // Step 1: Reset device
        self.common_cfg.device_status = 0;
        hal.mmio.memoryBarrier();

        // Poll until reset completes
        // SECURITY NOTE: Loop is bounded (100,000 * 1us = 100ms max). Returns error
        // on timeout, preventing infinite loop DoS from malicious device.
        var timeout: u32 = 100000;
        while (self.common_cfg.device_status != 0 and timeout > 0) : (timeout -= 1) {
            hal.timing.delayUs(1);
        }
        if (timeout == 0) return error.ResetFailed;

        // Step 2: Set ACKNOWLEDGE
        self.common_cfg.device_status = 1;
        hal.mmio.memoryBarrier();

        // Step 3: Set DRIVER
        self.common_cfg.device_status = 1 | 2;
        hal.mmio.memoryBarrier();

        // Step 4: Read and negotiate features
        try self.negotiateFeatures();

        // Step 5: Set FEATURES_OK
        self.common_cfg.device_status = 1 | 2 | 8;
        hal.mmio.memoryBarrier();

        // Verify FEATURES_OK stuck
        if ((self.common_cfg.device_status & 8) == 0) {
            self.common_cfg.device_status = 0x80; // FAILED
            return error.FeatureNegotiationFailed;
        }

        // Step 6: Cache device configuration
        self.sound_config = config.VirtioSoundConfig{
            .jacks = self.device_cfg.jacks,
            .streams = self.device_cfg.streams,
            .chmaps = self.device_cfg.chmaps,
        };

        // Step 7: Setup virtqueues
        try self.setupVirtqueues();

        // Step 8: Set DRIVER_OK
        self.common_cfg.device_status = 1 | 2 | 4 | 8;
        hal.mmio.memoryBarrier();
    }

    /// Negotiate VirtIO features
    fn negotiateFeatures(self: *Self) SoundError!void {
        // Read device features (low 32 bits)
        self.common_cfg.device_feature_select = 0;
        hal.mmio.memoryBarrier();
        const features_lo = self.common_cfg.device_feature;

        // Read device features (high 32 bits)
        self.common_cfg.device_feature_select = 1;
        hal.mmio.memoryBarrier();
        const features_hi = self.common_cfg.device_feature;

        // Check for VIRTIO_F_VERSION_1 (bit 32)
        if ((features_hi & 1) == 0) {
            console.err("VirtIO-Sound: VIRTIO_F_VERSION_1 not supported", .{});
            return error.FeatureNegotiationFailed;
        }

        // Accept VERSION_1
        self.common_cfg.driver_feature_select = 1;
        hal.mmio.memoryBarrier();
        self.common_cfg.driver_feature = 1; // VERSION_1

        // Accept any device-specific features we support
        self.common_cfg.driver_feature_select = 0;
        hal.mmio.memoryBarrier();
        self.common_cfg.driver_feature = 0; // No special features needed

        self.features = (@as(u64, features_hi) << 32) | features_lo;
    }

    /// Setup virtqueues
    fn setupVirtqueues(self: *Self) SoundError!void {
        // Setup control queue
        self.queues.control = self.setupQueue(.control, config.QueueIndex.CONTROL) orelse
            return error.QueueAllocationFailed;

        // Setup event queue (optional)
        self.queues.event = self.setupQueue(.event, config.QueueIndex.EVENT);

        // Setup TX queue (playback)
        self.queues.tx_queues[0] = self.setupQueue(.tx, config.QueueIndex.TX_BASE) orelse
            return error.QueueAllocationFailed;
        self.queues.tx_queue_count = 1;

        // Setup RX queue (capture) - optional
        self.queues.rx_queues[0] = self.setupQueue(.rx, config.QueueIndex.RX_BASE);
        if (self.queues.rx_queues[0] != null) {
            self.queues.rx_queue_count = 1;
        }
    }

    /// Setup a single queue
    fn setupQueue(self: *Self, queue_type: queue.QueueType, queue_idx: u16) ?queue.SoundQueue {
        // Select queue
        self.common_cfg.queue_select = queue_idx;
        hal.mmio.memoryBarrier();

        // Get queue size
        const queue_size = self.common_cfg.queue_size;
        if (queue_size == 0) return null;

        // Cap queue size
        const actual_size = @min(queue_size, config.Limits.DEFAULT_QUEUE_SIZE);
        self.common_cfg.queue_size = actual_size;

        // Initialize queue
        var q = queue.SoundQueue.init(queue_type, queue_idx, actual_size) orelse return null;

        // Get physical addresses
        const addrs = q.getPhysAddrs();

        // Configure device
        self.common_cfg.queue_desc = addrs.desc;
        self.common_cfg.queue_avail = addrs.avail;
        self.common_cfg.queue_used = addrs.used;
        hal.mmio.memoryBarrier();

        // Get notify offset and set notify address
        const notify_off = self.common_cfg.queue_notify_off;
        q.setNotifyAddr(self.notify_base, self.notify_off_mult, notify_off);

        // Enable queue
        self.common_cfg.queue_enable = 1;
        hal.mmio.memoryBarrier();

        return q;
    }

    /// Query PCM stream information
    fn queryStreams(self: *Self) SoundError!void {
        const num_streams = self.sound_config.streams;
        if (num_streams == 0) return;

        // Query streams one at a time
        var i: u32 = 0;
        while (i < num_streams and i < config.Limits.MAX_STREAMS) : (i += 1) {
            // Build PCM_INFO request
            const req_ptr: *request.PcmInfoRequest = @ptrCast(@alignCast(self.ctl_req_virt));
            req_ptr.* = .{
                .hdr = .{ .code = config.ControlCode.PCM_INFO },
                .start_id = i,
                .count = 1,
            };

            // Zero response area
            @memset(self.ctl_resp_virt[0..64], 0);

            // Submit to control queue
            const control_q = &self.queues.control.?;

            const out_bufs = &[_][]const u8{
                @as([*]const u8, @ptrCast(req_ptr))[0..@sizeOf(request.PcmInfoRequest)],
            };
            const in_bufs = &[_][]u8{
                self.ctl_resp_virt[0..36], // status + PcmInfo
            };

            _ = control_q.submitAndKick(out_bufs, in_bufs) orelse continue;

            // Poll for completion
            var timeout: u32 = 100000;
            while (!control_q.hasPending() and timeout > 0) : (timeout -= 1) {
                hal.timing.delayUs(1);
            }

            if (timeout == 0) continue;

            // Get result - validate device returned sufficient data
            const used = control_q.getUsed() orelse continue;
            // Response must contain at least CtlStatus (4 bytes) + PcmInfo (32 bytes)
            if (used.len < @sizeOf(request.CtlStatus) + @sizeOf(request.PcmInfo)) continue;

            // Parse response
            const status_ptr: *const request.CtlStatus = @ptrCast(@alignCast(self.ctl_resp_virt));
            if (!status_ptr.isOk()) continue;

            const info_ptr: *const request.PcmInfo = @ptrCast(@alignCast(self.ctl_resp_virt + 4));
            _ = self.streams.addStream(i, info_ptr);
        }
    }

    // =========================================================================
    // PCM Operations
    // =========================================================================

    /// Prepare a stream for playback/capture
    /// SECURITY: Holds lock to prevent TOCTOU race on stream state
    pub fn pcmPrepare(self: *Self, stream_id: u32) SoundError!void {
        if (!self.initialized) return error.NotInitialized;

        const held = self.lock.acquire();
        defer held.release();

        const stream = self.streams.getStream(stream_id) orelse return error.StreamNotFound;

        // Allocate buffer if needed
        if (!stream.allocateBuffer()) return error.AllocationFailed;

        // Send PCM_PREPARE
        try self.sendPcmControl(config.ControlCode.PCM_PREPARE, stream_id);
        stream.state = .prepared;
    }

    /// Start a stream
    /// SECURITY: Holds lock to prevent TOCTOU race on stream state
    pub fn pcmStart(self: *Self, stream_id: u32) SoundError!void {
        if (!self.initialized) return error.NotInitialized;

        const held = self.lock.acquire();
        defer held.release();

        const stream = self.streams.getStream(stream_id) orelse return error.StreamNotFound;

        try self.sendPcmControl(config.ControlCode.PCM_START, stream_id);
        stream.state = .running;
    }

    /// Stop a stream
    /// SECURITY: Holds lock to prevent TOCTOU race on stream state
    pub fn pcmStop(self: *Self, stream_id: u32) SoundError!void {
        if (!self.initialized) return error.NotInitialized;

        const held = self.lock.acquire();
        defer held.release();

        const stream = self.streams.getStream(stream_id) orelse return error.StreamNotFound;

        try self.sendPcmControl(config.ControlCode.PCM_STOP, stream_id);
        stream.state = .stopped;
    }

    /// Set stream parameters
    pub fn pcmSetParams(self: *Self, stream_id: u32, channels: u8, format: u64, rate: u64, buffer_bytes: u32, period_bytes: u32) SoundError!void {
        if (!self.initialized) return error.NotInitialized;

        const stream = self.streams.getStream(stream_id) orelse return error.StreamNotFound;

        // Validate parameters
        if (!stream.supportsFormat(format)) return error.InvalidFormat;
        if (!stream.supportsRate(rate)) return error.InvalidRate;
        if (!stream.supportsChannels(channels)) return error.InvalidParameter;

        // Build and send PCM_SET_PARAMS
        const params = request.PcmSetParams.init(stream_id, channels, format, rate, buffer_bytes, period_bytes) orelse
            return error.InvalidParameter;

        const req_ptr: *request.PcmSetParams = @ptrCast(@alignCast(self.ctl_req_virt));
        req_ptr.* = params;

        @memset(self.ctl_resp_virt[0..8], 0);

        const control_q = &self.queues.control.?;

        const out_bufs = &[_][]const u8{
            @as([*]const u8, @ptrCast(req_ptr))[0..@sizeOf(request.PcmSetParams)],
        };
        const in_bufs = &[_][]u8{
            self.ctl_resp_virt[0..4],
        };

        _ = control_q.submitAndKick(out_bufs, in_bufs) orelse return error.CommandFailed;

        // Poll for completion
        var timeout: u32 = 100000;
        while (!control_q.hasPending() and timeout > 0) : (timeout -= 1) {
            hal.timing.delayUs(1);
        }
        if (timeout == 0) return error.CommandTimeout;

        _ = control_q.getUsed() orelse return error.CommandFailed;

        const status_ptr: *const request.CtlStatus = @ptrCast(@alignCast(self.ctl_resp_virt));
        if (!status_ptr.isOk()) return error.CommandFailed;

        // Update stream state
        stream.format = config.PcmFormat.toIndex(format) orelse 0;
        stream.rate = config.PcmRate.toIndex(rate) orelse 0;
        stream.channels = channels;
        stream.buffer_bytes = buffer_bytes;
        stream.period_bytes = period_bytes;
    }

    /// Send a simple PCM control command (PREPARE, START, STOP, RELEASE)
    /// SECURITY NOTE: Response buffer is zeroed before use. If device returns short/no
    /// data, status reads as 0 which != OK (0x8000), causing CommandFailed - fail-safe.
    fn sendPcmControl(self: *Self, code: u32, stream_id: u32) SoundError!void {
        const req_ptr: *request.PcmRequest = @ptrCast(@alignCast(self.ctl_req_virt));
        req_ptr.* = .{
            .hdr = .{ .code = code },
            .stream_id = stream_id,
        };

        @memset(self.ctl_resp_virt[0..8], 0);

        const control_q = &self.queues.control.?;

        const out_bufs = &[_][]const u8{
            @as([*]const u8, @ptrCast(req_ptr))[0..@sizeOf(request.PcmRequest)],
        };
        const in_bufs = &[_][]u8{
            self.ctl_resp_virt[0..4],
        };

        _ = control_q.submitAndKick(out_bufs, in_bufs) orelse return error.CommandFailed;

        // Poll for completion
        var timeout: u32 = 100000;
        while (!control_q.hasPending() and timeout > 0) : (timeout -= 1) {
            hal.timing.delayUs(1);
        }
        if (timeout == 0) return error.CommandTimeout;

        _ = control_q.getUsed() orelse return error.CommandFailed;

        const status_ptr: *const request.CtlStatus = @ptrCast(@alignCast(self.ctl_resp_virt));
        if (!status_ptr.isOk()) return error.CommandFailed;
    }

    // =========================================================================
    // Audio Data Transfer
    // =========================================================================

    /// Write audio data (blocking)
    pub fn write(self: *Self, data: []const u8) isize {
        if (!self.initialized) return -1;

        const held = self.lock.acquire();
        defer held.release();

        // Get active output stream
        const stream = self.streams.getActiveOutput() orelse return -1;

        // Auto-prepare if needed
        if (stream.state == .idle) {
            // Set default parameters
            self.pcmSetParams(stream.stream_id, @intCast(self.oss_channels), config.PcmFormat.S16, config.PcmRate.R48000, config.Limits.BUFFER_POOL_SIZE, config.Limits.BUFFER_SIZE) catch return -1;
            self.pcmPrepare(stream.stream_id) catch return -1;
            self.pcmStart(stream.stream_id) catch return -1;
        }

        // Submit audio data to TX queue
        const tx_q = self.queues.selectTxQueue() orelse return -1;

        // Copy data to DMA buffer
        const to_copy = @min(data.len, self.buffer_pool_size);
        @memcpy(self.buffer_pool_virt[0..to_copy], data[0..to_copy]);

        // Setup transfer header
        self.xfer_hdr_virt.* = .{ .stream_id = stream.stream_id };

        // Zero status
        @memset(@as([*]u8, @ptrCast(@volatileCast(self.xfer_status_virt)))[0..@sizeOf(request.PcmXferStatus)], 0);

        // Build descriptor chain: [header] [data] -> [status]
        const out_bufs = &[_][]const u8{
            @as([*]const u8, @ptrCast(self.xfer_hdr_virt))[0..@sizeOf(request.PcmXferHdr)],
            self.buffer_pool_virt[0..to_copy],
        };
        const in_bufs = &[_][]u8{
            @as([*]u8, @ptrCast(@volatileCast(self.xfer_status_virt)))[0..@sizeOf(request.PcmXferStatus)],
        };

        _ = tx_q.submitAndKick(out_bufs, in_bufs) orelse return -1;

        // Poll for completion
        var timeout: u32 = 1000000;
        while (!tx_q.hasPending() and timeout > 0) : (timeout -= 1) {
            hal.timing.delayUs(1);
        }

        if (timeout == 0) return -1;

        _ = tx_q.getUsed() orelse return -1;

        // Check status
        if (!self.xfer_status_virt.isOk()) return -1;

        stream.bytes_processed += to_copy;
        return @intCast(to_copy);
    }

    /// Get available buffer space (for OSS GETOSPACE)
    pub fn getAvailableSpace(self: *Self) u32 {
        if (!self.initialized) return 0;
        return self.queues.getTotalTxSpace();
    }

    /// Check if we can write (for poll)
    pub fn canWrite(self: *Self) bool {
        if (!self.initialized) return false;
        if (self.queues.tx_queue_count == 0) return false;
        if (self.queues.tx_queues[0]) |*q| {
            return q.hasSpace(3); // header + data + status
        }
        return false;
    }

    /// Check if we can read (for poll)
    pub fn canRead(_: *Self) bool {
        // Capture not fully implemented yet
        return false;
    }

    /// Sync - wait for all pending buffers
    pub fn sync(self: *Self) void {
        if (!self.initialized) return;

        // Wait for TX queues to drain
        var timeout: u32 = 10000000;
        while (self.queues.getTotalTxInFlight() > 0 and timeout > 0) : (timeout -= 1) {
            hal.timing.delayUs(1);

            // Process any completions
            for (0..self.queues.tx_queue_count) |i| {
                if (self.queues.tx_queues[i]) |*q| {
                    while (q.getUsed()) |_| {}
                }
            }
        }
    }

    /// Reset driver state
    pub fn reset(self: *Self) void {
        if (!self.initialized) return;

        const held = self.lock.acquire();
        defer held.release();

        // Stop all streams
        for (&self.streams.streams) |*ms| {
            if (ms.*) |*s| {
                if (s.state == .running) {
                    self.pcmStop(s.stream_id) catch {};
                }
                s.reset();
            }
        }

        self.queues.resetAll();
    }

    /// Handle interrupt
    pub fn handleInterrupt(self: *Self) void {
        if (!self.initialized) return;

        // Read and clear ISR
        const isr_ptr: *volatile u8 = @ptrFromInt(self.isr_addr);
        const isr = isr_ptr.*;
        _ = isr;

        // Process TX queue completions
        for (0..self.queues.tx_queue_count) |i| {
            if (self.queues.tx_queues[i]) |*q| {
                while (q.getUsed()) |_| {
                    // Buffer completed
                }
            }
        }

        // Process RX queue completions
        for (0..self.queues.rx_queue_count) |i| {
            if (self.queues.rx_queues[i]) |*q| {
                while (q.getUsed()) |_| {
                    // Capture data available
                }
            }
        }
    }

    /// Set sample rate (for OSS)
    pub fn setSampleRate(self: *Self, rate: u32) u32 {
        self.oss_sample_rate = rate;

        // Map to nearest supported rate
        const rate_mask = config.PcmRate.fromHz(rate);
        if (rate_mask != null) {
            return rate;
        }

        // Find closest supported rate
        const rates = [_]u32{ 48000, 44100, 32000, 22050, 16000, 11025, 8000 };
        for (rates) |r| {
            if (r <= rate) {
                self.oss_sample_rate = r;
                return r;
            }
        }

        self.oss_sample_rate = 8000;
        return 8000;
    }

    /// Set format (for OSS)
    pub fn setFormat(self: *Self, format: u32) u32 {
        const sound = @import("uapi").sound;
        self.oss_format = switch (format) {
            sound.AFMT_S16_LE => format,
            sound.AFMT_U8 => format,
            sound.AFMT_S8 => format,
            else => sound.AFMT_S16_LE,
        };
        return self.oss_format;
    }
};

// =============================================================================
// Global Instance
// =============================================================================

var g_driver: ?*VirtioSoundDriver = null;

/// Get the global driver instance
pub fn getDriver() ?*VirtioSoundDriver {
    return g_driver;
}

/// Initialize from PCI device
pub fn initFromPci(pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) SoundError!*VirtioSoundDriver {
    const driver = heap.allocator().create(VirtioSoundDriver) catch return error.AllocationFailed;

    driver.init(pci_dev, pci_access) catch |err| {
        heap.allocator().destroy(driver);
        return err;
    };

    g_driver = driver;

    // Register /dev/dsp with devfs
    devfs.registerDevice("dsp", &dsp.dsp_ops, null) catch |err| {
        console.warn("VirtIO-Sound: Failed to register /dev/dsp: {}", .{err});
    };

    return driver;
}

/// Check if device is VirtIO-Sound
pub fn isVirtioSound(pci_dev: *const pci.PciDevice) bool {
    if (pci_dev.vendor_id != config.PCI_VENDOR_VIRTIO) return false;
    return pci_dev.device_id == config.PCI_DEVICE_SOUND_MODERN or
        pci_dev.device_id == config.PCI_DEVICE_SOUND_LEGACY;
}

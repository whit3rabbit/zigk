// VirtIO-9P Driver
//
// Provides shared folder access via the 9P2000.u protocol over VirtIO.
// Enables QEMU's -virtfs feature for host-guest file sharing.
//
// Usage:
//   const virtio9p = @import("virtio9p");
//   var device = try virtio9p.initFromPci(pci_dev, pci_access);
//   try device.attach("/");
//   const fid = try device.walk(root_fid, newfid, &[_][]const u8{"path", "to", "file"});
//
// Reference: VirtIO Specification 1.2+ Section 5.11

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const pci = @import("pci");
const vmm = @import("vmm");
const pmm = @import("pmm");
const heap = @import("heap");
const sync = @import("sync");
const dma = @import("dma");
const iommu = @import("iommu");
const virtio = @import("virtio");

pub const config = @import("config.zig");
pub const protocol = @import("protocol.zig");
pub const fid = @import("fid.zig");
pub const queue = @import("queue.zig");
pub const irq = @import("irq.zig");

// ============================================================================
// Error Types
// ============================================================================

pub const P9Error = error{
    NotVirtio9P,
    InvalidBar,
    MappingFailed,
    CapabilityNotFound,
    ResetFailed,
    FeatureNegotiationFailed,
    QueueAllocationFailed,
    AllocationFailed,
    VersionMismatch,
    AttachFailed,
    WalkFailed,
    OpenFailed,
    ReadFailed,
    WriteFailed,
    ClunkFailed,
    StatFailed,
    CreateFailed,
    RemoveFailed,
    InvalidFid,
    FidTableFull,
    QueueFull,
    Timeout,
    ServerError,
    ProtocolError,
    PathTooLong,
    TooManyWalkElements,
    BufferTooSmall,
};

// ============================================================================
// Global State
// ============================================================================

/// Global 9P device instance (singleton for now)
var g_device: ?*Virtio9PDevice = null;

/// Get the global device instance
pub fn getDevice() ?*Virtio9PDevice {
    return g_device;
}

// ============================================================================
// Device Detection
// ============================================================================

/// Check if a PCI device is a VirtIO-9P device
pub fn isVirtio9P(dev: *const pci.PciDevice) bool {
    if (dev.vendor_id != config.PCI_VENDOR_VIRTIO) return false;
    return dev.device_id == config.PCI_DEVICE_9P_LEGACY or
        dev.device_id == config.PCI_DEVICE_9P_MODERN;
}

// ============================================================================
// VirtIO-9P Device
// ============================================================================

pub const Virtio9PDevice = struct {
    /// VirtIO common configuration MMIO
    common_cfg: *volatile virtio.VirtioPciCommonCfg,

    /// Notify register base address
    notify_base: u64,

    /// Notify offset multiplier
    notify_off_mult: u32,

    /// ISR register address
    isr_addr: u64,

    /// Device-specific configuration
    device_cfg: *volatile config.Virtio9PConfig,

    /// Request queue
    p9queue: ?queue.P9Queue,

    /// Fid management table
    fid_table: fid.FidTable,

    /// Root fid number (from Tattach)
    root_fid: u32,

    /// Root qid (from Rattach)
    root_qid: protocol.P9Qid,

    /// Mount tag from device config
    mount_tag: [config.MAX_TAG_LEN + 1]u8,
    mount_tag_len: usize,

    /// Negotiated message size
    msize: u32,

    /// Negotiated protocol version
    version: [32]u8,
    version_len: usize,

    /// Negotiated features
    features: u64,

    /// PCI device reference
    pci_dev: *const pci.PciDevice,

    /// PCI BDF for IOMMU
    bdf: iommu.DeviceBdf,

    /// MSI-X vector
    msix_vector: ?u8,

    /// Request/response buffers (DMA-safe)
    request_dma: dma.DmaBuffer,
    response_dma: dma.DmaBuffer,

    /// Lock for synchronous operations
    op_lock: sync.Spinlock,

    /// Device state
    initialized: bool,
    attached: bool,

    const Self = @This();

    // ========================================================================
    // Initialization
    // ========================================================================

    /// Initialize device from PCI
    pub fn init(self: *Self, pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) P9Error!void {
        self.pci_dev = pci_dev;
        self.initialized = false;
        self.attached = false;
        self.features = 0;
        self.msix_vector = null;
        self.p9queue = null;
        self.root_fid = config.P9_ROOT_FID;
        self.msize = config.P9_DEFAULT_MSIZE;
        self.mount_tag_len = 0;
        self.version_len = 0;
        self.fid_table = fid.FidTable.init();
        self.op_lock = .{};

        // Set up BDF for IOMMU
        self.bdf = iommu.DeviceBdf{
            .bus = pci_dev.bus,
            .device = pci_dev.device,
            .func = pci_dev.func,
        };

        // Verify device type
        if (!isVirtio9P(pci_dev)) {
            return error.NotVirtio9P;
        }

        // Get ECAM access
        const ecam = switch (pci_access) {
            .ecam => |e| e,
            .legacy => {
                console.err("VirtIO-9P: Legacy PCI access not supported", .{});
                return error.InvalidBar;
            },
        };

        // Enable bus mastering and memory space
        ecam.enableBusMaster(pci_dev.bus, pci_dev.device, pci_dev.func);
        ecam.enableMemorySpace(pci_dev.bus, pci_dev.device, pci_dev.func);

        // Parse VirtIO capabilities and map MMIO regions
        try self.parseCapabilities(pci_dev, ecam);

        // Allocate DMA buffers for request/response
        self.request_dma = dma.allocBuffer(self.bdf, config.P9_MAX_MSIZE, false) catch {
            return error.AllocationFailed;
        };
        self.response_dma = dma.allocBuffer(self.bdf, config.P9_MAX_MSIZE, true) catch {
            dma.freeBuffer(&self.request_dma);
            return error.AllocationFailed;
        };

        // Zero-initialize buffers (security)
        @memset(self.getRequestBuf(), 0);
        @memset(self.getResponseBuf(), 0);

        // Initialize device per VirtIO spec
        try self.initializeDevice();

        // Set up MSI-X interrupts
        irq.setupMsix(self, pci_access) catch |err| {
            console.warn("VirtIO-9P: MSI-X setup failed: {}, using polling", .{err});
        };

        // Read mount tag
        self.readMountTag();

        self.initialized = true;
        g_device = self;

        console.info("VirtIO-9P: Device initialized, tag=\"{s}\"", .{self.mount_tag[0..self.mount_tag_len]});
    }

    /// Parse VirtIO PCI capabilities
    fn parseCapabilities(self: *Self, pci_dev: *const pci.PciDevice, ecam: pci.Ecam) P9Error!void {
        // Check if capabilities are supported
        const status = ecam.read16(pci_dev.bus, pci_dev.device, pci_dev.func, 0x06);
        if ((status & 0x10) == 0) {
            return error.CapabilityNotFound;
        }

        // Get initial capability pointer
        var cap_ptr = ecam.read8(pci_dev.bus, pci_dev.device, pci_dev.func, 0x34);
        cap_ptr &= 0xFC;

        var common_found = false;
        var notify_found = false;
        var device_found = false;

        while (cap_ptr != 0) {
            const cap_id = ecam.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr);
            const next_ptr = ecam.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 1);

            if (cap_id == 0x09) { // VirtIO vendor-specific capability
                const cfg_type = ecam.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 3);
                const bar_idx = ecam.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 4);
                const offset = ecam.read32(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 8);

                if (bar_idx > 5) {
                    cap_ptr = next_ptr;
                    continue;
                }

                const bar = pci_dev.bar[bar_idx];
                if (!bar.isValid() or !bar.is_mmio) {
                    cap_ptr = next_ptr;
                    continue;
                }

                // Validate offset fits within BAR
                const bar_size = bar.size;
                const struct_size: u64 = switch (cfg_type) {
                    virtio.common.VIRTIO_PCI_CAP_COMMON_CFG => @sizeOf(virtio.VirtioPciCommonCfg),
                    virtio.common.VIRTIO_PCI_CAP_NOTIFY_CFG => 4,
                    virtio.common.VIRTIO_PCI_CAP_ISR_CFG => 4,
                    virtio.common.VIRTIO_PCI_CAP_DEVICE_CFG => @sizeOf(config.Virtio9PConfig),
                    else => 0,
                };
                if (struct_size > 0 and (offset > bar_size or struct_size > bar_size - offset)) {
                    cap_ptr = next_ptr;
                    continue;
                }

                // Map BAR
                const bar_virt = vmm.mapMmio(bar.base, bar.size) catch {
                    cap_ptr = next_ptr;
                    continue;
                };

                const virt_addr = bar_virt + offset;

                switch (cfg_type) {
                    virtio.common.VIRTIO_PCI_CAP_COMMON_CFG => {
                        self.common_cfg = @ptrFromInt(virt_addr);
                        common_found = true;
                    },
                    virtio.common.VIRTIO_PCI_CAP_NOTIFY_CFG => {
                        self.notify_base = virt_addr;
                        self.notify_off_mult = ecam.read32(
                            pci_dev.bus,
                            pci_dev.device,
                            pci_dev.func,
                            cap_ptr + 16,
                        );
                        notify_found = true;
                    },
                    virtio.common.VIRTIO_PCI_CAP_ISR_CFG => {
                        self.isr_addr = virt_addr;
                    },
                    virtio.common.VIRTIO_PCI_CAP_DEVICE_CFG => {
                        self.device_cfg = @ptrFromInt(virt_addr);
                        device_found = true;
                    },
                    else => {},
                }
            }

            cap_ptr = next_ptr;
        }

        if (!common_found or !notify_found or !device_found) {
            return error.CapabilityNotFound;
        }
    }

    /// Initialize device per VirtIO spec
    fn initializeDevice(self: *Self) P9Error!void {
        // 1. Reset device
        self.common_cfg.device_status = 0;
        hal.mmio.memoryBarrier();

        var timeout: u32 = 1000;
        while (self.common_cfg.device_status != 0 and timeout > 0) : (timeout -= 1) {
            hal.cpu.pause();
        }

        // 2. Set ACKNOWLEDGE
        self.common_cfg.device_status = virtio.VIRTIO_STATUS_ACKNOWLEDGE;
        hal.mmio.memoryBarrier();

        // 3. Set DRIVER
        self.common_cfg.device_status |= virtio.VIRTIO_STATUS_DRIVER;
        hal.mmio.memoryBarrier();

        // 4. Negotiate features
        try self.negotiateFeatures();

        // 5. Set FEATURES_OK
        self.common_cfg.device_status |= virtio.VIRTIO_STATUS_FEATURES_OK;
        hal.mmio.memoryBarrier();

        // 6. Verify FEATURES_OK
        if ((self.common_cfg.device_status & virtio.VIRTIO_STATUS_FEATURES_OK) == 0) {
            self.common_cfg.device_status |= virtio.VIRTIO_STATUS_FAILED;
            return error.FeatureNegotiationFailed;
        }

        // 7. Set up virtqueues
        try self.setupVirtqueue();

        // 8. Set DRIVER_OK
        self.common_cfg.device_status |= virtio.VIRTIO_STATUS_DRIVER_OK;
        hal.mmio.memoryBarrier();
    }

    /// Negotiate features
    fn negotiateFeatures(self: *Self) P9Error!void {
        // Read device features
        self.common_cfg.device_feature_select = 0;
        hal.mmio.memoryBarrier();
        var device_features: u64 = self.common_cfg.device_feature;

        self.common_cfg.device_feature_select = 1;
        hal.mmio.memoryBarrier();
        device_features |= @as(u64, self.common_cfg.device_feature) << 32;

        // Require VERSION_1
        if ((device_features & (1 << virtio.VIRTIO_F_VERSION_1)) == 0) {
            return error.FeatureNegotiationFailed;
        }

        // Accept features
        self.features = (1 << virtio.VIRTIO_F_VERSION_1);

        // Accept MOUNT_TAG if available
        if ((device_features & config.Features.MOUNT_TAG) != 0) {
            self.features |= config.Features.MOUNT_TAG;
        }

        // Write features
        self.common_cfg.driver_feature_select = 0;
        hal.mmio.memoryBarrier();
        self.common_cfg.driver_feature = @truncate(self.features);

        self.common_cfg.driver_feature_select = 1;
        hal.mmio.memoryBarrier();
        self.common_cfg.driver_feature = @truncate(self.features >> 32);
    }

    /// Set up the request virtqueue
    fn setupVirtqueue(self: *Self) P9Error!void {
        // Select queue 0
        self.common_cfg.queue_select = config.QueueIndex.REQUEST;
        hal.mmio.memoryBarrier();

        // Read queue size
        const queue_size = self.common_cfg.queue_size;
        if (queue_size == 0) {
            return error.QueueAllocationFailed;
        }

        // Initialize queue
        self.p9queue = queue.P9Queue.init(@min(queue_size, config.Limits.DEFAULT_QUEUE_SIZE)) orelse {
            return error.QueueAllocationFailed;
        };

        // Configure queue addresses
        const addrs = self.p9queue.?.getPhysAddrs();
        self.common_cfg.queue_desc = addrs.desc;
        self.common_cfg.queue_avail = addrs.avail;
        self.common_cfg.queue_used = addrs.used;
        hal.mmio.memoryBarrier();

        // Set notify offset
        const notify_off = self.common_cfg.queue_notify_off;
        self.p9queue.?.setNotifyAddr(self.notify_base, self.notify_off_mult, notify_off);

        // Enable queue
        self.common_cfg.queue_enable = 1;
        hal.mmio.memoryBarrier();
    }

    /// Read mount tag from device config
    fn readMountTag(self: *Self) void {
        if ((self.features & config.Features.MOUNT_TAG) == 0) {
            self.mount_tag_len = 0;
            return;
        }

        const tag_len = @min(self.device_cfg.tag_len, config.MAX_TAG_LEN);
        for (0..tag_len) |i| {
            self.mount_tag[i] = self.device_cfg.tag[i];
        }
        self.mount_tag[tag_len] = 0; // Null terminate
        self.mount_tag_len = tag_len;
    }

    // ========================================================================
    // Buffer Access Helpers
    // ========================================================================

    /// Get request buffer slice for CPU access
    fn getRequestBuf(self: *Self) []u8 {
        const ptr = self.request_dma.getVirt();
        return ptr[0..@intCast(self.request_dma.size)];
    }

    /// Get response buffer slice for CPU access
    fn getResponseBuf(self: *Self) []u8 {
        const ptr = self.response_dma.getVirt();
        return ptr[0..@intCast(self.response_dma.size)];
    }

    /// Wait for a pending request to complete, polling the used ring
    /// This handles the case where MSI-X interrupts don't work (e.g., QEMU TCG)
    fn waitForCompletion(self: *Self, pending: *queue.PendingRequest, timeout_ns: u64) bool {
        const start = hal.timing.getNanoseconds();
        while (!pending.completed.load(.acquire)) {
            // Poll the used ring to check for completions
            self.p9queue.?.processCompleted();

            const elapsed = hal.timing.getNanoseconds() - start;
            if (elapsed >= timeout_ns) return false;
            hal.cpu.pause();
        }
        return true;
    }

    // ========================================================================
    // 9P Protocol Operations
    // ========================================================================

    /// Perform Tversion/Rversion handshake
    pub fn negotiateVersion(self: *Self) P9Error!void {
        const held = self.op_lock.acquire();
        defer held.release();

        var req_buf = protocol.P9Buffer.init(self.getRequestBuf());
        const tag = self.p9queue.?.allocTag();

        // Build Tversion
        protocol.buildTversion(&req_buf, tag, config.P9_DEFAULT_MSIZE, config.P9_PROTO_2000U) catch {
            return error.ProtocolError;
        };

        // Submit and wait
        const pending = self.p9queue.?.submitRequest(
            req_buf.getMessage(),
            self.getResponseBuf(),
            tag,
            .Rversion,
        ) orelse return error.QueueFull;

        // Poll for completion (handles case where MSI-X doesn't work under TCG)
        if (!self.waitForCompletion(pending, 1_000_000_000)) {
            return error.Timeout;
        }

        // Parse response
        var resp_buf = protocol.P9Buffer.init(self.getResponseBuf()[0..pending.response_len]);
        const hdr = resp_buf.readHeader() catch return error.ProtocolError;

        if (@as(protocol.MsgType, @enumFromInt(hdr.msg_type)) == .Rerror) {
            return error.ServerError;
        }

        const result = protocol.parseRversion(&resp_buf) catch return error.ProtocolError;
        self.msize = result.msize;

        // Store version
        const ver_len = @min(result.version.len, self.version.len);
        @memcpy(self.version[0..ver_len], result.version[0..ver_len]);
        self.version_len = ver_len;

        self.p9queue.?.releaseRequest(pending);
    }

    /// Attach to the server (establish session)
    pub fn attach(self: *Self, aname: []const u8) P9Error!void {
        const held = self.op_lock.acquire();
        defer held.release();

        // Allocate root fid
        const root_fid_entry = self.fid_table.allocateWithNum(config.P9_ROOT_FID) orelse {
            return error.FidTableFull;
        };

        var req_buf = protocol.P9Buffer.init(self.getRequestBuf());
        const tag = self.p9queue.?.allocTag();

        // Build Tattach
        protocol.buildTattach(
            &req_buf,
            tag,
            config.P9_ROOT_FID,
            config.P9_NOFID, // No auth
            "", // uname
            aname,
            0, // n_uname
        ) catch return error.ProtocolError;

        // Submit
        const pending = self.p9queue.?.submitRequest(
            req_buf.getMessage(),
            self.getResponseBuf(),
            tag,
            .Rattach,
        ) orelse {
            self.fid_table.release(root_fid_entry);
            return error.QueueFull;
        };

        if (!self.waitForCompletion(pending, 5_000_000_000)) { // 5 second timeout
            self.fid_table.release(root_fid_entry);
            return error.Timeout;
        }

        // Parse response
        var resp_buf = protocol.P9Buffer.init(self.getResponseBuf()[0..pending.response_len]);
        const hdr = resp_buf.readHeader() catch {
            self.fid_table.release(root_fid_entry);
            return error.ProtocolError;
        };

        if (@as(protocol.MsgType, @enumFromInt(hdr.msg_type)) == .Rerror) {
            self.fid_table.release(root_fid_entry);
            return error.AttachFailed;
        }

        self.root_qid = protocol.parseRattach(&resp_buf) catch {
            self.fid_table.release(root_fid_entry);
            return error.ProtocolError;
        };

        root_fid_entry.attach(self.root_qid);
        root_fid_entry.setPath("/");
        self.attached = true;

        self.p9queue.?.releaseRequest(pending);
    }

    /// Walk from a fid to a path
    pub fn walk(self: *Self, from_fid: u32, new_fid: u32, names: []const []const u8) P9Error!protocol.P9Qid {
        if (names.len > config.Limits.MAX_WALK_ELEMS) {
            return error.TooManyWalkElements;
        }

        const held = self.op_lock.acquire();
        defer held.release();

        // Allocate new fid
        const new_fid_entry = self.fid_table.allocateWithNum(new_fid) orelse {
            return error.FidTableFull;
        };

        var req_buf = protocol.P9Buffer.init(self.getRequestBuf());
        const tag = self.p9queue.?.allocTag();

        protocol.buildTwalk(&req_buf, tag, from_fid, new_fid, names) catch {
            self.fid_table.release(new_fid_entry);
            return error.ProtocolError;
        };

        const pending = self.p9queue.?.submitRequest(
            req_buf.getMessage(),
            self.getResponseBuf(),
            tag,
            .Rwalk,
        ) orelse {
            self.fid_table.release(new_fid_entry);
            return error.QueueFull;
        };

        if (!self.waitForCompletion(pending, 5_000_000_000)) {
            self.fid_table.release(new_fid_entry);
            return error.Timeout;
        }

        var resp_buf = protocol.P9Buffer.init(self.getResponseBuf()[0..pending.response_len]);
        const hdr = resp_buf.readHeader() catch {
            self.fid_table.release(new_fid_entry);
            return error.ProtocolError;
        };

        if (@as(protocol.MsgType, @enumFromInt(hdr.msg_type)) == .Rerror) {
            self.fid_table.release(new_fid_entry);
            return error.WalkFailed;
        }

        var qids: [config.Limits.MAX_WALK_ELEMS]protocol.P9Qid = undefined;
        const nwqid = protocol.parseRwalk(&resp_buf, &qids) catch {
            self.fid_table.release(new_fid_entry);
            return error.ProtocolError;
        };

        if (nwqid == 0 and names.len > 0) {
            self.fid_table.release(new_fid_entry);
            return error.WalkFailed;
        }

        // Update fid with final qid
        const final_qid = if (nwqid > 0) qids[nwqid - 1] else self.root_qid;
        new_fid_entry.attach(final_qid);

        self.p9queue.?.releaseRequest(pending);
        return final_qid;
    }

    /// Open a fid for I/O
    pub fn open(self: *Self, fid_num: u32, mode: u8) P9Error!struct { qid: protocol.P9Qid, iounit: u32 } {
        const held = self.op_lock.acquire();
        defer held.release();

        const fid_entry = self.fid_table.lookup(fid_num) orelse return error.InvalidFid;

        var req_buf = protocol.P9Buffer.init(self.getRequestBuf());
        const tag = self.p9queue.?.allocTag();

        protocol.buildTopen(&req_buf, tag, fid_num, mode) catch return error.ProtocolError;

        const pending = self.p9queue.?.submitRequest(
            req_buf.getMessage(),
            self.getResponseBuf(),
            tag,
            .Ropen,
        ) orelse return error.QueueFull;

        if (!self.waitForCompletion(pending, 5_000_000_000)) {
            return error.Timeout;
        }

        var resp_buf = protocol.P9Buffer.init(self.getResponseBuf()[0..pending.response_len]);
        const hdr = resp_buf.readHeader() catch return error.ProtocolError;

        if (@as(protocol.MsgType, @enumFromInt(hdr.msg_type)) == .Rerror) {
            return error.OpenFailed;
        }

        const result = protocol.parseRopen(&resp_buf) catch return error.ProtocolError;
        fid_entry.open(result.qid, result.iounit, mode);

        self.p9queue.?.releaseRequest(pending);
        return result;
    }

    /// Read from an open fid
    pub fn read(self: *Self, fid_num: u32, offset: u64, count: u32, out_buf: []u8) P9Error!usize {
        const held = self.op_lock.acquire();
        defer held.release();

        _ = self.fid_table.lookup(fid_num) orelse return error.InvalidFid;

        var req_buf = protocol.P9Buffer.init(self.getRequestBuf());
        const tag = self.p9queue.?.allocTag();

        const actual_count = @min(count, @as(u32, @intCast(out_buf.len)));
        protocol.buildTread(&req_buf, tag, fid_num, offset, actual_count) catch return error.ProtocolError;

        const pending = self.p9queue.?.submitRequest(
            req_buf.getMessage(),
            self.getResponseBuf(),
            tag,
            .Rread,
        ) orelse return error.QueueFull;

        if (!self.waitForCompletion(pending, 10_000_000_000)) { // 10 second timeout for reads
            return error.Timeout;
        }

        var resp_buf = protocol.P9Buffer.init(self.getResponseBuf()[0..pending.response_len]);
        const hdr = resp_buf.readHeader() catch return error.ProtocolError;

        if (@as(protocol.MsgType, @enumFromInt(hdr.msg_type)) == .Rerror) {
            return error.ReadFailed;
        }

        const data = protocol.parseRread(&resp_buf) catch return error.ProtocolError;
        const copy_len = @min(data.len, out_buf.len);
        @memcpy(out_buf[0..copy_len], data[0..copy_len]);

        self.p9queue.?.releaseRequest(pending);
        return copy_len;
    }

    /// Write to an open fid
    pub fn write(self: *Self, fid_num: u32, offset: u64, data: []const u8) P9Error!u32 {
        const held = self.op_lock.acquire();
        defer held.release();

        _ = self.fid_table.lookup(fid_num) orelse return error.InvalidFid;

        var req_buf = protocol.P9Buffer.init(self.getRequestBuf());
        const tag = self.p9queue.?.allocTag();

        protocol.buildTwrite(&req_buf, tag, fid_num, offset, data) catch return error.ProtocolError;

        const pending = self.p9queue.?.submitRequest(
            req_buf.getMessage(),
            self.getResponseBuf(),
            tag,
            .Rwrite,
        ) orelse return error.QueueFull;

        if (!self.waitForCompletion(pending, 10_000_000_000)) {
            return error.Timeout;
        }

        var resp_buf = protocol.P9Buffer.init(self.getResponseBuf()[0..pending.response_len]);
        const hdr = resp_buf.readHeader() catch return error.ProtocolError;

        if (@as(protocol.MsgType, @enumFromInt(hdr.msg_type)) == .Rerror) {
            return error.WriteFailed;
        }

        const count = protocol.parseRwrite(&resp_buf) catch return error.ProtocolError;

        self.p9queue.?.releaseRequest(pending);
        return count;
    }

    /// Clunk (close) a fid
    pub fn clunk(self: *Self, fid_num: u32) P9Error!void {
        const held = self.op_lock.acquire();
        defer held.release();

        _ = self.fid_table.lookup(fid_num) orelse return error.InvalidFid;

        var req_buf = protocol.P9Buffer.init(self.getRequestBuf());
        const tag = self.p9queue.?.allocTag();

        protocol.buildTclunk(&req_buf, tag, fid_num) catch return error.ProtocolError;

        const pending = self.p9queue.?.submitRequest(
            req_buf.getMessage(),
            self.getResponseBuf(),
            tag,
            .Rclunk,
        ) orelse return error.QueueFull;

        if (!self.waitForCompletion(pending, 5_000_000_000)) {
            return error.Timeout;
        }

        var resp_buf = protocol.P9Buffer.init(self.getResponseBuf()[0..pending.response_len]);
        const hdr = resp_buf.readHeader() catch return error.ProtocolError;

        if (@as(protocol.MsgType, @enumFromInt(hdr.msg_type)) == .Rerror) {
            return error.ClunkFailed;
        }

        // Release fid from table
        _ = self.fid_table.releaseByNum(fid_num);

        self.p9queue.?.releaseRequest(pending);
    }

    /// Get stat for a fid
    pub fn stat(self: *Self, fid_num: u32) P9Error!protocol.P9Stat {
        const held = self.op_lock.acquire();
        defer held.release();

        _ = self.fid_table.lookup(fid_num) orelse return error.InvalidFid;

        var req_buf = protocol.P9Buffer.init(self.getRequestBuf());
        const tag = self.p9queue.?.allocTag();

        protocol.buildTstat(&req_buf, tag, fid_num) catch return error.ProtocolError;

        const pending = self.p9queue.?.submitRequest(
            req_buf.getMessage(),
            self.getResponseBuf(),
            tag,
            .Rstat,
        ) orelse return error.QueueFull;

        if (!self.waitForCompletion(pending, 5_000_000_000)) {
            return error.Timeout;
        }

        var resp_buf = protocol.P9Buffer.init(self.getResponseBuf()[0..pending.response_len]);
        const hdr = resp_buf.readHeader() catch return error.ProtocolError;

        if (@as(protocol.MsgType, @enumFromInt(hdr.msg_type)) == .Rerror) {
            return error.StatFailed;
        }

        const stat_data = protocol.parseRstat(&resp_buf) catch return error.ProtocolError;
        const parsed_stat = protocol.parseStat(stat_data) catch return error.ProtocolError;

        self.p9queue.?.releaseRequest(pending);
        return parsed_stat;
    }

    /// Get mount tag
    pub fn getMountTag(self: *const Self) []const u8 {
        return self.mount_tag[0..self.mount_tag_len];
    }

    /// Check if attached
    pub fn isAttached(self: *const Self) bool {
        return self.attached;
    }
};

// ============================================================================
// Public Initialization Function
// ============================================================================

/// Initialize VirtIO-9P from PCI device
pub fn initFromPci(pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) P9Error!*Virtio9PDevice {
    // Allocate device structure
    const device = heap.allocator().create(Virtio9PDevice) catch {
        return error.AllocationFailed;
    };

    // Initialize
    try device.init(pci_dev, pci_access);

    // Perform version handshake
    try device.negotiateVersion();

    return device;
}

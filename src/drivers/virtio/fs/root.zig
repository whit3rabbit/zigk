// VirtIO-FS Driver
//
// Provides shared folder access via the FUSE protocol over VirtIO.
// Enables QEMU's virtiofsd feature for high-performance host-guest file sharing.
//
// Usage:
//   const virtiofs = @import("virtiofs");
//   var device = try virtiofs.initFromPci(pci_dev, pci_access);
//   try device.fuseInit();
//   const entry = try device.lookup(FUSE_ROOT_ID, "filename");
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
pub const queue = @import("queue.zig");
pub const irq = @import("irq.zig");
pub const inode_cache = @import("inode_cache.zig");
pub const dentry_cache = @import("dentry_cache.zig");

// ============================================================================
// Error Types
// ============================================================================

pub const FsError = error{
    NotVirtioFs,
    InvalidBar,
    MappingFailed,
    CapabilityNotFound,
    ResetFailed,
    FeatureNegotiationFailed,
    QueueAllocationFailed,
    AllocationFailed,
    InitFailed,
    LookupFailed,
    GetAttrFailed,
    OpenFailed,
    ReadFailed,
    WriteFailed,
    ReleaseFailed,
    CreateFailed,
    MkdirFailed,
    UnlinkFailed,
    RmdirFailed,
    RenameFailed,
    StatfsFailed,
    ReadDirFailed,
    InvalidNodeId,
    QueueFull,
    Timeout,
    ServerError,
    ProtocolError,
    PathTooLong,
    NameTooLong,
    NotDirectory,
    IsDirectory,
    NotFound,
    PermissionDenied,
    NoSpace,
    NotEmpty,
    Exists,
};

// ============================================================================
// Global State
// ============================================================================

/// Global FS device instance (singleton for now)
var g_device: ?*VirtioFsDevice = null;

/// Get the global device instance
pub fn getDevice() ?*VirtioFsDevice {
    return g_device;
}

// ============================================================================
// Device Detection
// ============================================================================

/// Check if a PCI device is a VirtIO-FS device
pub fn isVirtioFs(dev: *const pci.PciDevice) bool {
    if (dev.vendor_id != config.PCI_VENDOR_VIRTIO) return false;
    return dev.device_id == config.PCI_DEVICE_FS_MODERN or
        dev.device_id == config.PCI_DEVICE_FS_LEGACY;
}

// ============================================================================
// VirtIO-FS Device
// ============================================================================

pub const VirtioFsDevice = struct {
    /// VirtIO common configuration MMIO
    common_cfg: *volatile virtio.VirtioPciCommonCfg,

    /// Notify register base address
    notify_base: u64,

    /// Notify offset multiplier
    notify_off_mult: u32,

    /// ISR register address
    isr_addr: u64,

    /// Device-specific configuration
    device_cfg: *volatile config.VirtioFsConfig,

    /// Queue set (hiprio + request)
    queues: ?queue.FsQueues,

    /// Inode cache
    inodes: inode_cache.InodeCache,

    /// Dentry cache
    dentries: dentry_cache.DentryCache,

    /// Mount tag from device config
    mount_tag: [config.MAX_TAG_LEN + 1]u8,
    mount_tag_len: usize,

    /// Number of request queues from device config
    num_request_queues: u32,

    /// Negotiated features
    features: u64,

    /// FUSE negotiated parameters
    fuse_major: u32,
    fuse_minor: u32,
    fuse_max_write: u32,
    fuse_max_readahead: u32,
    fuse_flags: u32,

    /// PCI device reference
    pci_dev: *const pci.PciDevice,

    /// PCI BDF for IOMMU
    bdf: iommu.DeviceBdf,

    /// MSI-X vectors
    msix_hiprio_vector: ?u8,
    msix_request_vector: ?u8,

    /// Request/response buffers (DMA-safe)
    request_dma: dma.DmaBuffer,
    response_dma: dma.DmaBuffer,

    /// Lock for synchronous operations
    op_lock: sync.Spinlock,

    /// Device state
    initialized: bool,
    fuse_initialized: bool,

    const Self = @This();

    // ========================================================================
    // Initialization
    // ========================================================================

    /// Initialize device from PCI
    pub fn init(self: *Self, pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) FsError!void {
        self.pci_dev = pci_dev;
        self.initialized = false;
        self.fuse_initialized = false;
        self.features = 0;
        self.msix_hiprio_vector = null;
        self.msix_request_vector = null;
        self.queues = null;
        self.mount_tag_len = 0;
        self.num_request_queues = 1;
        self.fuse_major = 0;
        self.fuse_minor = 0;
        self.fuse_max_write = config.Limits.MAX_IO_SIZE;
        self.fuse_max_readahead = config.Limits.MAX_IO_SIZE;
        self.fuse_flags = 0;
        self.op_lock = .{};
        self.inodes = inode_cache.InodeCache.init();
        self.dentries = dentry_cache.DentryCache.init();

        // Set up BDF for IOMMU
        self.bdf = iommu.DeviceBdf{
            .bus = pci_dev.bus,
            .device = pci_dev.device,
            .func = pci_dev.func,
        };

        // Verify device type
        if (!isVirtioFs(pci_dev)) {
            return error.NotVirtioFs;
        }

        // Get ECAM access
        const ecam = switch (pci_access) {
            .ecam => |e| e,
            .legacy => {
                console.err("VirtIO-FS: Legacy PCI access not supported", .{});
                return error.InvalidBar;
            },
        };

        // Enable bus mastering and memory space
        ecam.enableBusMaster(pci_dev.bus, pci_dev.device, pci_dev.func);
        ecam.enableMemorySpace(pci_dev.bus, pci_dev.device, pci_dev.func);

        // Parse VirtIO capabilities and map MMIO regions
        try self.parseCapabilities(pci_dev, ecam);

        // Allocate DMA buffers for request/response
        self.request_dma = dma.allocBuffer(self.bdf, config.Limits.MAX_MSG_SIZE, false) catch {
            return error.AllocationFailed;
        };
        self.response_dma = dma.allocBuffer(self.bdf, config.Limits.MAX_MSG_SIZE, true) catch {
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
            console.warn("VirtIO-FS: MSI-X setup failed: {}, using polling", .{err});
        };

        // Read mount tag
        self.readMountTag();
        self.readNumQueues();

        self.initialized = true;
        g_device = self;
    }

    /// Parse VirtIO PCI capabilities
    fn parseCapabilities(self: *Self, pci_dev: *const pci.PciDevice, ecam: pci.Ecam) FsError!void {
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
                    virtio.common.VIRTIO_PCI_CAP_DEVICE_CFG => @sizeOf(config.VirtioFsConfig),
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
    fn initializeDevice(self: *Self) FsError!void {
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
        try self.setupVirtqueues();

        // 8. Set DRIVER_OK
        self.common_cfg.device_status |= virtio.VIRTIO_STATUS_DRIVER_OK;
        hal.mmio.memoryBarrier();
    }

    /// Negotiate features
    fn negotiateFeatures(self: *Self) FsError!void {
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

        // Accept NOTIFICATION if available (optional)
        if ((device_features & config.Features.NOTIFICATION) != 0) {
            // We don't use notifications, but acknowledge support
        }

        // Write features
        self.common_cfg.driver_feature_select = 0;
        hal.mmio.memoryBarrier();
        self.common_cfg.driver_feature = @truncate(self.features);

        self.common_cfg.driver_feature_select = 1;
        hal.mmio.memoryBarrier();
        self.common_cfg.driver_feature = @truncate(self.features >> 32);
    }

    /// Set up virtqueues
    fn setupVirtqueues(self: *Self) FsError!void {
        // Read number of request queues from config
        const num_req_queues = @max(1, self.device_cfg.num_request_queues);

        // Initialize queue set
        self.queues = queue.FsQueues.init(config.Limits.DEFAULT_QUEUE_SIZE, num_req_queues) orelse {
            return error.QueueAllocationFailed;
        };

        // Configure hiprio queue (queue 0)
        self.common_cfg.queue_select = config.QueueIndex.HIPRIO;
        hal.mmio.memoryBarrier();

        const hiprio_size = self.common_cfg.queue_size;
        if (hiprio_size == 0) {
            return error.QueueAllocationFailed;
        }

        const hiprio_addrs = self.queues.?.hiprio.getPhysAddrs();
        self.common_cfg.queue_desc = hiprio_addrs.desc;
        self.common_cfg.queue_avail = hiprio_addrs.avail;
        self.common_cfg.queue_used = hiprio_addrs.used;
        hal.mmio.memoryBarrier();

        var notify_off = self.common_cfg.queue_notify_off;
        self.queues.?.hiprio.setNotifyAddr(self.notify_base, self.notify_off_mult, notify_off);

        self.common_cfg.queue_enable = 1;
        hal.mmio.memoryBarrier();

        // Configure request queue (queue 1)
        self.common_cfg.queue_select = config.QueueIndex.REQUEST;
        hal.mmio.memoryBarrier();

        const req_size = self.common_cfg.queue_size;
        if (req_size == 0) {
            return error.QueueAllocationFailed;
        }

        const req_addrs = self.queues.?.request.getPhysAddrs();
        self.common_cfg.queue_desc = req_addrs.desc;
        self.common_cfg.queue_avail = req_addrs.avail;
        self.common_cfg.queue_used = req_addrs.used;
        hal.mmio.memoryBarrier();

        notify_off = self.common_cfg.queue_notify_off;
        self.queues.?.request.setNotifyAddr(self.notify_base, self.notify_off_mult, notify_off);

        self.common_cfg.queue_enable = 1;
        hal.mmio.memoryBarrier();
    }

    /// Read mount tag from device config
    fn readMountTag(self: *Self) void {
        var tag_len: usize = 0;
        for (0..config.MAX_TAG_LEN) |i| {
            const c = self.device_cfg.tag[i];
            if (c == 0) break;
            self.mount_tag[i] = c;
            tag_len += 1;
        }
        self.mount_tag[tag_len] = 0;
        self.mount_tag_len = tag_len;
    }

    /// Read number of request queues from config
    fn readNumQueues(self: *Self) void {
        self.num_request_queues = @max(1, self.device_cfg.num_request_queues);
    }

    // ========================================================================
    // Buffer Access Helpers
    // ========================================================================

    fn getRequestBuf(self: *Self) []u8 {
        const ptr = self.request_dma.getVirt();
        return ptr[0..@intCast(self.request_dma.size)];
    }

    fn getResponseBuf(self: *Self) []u8 {
        const ptr = self.response_dma.getVirt();
        return ptr[0..@intCast(self.response_dma.size)];
    }

    /// Wait for a pending request to complete
    fn waitForCompletion(self: *Self, pending: *queue.PendingRequest, timeout_ns: u64) bool {
        const start = hal.timing.getNanoseconds();
        while (!pending.completed.load(.acquire)) {
            self.queues.?.request.processCompleted();

            const elapsed = hal.timing.getNanoseconds() - start;
            if (elapsed >= timeout_ns) return false;
            hal.cpu.pause();
        }
        return true;
    }

    // ========================================================================
    // FUSE Operations
    // ========================================================================

    /// Perform FUSE_INIT handshake
    pub fn fuseInit(self: *Self) FsError!void {
        const held = self.op_lock.acquire();
        defer held.release();

        var req_buf = protocol.FuseBuffer.init(self.getRequestBuf());
        const unique = self.queues.?.request.allocUnique();

        protocol.buildInit(&req_buf, unique) catch {
            return error.ProtocolError;
        };

        const pending = self.queues.?.request.submitRequest(
            req_buf.getMessage(),
            self.getResponseBuf(),
            unique,
            .INIT,
        ) orelse return error.QueueFull;

        if (!self.waitForCompletion(pending, 5_000_000_000)) {
            return error.Timeout;
        }

        // Parse response
        const resp_data = self.getResponseBuf()[0..pending.response_len];
        const out_hdr = protocol.parseOutHeader(resp_data) orelse return error.ProtocolError;

        if (out_hdr.@"error" < 0) {
            return error.InitFailed;
        }

        const init_out = protocol.parseInitOut(resp_data) orelse return error.ProtocolError;

        // Store negotiated parameters
        self.fuse_major = init_out.major;
        self.fuse_minor = init_out.minor;
        self.fuse_max_write = init_out.max_write;
        self.fuse_max_readahead = init_out.max_readahead;
        self.fuse_flags = init_out.flags;
        self.fuse_initialized = true;

        self.queues.?.request.releaseRequest(pending);

        console.info("VirtIO-FS: FUSE {d}.{d}, max_write={d}", .{
            self.fuse_major,
            self.fuse_minor,
            self.fuse_max_write,
        });
    }

    /// Lookup a name in a directory
    pub fn lookup(self: *Self, parent_nodeid: u64, name: []const u8) FsError!protocol.FuseEntryOut {
        if (name.len > config.Limits.MAX_NAME_LEN) {
            return error.NameTooLong;
        }

        // Check dentry cache first
        if (self.dentries.lookup(parent_nodeid, name)) |cached| {
            // Check if still valid
            const now = hal.timing.getNanoseconds();
            if (now < cached.expire_ns) {
                // Check if it's a negative entry
                if (cached.nodeid == 0) {
                    return error.NotFound;
                }

                // Reconstruct FuseEntryOut from cached data
                if (self.inodes.lookup(cached.nodeid)) |inode| {
                    return protocol.FuseEntryOut{
                        .nodeid = cached.nodeid,
                        .generation = cached.generation,
                        .entry_valid = 0,
                        .attr_valid = 0,
                        .entry_valid_nsec = 0,
                        .attr_valid_nsec = 0,
                        .attr = inode.attr,
                    };
                }
            }
        }

        const held = self.op_lock.acquire();
        defer held.release();

        var req_buf = protocol.FuseBuffer.init(self.getRequestBuf());
        const unique = self.queues.?.request.allocUnique();

        protocol.buildLookup(&req_buf, unique, parent_nodeid, name) catch {
            return error.ProtocolError;
        };

        const pending = self.queues.?.request.submitRequest(
            req_buf.getMessage(),
            self.getResponseBuf(),
            unique,
            .LOOKUP,
        ) orelse return error.QueueFull;

        if (!self.waitForCompletion(pending, 5_000_000_000)) {
            return error.Timeout;
        }

        const resp_data = self.getResponseBuf()[0..pending.response_len];
        const out_hdr = protocol.parseOutHeader(resp_data) orelse return error.ProtocolError;

        if (out_hdr.@"error" < 0) {
            const errno = config.fuseErrorToErrno(out_hdr.@"error");
            self.queues.?.request.releaseRequest(pending);

            // Cache negative result
            self.dentries.insertNegative(parent_nodeid, name, config.Limits.DEFAULT_ENTRY_TTL_SECS * 1_000_000_000);

            return switch (errno) {
                2 => error.NotFound, // ENOENT
                13 => error.PermissionDenied, // EACCES
                20 => error.NotDirectory, // ENOTDIR
                else => error.LookupFailed,
            };
        }

        const entry_out = protocol.parseEntryOut(resp_data) orelse {
            self.queues.?.request.releaseRequest(pending);
            return error.ProtocolError;
        };

        // Cache the result
        const entry_ttl_ns = entry_out.entry_valid * 1_000_000_000 + entry_out.entry_valid_nsec;
        const attr_ttl_ns = entry_out.attr_valid * 1_000_000_000 + entry_out.attr_valid_nsec;

        self.inodes.insert(entry_out.nodeid, entry_out.generation, entry_out.attr, attr_ttl_ns);
        self.dentries.insert(parent_nodeid, name, entry_out.nodeid, entry_out.generation, entry_ttl_ns);

        self.queues.?.request.releaseRequest(pending);
        return entry_out;
    }

    /// Get attributes for a node
    pub fn getAttr(self: *Self, nodeid: u64, fh: ?u64) FsError!protocol.FuseAttrOut {
        // Check inode cache first
        if (fh == null) {
            if (self.inodes.lookup(nodeid)) |cached| {
                const now = hal.timing.getNanoseconds();
                if (now < cached.expire_ns) {
                    return protocol.FuseAttrOut{
                        .attr_valid = 0,
                        .attr_valid_nsec = 0,
                        .dummy = 0,
                        .attr = cached.attr,
                    };
                }
            }
        }

        const held = self.op_lock.acquire();
        defer held.release();

        var req_buf = protocol.FuseBuffer.init(self.getRequestBuf());
        const unique = self.queues.?.request.allocUnique();

        protocol.buildGetAttr(&req_buf, unique, nodeid, fh) catch {
            return error.ProtocolError;
        };

        const pending = self.queues.?.request.submitRequest(
            req_buf.getMessage(),
            self.getResponseBuf(),
            unique,
            .GETATTR,
        ) orelse return error.QueueFull;

        if (!self.waitForCompletion(pending, 5_000_000_000)) {
            return error.Timeout;
        }

        const resp_data = self.getResponseBuf()[0..pending.response_len];
        const out_hdr = protocol.parseOutHeader(resp_data) orelse return error.ProtocolError;

        if (out_hdr.@"error" < 0) {
            self.queues.?.request.releaseRequest(pending);
            return error.GetAttrFailed;
        }

        const attr_out = protocol.parseAttrOut(resp_data) orelse {
            self.queues.?.request.releaseRequest(pending);
            return error.ProtocolError;
        };

        // Update cache
        const ttl_ns = attr_out.attr_valid * 1_000_000_000 + attr_out.attr_valid_nsec;
        self.inodes.updateAttr(nodeid, attr_out.attr, ttl_ns);

        self.queues.?.request.releaseRequest(pending);
        return attr_out;
    }

    /// Open a file/directory
    pub fn open(self: *Self, nodeid: u64, flags: u32, is_dir: bool) FsError!protocol.FuseOpenOut {
        const held = self.op_lock.acquire();
        defer held.release();

        var req_buf = protocol.FuseBuffer.init(self.getRequestBuf());
        const unique = self.queues.?.request.allocUnique();

        if (is_dir) {
            protocol.buildOpenDir(&req_buf, unique, nodeid, flags) catch {
                return error.ProtocolError;
            };
        } else {
            protocol.buildOpen(&req_buf, unique, nodeid, flags) catch {
                return error.ProtocolError;
            };
        }

        const expected_opcode: config.FuseOpcode = if (is_dir) .OPENDIR else .OPEN;

        const pending = self.queues.?.request.submitRequest(
            req_buf.getMessage(),
            self.getResponseBuf(),
            unique,
            expected_opcode,
        ) orelse return error.QueueFull;

        if (!self.waitForCompletion(pending, 5_000_000_000)) {
            return error.Timeout;
        }

        const resp_data = self.getResponseBuf()[0..pending.response_len];
        const out_hdr = protocol.parseOutHeader(resp_data) orelse return error.ProtocolError;

        if (out_hdr.@"error" < 0) {
            self.queues.?.request.releaseRequest(pending);
            const errno = config.fuseErrorToErrno(out_hdr.@"error");
            return switch (errno) {
                2 => error.NotFound,
                13 => error.PermissionDenied,
                21 => error.IsDirectory,
                else => error.OpenFailed,
            };
        }

        const open_out = protocol.parseOpenOut(resp_data) orelse {
            self.queues.?.request.releaseRequest(pending);
            return error.ProtocolError;
        };

        self.queues.?.request.releaseRequest(pending);
        return open_out;
    }

    /// Read from a file
    pub fn read(self: *Self, nodeid: u64, fh: u64, offset: u64, size: u32, out_buf: []u8) FsError!usize {
        const held = self.op_lock.acquire();
        defer held.release();

        const actual_size = @min(size, @as(u32, @intCast(out_buf.len)), self.fuse_max_write);

        var req_buf = protocol.FuseBuffer.init(self.getRequestBuf());
        const unique = self.queues.?.request.allocUnique();

        protocol.buildRead(&req_buf, unique, nodeid, fh, offset, actual_size) catch {
            return error.ProtocolError;
        };

        const pending = self.queues.?.request.submitRequest(
            req_buf.getMessage(),
            self.getResponseBuf(),
            unique,
            .READ,
        ) orelse return error.QueueFull;

        if (!self.waitForCompletion(pending, 10_000_000_000)) {
            return error.Timeout;
        }

        const resp_data = self.getResponseBuf()[0..pending.response_len];
        const out_hdr = protocol.parseOutHeader(resp_data) orelse return error.ProtocolError;

        if (out_hdr.@"error" < 0) {
            self.queues.?.request.releaseRequest(pending);
            return error.ReadFailed;
        }

        const data = protocol.parseReadData(resp_data) orelse {
            self.queues.?.request.releaseRequest(pending);
            return error.ProtocolError;
        };

        const copy_len = @min(data.len, out_buf.len);
        @memcpy(out_buf[0..copy_len], data[0..copy_len]);

        self.queues.?.request.releaseRequest(pending);
        return copy_len;
    }

    /// Write to a file
    pub fn write(self: *Self, nodeid: u64, fh: u64, offset: u64, data: []const u8) FsError!u32 {
        const held = self.op_lock.acquire();
        defer held.release();

        const actual_size: u32 = @intCast(@min(data.len, self.fuse_max_write));

        var req_buf = protocol.FuseBuffer.init(self.getRequestBuf());
        const unique = self.queues.?.request.allocUnique();

        protocol.buildWriteHeader(&req_buf, unique, nodeid, fh, offset, actual_size) catch {
            return error.ProtocolError;
        };

        // Append the data
        req_buf.writeBytes(data[0..actual_size]) catch {
            return error.ProtocolError;
        };
        req_buf.finalize();

        const pending = self.queues.?.request.submitRequest(
            req_buf.getMessage(),
            self.getResponseBuf(),
            unique,
            .WRITE,
        ) orelse return error.QueueFull;

        if (!self.waitForCompletion(pending, 10_000_000_000)) {
            return error.Timeout;
        }

        const resp_data = self.getResponseBuf()[0..pending.response_len];
        const out_hdr = protocol.parseOutHeader(resp_data) orelse return error.ProtocolError;

        if (out_hdr.@"error" < 0) {
            self.queues.?.request.releaseRequest(pending);
            const errno = config.fuseErrorToErrno(out_hdr.@"error");
            return switch (errno) {
                28 => error.NoSpace, // ENOSPC
                else => error.WriteFailed,
            };
        }

        const write_out = protocol.parseWriteOut(resp_data) orelse {
            self.queues.?.request.releaseRequest(pending);
            return error.ProtocolError;
        };

        // Invalidate inode cache (size may have changed)
        self.inodes.invalidate(nodeid);

        self.queues.?.request.releaseRequest(pending);
        return write_out.size;
    }

    /// Release (close) a file handle
    pub fn release(self: *Self, nodeid: u64, fh: u64, flags: u32, is_dir: bool) FsError!void {
        const held = self.op_lock.acquire();
        defer held.release();

        var req_buf = protocol.FuseBuffer.init(self.getRequestBuf());
        const unique = self.queues.?.request.allocUnique();

        protocol.buildRelease(&req_buf, unique, nodeid, fh, flags, is_dir) catch {
            return error.ProtocolError;
        };

        const expected_opcode: config.FuseOpcode = if (is_dir) .RELEASEDIR else .RELEASE;

        const pending = self.queues.?.request.submitRequest(
            req_buf.getMessage(),
            self.getResponseBuf(),
            unique,
            expected_opcode,
        ) orelse return error.QueueFull;

        if (!self.waitForCompletion(pending, 5_000_000_000)) {
            return error.Timeout;
        }

        const resp_data = self.getResponseBuf()[0..pending.response_len];
        const out_hdr = protocol.parseOutHeader(resp_data) orelse return error.ProtocolError;

        if (out_hdr.@"error" < 0) {
            self.queues.?.request.releaseRequest(pending);
            return error.ReleaseFailed;
        }

        self.queues.?.request.releaseRequest(pending);
    }

    /// Read directory entries
    pub fn readDir(self: *Self, nodeid: u64, fh: u64, offset: u64, size: u32, out_buf: []u8) FsError!usize {
        const held = self.op_lock.acquire();
        defer held.release();

        const actual_size = @min(size, @as(u32, @intCast(out_buf.len)));

        var req_buf = protocol.FuseBuffer.init(self.getRequestBuf());
        const unique = self.queues.?.request.allocUnique();

        protocol.buildReadDir(&req_buf, unique, nodeid, fh, offset, actual_size) catch {
            return error.ProtocolError;
        };

        const pending = self.queues.?.request.submitRequest(
            req_buf.getMessage(),
            self.getResponseBuf(),
            unique,
            .READDIR,
        ) orelse return error.QueueFull;

        if (!self.waitForCompletion(pending, 10_000_000_000)) {
            return error.Timeout;
        }

        const resp_data = self.getResponseBuf()[0..pending.response_len];
        const out_hdr = protocol.parseOutHeader(resp_data) orelse return error.ProtocolError;

        if (out_hdr.@"error" < 0) {
            self.queues.?.request.releaseRequest(pending);
            return error.ReadDirFailed;
        }

        const data = protocol.parseReadData(resp_data) orelse {
            self.queues.?.request.releaseRequest(pending);
            return error.ProtocolError;
        };

        const copy_len = @min(data.len, out_buf.len);
        @memcpy(out_buf[0..copy_len], data[0..copy_len]);

        self.queues.?.request.releaseRequest(pending);
        return copy_len;
    }

    /// Create a file
    pub fn create(self: *Self, parent_nodeid: u64, name: []const u8, flags: u32, mode: u32) FsError!struct { entry: protocol.FuseEntryOut, open: protocol.FuseOpenOut } {
        if (name.len > config.Limits.MAX_NAME_LEN) {
            return error.NameTooLong;
        }

        const held = self.op_lock.acquire();
        defer held.release();

        var req_buf = protocol.FuseBuffer.init(self.getRequestBuf());
        const unique = self.queues.?.request.allocUnique();

        protocol.buildCreate(&req_buf, unique, parent_nodeid, name, flags, mode) catch {
            return error.ProtocolError;
        };

        const pending = self.queues.?.request.submitRequest(
            req_buf.getMessage(),
            self.getResponseBuf(),
            unique,
            .CREATE,
        ) orelse return error.QueueFull;

        if (!self.waitForCompletion(pending, 5_000_000_000)) {
            return error.Timeout;
        }

        const resp_data = self.getResponseBuf()[0..pending.response_len];
        const out_hdr = protocol.parseOutHeader(resp_data) orelse return error.ProtocolError;

        if (out_hdr.@"error" < 0) {
            self.queues.?.request.releaseRequest(pending);
            const errno = config.fuseErrorToErrno(out_hdr.@"error");
            return switch (errno) {
                17 => error.Exists, // EEXIST
                28 => error.NoSpace, // ENOSPC
                else => error.CreateFailed,
            };
        }

        // CREATE returns both FuseEntryOut and FuseOpenOut
        const entry_out = protocol.parseEntryOut(resp_data) orelse {
            self.queues.?.request.releaseRequest(pending);
            return error.ProtocolError;
        };

        // FuseOpenOut follows FuseEntryOut in the response
        const open_offset = protocol.FuseOutHeader.SIZE + protocol.FuseEntryOut.SIZE;
        if (pending.response_len < open_offset + protocol.FuseOpenOut.SIZE) {
            self.queues.?.request.releaseRequest(pending);
            return error.ProtocolError;
        }

        const open_out: protocol.FuseOpenOut = @as(*align(1) const protocol.FuseOpenOut, @ptrCast(resp_data[open_offset..].ptr)).*;

        // Cache the new entry
        const entry_ttl_ns = entry_out.entry_valid * 1_000_000_000 + entry_out.entry_valid_nsec;
        const attr_ttl_ns = entry_out.attr_valid * 1_000_000_000 + entry_out.attr_valid_nsec;

        self.inodes.insert(entry_out.nodeid, entry_out.generation, entry_out.attr, attr_ttl_ns);
        self.dentries.insert(parent_nodeid, name, entry_out.nodeid, entry_out.generation, entry_ttl_ns);

        self.queues.?.request.releaseRequest(pending);
        return .{ .entry = entry_out, .open = open_out };
    }

    /// Create a directory
    pub fn mkdir(self: *Self, parent_nodeid: u64, name: []const u8, mode: u32) FsError!protocol.FuseEntryOut {
        if (name.len > config.Limits.MAX_NAME_LEN) {
            return error.NameTooLong;
        }

        const held = self.op_lock.acquire();
        defer held.release();

        var req_buf = protocol.FuseBuffer.init(self.getRequestBuf());
        const unique = self.queues.?.request.allocUnique();

        protocol.buildMkdir(&req_buf, unique, parent_nodeid, name, mode) catch {
            return error.ProtocolError;
        };

        const pending = self.queues.?.request.submitRequest(
            req_buf.getMessage(),
            self.getResponseBuf(),
            unique,
            .MKDIR,
        ) orelse return error.QueueFull;

        if (!self.waitForCompletion(pending, 5_000_000_000)) {
            return error.Timeout;
        }

        const resp_data = self.getResponseBuf()[0..pending.response_len];
        const out_hdr = protocol.parseOutHeader(resp_data) orelse return error.ProtocolError;

        if (out_hdr.@"error" < 0) {
            self.queues.?.request.releaseRequest(pending);
            const errno = config.fuseErrorToErrno(out_hdr.@"error");
            return switch (errno) {
                17 => error.Exists,
                28 => error.NoSpace,
                else => error.MkdirFailed,
            };
        }

        const entry_out = protocol.parseEntryOut(resp_data) orelse {
            self.queues.?.request.releaseRequest(pending);
            return error.ProtocolError;
        };

        // Cache the new entry
        const entry_ttl_ns = entry_out.entry_valid * 1_000_000_000 + entry_out.entry_valid_nsec;
        const attr_ttl_ns = entry_out.attr_valid * 1_000_000_000 + entry_out.attr_valid_nsec;

        self.inodes.insert(entry_out.nodeid, entry_out.generation, entry_out.attr, attr_ttl_ns);
        self.dentries.insert(parent_nodeid, name, entry_out.nodeid, entry_out.generation, entry_ttl_ns);

        self.queues.?.request.releaseRequest(pending);
        return entry_out;
    }

    /// Unlink (delete) a file
    pub fn unlink(self: *Self, parent_nodeid: u64, name: []const u8) FsError!void {
        const held = self.op_lock.acquire();
        defer held.release();

        var req_buf = protocol.FuseBuffer.init(self.getRequestBuf());
        const unique = self.queues.?.request.allocUnique();

        protocol.buildUnlink(&req_buf, unique, parent_nodeid, name) catch {
            return error.ProtocolError;
        };

        const pending = self.queues.?.request.submitRequest(
            req_buf.getMessage(),
            self.getResponseBuf(),
            unique,
            .UNLINK,
        ) orelse return error.QueueFull;

        if (!self.waitForCompletion(pending, 5_000_000_000)) {
            return error.Timeout;
        }

        const resp_data = self.getResponseBuf()[0..pending.response_len];
        const out_hdr = protocol.parseOutHeader(resp_data) orelse return error.ProtocolError;

        if (out_hdr.@"error" < 0) {
            self.queues.?.request.releaseRequest(pending);
            const errno = config.fuseErrorToErrno(out_hdr.@"error");
            return switch (errno) {
                2 => error.NotFound,
                21 => error.IsDirectory,
                else => error.UnlinkFailed,
            };
        }

        // Invalidate caches
        self.dentries.invalidate(parent_nodeid, name);

        self.queues.?.request.releaseRequest(pending);
    }

    /// Remove a directory
    pub fn rmdir(self: *Self, parent_nodeid: u64, name: []const u8) FsError!void {
        const held = self.op_lock.acquire();
        defer held.release();

        var req_buf = protocol.FuseBuffer.init(self.getRequestBuf());
        const unique = self.queues.?.request.allocUnique();

        protocol.buildRmdir(&req_buf, unique, parent_nodeid, name) catch {
            return error.ProtocolError;
        };

        const pending = self.queues.?.request.submitRequest(
            req_buf.getMessage(),
            self.getResponseBuf(),
            unique,
            .RMDIR,
        ) orelse return error.QueueFull;

        if (!self.waitForCompletion(pending, 5_000_000_000)) {
            return error.Timeout;
        }

        const resp_data = self.getResponseBuf()[0..pending.response_len];
        const out_hdr = protocol.parseOutHeader(resp_data) orelse return error.ProtocolError;

        if (out_hdr.@"error" < 0) {
            self.queues.?.request.releaseRequest(pending);
            const errno = config.fuseErrorToErrno(out_hdr.@"error");
            return switch (errno) {
                2 => error.NotFound,
                20 => error.NotDirectory,
                39 => error.NotEmpty, // ENOTEMPTY
                else => error.RmdirFailed,
            };
        }

        // Invalidate caches
        self.dentries.invalidate(parent_nodeid, name);

        self.queues.?.request.releaseRequest(pending);
    }

    /// Rename a file/directory
    pub fn rename(self: *Self, old_parent: u64, old_name: []const u8, new_parent: u64, new_name: []const u8) FsError!void {
        const held = self.op_lock.acquire();
        defer held.release();

        var req_buf = protocol.FuseBuffer.init(self.getRequestBuf());
        const unique = self.queues.?.request.allocUnique();

        protocol.buildRename(&req_buf, unique, old_parent, old_name, new_parent, new_name) catch {
            return error.ProtocolError;
        };

        const pending = self.queues.?.request.submitRequest(
            req_buf.getMessage(),
            self.getResponseBuf(),
            unique,
            .RENAME,
        ) orelse return error.QueueFull;

        if (!self.waitForCompletion(pending, 5_000_000_000)) {
            return error.Timeout;
        }

        const resp_data = self.getResponseBuf()[0..pending.response_len];
        const out_hdr = protocol.parseOutHeader(resp_data) orelse return error.ProtocolError;

        if (out_hdr.@"error" < 0) {
            self.queues.?.request.releaseRequest(pending);
            return error.RenameFailed;
        }

        // Invalidate caches for both old and new locations
        self.dentries.invalidate(old_parent, old_name);
        self.dentries.invalidate(new_parent, new_name);

        self.queues.?.request.releaseRequest(pending);
    }

    /// Get filesystem statistics
    pub fn statfs(self: *Self, nodeid: u64) FsError!protocol.FuseStatfsOut {
        const held = self.op_lock.acquire();
        defer held.release();

        var req_buf = protocol.FuseBuffer.init(self.getRequestBuf());
        const unique = self.queues.?.request.allocUnique();

        protocol.buildStatfs(&req_buf, unique, nodeid) catch {
            return error.ProtocolError;
        };

        const pending = self.queues.?.request.submitRequest(
            req_buf.getMessage(),
            self.getResponseBuf(),
            unique,
            .STATFS,
        ) orelse return error.QueueFull;

        if (!self.waitForCompletion(pending, 5_000_000_000)) {
            return error.Timeout;
        }

        const resp_data = self.getResponseBuf()[0..pending.response_len];
        const out_hdr = protocol.parseOutHeader(resp_data) orelse return error.ProtocolError;

        if (out_hdr.@"error" < 0) {
            self.queues.?.request.releaseRequest(pending);
            return error.StatfsFailed;
        }

        const statfs_out = protocol.parseStatfsOut(resp_data) orelse {
            self.queues.?.request.releaseRequest(pending);
            return error.ProtocolError;
        };

        self.queues.?.request.releaseRequest(pending);
        return statfs_out;
    }

    /// Send FORGET to release server-side reference
    pub fn forget(self: *Self, nodeid: u64, nlookup: u64) void {
        // FORGET is fire-and-forget, use hiprio queue
        var buf: [64]u8 = undefined;
        var req_buf = protocol.FuseBuffer.init(&buf);

        protocol.buildForget(&req_buf, 0, nodeid, nlookup) catch return;

        _ = self.queues.?.hiprio.submitForget(req_buf.getMessage());
    }

    // ========================================================================
    // Public Helpers
    // ========================================================================

    /// Get mount tag
    pub fn getMountTag(self: *const Self) []const u8 {
        return self.mount_tag[0..self.mount_tag_len];
    }

    /// Check if FUSE is initialized
    pub fn isFuseInitialized(self: *const Self) bool {
        return self.fuse_initialized;
    }

    /// Get max write size
    pub fn getMaxWrite(self: *const Self) u32 {
        return self.fuse_max_write;
    }
};

// ============================================================================
// Public Initialization Function
// ============================================================================

/// Initialize VirtIO-FS from PCI device
pub fn initFromPci(pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) FsError!*VirtioFsDevice {
    // Allocate device structure
    const device = heap.allocator().create(VirtioFsDevice) catch {
        return error.AllocationFailed;
    };

    // Initialize
    try device.init(pci_dev, pci_access);

    // Perform FUSE_INIT handshake
    try device.fuseInit();

    return device;
}

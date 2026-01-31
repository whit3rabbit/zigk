// VirtIO-SCSI Controller Driver
//
// Provides block device access to SCSI devices via the VirtIO SCSI protocol.
// This driver initializes the controller, discovers LUNs, and provides
// read/write operations with both synchronous and asynchronous APIs.
//
// Usage:
//   const virtio_scsi = @import("virtio_scsi");
//   var controller = try virtio_scsi.initFromPci(pci_dev, pci_access);
//   try controller.readBlocks(lun_idx, lba, count, buffer);
//
// Reference: VirtIO Specification 1.1, Section 5.6

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const pci = @import("pci");
const vmm = @import("vmm");
const pmm = @import("pmm");
const heap = @import("heap");
const io = @import("io");
const sync = @import("sync");
const dma = @import("dma");
const iommu = @import("iommu");
const virtio = @import("virtio");

pub const config = @import("config.zig");
pub const request = @import("request.zig");
pub const command = @import("command.zig");
pub const lun = @import("lun.zig");
pub const queue = @import("queue.zig");
pub const adapter = @import("adapter.zig");
pub const irq = @import("irq.zig");

// ============================================================================
// Error Types
// ============================================================================

pub const ScsiError = error{
    NotVirtioScsi,
    InvalidBar,
    MappingFailed,
    CapabilityNotFound,
    ResetFailed,
    FeatureNegotiationFailed,
    QueueAllocationFailed,
    AllocationFailed,
    CommandTimeout,
    CommandFailed,
    TransferError,
    InvalidParameter,
    LunNotFound,
    VirtqueueFull,
    DeviceError,
    BufferTooLarge,
    DeviceNotReady,
};

// ============================================================================
// Controller State
// ============================================================================

/// VirtIO-SCSI Controller
pub const VirtioScsiController = struct {
    /// VirtIO common configuration MMIO
    common_cfg: *volatile virtio.VirtioPciCommonCfg,

    /// Notify register base address
    notify_base: u64,

    /// Notify offset multiplier
    notify_off_mult: u32,

    /// ISR register address
    isr_addr: u64,

    /// Device-specific configuration
    device_cfg: *volatile config.VirtioScsiConfig,

    /// Queue set (control, event, request queues)
    queues: queue.ScsiQueueSet,

    /// Discovered LUNs
    luns: [config.Limits.MAX_LUNS]?lun.ScsiLun,

    /// Number of active LUNs
    lun_count: u8,

    /// Device configuration (cached)
    scsi_config: config.VirtioScsiConfig,

    /// Negotiated features
    features: u64,

    /// PCI device reference
    pci_dev: *const pci.PciDevice,

    /// PCI BDF for IOMMU
    bdf: iommu.DeviceBdf,

    /// MSI-X vectors (one per request queue + config)
    msix_vectors: [config.Limits.MAX_REQUEST_QUEUES + 2]?u8,

    /// Whether controller is initialized
    initialized: bool,

    const Self = @This();

    // ========================================================================
    // Initialization
    // ========================================================================

    /// Initialize controller from PCI device
    pub fn init(self: *Self, pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) ScsiError!void {
        self.pci_dev = pci_dev;
        self.initialized = false;
        self.lun_count = 0;
        self.features = 0;

        // Initialize arrays
        for (&self.luns) |*l| l.* = null;
        for (&self.msix_vectors) |*v| v.* = null;
        self.queues = queue.ScsiQueueSet.init();

        // Set up BDF for IOMMU
        self.bdf = iommu.DeviceBdf{
            .bus = pci_dev.bus,
            .device = pci_dev.device,
            .func = pci_dev.func,
        };

        // Verify VirtIO-SCSI device
        if (!isVirtioScsi(pci_dev)) {
            return error.NotVirtioScsi;
        }

        // Get ECAM access
        const ecam = switch (pci_access) {
            .ecam => |e| e,
            .legacy => {
                console.err("VirtIO-SCSI: Legacy PCI access not supported", .{});
                return error.InvalidBar;
            },
        };

        // Enable bus mastering and memory space
        ecam.enableBusMaster(pci_dev.bus, pci_dev.device, pci_dev.func);
        ecam.enableMemorySpace(pci_dev.bus, pci_dev.device, pci_dev.func);

        // Parse VirtIO capabilities and map MMIO regions
        try self.parseCapabilities(pci_dev, ecam);

        // Initialize device per VirtIO spec
        try self.initializeDevice();

        // Set up MSI-X interrupts
        irq.setupMsix(self, pci_access) catch |err| {
            console.warn("VirtIO-SCSI: MSI-X setup failed: {}, using polling", .{err});
        };

        // Enumerate LUNs
        self.enumerateLuns() catch |err| {
            console.warn("VirtIO-SCSI: LUN enumeration failed: {}", .{err});
            // Continue - may have no devices attached
        };

        self.initialized = true;
        console.info("VirtIO-SCSI: Controller initialized, {} LUNs found", .{self.lun_count});
    }

    /// Parse VirtIO PCI capabilities and map MMIO regions
    fn parseCapabilities(self: *Self, pci_dev: *const pci.PciDevice, ecam: pci.Ecam) ScsiError!void {
        // Check if capabilities are supported
        const status = ecam.read16(pci_dev.bus, pci_dev.device, pci_dev.func, 0x06);
        if ((status & 0x10) == 0) {
            return ScsiError.CapabilityNotFound;
        }

        // Get initial capability pointer from offset 0x34
        var cap_ptr = ecam.read8(pci_dev.bus, pci_dev.device, pci_dev.func, 0x34);
        cap_ptr &= 0xFC; // Align to DWORD

        var common_found = false;
        var notify_found = false;
        var device_found = false;

        // Iterate through capabilities
        while (cap_ptr != 0) {
            const cap_id = ecam.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr);
            const next_ptr = ecam.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 1);

            if (cap_id == 0x09) { // VirtIO vendor-specific capability
                const cfg_type = ecam.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 3);
                const bar_idx = ecam.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 4);
                const offset = ecam.read32(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 8);
                _ = ecam.read32(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 12); // length (unused)

                if (bar_idx > 5) {
                    cap_ptr = next_ptr;
                    continue;
                }

                const bar = pci_dev.bar[bar_idx];
                if (!bar.isValid() or !bar.is_mmio) {
                    cap_ptr = next_ptr;
                    continue;
                }

                // Security: Validate offset + structure size fits within BAR
                // A malicious hypervisor could provide an offset that exceeds BAR size,
                // causing kernel memory corruption when dereferencing the computed address.
                const bar_size = bar.size;
                const struct_size: u64 = switch (cfg_type) {
                    virtio.common.VIRTIO_PCI_CAP_COMMON_CFG => @sizeOf(virtio.VirtioPciCommonCfg),
                    virtio.common.VIRTIO_PCI_CAP_NOTIFY_CFG => 4, // Minimum notify size
                    virtio.common.VIRTIO_PCI_CAP_ISR_CFG => 4, // ISR is at least 1 byte, align to 4
                    virtio.common.VIRTIO_PCI_CAP_DEVICE_CFG => @sizeOf(config.VirtioScsiConfig),
                    else => 0,
                };
                if (struct_size > 0 and (offset > bar_size or struct_size > bar_size - offset)) {
                    console.warn("VirtIO-SCSI: Capability offset {x} + size {x} exceeds BAR{d} size {x}", .{ offset, struct_size, bar_idx, bar_size });
                    cap_ptr = next_ptr;
                    continue;
                }

                // Map BAR if not already mapped
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
                        // Read notify_off_mult from capability
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
            console.err("VirtIO-SCSI: Missing required capabilities", .{});
            return error.CapabilityNotFound;
        }
    }

    /// Initialize device per VirtIO spec 3.1.1
    fn initializeDevice(self: *Self) ScsiError!void {
        // 1. Reset device
        self.common_cfg.device_status = 0;
        hal.mmio.memoryBarrier();

        // Wait for reset to complete
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

        // 7. Read device configuration
        self.readDeviceConfig();

        // 8. Set up virtqueues
        try self.setupVirtqueues();

        // 9. Set DRIVER_OK
        self.common_cfg.device_status |= virtio.VIRTIO_STATUS_DRIVER_OK;
        hal.mmio.memoryBarrier();

        console.info("VirtIO-SCSI: Device initialized", .{});
    }

    /// Negotiate features with device
    fn negotiateFeatures(self: *Self) ScsiError!void {
        // Read device features (low 32 bits)
        self.common_cfg.device_feature_select = 0;
        hal.mmio.memoryBarrier();
        var device_features: u64 = self.common_cfg.device_feature;

        // Read device features (high 32 bits)
        self.common_cfg.device_feature_select = 1;
        hal.mmio.memoryBarrier();
        device_features |= @as(u64, self.common_cfg.device_feature) << 32;

        // We require VIRTIO_F_VERSION_1 for modern devices
        if ((device_features & (1 << virtio.VIRTIO_F_VERSION_1)) == 0) {
            console.err("VirtIO-SCSI: VIRTIO_F_VERSION_1 not supported", .{});
            return error.FeatureNegotiationFailed;
        }

        // Accept features we support
        self.features = (1 << virtio.VIRTIO_F_VERSION_1);

        // Optionally accept INOUT feature
        if ((device_features & config.Features.INOUT) != 0) {
            self.features |= config.Features.INOUT;
        }

        // Write our accepted features (low 32 bits)
        self.common_cfg.driver_feature_select = 0;
        hal.mmio.memoryBarrier();
        self.common_cfg.driver_feature = @truncate(self.features);

        // Write our accepted features (high 32 bits)
        self.common_cfg.driver_feature_select = 1;
        hal.mmio.memoryBarrier();
        self.common_cfg.driver_feature = @truncate(self.features >> 32);
    }

    /// Read device-specific configuration
    fn readDeviceConfig(self: *Self) void {
        // Read configuration (volatile reads)
        self.scsi_config.num_queues = self.device_cfg.num_queues;
        self.scsi_config.seg_max = self.device_cfg.seg_max;
        self.scsi_config.max_sectors = self.device_cfg.max_sectors;
        self.scsi_config.cmd_per_lun = self.device_cfg.cmd_per_lun;
        self.scsi_config.event_info_size = self.device_cfg.event_info_size;
        self.scsi_config.sense_size = self.device_cfg.sense_size;
        self.scsi_config.cdb_size = self.device_cfg.cdb_size;
        self.scsi_config.max_channel = self.device_cfg.max_channel;
        self.scsi_config.max_target = self.device_cfg.max_target;
        self.scsi_config.max_lun = self.device_cfg.max_lun;

        console.info("VirtIO-SCSI: {} request queues, max_sectors={}, max_target={}", .{
            self.scsi_config.num_queues,
            self.scsi_config.max_sectors,
            self.scsi_config.max_target,
        });
    }

    /// Set up virtqueues
    fn setupVirtqueues(self: *Self) ScsiError!void {
        const num_queues = self.common_cfg.num_queues;
        console.info("VirtIO-SCSI: Device has {} queues", .{num_queues});

        // Queue 0: Control queue
        self.common_cfg.queue_select = config.QueueIndex.CONTROL;
        hal.mmio.memoryBarrier();
        const ctrl_size = self.common_cfg.queue_size;
        if (ctrl_size > 0) {
            self.queues.control = queue.ScsiQueue.init(.control, config.QueueIndex.CONTROL, ctrl_size);
            if (self.queues.control) |*q| {
                self.configureQueue(config.QueueIndex.CONTROL, q);
            }
        }

        // Queue 1: Event queue
        self.common_cfg.queue_select = config.QueueIndex.EVENT;
        hal.mmio.memoryBarrier();
        const event_size = self.common_cfg.queue_size;
        if (event_size > 0) {
            self.queues.event = queue.ScsiQueue.init(.event, config.QueueIndex.EVENT, event_size);
            if (self.queues.event) |*q| {
                self.configureQueue(config.QueueIndex.EVENT, q);
            }
        }

        // Queue 2+: Request queues
        const req_queue_count = @min(self.scsi_config.num_queues, config.Limits.MAX_REQUEST_QUEUES);
        for (0..req_queue_count) |i| {
            const queue_idx = config.QueueIndex.REQUEST_BASE + @as(u16, @intCast(i));
            self.common_cfg.queue_select = queue_idx;
            hal.mmio.memoryBarrier();

            const q_size = self.common_cfg.queue_size;
            if (q_size == 0) break;

            self.queues.request_queues[i] = queue.ScsiQueue.init(.request, queue_idx, q_size);
            if (self.queues.request_queues[i]) |*q| {
                self.configureQueue(queue_idx, q);
                q.setNotifyAddr(self.notify_base, self.notify_off_mult, self.common_cfg.queue_notify_off);
                self.queues.request_queue_count += 1;
            }
        }

        if (self.queues.request_queue_count == 0) {
            return error.QueueAllocationFailed;
        }

        console.info("VirtIO-SCSI: {} request queues configured", .{self.queues.request_queue_count});
    }

    /// Configure a single queue
    fn configureQueue(self: *Self, queue_idx: u16, q: *queue.ScsiQueue) void {
        self.common_cfg.queue_select = queue_idx;
        hal.mmio.memoryBarrier();

        const addrs = q.getPhysAddrs();
        self.common_cfg.queue_desc = addrs.desc;
        self.common_cfg.queue_avail = addrs.avail;
        self.common_cfg.queue_used = addrs.used;

        // Enable the queue
        self.common_cfg.queue_enable = 1;
        hal.mmio.memoryBarrier();
    }

    // ========================================================================
    // LUN Enumeration
    // ========================================================================

    /// Enumerate available LUNs
    fn enumerateLuns(self: *Self) ScsiError!void {
        // Try REPORT LUNS first
        const report_luns_result = self.tryReportLuns();
        if (report_luns_result) {
            return;
        }

        // Fall back to sequential scan
        console.info("VirtIO-SCSI: Using sequential LUN scan", .{});
        try self.scanLunsSequential();
    }

    /// Try to enumerate LUNs via REPORT LUNS command
    fn tryReportLuns(self: *Self) bool {
        const lun_list_dma = dma.allocBuffer(self.bdf, 256, true) catch return false;
        defer dma.freeBuffer(&lun_list_dma);

        var cdb: [config.Limits.MAX_CDB_SIZE]u8 = undefined;
        command.buildReportLuns(&cdb, 256);

        const result = self.executeCommandSyncDma(0, 0, &cdb, null, lun_list_dma) catch {
            return false;
        };

        if (!result.isSuccess()) return false;

        // Parse response from DMA buffer
        const lun_list = lun_list_dma.slice();
        const header: *const command.ReportLunsHeader = @ptrCast(lun_list.ptr);
        const lun_count = @min(header.lunCount(), config.Limits.MAX_LUNS);

        var i: u32 = 0;
        while (i < lun_count and self.lun_count < config.Limits.MAX_LUNS) : (i += 1) {
            const offset: usize = 8 + i * 8;
            // Bounds check: ensure we don't read past lun_list buffer
            if (offset + 8 > lun_list.len) break;
            const lun_bytes: *const [8]u8 = @ptrCast(&lun_list[offset]);
            const decoded = request.decodeLun(lun_bytes.*);

            self.probeLun(decoded.target, decoded.lun) catch continue;
        }

        return self.lun_count > 0;
    }

    /// Sequential LUN scan
    fn scanLunsSequential(self: *Self) ScsiError!void {
        const max_target = @min(self.scsi_config.max_target, 8); // Limit scan scope

        for (0..max_target) |target| {
            // Try LUN 0 for each target
            self.probeLun(@intCast(target), 0) catch continue;
        }
    }

    /// Probe a single LUN
    fn probeLun(self: *Self, target: u16, lun_num: u32) ScsiError!void {
        if (self.lun_count >= config.Limits.MAX_LUNS) return error.AllocationFailed;

        // Send TEST UNIT READY first to ensure device is ready
        var cdb: [config.Limits.MAX_CDB_SIZE]u8 = undefined;
        command.buildTestUnitReady(&cdb);

        // TEST UNIT READY has no data transfer, just check status
        const dummy_dma = dma.allocBuffer(self.bdf, 4, true) catch
            return error.AllocationFailed;
        defer dma.freeBuffer(&dummy_dma);

        const tur_result = self.executeCommandSyncDma(target, lun_num, &cdb, null, dummy_dma) catch {
            // Device not ready - skip this LUN
            return error.DeviceNotReady;
        };

        // If device returns CHECK CONDITION, it might not be ready - skip
        if (!tur_result.isSuccess()) {
            return error.DeviceNotReady;
        }

        // Allocate DMA buffer for INQUIRY response
        const inquiry_dma = dma.allocBuffer(self.bdf, 36, true) catch
            return error.AllocationFailed;
        defer dma.freeBuffer(&inquiry_dma);

        // Send INQUIRY
        command.buildInquiry(&cdb, 36);

        const result = self.executeCommandSyncDma(target, lun_num, &cdb, null, inquiry_dma) catch {
            return error.CommandFailed;
        };

        if (!result.isSuccess()) return error.DeviceError;

        // Parse INQUIRY from DMA buffer
        const inquiry: *const command.InquiryData = @ptrCast(@alignCast(inquiry_dma.getVirt()));
        if (!inquiry.isPresent()) return error.LunNotFound;

        // Initialize LUN
        var scsi_lun = lun.ScsiLun.initFromInquiry(@intCast(self.lun_count), target, lun_num, inquiry);

        // Get capacity if it's a block device
        if (scsi_lun.isBlockDevice()) {
            self.getLunCapacity(&scsi_lun) catch {
                // Non-fatal - device might not be ready
            };
        }

        // Store LUN
        self.luns[self.lun_count] = scsi_lun;
        self.lun_count += 1;

        console.info("VirtIO-SCSI: LUN {d}:{d} - {s} {s}, {} MB", .{
            target,
            lun_num,
            scsi_lun.vendorStr(),
            scsi_lun.productStr(),
            scsi_lun.capacityMB(),
        });
    }

    /// Get LUN capacity
    fn getLunCapacity(self: *Self, scsi_lun: *lun.ScsiLun) ScsiError!void {
        // Allocate DMA buffer for capacity response
        const cap_dma = dma.allocBuffer(self.bdf, 8, true) catch |err| {
            console.warn("VirtIO-SCSI: Failed to allocate DMA buffer for capacity: {}", .{err});
            return error.AllocationFailed;
        };
        defer dma.freeBuffer(&cap_dma);

        var cdb: [config.Limits.MAX_CDB_SIZE]u8 = undefined;
        command.buildReadCapacity10(&cdb);

        const result = self.executeCommandSyncDma(
            scsi_lun.target,
            scsi_lun.lun,
            &cdb,
            null,
            cap_dma,
        ) catch |err| {
            console.warn("VirtIO-SCSI: READ CAPACITY command failed: {}", .{err});
            return error.CommandFailed;
        };

        if (!result.isSuccess()) {
            console.warn("VirtIO-SCSI: READ CAPACITY returned error status: {x}", .{result.status});
            return error.DeviceError;
        }

        const cap_data: *const command.ReadCapacity10Data = @ptrCast(@alignCast(cap_dma.getVirt()));
        console.info("VirtIO-SCSI: READ CAPACITY returned: last_lba={x}, block_size={}", .{
            cap_data.lastLba(),
            cap_data.blockSize(),
        });
        scsi_lun.updateCapacity10(cap_data);

        // If device reports 0xFFFFFFFF, try READ CAPACITY (16)
        if (cap_data.needsCapacity16()) {
            const cap16_dma = dma.allocBuffer(self.bdf, 32, true) catch return;
            defer dma.freeBuffer(&cap16_dma);

            command.buildReadCapacity16(&cdb, 32);

            const result16 = self.executeCommandSyncDma(
                scsi_lun.target,
                scsi_lun.lun,
                &cdb,
                null,
                cap16_dma,
            ) catch return;

            if (result16.isSuccess()) {
                const cap16_data: *const command.ReadCapacity16Data = @ptrCast(@alignCast(cap16_dma.getVirt()));
                scsi_lun.updateCapacity16(cap16_data);
            }
        }
    }

    // ========================================================================
    // Command Execution
    // ========================================================================

    /// Execute a SCSI command synchronously
    pub fn executeCommandSync(
        self: *Self,
        target: u16,
        lun_num: u32,
        cdb: []const u8,
        data_out: ?[]const u8,
        data_in: ?[]u8,
    ) ScsiError!request.ScsiResponseCmd {
        // Allocate DMA buffers
        const req_dma = dma.allocBuffer(self.bdf, @sizeOf(request.ScsiRequestCmd), false) catch
            return error.AllocationFailed;
        defer dma.freeBuffer(&req_dma);

        const resp_dma = dma.allocBuffer(self.bdf, @sizeOf(request.ScsiResponseCmd), true) catch
            return error.AllocationFailed;
        defer dma.freeBuffer(&resp_dma);

        // Build request header (zero-init first for security)
        const req_ptr: *request.ScsiRequestCmd = @ptrCast(@alignCast(req_dma.getVirt()));
        @memset(std.mem.asBytes(req_ptr), 0);
        req_ptr.lun = request.encodeLun(target, lun_num);
        req_ptr.tag = request.generateTag();
        req_ptr.task_attr = @intFromEnum(request.TaskAttr.SIMPLE);

        // Copy CDB
        const cdb_len = @min(cdb.len, config.Limits.MAX_CDB_SIZE);
        @memcpy(req_ptr.cdb[0..cdb_len], cdb[0..cdb_len]);

        // Zero-init response buffer (security: prevents info leak)
        const resp_ptr: *request.ScsiResponseCmd = @ptrCast(@alignCast(resp_dma.getVirt()));
        @memset(std.mem.asBytes(resp_ptr), 0);

        // Get a request queue
        const q = self.queues.selectRequestQueue() orelse return error.VirtqueueFull;

        // Build descriptor chain using physical addresses from DMA buffers
        const DmaBuf = virtio.Virtqueue.DmaBuf;
        var out_bufs: [2]DmaBuf = undefined;
        var out_count: usize = 0;

        out_bufs[out_count] = .{
            .phys_addr = req_dma.device_addr,
            .len = @intCast(@sizeOf(request.ScsiRequestCmd)),
        };
        out_count += 1;

        if (data_out) |d| {
            // For data_out, we need the physical address - caller must provide DMA buffer
            // For now, this will panic if data_out is not in HHDM (requires API change)
            out_bufs[out_count] = .{
                .phys_addr = hal.paging.virtToPhys(@intFromPtr(d.ptr)),
                .len = std.math.cast(u32, d.len) orelse return error.BufferTooLarge,
            };
            out_count += 1;
        }

        var in_bufs: [2]DmaBuf = undefined;
        var in_count: usize = 0;

        in_bufs[in_count] = .{
            .phys_addr = resp_dma.device_addr,
            .len = @intCast(@sizeOf(request.ScsiResponseCmd)),
        };
        in_count += 1;

        if (data_in) |d| {
            // For data_in, we need the physical address - caller must provide DMA buffer
            // For now, this will panic if data_in is not in HHDM (requires API change)
            in_bufs[in_count] = .{
                .phys_addr = hal.paging.virtToPhys(@intFromPtr(d.ptr)),
                .len = std.math.cast(u32, d.len) orelse return error.BufferTooLarge,
            };
            in_count += 1;
        }

        // Submit to virtqueue using DMA-safe API
        const head = q.vq.addBufDma(out_bufs[0..out_count], in_bufs[0..in_count]) orelse
            return error.VirtqueueFull;

        // Notify device
        q.kick();

        // Poll for completion (synchronous)
        const timeout_ns: u64 = 5_000_000_000; // 5 seconds
        const start = hal.timing.getNanoseconds();
        while (true) {
            const now = hal.timing.getNanoseconds();
            if (now >= start and (now - start) > timeout_ns) {
                return error.CommandTimeout;
            }
            if (q.vq.getUsed()) |used| {
                if (used.head == head) {
                    return resp_ptr.*;
                }
            }
            hal.cpu.pause();
        }
    }

    /// Execute a SCSI command synchronously with DMA buffer for data_in
    /// This variant avoids virtToPhys issues by accepting pre-allocated DMA buffers
    fn executeCommandSyncDma(
        self: *Self,
        target: u16,
        lun_num: u32,
        cdb: []const u8,
        data_out_dma: ?dma.DmaBuffer,
        data_in_dma: ?dma.DmaBuffer,
    ) ScsiError!request.ScsiResponseCmd {
        // Allocate DMA buffers for request/response headers
        const req_dma = dma.allocBuffer(self.bdf, @sizeOf(request.ScsiRequestCmd), false) catch
            return error.AllocationFailed;
        defer dma.freeBuffer(&req_dma);

        const resp_dma = dma.allocBuffer(self.bdf, @sizeOf(request.ScsiResponseCmd), true) catch
            return error.AllocationFailed;
        defer dma.freeBuffer(&resp_dma);

        // Build request header
        const req_ptr: *request.ScsiRequestCmd = @ptrCast(@alignCast(req_dma.getVirt()));
        @memset(std.mem.asBytes(req_ptr), 0);
        req_ptr.lun = request.encodeLun(target, lun_num);
        req_ptr.tag = request.generateTag();
        req_ptr.task_attr = @intFromEnum(request.TaskAttr.SIMPLE);

        const cdb_len = @min(cdb.len, config.Limits.MAX_CDB_SIZE);
        @memcpy(req_ptr.cdb[0..cdb_len], cdb[0..cdb_len]);

        const resp_ptr: *request.ScsiResponseCmd = @ptrCast(@alignCast(resp_dma.getVirt()));
        @memset(std.mem.asBytes(resp_ptr), 0);

        const q = self.queues.selectRequestQueue() orelse return error.VirtqueueFull;

        // Build descriptor chain
        const DmaBuf = virtio.Virtqueue.DmaBuf;
        var out_bufs: [2]DmaBuf = undefined;
        var out_count: usize = 0;

        out_bufs[out_count] = .{
            .phys_addr = req_dma.device_addr,
            .len = @intCast(@sizeOf(request.ScsiRequestCmd)),
        };
        out_count += 1;

        if (data_out_dma) |d| {
            console.info("VirtIO-SCSI: Adding data_out DMA buf: phys=0x{X}, device=0x{X}, len={}", .{
                d.phys_addr, d.device_addr, d.size
            });
            out_bufs[out_count] = .{
                .phys_addr = d.device_addr,
                .len = std.math.cast(u32, d.size) orelse return error.BufferTooLarge,
            };
            out_count += 1;
        }

        var in_bufs: [2]DmaBuf = undefined;
        var in_count: usize = 0;

        in_bufs[in_count] = .{
            .phys_addr = resp_dma.device_addr,
            .len = @intCast(@sizeOf(request.ScsiResponseCmd)),
        };
        in_count += 1;

        // Use DMA buffer for data_in (if provided)
        if (data_in_dma) |d| {
            in_bufs[in_count] = .{
                .phys_addr = d.device_addr,
                .len = std.math.cast(u32, d.size) orelse return error.BufferTooLarge,
            };
            in_count += 1;
        }

        const head = q.vq.addBufDma(out_bufs[0..out_count], in_bufs[0..in_count]) orelse
            return error.VirtqueueFull;

        q.kick();

        // Poll for completion
        const timeout_ns: u64 = 5_000_000_000;
        const start = hal.timing.getNanoseconds();
        while (true) {
            const now = hal.timing.getNanoseconds();
            if (now >= start and (now - start) > timeout_ns) {
                console.warn("VirtIO-SCSI: Command timeout!", .{});
                return error.CommandTimeout;
            }
            if (q.vq.getUsed()) |used| {
                if (used.head == head) {
                    const result = resp_ptr.*;
                    console.info("VirtIO-SCSI: Command complete: status=0x{X}, response=0x{X}, residual={}", .{
                        result.status, result.response, result.residual
                    });
                    return result;
                }
            }
            hal.cpu.pause();
        }
    }

    // ========================================================================
    // Block I/O
    // ========================================================================

    /// Read blocks synchronously
    pub fn readBlocks(
        self: *Self,
        lun_idx: u8,
        lba: u64,
        block_count: u32,
        buffer: []u8,
    ) ScsiError!usize {
        if (lun_idx >= self.lun_count) return error.LunNotFound;
        const scsi_lun = self.luns[lun_idx] orelse return error.LunNotFound;

        // Validate parameters
        const transfer_size = std.math.mul(usize, block_count, scsi_lun.block_size) catch
            return error.InvalidParameter;
        if (buffer.len < transfer_size) return error.InvalidParameter;

        // Allocate DMA buffer for data transfer
        const data_dma = dma.allocBuffer(self.bdf, transfer_size, true) catch
            return error.AllocationFailed;
        defer dma.freeBuffer(&data_dma);

        // Build CDB based on LBA size
        var cdb: [config.Limits.MAX_CDB_SIZE]u8 = undefined;
        if (lba > 0xFFFFFFFF or block_count > 0xFFFF) {
            command.buildRead16(&cdb, lba, block_count);
        } else {
            command.buildRead10(&cdb, @truncate(lba), @truncate(block_count));
        }

        // Execute command with DMA buffer
        const result = try self.executeCommandSyncDma(
            scsi_lun.target,
            scsi_lun.lun,
            &cdb,
            null, // data_out_dma
            data_dma, // data_in_dma
        );

        if (!result.isSuccess()) return error.TransferError;

        // Calculate bytes transferred (validate residual from device)
        if (result.residual > transfer_size) return error.DeviceError;
        const transferred = transfer_size - result.residual;

        // Copy from DMA buffer to user buffer
        const src: [*]const u8 = @ptrCast(data_dma.getVirt());
        @memcpy(buffer[0..transferred], src[0..transferred]);

        return transferred;
    }

    /// Write blocks synchronously
    pub fn writeBlocks(
        self: *Self,
        lun_idx: u8,
        lba: u64,
        block_count: u32,
        buffer: []const u8,
    ) ScsiError!usize {
        if (lun_idx >= self.lun_count) return error.LunNotFound;
        const scsi_lun = self.luns[lun_idx] orelse return error.LunNotFound;

        // Validate parameters
        const transfer_size = std.math.mul(usize, block_count, scsi_lun.block_size) catch
            return error.InvalidParameter;
        if (buffer.len < transfer_size) return error.InvalidParameter;

        // Allocate DMA buffer for write data
        const data_dma = dma.allocBuffer(self.bdf, transfer_size, false) catch
            return error.AllocationFailed;
        defer dma.freeBuffer(&data_dma);

        // Copy user data to DMA buffer
        const dest: [*]u8 = @ptrCast(data_dma.getVirt());
        @memcpy(dest[0..transfer_size], buffer[0..transfer_size]);

        // Build CDB based on LBA size
        var cdb: [config.Limits.MAX_CDB_SIZE]u8 = undefined;
        if (lba > 0xFFFFFFFF or block_count > 0xFFFF) {
            command.buildWrite16(&cdb, lba, block_count);
        } else {
            command.buildWrite10(&cdb, @truncate(lba), @truncate(block_count));
        }

        // Execute command with DMA buffer - preserves physical address for aarch64 compatibility
        const result = try self.executeCommandSyncDma(
            scsi_lun.target,
            scsi_lun.lun,
            &cdb,
            data_dma, // data_out_dma
            null, // data_in_dma
        );

        if (!result.isSuccess()) return error.TransferError;

        // Calculate bytes transferred (validate residual from device)
        if (result.residual > transfer_size) return error.DeviceError;
        const transferred = transfer_size - result.residual;
        return transferred;
    }

    // ========================================================================
    // Interrupt Handling
    // ========================================================================

    /// Handle interrupt (called from IRQ handler)
    pub fn handleInterrupt(self: *Self) void {
        // Process completions on all request queues
        for (0..self.queues.request_queue_count) |i| {
            if (self.queues.request_queues[i]) |*q| {
                self.processQueueCompletion(q);
            }
        }
    }

    /// Process completions on a single queue
    pub fn processQueueCompletion(self: *Self, q: *queue.ScsiQueue) void {
        _ = self;
        while (q.hasPending()) {
            const used = q.getUsed() orelse break;

            // Get pending request
            const pending = q.takePending(used.head) orelse continue;

            // Parse response
            const resp: *const request.ScsiResponseCmd = @ptrCast(@alignCast(pending.resp_dma.getVirt()));

            // Complete IoRequest
            if (resp.isSuccess()) {
                // Validate residual from device to prevent underflow
                const bytes = if (resp.residual > pending.expected_bytes)
                    0
                else
                    pending.expected_bytes - resp.residual;
                _ = pending.io_request.complete(.{ .success = bytes });
            } else {
                _ = pending.io_request.complete(.{ .err = error.EIO });
            }

            // Free DMA buffers
            dma.freeBuffer(&pending.req_dma);
            dma.freeBuffer(&pending.resp_dma);
            if (pending.data_dma) |*d| dma.freeBuffer(d);

            // Free pending structure
            heap.allocator().destroy(pending);
        }
    }

    // ========================================================================
    // Accessors
    // ========================================================================

    /// Get the number of LUNs
    pub fn getLunCount(self: *const Self) u8 {
        return self.lun_count;
    }

    /// Get a LUN by index
    pub fn getLun(self: *Self, idx: u8) ?*const lun.ScsiLun {
        if (idx >= self.lun_count) return null;
        if (self.luns[idx]) |*l| return l;
        return null;
    }
};

// ============================================================================
// Global Controller Instance
// ============================================================================

var controller_instance: ?*VirtioScsiController = null;

/// Get the global controller instance
pub fn getController() ?*VirtioScsiController {
    return controller_instance;
}

/// Initialize controller from PCI device
pub fn initFromPci(
    pci_dev: *const pci.PciDevice,
    pci_access: pci.PciAccess,
) ScsiError!*VirtioScsiController {
    // Allocate controller
    const controller = heap.allocator().create(VirtioScsiController) catch
        return error.AllocationFailed;
    errdefer heap.allocator().destroy(controller);

    // Initialize
    try controller.init(pci_dev, pci_access);

    // Store global instance
    controller_instance = controller;

    return controller;
}

/// Check if a PCI device is a VirtIO-SCSI controller
pub fn isVirtioScsi(pci_dev: *const pci.PciDevice) bool {
    if (pci_dev.vendor_id != config.PCI_VENDOR_VIRTIO) return false;

    return pci_dev.device_id == config.PCI_DEVICE_SCSI_MODERN or
        pci_dev.device_id == config.PCI_DEVICE_SCSI_LEGACY;
}

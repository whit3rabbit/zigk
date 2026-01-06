// NVMe Controller Driver
//
// Provides block device access to NVMe namespaces via the NVM Express protocol.
// This driver initializes the controller, discovers namespaces, and provides
// read/write operations with both synchronous and asynchronous APIs.
//
// Usage:
//   const nvme = @import("nvme");
//   var controller = try nvme.initFromPci(pci_dev, pci_access);
//   try controller.readBlocks(nsid, lba, count, buffer);
//
// Reference: NVM Express Base Specification 2.0

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

pub const regs = @import("regs.zig");
pub const queue = @import("queue.zig");
pub const command = @import("command.zig");
pub const namespace = @import("namespace.zig");
pub const init_mod = @import("init.zig");
pub const adapter = @import("adapter.zig");
pub const irq_mod = @import("irq.zig");

// ============================================================================
// Constants
// ============================================================================

/// Maximum I/O queues (excluding admin queue)
pub const MAX_IO_QUEUES: usize = 16;

/// Maximum namespaces supported
pub const MAX_NAMESPACES: usize = 16;

/// Default sector size (will be overridden by namespace LBA size)
pub const SECTOR_SIZE: usize = 512;

/// Maximum blocks per transfer (limited by PRP list and MDTS)
pub const MAX_BLOCKS_PER_TRANSFER: usize = 256;

/// NVMe PCI class codes
pub const PCI_CLASS_STORAGE: u8 = 0x01;
pub const PCI_SUBCLASS_NVME: u8 = 0x08;
pub const PCI_PROGIF_NVME: u8 = 0x02;

// ============================================================================
// Error Types
// ============================================================================

pub const NvmeError = error{
    NotNvmeController,
    InvalidBar,
    MappingFailed,
    ResetTimeout,
    EnableTimeout,
    FatalError,
    AllocationFailed,
    QueueCreationFailed,
    CommandTimeout,
    CommandFailed,
    TransferError,
    InvalidParameter,
    NamespaceNotFound,
    NoCapacity,
};

// ============================================================================
// Namespace Info
// ============================================================================

/// Per-namespace state
pub const NvmeNamespace = struct {
    /// Namespace ID (1-based)
    nsid: u32,
    /// Whether namespace is active
    active: bool,
    /// LBA size in bytes
    lba_size: u32,
    /// Total number of LBAs
    total_lbas: u64,
    /// Capacity in bytes
    capacity_bytes: u64,
    /// Metadata size per LBA
    metadata_size: u16,
    /// Supports TRIM/deallocate
    supports_trim: bool,
    /// Identify data (cached)
    identify: ?*namespace.IdentifyNamespace,
};

// ============================================================================
// Controller State
// ============================================================================

/// NVMe Controller
pub const NvmeController = struct {
    /// BAR0 register access
    nvme_regs: regs.NvmeRegs,

    /// Controller capabilities
    cap: regs.Capabilities,

    /// Version
    version: regs.Version,

    /// Doorbell stride in bytes
    doorbell_stride: u32,

    /// Admin queue
    admin_queue: queue.QueuePair,

    /// I/O queues (1 to MAX_IO_QUEUES)
    io_queues: [MAX_IO_QUEUES]?queue.QueuePair,
    io_queue_count: u8,

    /// Namespaces
    namespaces: [MAX_NAMESPACES]?NvmeNamespace,
    namespace_count: u8,

    /// Identify Controller data
    identify_ctrl: ?*namespace.IdentifyController,

    /// PCI device reference
    pci_dev: *const pci.PciDevice,

    /// PCI BDF for IOMMU
    bdf: iommu.DeviceBdf,

    /// MSI-X vectors (one per queue)
    msix_vectors: [MAX_IO_QUEUES + 1]?u8,

    /// Whether controller is initialized
    initialized: bool,

    /// Lock for I/O operations
    io_lock: sync.Spinlock,

    /// Round-robin I/O queue index (atomic)
    io_queue_idx: std.atomic.Value(u32),

    const Self = @This();

    // ========================================================================
    // Initialization
    // ========================================================================

    /// Initialize controller from PCI device
    pub fn init(self: *Self, pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) NvmeError!void {
        self.pci_dev = pci_dev;
        self.initialized = false;
        self.io_lock = .{};
        self.io_queue_idx = std.atomic.Value(u32).init(0);
        self.io_queue_count = 0;
        self.namespace_count = 0;
        self.identify_ctrl = null;

        // Initialize arrays
        for (&self.io_queues) |*q| q.* = null;
        for (&self.namespaces) |*ns| ns.* = null;
        for (&self.msix_vectors) |*v| v.* = null;

        // Set up BDF for IOMMU
        self.bdf = iommu.DeviceBdf{
            .bus = pci_dev.bus,
            .device = pci_dev.device,
            .func = pci_dev.func,
        };

        // Verify NVMe controller
        if (pci_dev.class_code != PCI_CLASS_STORAGE or
            pci_dev.subclass != PCI_SUBCLASS_NVME or
            pci_dev.prog_if != PCI_PROGIF_NVME)
        {
            return error.NotNvmeController;
        }

        // Get BAR0 (64-bit MMIO)
        const bar0 = pci_dev.bar[0];
        if (!bar0.isValid() or !bar0.is_mmio) {
            console.err("NVMe: Invalid BAR0", .{});
            return error.InvalidBar;
        }

        // Enable bus master and memory space
        const ecam = switch (pci_access) {
            .ecam => |e| e,
            .legacy => {
                console.err("NVMe: Legacy PCI access not supported", .{});
                return error.InvalidBar;
            },
        };

        // Enable bus mastering and memory space access
        ecam.enableBusMaster(pci_dev.bus, pci_dev.device, pci_dev.func);
        ecam.enableMemorySpace(pci_dev.bus, pci_dev.device, pci_dev.func);

        // Map BAR0
        const bar_size = if (bar0.size > 0) bar0.size else 0x4000; // Default 16KB
        const bar_virt = vmm.mapMmio(bar0.base, bar_size) catch {
            console.err("NVMe: Failed to map BAR0 at 0x{x}", .{bar0.base});
            return error.MappingFailed;
        };

        self.nvme_regs = regs.NvmeRegs.init(bar_virt, bar_size);

        // Read capabilities
        self.cap = self.nvme_regs.readCapabilities();
        self.version = self.nvme_regs.readVersion();
        self.doorbell_stride = self.cap.doorbellStride();

        const ver = self.version.format();
        console.info("NVMe: Version {}.{}.{}", .{ ver.major, ver.minor, ver.tertiary });
        console.info("NVMe: Max queue entries: {}, Doorbell stride: {} bytes", .{
            self.cap.maxQueueEntries(),
            self.doorbell_stride,
        });

        // Verify NVM command set is supported
        if (!self.cap.supportsNvmCommandSet()) {
            console.err("NVMe: NVM command set not supported", .{});
            return error.InvalidParameter;
        }

        // Disable controller
        init_mod.disableController(self.nvme_regs, init_mod.Timeouts.RESET_MS) catch |err| {
            console.err("NVMe: Failed to disable controller", .{});
            return mapInitError(err);
        };

        // Configure controller
        init_mod.configureController(self.nvme_regs, self.cap) catch |err| {
            console.err("NVMe: Failed to configure controller", .{});
            return mapInitError(err);
        };

        // Allocate admin queue
        self.admin_queue = init_mod.allocateQueuePair(
            0, // QID 0 = admin
            init_mod.ADMIN_QUEUE_SIZE,
            self.doorbell_stride,
            self.bdf,
        ) catch |err| {
            console.err("NVMe: Failed to allocate admin queue", .{});
            return mapInitError(err);
        };
        errdefer init_mod.freeQueuePair(&self.admin_queue, self.bdf);

        // Configure admin queue registers
        init_mod.configureAdminQueues(self.nvme_regs, &self.admin_queue);

        // Enable controller
        init_mod.enableController(self.nvme_regs, self.cap.timeoutMs()) catch |err| {
            console.err("NVMe: Failed to enable controller", .{});
            return mapInitError(err);
        };

        console.info("NVMe: Controller enabled", .{});

        // Identify controller
        self.identify_ctrl = init_mod.identifyController(
            self.nvme_regs,
            &self.admin_queue,
            self.bdf,
        ) catch |err| {
            console.err("NVMe: Failed to identify controller", .{});
            return mapInitError(err);
        };

        if (self.identify_ctrl) |id| {
            console.info("NVMe: Model: {s}", .{id.modelNumber()});
            console.info("NVMe: Serial: {s}", .{id.serialNumber()});
            console.info("NVMe: Firmware: {s}", .{id.firmwareRevision()});
            console.info("NVMe: Namespaces: {}", .{id.nn});
        }

        // Set number of queues
        const queue_result = init_mod.setNumQueues(
            self.nvme_regs,
            &self.admin_queue,
            MAX_IO_QUEUES,
            MAX_IO_QUEUES,
        ) catch |err| {
            console.warn("NVMe: Failed to set queue count: {}", .{err});
            // Continue with just admin queue
            self.io_queue_count = 0;
            self.discoverNamespaces() catch |ns_err| {
                console.err("NVMe: Failed to discover namespaces", .{});
                return ns_err; // ns_err is already NvmeError
            };
            self.initialized = true;
            return;
        };

        const allocated_queues = @min(queue_result.sq, queue_result.cq);
        console.info("NVMe: Allocated {} I/O queues", .{allocated_queues});

        // Create I/O queues
        try self.createIoQueues(@intCast(@min(allocated_queues, MAX_IO_QUEUES)));

        // Discover namespaces
        try self.discoverNamespaces();

        self.initialized = true;
        console.info("NVMe: Initialization complete", .{});
    }

    /// Create I/O queue pairs
    fn createIoQueues(self: *Self, count: u8) NvmeError!void {
        var created: u8 = 0;

        for (0..count) |i| {
            const qid: u16 = @intCast(i + 1); // QID 1+

            // Allocate queue pair
            var qp = init_mod.allocateQueuePair(
                qid,
                init_mod.IO_QUEUE_SIZE,
                self.doorbell_stride,
                self.bdf,
            ) catch {
                console.warn("NVMe: Failed to allocate I/O queue {}", .{qid});
                break;
            };
            errdefer init_mod.freeQueuePair(&qp, self.bdf);

            // Create CQ first (required by spec)
            init_mod.createIoCq(
                self.nvme_regs,
                &self.admin_queue,
                &qp,
                0, // IV = 0 for now (polling mode)
            ) catch |err| {
                console.warn("NVMe: Failed to create I/O CQ {}: {}", .{ qid, err });
                init_mod.freeQueuePair(&qp, self.bdf);
                break;
            };

            // Create SQ
            init_mod.createIoSq(
                self.nvme_regs,
                &self.admin_queue,
                &qp,
            ) catch |err| {
                console.warn("NVMe: Failed to create I/O SQ {}: {}", .{ qid, err });
                // Try to delete the CQ we created
                init_mod.deleteIoCq(self.nvme_regs, &self.admin_queue, qid) catch {};
                init_mod.freeQueuePair(&qp, self.bdf);
                break;
            };

            self.io_queues[i] = qp;
            created += 1;
        }

        self.io_queue_count = created;
        console.info("NVMe: Created {} I/O queue pairs", .{created});
    }

    /// Discover active namespaces
    fn discoverNamespaces(self: *Self) NvmeError!void {
        const id_ctrl = self.identify_ctrl orelse return error.CommandFailed;

        // Get active namespace list
        const ns_list = init_mod.getActiveNamespaceList(
            self.nvme_regs,
            &self.admin_queue,
            0, // Start from NSID 0
            self.bdf,
        ) catch |err| {
            console.warn("NVMe: Failed to get namespace list: {}", .{err});
            // Fall back to sequential scan
            return self.discoverNamespacesSequential(id_ctrl.nn);
        };
        defer heap.allocator().destroy(ns_list);

        var iter = ns_list.iterator();
        var count: u8 = 0;

        while (iter.next()) |nsid| {
            if (count >= MAX_NAMESPACES) break;

            const id_ns = init_mod.identifyNamespace(
                self.nvme_regs,
                &self.admin_queue,
                nsid,
                self.bdf,
            ) catch |err| {
                console.warn("NVMe: Failed to identify namespace {}: {}", .{ nsid, err });
                continue;
            };

            const lba_size = id_ns.lbaSize();
            // SECURITY FIX: Validate lba_size to prevent division-by-zero.
            // Malicious/buggy hardware could report lbads=0 causing lba_size=0.
            // Minimum valid LBA size is 512 bytes (2^9).
            if (id_ns.nsze > 0 and lba_size >= 512) {
                self.namespaces[count] = NvmeNamespace{
                    .nsid = nsid,
                    .active = true,
                    .lba_size = lba_size,
                    .total_lbas = id_ns.nsze,
                    .capacity_bytes = id_ns.capacityBytes(),
                    .metadata_size = id_ns.metadataSize(),
                    .supports_trim = id_ctrl.supportsDatasetManagement(),
                    .identify = id_ns,
                };

                console.info("NVMe: Namespace {}: {} LBAs, {} bytes/LBA, {} MB", .{
                    nsid,
                    id_ns.nsze,
                    lba_size,
                    id_ns.capacityBytes() / (1024 * 1024),
                });

                count += 1;
            } else {
                if (id_ns.nsze > 0 and lba_size < 512) {
                    console.warn("NVMe: Namespace {} has invalid LBA size {}, skipping", .{ nsid, lba_size });
                }
                heap.allocator().destroy(id_ns);
            }
        }

        self.namespace_count = count;

        if (count == 0) {
            console.warn("NVMe: No active namespaces found", .{});
        }
    }

    /// Discover namespaces by sequential enumeration
    fn discoverNamespacesSequential(self: *Self, max_nsid: u32) NvmeError!void {
        const id_ctrl = self.identify_ctrl orelse return error.CommandFailed;
        var count: u8 = 0;

        for (1..@min(max_nsid + 1, MAX_NAMESPACES + 1)) |i| {
            const nsid: u32 = @intCast(i);

            const id_ns = init_mod.identifyNamespace(
                self.nvme_regs,
                &self.admin_queue,
                nsid,
                self.bdf,
            ) catch {
                continue;
            };

            const lba_size = id_ns.lbaSize();
            // SECURITY FIX: Validate lba_size (same as discoverNamespaces)
            if (id_ns.nsze > 0 and lba_size >= 512) {
                self.namespaces[count] = NvmeNamespace{
                    .nsid = nsid,
                    .active = true,
                    .lba_size = lba_size,
                    .total_lbas = id_ns.nsze,
                    .capacity_bytes = id_ns.capacityBytes(),
                    .metadata_size = id_ns.metadataSize(),
                    .supports_trim = id_ctrl.supportsDatasetManagement(),
                    .identify = id_ns,
                };

                console.info("NVMe: Namespace {}: {} MB", .{
                    nsid,
                    id_ns.capacityBytes() / (1024 * 1024),
                });

                count += 1;
            } else {
                if (id_ns.nsze > 0 and lba_size < 512) {
                    console.warn("NVMe: Namespace {} has invalid LBA size {}, skipping", .{ nsid, lba_size });
                }
                heap.allocator().destroy(id_ns);
            }
        }

        self.namespace_count = count;
    }

    // ========================================================================
    // Namespace Access
    // ========================================================================

    /// Get namespace by index (0-based)
    pub fn getNamespace(self: *Self, index: u8) ?*NvmeNamespace {
        if (index >= self.namespace_count) return null;
        if (self.namespaces[index]) |*ns| {
            return ns;
        }
        return null;
    }

    /// Find namespace by NSID
    pub fn findNamespace(self: *Self, nsid: u32) ?*NvmeNamespace {
        for (&self.namespaces) |*ns_opt| {
            if (ns_opt.*) |*ns| {
                if (ns.nsid == nsid and ns.active) {
                    return ns;
                }
            }
        }
        return null;
    }

    // ========================================================================
    // I/O Queue Selection
    // ========================================================================

    /// Select an I/O queue for a command
    fn selectIoQueue(self: *Self) ?*queue.QueuePair {
        if (self.io_queue_count == 0) return null;

        // Simple round-robin selection
        // For better performance, could use per-CPU queues
        const idx: usize = @intCast(@mod(
            self.io_queue_idx.fetchAdd(1, .monotonic),
            self.io_queue_count,
        ));

        if (self.io_queues[idx]) |*qp| {
            return qp;
        }
        return null;
    }

    // ========================================================================
    // Synchronous I/O
    // ========================================================================

    /// Read blocks from namespace (synchronous)
    pub fn readBlocks(
        self: *Self,
        nsid: u32,
        lba: u64,
        block_count: u32,
        buffer: []u8,
    ) NvmeError!void {
        const ns = self.findNamespace(nsid) orelse return error.NamespaceNotFound;

        // Validate
        if (block_count == 0) return error.InvalidParameter;

        // Use checked arithmetic to prevent integer overflow (CLAUDE.md security)
        const bytes_needed = std.math.mul(usize, @as(usize, block_count), @as(usize, ns.lba_size)) catch {
            return error.InvalidParameter;
        };
        if (buffer.len < bytes_needed) {
            return error.InvalidParameter;
        }

        // Checked addition for LBA range validation
        const end_lba = std.math.add(u64, lba, @as(u64, block_count)) catch {
            return error.InvalidParameter;
        };
        if (end_lba > ns.total_lbas) {
            return error.InvalidParameter;
        }

        // Allocate DMA buffer (checked page calculation)
        const pages_raw = std.math.add(usize, bytes_needed, init_mod.PAGE_SIZE - 1) catch {
            return error.InvalidParameter;
        };
        const pages = pages_raw / init_mod.PAGE_SIZE;

        // SECURITY FIX: Validate page count for PRP handling.
        // - 1 page: PRP1 only (PRP2 = 0)
        // - 2 pages: PRP1 + PRP2 (PRP2 = second page address)
        // - >2 pages: Requires PRP list (not yet implemented)
        // For now, reject transfers larger than 2 pages to prevent silent data corruption.
        if (pages > 2) {
            return error.InvalidParameter;
        }

        const buf_dma = dma.allocBuffer(self.bdf, pages * init_mod.PAGE_SIZE, true) catch {
            return error.AllocationFailed;
        };
        defer dma.freeBuffer(&buf_dma);

        // Zero-initialize DMA buffer (security)
        const dma_ptr: [*]u8 = @ptrFromInt(@intFromPtr(hal.paging.physToVirt(buf_dma.phys_addr)));
        @memset(dma_ptr[0 .. pages * init_mod.PAGE_SIZE], 0);

        // Select queue and build command
        const io_qp = self.selectIoQueue() orelse &self.admin_queue;

        // SECURITY: Use pending_lock (not io_lock) for CID allocation to prevent
        // race with async path which also uses pending_lock. Both paths must use
        // the same lock when allocating CIDs from the same queue.
        const held = io_qp.pending_lock.acquire();
        defer held.release();

        // Allocate CID
        const cid = io_qp.allocCidLocked() orelse return error.NoCapacity;

        // Calculate PRP2 for 2-page transfers
        const prp2: u64 = if (pages == 2) buf_dma.device_addr + init_mod.PAGE_SIZE else 0;

        // Build read command
        const sqe = io_qp.getSqEntry(io_qp.sq_tail);
        sqe.* = queue.SubmissionEntry.init();
        command.buildRead(
            sqe,
            nsid,
            lba,
            @truncate(block_count - 1), // 0-based
            buf_dma.device_addr,
            prp2,
        );
        sqe.setCid(cid);

        // Submit
        io_qp.submit();
        self.nvme_regs.ringSqTailDoorbell(io_qp.qid, self.doorbell_stride, io_qp.sq_tail);

        // Wait for completion (timeout in microseconds)
        const timeout_us = @as(u64, init_mod.Timeouts.COMMAND_MS) * 1_000;
        const start_tsc = hal.timing.rdtsc();

        while (true) {
            if (io_qp.hasCompletion()) {
                const cqe = io_qp.getCqEntry(io_qp.cq_head);
                if (cqe.getCid() == cid) {
                    const succeeded = cqe.succeeded();
                    io_qp.advanceCqHead();
                    self.nvme_regs.ringCqHeadDoorbell(io_qp.qid, self.doorbell_stride, io_qp.cq_head);

                    if (!succeeded) {
                        return error.TransferError;
                    }

                    // Copy data to user buffer
                    @memcpy(buffer[0..bytes_needed], dma_ptr[0..bytes_needed]);
                    return;
                }
            }

            if (hal.timing.hasTimedOut(start_tsc, timeout_us)) {
                return error.CommandTimeout;
            }

            hal.timing.delayUs(10);
        }
    }

    /// Write blocks to namespace (synchronous)
    pub fn writeBlocks(
        self: *Self,
        nsid: u32,
        lba: u64,
        block_count: u32,
        buffer: []const u8,
    ) NvmeError!void {
        const ns = self.findNamespace(nsid) orelse return error.NamespaceNotFound;

        // Validate
        if (block_count == 0) return error.InvalidParameter;

        // Use checked arithmetic to prevent integer overflow (CLAUDE.md security)
        const bytes_needed = std.math.mul(usize, @as(usize, block_count), @as(usize, ns.lba_size)) catch {
            return error.InvalidParameter;
        };
        if (buffer.len < bytes_needed) {
            return error.InvalidParameter;
        }

        // Checked addition for LBA range validation
        const end_lba = std.math.add(u64, lba, @as(u64, block_count)) catch {
            return error.InvalidParameter;
        };
        if (end_lba > ns.total_lbas) {
            return error.InvalidParameter;
        }

        // Allocate DMA buffer (checked page calculation)
        const pages_raw = std.math.add(usize, bytes_needed, init_mod.PAGE_SIZE - 1) catch {
            return error.InvalidParameter;
        };
        const pages = pages_raw / init_mod.PAGE_SIZE;

        // SECURITY FIX: Validate page count for PRP handling (same as readBlocks).
        if (pages > 2) {
            return error.InvalidParameter;
        }

        const buf_dma = dma.allocBuffer(self.bdf, pages * init_mod.PAGE_SIZE, true) catch {
            return error.AllocationFailed;
        };
        defer dma.freeBuffer(&buf_dma);

        // Copy data to DMA buffer
        const dma_ptr: [*]u8 = @ptrFromInt(@intFromPtr(hal.paging.physToVirt(buf_dma.phys_addr)));
        @memcpy(dma_ptr[0..bytes_needed], buffer[0..bytes_needed]);

        // Select queue and build command
        const io_qp = self.selectIoQueue() orelse &self.admin_queue;

        // SECURITY: Use pending_lock (not io_lock) for CID allocation to prevent
        // race with async path which also uses pending_lock. Both paths must use
        // the same lock when allocating CIDs from the same queue.
        const held = io_qp.pending_lock.acquire();
        defer held.release();

        // Allocate CID
        const cid = io_qp.allocCidLocked() orelse return error.NoCapacity;

        // Calculate PRP2 for 2-page transfers
        const prp2: u64 = if (pages == 2) buf_dma.device_addr + init_mod.PAGE_SIZE else 0;

        // Build write command
        const sqe = io_qp.getSqEntry(io_qp.sq_tail);
        sqe.* = queue.SubmissionEntry.init();
        command.buildWrite(
            sqe,
            nsid,
            lba,
            @truncate(block_count - 1), // 0-based
            buf_dma.device_addr,
            prp2,
        );
        sqe.setCid(cid);

        // Submit
        io_qp.submit();
        self.nvme_regs.ringSqTailDoorbell(io_qp.qid, self.doorbell_stride, io_qp.sq_tail);

        // Wait for completion (timeout in microseconds)
        const timeout_us = @as(u64, init_mod.Timeouts.COMMAND_MS) * 1_000;
        const start_tsc = hal.timing.rdtsc();

        while (true) {
            if (io_qp.hasCompletion()) {
                const cqe = io_qp.getCqEntry(io_qp.cq_head);
                if (cqe.getCid() == cid) {
                    const succeeded = cqe.succeeded();
                    io_qp.advanceCqHead();
                    self.nvme_regs.ringCqHeadDoorbell(io_qp.qid, self.doorbell_stride, io_qp.cq_head);

                    if (!succeeded) {
                        return error.TransferError;
                    }
                    return;
                }
            }

            if (hal.timing.hasTimedOut(start_tsc, timeout_us)) {
                return error.CommandTimeout;
            }

            hal.timing.delayUs(10);
        }
    }

    /// Flush namespace (synchronous)
    pub fn flush(self: *Self, nsid: u32) NvmeError!void {
        _ = self.findNamespace(nsid) orelse return error.NamespaceNotFound;

        const io_qp = self.selectIoQueue() orelse &self.admin_queue;

        // SECURITY FIX: Use pending_lock (not io_lock) for CID allocation.
        // allocCidLocked() expects the caller holds pending_lock, same as
        // readBlocks() and writeBlocks(). Using a different lock would cause
        // CID collision race conditions.
        const held = io_qp.pending_lock.acquire();
        defer held.release();

        const cid = io_qp.allocCidLocked() orelse return error.NoCapacity;

        const sqe = io_qp.getSqEntry(io_qp.sq_tail);
        sqe.* = queue.SubmissionEntry.init();
        command.buildFlush(sqe, nsid);
        sqe.setCid(cid);

        io_qp.submit();
        self.nvme_regs.ringSqTailDoorbell(io_qp.qid, self.doorbell_stride, io_qp.sq_tail);

        const timeout_us = @as(u64, 30_000) * 1_000; // 30 second flush timeout (in microseconds)
        const start_tsc = hal.timing.rdtsc();

        while (true) {
            if (io_qp.hasCompletion()) {
                const cqe = io_qp.getCqEntry(io_qp.cq_head);
                if (cqe.getCid() == cid) {
                    const succeeded = cqe.succeeded();
                    io_qp.advanceCqHead();
                    self.nvme_regs.ringCqHeadDoorbell(io_qp.qid, self.doorbell_stride, io_qp.cq_head);

                    if (!succeeded) {
                        return error.TransferError;
                    }
                    return;
                }
            }

            if (hal.timing.hasTimedOut(start_tsc, timeout_us)) {
                return error.CommandTimeout;
            }

            hal.timing.delayUs(100);
        }
    }

    // ========================================================================
    // Asynchronous I/O
    // ========================================================================

    /// Read blocks asynchronously
    pub fn readBlocksAsync(
        self: *Self,
        nsid: u32,
        lba: u64,
        block_count: u32,
        buf_phys: u64,
        request: *io.IoRequest,
    ) NvmeError!void {
        const ns = self.findNamespace(nsid) orelse return error.NamespaceNotFound;

        // SECURITY: Validate LBA range (same as sync path) to prevent out-of-bounds access
        const end_lba = std.math.add(u64, lba, @as(u64, block_count)) catch {
            return error.InvalidParameter;
        };
        if (end_lba > ns.total_lbas) {
            return error.InvalidParameter;
        }

        const io_qp = self.selectIoQueue() orelse return error.NoCapacity;

        const held = io_qp.pending_lock.acquire();
        defer held.release();

        const cid = io_qp.allocCidLocked() orelse return error.NoCapacity;

        const sqe = io_qp.getSqEntry(io_qp.sq_tail);
        sqe.* = queue.SubmissionEntry.init();
        command.buildRead(sqe, nsid, lba, @truncate(block_count - 1), buf_phys, 0);
        sqe.setCid(cid);

        // Store request metadata
        request.op_data = .{
            .disk = .{
                .lba = lba,
                .sector_count = @intCast(block_count),
                .port = 0,
                .slot = @intCast(cid),
            },
        };

        io_qp.pending_requests[cid] = request;
        _ = request.compareAndSwapState(.pending, .in_progress);

        io_qp.submit();
        self.nvme_regs.ringSqTailDoorbell(io_qp.qid, self.doorbell_stride, io_qp.sq_tail);
    }

    /// Write blocks asynchronously
    pub fn writeBlocksAsync(
        self: *Self,
        nsid: u32,
        lba: u64,
        block_count: u32,
        buf_phys: u64,
        request: *io.IoRequest,
    ) NvmeError!void {
        const ns = self.findNamespace(nsid) orelse return error.NamespaceNotFound;

        // SECURITY: Validate LBA range (same as sync path) to prevent out-of-bounds access
        const end_lba = std.math.add(u64, lba, @as(u64, block_count)) catch {
            return error.InvalidParameter;
        };
        if (end_lba > ns.total_lbas) {
            return error.InvalidParameter;
        }

        const io_qp = self.selectIoQueue() orelse return error.NoCapacity;

        const held = io_qp.pending_lock.acquire();
        defer held.release();

        const cid = io_qp.allocCidLocked() orelse return error.NoCapacity;

        const sqe = io_qp.getSqEntry(io_qp.sq_tail);
        sqe.* = queue.SubmissionEntry.init();
        command.buildWrite(sqe, nsid, lba, @truncate(block_count - 1), buf_phys, 0);
        sqe.setCid(cid);

        request.op_data = .{
            .disk = .{
                .lba = lba,
                .sector_count = @intCast(block_count),
                .port = 0,
                .slot = @intCast(cid),
            },
        };

        io_qp.pending_requests[cid] = request;
        _ = request.compareAndSwapState(.pending, .in_progress);

        io_qp.submit();
        self.nvme_regs.ringSqTailDoorbell(io_qp.qid, self.doorbell_stride, io_qp.sq_tail);
    }

    // ========================================================================
    // Interrupt Handling
    // ========================================================================

    /// Handle interrupt for a specific queue
    pub fn handleQueueInterrupt(self: *Self, qid: u16) void {
        var qp: *queue.QueuePair = undefined;

        if (qid == 0) {
            qp = &self.admin_queue;
        } else if (qid <= self.io_queue_count) {
            if (self.io_queues[qid - 1]) |*q| {
                qp = q;
            } else {
                return;
            }
        } else {
            return;
        }

        var processed: u16 = 0;

        while (qp.hasCompletion() and processed < qp.size) {
            const cqe = qp.getCqEntry(qp.cq_head);
            const cid = cqe.getCid();

            // Validate CID bounds (security: hardware-provided value)
            if (cid >= queue.MAX_PENDING_REQUESTS) {
                console.err("NVMe: Invalid CID {} from hardware (max {})", .{ cid, queue.MAX_PENDING_REQUESTS });
                qp.advanceCqHead();
                processed += 1;
                continue;
            }

            // Complete pending request
            // SECURITY: Complete request BEFORE releasing lock to prevent use-after-free.
            // If lock is released first, another thread could reuse this CID slot with a
            // new request, potentially invalidating our request pointer.
            const held = qp.pending_lock.acquire();
            if (qp.pending_requests[cid]) |request| {
                qp.pending_requests[cid] = null;
                const result: io.IoResult = if (cqe.succeeded())
                    .{ .success = 0 }
                else
                    .{ .err = error.EIO };
                _ = request.complete(result);
                held.release();
            } else {
                held.release();
            }

            qp.advanceCqHead();
            processed += 1;
        }

        if (processed > 0) {
            self.nvme_regs.ringCqHeadDoorbell(qid, self.doorbell_stride, qp.cq_head);
        }
    }

    /// Handle interrupt (all queues)
    pub fn handleInterrupt(self: *Self) void {
        // Check admin queue
        self.handleQueueInterrupt(0);

        // Check I/O queues
        for (0..self.io_queue_count) |i| {
            self.handleQueueInterrupt(@intCast(i + 1));
        }
    }
};

// ============================================================================
// Global Controller Instance
// ============================================================================

var controller_instance: ?*NvmeController = null;

/// Initialize NVMe controller from PCI device
pub fn initFromPci(pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) NvmeError!*NvmeController {
    const alloc = heap.allocator();
    const controller = alloc.create(NvmeController) catch return error.AllocationFailed;

    controller.init(pci_dev, pci_access) catch |err| {
        alloc.destroy(controller);
        return err;
    };

    controller_instance = controller;
    return controller;
}

/// Get the global controller instance
pub fn getController() ?*NvmeController {
    return controller_instance;
}

// ============================================================================
// Helper Functions
// ============================================================================

fn mapInitError(err: init_mod.InitError) NvmeError {
    return switch (err) {
        error.InvalidCapabilities => error.InvalidParameter,
        error.ResetTimeout => error.ResetTimeout,
        error.EnableTimeout => error.EnableTimeout,
        error.FatalError => error.FatalError,
        error.AllocationFailed => error.AllocationFailed,
        error.QueueCreationFailed => error.QueueCreationFailed,
        error.CommandTimeout => error.CommandTimeout,
        error.CommandFailed => error.CommandFailed,
        error.NoNamespaces => error.NamespaceNotFound,
        error.UnsupportedPageSize => error.InvalidParameter,
    };
}

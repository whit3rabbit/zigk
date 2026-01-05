// NVMe Controller Initialization
//
// Handles the NVMe controller initialization sequence including:
// - Controller reset and enable
// - Admin queue allocation and configuration
// - I/O queue creation
// - Namespace discovery
//
// Reference: NVM Express Base Specification 2.0, Section 7.6

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const heap = @import("heap");
const dma = @import("dma");
const iommu = @import("iommu");

const regs = @import("regs.zig");
const queue = @import("queue.zig");
const command = @import("command.zig");
const namespace = @import("namespace.zig");

// ============================================================================
// Constants
// ============================================================================

/// Default Admin Queue size (entries)
pub const ADMIN_QUEUE_SIZE: u16 = 64;

/// Default I/O Queue size (entries)
pub const IO_QUEUE_SIZE: u16 = 256;

/// Page size (4KB, standard for NVMe)
pub const PAGE_SIZE: u32 = 4096;

/// Initialization Timeouts
pub const Timeouts = struct {
    /// Controller ready timeout (from CAP.TO)
    pub const READY_MS: u32 = 10000; // 10 seconds max
    /// Command completion timeout
    pub const COMMAND_MS: u32 = 5000; // 5 seconds
    /// Reset timeout
    pub const RESET_MS: u32 = 5000; // 5 seconds
};

// ============================================================================
// Initialization Errors
// ============================================================================

pub const InitError = error{
    InvalidCapabilities,
    ResetTimeout,
    EnableTimeout,
    FatalError,
    AllocationFailed,
    QueueCreationFailed,
    CommandTimeout,
    CommandFailed,
    NoNamespaces,
    UnsupportedPageSize,
};

// ============================================================================
// Queue Allocation
// ============================================================================

/// Allocate DMA memory for a queue pair
pub fn allocateQueuePair(
    qid: u16,
    size: u16,
    doorbell_stride: u32,
    bdf: iommu.DeviceBdf,
) !queue.QueuePair {
    var qp = queue.QueuePair.init(qid, size);

    // Calculate memory requirements
    const sq_bytes = @as(usize, size) * queue.SQE_SIZE;
    const cq_bytes = @as(usize, size) * queue.CQE_SIZE;

    // Round up to page boundary
    const sq_pages = (sq_bytes + PAGE_SIZE - 1) / PAGE_SIZE;
    const cq_pages = (cq_bytes + PAGE_SIZE - 1) / PAGE_SIZE;

    // Allocate SQ (must be page-aligned)
    qp.sq_dma = dma.allocBuffer(bdf, sq_pages * PAGE_SIZE, true) catch {
        return error.AllocationFailed;
    };
    errdefer dma.freeBuffer(&qp.sq_dma);

    qp.sq_base_phys = qp.sq_dma.device_addr;
    qp.sq_base_virt = @intFromPtr(hal.paging.physToVirt(qp.sq_dma.phys_addr));

    // Zero-initialize SQ (security: prevent info leaks)
    const sq_ptr: [*]u8 = @ptrFromInt(qp.sq_base_virt);
    @memset(sq_ptr[0 .. sq_pages * PAGE_SIZE], 0);

    // Allocate CQ (must be page-aligned)
    qp.cq_dma = dma.allocBuffer(bdf, cq_pages * PAGE_SIZE, true) catch {
        return error.AllocationFailed;
    };
    errdefer dma.freeBuffer(&qp.cq_dma);

    qp.cq_base_phys = qp.cq_dma.device_addr;
    qp.cq_base_virt = @intFromPtr(hal.paging.physToVirt(qp.cq_dma.phys_addr));

    // Zero-initialize CQ (critical: phase bits start as 0)
    const cq_ptr: [*]u8 = @ptrFromInt(qp.cq_base_virt);
    @memset(cq_ptr[0 .. cq_pages * PAGE_SIZE], 0);

    // Calculate doorbell offsets
    qp.sq_doorbell_offset = regs.sqTailDoorbellOffset(qid, doorbell_stride);
    qp.cq_doorbell_offset = regs.cqHeadDoorbellOffset(qid, doorbell_stride);

    qp.active = true;
    return qp;
}

/// Free queue pair DMA memory
pub fn freeQueuePair(qp: *queue.QueuePair, bdf: iommu.DeviceBdf) void {
    _ = bdf; // Unused - freeBuffer doesn't need BDF
    if (qp.active) {
        dma.freeBuffer(&qp.sq_dma);
        dma.freeBuffer(&qp.cq_dma);
        qp.active = false;
    }
}

// ============================================================================
// Controller Reset and Enable
// ============================================================================

/// Disable the controller (CC.EN = 0) and wait for CSTS.RDY = 0
pub fn disableController(nvme_regs: regs.NvmeRegs, timeout_ms: u32) InitError!void {
    var cc = nvme_regs.readConfig();

    if (!cc.en) {
        // Already disabled, just verify ready is clear
        const csts = nvme_regs.readStatus();
        if (!csts.rdy) return;
    }

    // Clear enable bit
    cc.en = false;
    nvme_regs.writeConfig(cc);

    // Wait for ready to clear (timeout in microseconds)
    const start_tsc = hal.timing.rdtsc();
    const timeout_us = @as(u64, timeout_ms) * 1_000;

    while (true) {
        const csts = nvme_regs.readStatus();

        if (csts.cfs) {
            console.err("NVMe: Controller fatal status during disable", .{});
            return error.FatalError;
        }

        if (!csts.rdy) {
            return; // Successfully disabled
        }

        if (hal.timing.hasTimedOut(start_tsc, timeout_us)) {
            console.err("NVMe: Timeout waiting for controller disable", .{});
            return error.ResetTimeout;
        }

        hal.timing.delayUs(100);
    }
}

/// Enable the controller (CC.EN = 1) and wait for CSTS.RDY = 1
pub fn enableController(nvme_regs: regs.NvmeRegs, timeout_ms: u32) InitError!void {
    var cc = nvme_regs.readConfig();

    if (cc.en) {
        // Already enabled, verify ready
        const csts = nvme_regs.readStatus();
        if (csts.rdy) return;
    }

    // Set enable bit
    cc.en = true;
    nvme_regs.writeConfig(cc);

    // Wait for ready (timeout in microseconds)
    const start_tsc = hal.timing.rdtsc();
    const timeout_us = @as(u64, timeout_ms) * 1_000;

    while (true) {
        const csts = nvme_regs.readStatus();

        if (csts.cfs) {
            console.err("NVMe: Controller fatal status during enable", .{});
            return error.FatalError;
        }

        if (csts.rdy) {
            return; // Successfully enabled
        }

        if (hal.timing.hasTimedOut(start_tsc, timeout_us)) {
            console.err("NVMe: Timeout waiting for controller enable", .{});
            return error.EnableTimeout;
        }

        hal.timing.delayUs(100);
    }
}

/// Configure controller for NVM command set
pub fn configureController(nvme_regs: regs.NvmeRegs, cap: regs.Capabilities) InitError!void {
    // Verify page size is supported
    const min_ps = cap.minPageSize();
    const max_ps = cap.maxPageSize();

    if (PAGE_SIZE < min_ps or PAGE_SIZE > max_ps) {
        console.err("NVMe: 4KB page size not supported (min={}, max={})", .{ min_ps, max_ps });
        return error.UnsupportedPageSize;
    }

    // Build controller configuration
    var cc = regs.ControllerConfig.defaultNvm();

    // MPS: log2(PAGE_SIZE) - 12 = 0 for 4KB
    cc.mps = 0;

    // CSS: 0 = NVM Command Set
    cc.css = 0;

    // IOSQES: 6 = 64 bytes (required for NVM)
    cc.iosqes = 6;

    // IOCQES: 4 = 16 bytes (required for NVM)
    cc.iocqes = 4;

    // AMS: 0 = Round Robin
    cc.ams = 0;

    // EN = 0 initially
    cc.en = false;

    nvme_regs.writeConfig(cc);
}

/// Configure admin queue addresses
pub fn configureAdminQueues(
    nvme_regs: regs.NvmeRegs,
    admin_qp: *const queue.QueuePair,
) void {
    // Write Admin Queue Attributes
    // Size is 0-based (actual_size - 1)
    const aqa = regs.AdminQueueAttrs.init(
        @truncate(admin_qp.size - 1),
        @truncate(admin_qp.size - 1),
    );
    nvme_regs.writeAdminQueueAttrs(aqa);

    // Write Admin SQ Base Address
    nvme_regs.writeAdminSqBase(admin_qp.sq_base_phys);

    // Write Admin CQ Base Address
    nvme_regs.writeAdminCqBase(admin_qp.cq_base_phys);
}

// ============================================================================
// Admin Command Execution
// ============================================================================

/// Submit an admin command and wait for completion (synchronous)
pub fn executeAdminCommand(
    nvme_regs: regs.NvmeRegs,
    admin_qp: *queue.QueuePair,
    entry: *queue.SubmissionEntry,
    timeout_ms: u32,
) InitError!queue.CompletionEntry {
    // Assign command ID
    const cid = admin_qp.allocCidLocked() orelse return error.CommandFailed;
    entry.setCid(cid);

    // Copy to submission queue
    const sqe = admin_qp.getSqEntry(admin_qp.sq_tail);
    sqe.* = entry.*;

    // Advance tail and ring doorbell
    admin_qp.submit();
    nvme_regs.ringSqTailDoorbell(
        admin_qp.qid,
        regs.Capabilities.doorbellStride(nvme_regs.readCapabilities()),
        admin_qp.sq_tail,
    );

    // Poll for completion (timeout in microseconds)
    const start_tsc = hal.timing.rdtsc();
    const timeout_us = @as(u64, timeout_ms) * 1_000;

    while (true) {
        if (admin_qp.hasCompletion()) {
            const cqe = admin_qp.getCqEntry(admin_qp.cq_head);

            // Verify this is our command
            if (cqe.getCid() == cid) {
                // Save completion before advancing
                const result = cqe.*;

                // Advance CQ head and ring doorbell
                admin_qp.advanceCqHead();
                nvme_regs.ringCqHeadDoorbell(
                    admin_qp.qid,
                    regs.Capabilities.doorbellStride(nvme_regs.readCapabilities()),
                    admin_qp.cq_head,
                );

                if (!result.succeeded()) {
                    console.warn("NVMe: Admin command failed, status=0x{x}", .{result.getStatus()});
                    return error.CommandFailed;
                }

                return result;
            }
        }

        if (hal.timing.hasTimedOut(start_tsc, timeout_us)) {
            console.err("NVMe: Admin command timeout (CID={})", .{cid});
            return error.CommandTimeout;
        }

        // Brief pause before retry
        hal.timing.delayUs(10);
    }
}

// ============================================================================
// I/O Queue Creation
// ============================================================================

/// Create an I/O Completion Queue via admin command
pub fn createIoCq(
    nvme_regs: regs.NvmeRegs,
    admin_qp: *queue.QueuePair,
    io_qp: *const queue.QueuePair,
    iv: u16,
) InitError!void {
    var sqe = queue.SubmissionEntry.init();
    command.buildCreateIoCq(
        &sqe,
        io_qp.qid,
        io_qp.size - 1, // 0-based size
        io_qp.cq_base_phys,
        iv,
        true, // IEN = interrupt enable
        true, // PC = physically contiguous
    );

    _ = try executeAdminCommand(nvme_regs, admin_qp, &sqe, Timeouts.COMMAND_MS);
}

/// Create an I/O Submission Queue via admin command
pub fn createIoSq(
    nvme_regs: regs.NvmeRegs,
    admin_qp: *queue.QueuePair,
    io_qp: *const queue.QueuePair,
) InitError!void {
    var sqe = queue.SubmissionEntry.init();
    command.buildCreateIoSq(
        &sqe,
        io_qp.qid,
        io_qp.size - 1, // 0-based size
        io_qp.sq_base_phys,
        io_qp.qid, // CQID = same as SQID (1:1 mapping)
        0, // QPRIO = 0 (medium)
        true, // PC = physically contiguous
    );

    _ = try executeAdminCommand(nvme_regs, admin_qp, &sqe, Timeouts.COMMAND_MS);
}

/// Delete an I/O Submission Queue via admin command
pub fn deleteIoSq(
    nvme_regs: regs.NvmeRegs,
    admin_qp: *queue.QueuePair,
    qid: u16,
) InitError!void {
    var sqe = queue.SubmissionEntry.init();
    command.buildDeleteIoSq(&sqe, qid);
    _ = try executeAdminCommand(nvme_regs, admin_qp, &sqe, Timeouts.COMMAND_MS);
}

/// Delete an I/O Completion Queue via admin command
pub fn deleteIoCq(
    nvme_regs: regs.NvmeRegs,
    admin_qp: *queue.QueuePair,
    qid: u16,
) InitError!void {
    var sqe = queue.SubmissionEntry.init();
    command.buildDeleteIoCq(&sqe, qid);
    _ = try executeAdminCommand(nvme_regs, admin_qp, &sqe, Timeouts.COMMAND_MS);
}

// ============================================================================
// Identify Commands
// ============================================================================

/// Execute Identify Controller command
pub fn identifyController(
    nvme_regs: regs.NvmeRegs,
    admin_qp: *queue.QueuePair,
    bdf: iommu.DeviceBdf,
) InitError!*namespace.IdentifyController {
    // Allocate 4KB buffer for identify data
    const id_dma = dma.allocBuffer(bdf, 4096, true) catch return error.AllocationFailed;
    errdefer dma.freeBuffer(&id_dma);

    // Zero-initialize buffer
    const buf_ptr: [*]u8 = @ptrFromInt(@intFromPtr(hal.paging.physToVirt(id_dma.phys_addr)));
    @memset(buf_ptr[0..4096], 0);

    // Build and execute command
    var sqe = queue.SubmissionEntry.init();
    command.buildIdentifyController(&sqe, id_dma.device_addr);

    _ = try executeAdminCommand(nvme_regs, admin_qp, &sqe, Timeouts.COMMAND_MS);

    // Allocate persistent copy
    const id_ctrl = heap.allocator().create(namespace.IdentifyController) catch
        return error.AllocationFailed;

    // Copy data
    const src: *const namespace.IdentifyController = @ptrCast(@alignCast(buf_ptr));
    id_ctrl.* = src.*;

    // Free DMA buffer (use a mutable copy since id_dma is const)
    var dma_copy = id_dma;
    dma.freeBuffer(&dma_copy);

    return id_ctrl;
}

/// Execute Identify Namespace command
pub fn identifyNamespace(
    nvme_regs: regs.NvmeRegs,
    admin_qp: *queue.QueuePair,
    nsid: u32,
    bdf: iommu.DeviceBdf,
) InitError!*namespace.IdentifyNamespace {
    // Allocate 4KB buffer for identify data
    const id_dma = dma.allocBuffer(bdf, 4096, true) catch return error.AllocationFailed;
    errdefer dma.freeBuffer(&id_dma);

    // Zero-initialize buffer
    const buf_ptr: [*]u8 = @ptrFromInt(@intFromPtr(hal.paging.physToVirt(id_dma.phys_addr)));
    @memset(buf_ptr[0..4096], 0);

    // Build and execute command
    var sqe = queue.SubmissionEntry.init();
    command.buildIdentifyNamespace(&sqe, nsid, id_dma.device_addr);

    _ = try executeAdminCommand(nvme_regs, admin_qp, &sqe, Timeouts.COMMAND_MS);

    // Allocate persistent copy
    const id_ns = heap.allocator().create(namespace.IdentifyNamespace) catch
        return error.AllocationFailed;

    // Copy data
    const src: *const namespace.IdentifyNamespace = @ptrCast(@alignCast(buf_ptr));
    id_ns.* = src.*;

    // Free DMA buffer (use a mutable copy since id_dma is const)
    var dma_copy = id_dma;
    dma.freeBuffer(&dma_copy);

    return id_ns;
}

/// Get active namespace list
pub fn getActiveNamespaceList(
    nvme_regs: regs.NvmeRegs,
    admin_qp: *queue.QueuePair,
    start_nsid: u32,
    bdf: iommu.DeviceBdf,
) InitError!*namespace.ActiveNamespaceList {
    // Allocate 4KB buffer
    const list_dma = dma.allocBuffer(bdf, 4096, true) catch return error.AllocationFailed;
    errdefer dma.freeBuffer(&list_dma);

    // Zero-initialize buffer
    const buf_ptr: [*]u8 = @ptrFromInt(@intFromPtr(hal.paging.physToVirt(list_dma.phys_addr)));
    @memset(buf_ptr[0..4096], 0);

    // Build and execute command
    var sqe = queue.SubmissionEntry.init();
    command.buildIdentifyActiveNsList(&sqe, start_nsid, list_dma.device_addr);

    _ = try executeAdminCommand(nvme_regs, admin_qp, &sqe, Timeouts.COMMAND_MS);

    // Allocate persistent copy
    const ns_list = heap.allocator().create(namespace.ActiveNamespaceList) catch
        return error.AllocationFailed;

    // Copy data
    const src: *const namespace.ActiveNamespaceList = @ptrCast(@alignCast(buf_ptr));
    ns_list.* = src.*;

    // Free DMA buffer (use a mutable copy since list_dma is const)
    var dma_copy = list_dma;
    dma.freeBuffer(&dma_copy);

    return ns_list;
}

// ============================================================================
// Set Features Commands
// ============================================================================

/// Set Number of Queues feature
/// Returns (allocated_sq_count, allocated_cq_count)
pub fn setNumQueues(
    nvme_regs: regs.NvmeRegs,
    admin_qp: *queue.QueuePair,
    requested_sq: u16,
    requested_cq: u16,
) InitError!struct { sq: u16, cq: u16 } {
    var sqe = queue.SubmissionEntry.init();
    command.buildSetNumQueues(
        &sqe,
        requested_sq -| 1, // 0-based
        requested_cq -| 1, // 0-based
    );

    const cqe = try executeAdminCommand(nvme_regs, admin_qp, &sqe, Timeouts.COMMAND_MS);

    // DW0 contains allocated counts
    const nsqa = @as(u16, @truncate(cqe.dw0 & 0xFFFF)) + 1;
    const ncqa = @as(u16, @truncate(cqe.dw0 >> 16)) + 1;

    return .{ .sq = nsqa, .cq = ncqa };
}

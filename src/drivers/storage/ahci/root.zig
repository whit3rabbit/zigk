// AHCI Controller Driver
//
// Provides block device access to SATA drives via AHCI (Advanced Host Controller Interface).
// This driver initializes the HBA, detects connected drives, and provides read/write operations.
//
// Usage:
//   const ahci = @import("ahci");
//   var controller = try ahci.initFromPci(pci_dev, ecam);
//   try controller.readSectors(port, lba, count, buffer);
//
// Reference: AHCI Specification 1.3.1

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

pub const hba = @import("hba.zig");
pub const port = @import("port.zig");
pub const command = @import("command.zig");
pub const fis = @import("fis.zig");
pub const adapter = @import("adapter.zig");
pub const init_mod = @import("init.zig");
pub const irq_mod = @import("irq.zig");

// ============================================================================
// Constants
// ============================================================================

/// Maximum ports per controller
pub const MAX_PORTS: usize = 32;

/// Sector size (bytes)
pub const SECTOR_SIZE: usize = 512;

/// Maximum sectors per transfer (limited by PRDT size)
pub const MAX_SECTORS_PER_TRANSFER: usize = 256; // 128KB

// AHCI Timeout Constants (microseconds)
// Based on Linux kernel libahci.c best practices
pub const Timeouts = struct {
    pub const BIOS_HANDOFF_US: u64 = 25_000; // 25ms - Primary BIOS handoff
    pub const BIOS_BUSY_US: u64 = 2_000_000; // 2s - BIOS busy extended wait
    pub const ENGINE_STOP_US: u64 = 1_000_000; // 1s - CR/FR clear timeout
    pub const DEVICE_DETECT_US: u64 = 2_000_000; // 2s - PHY establishment
    pub const DEVICE_READY_US: u64 = 5_000_000; // 5s - BSY/DRQ clear (AHCI spec minimum)
    pub const COMMAND_US: u64 = 7_000_000; // 7s - Standard command timeout
    pub const FLUSH_US: u64 = 30_000_000; // 30s - Cache flush timeout
    pub const POST_RESET_US: u64 = 150_000; // 150ms - Post-reset stability delay
    pub const COMRESET_US: u64 = 1_000; // 1ms - COMRESET signal duration
};

// ============================================================================
// Error Types
// ============================================================================

pub const AhciError = error{
    NotAhciController,
    InvalidBar,
    MappingFailed,
    ResetTimeout,
    PortNotConnected,
    CommandTimeout,
    DeviceError,
    TransferError,
    AllocationFailed,
    InvalidParameter,
};

// ============================================================================
// Port State
// ============================================================================

/// Per-port state
pub const AhciPort = struct {
    /// Port number (0-31)
    num: u5,

    /// Port register base address (virtual)
    base: u64,

    /// Port is connected and initialized
    active: bool,

    /// Device type
    device_type: port.DeviceSignature,

    /// Command list physical address (device address for hardware)
    cmd_list_phys: u64,

    /// Command list virtual address
    cmd_list_virt: u64,

    /// FIS receive buffer physical address (device address for hardware)
    fis_phys: u64,

    /// FIS receive buffer virtual address
    fis_virt: u64,

    /// Command tables physical address (device addresses for hardware)
    cmd_tables_phys: [32]u64,

    /// Command tables virtual address (array of 32)
    cmd_tables_virt: [32]u64,

    /// DMA buffer tracking for IOMMU integration
    cmd_list_dma: dma.DmaBuffer,
    fis_dma: dma.DmaBuffer,
    cmd_tables_dma: [32]dma.DmaBuffer,
    /// Whether IOMMU-aware DMA is being used
    using_iommu_dma: bool,

    /// Device identify data (if available)
    identify: ?fis.IdentifyData,

    /// Pending async requests per command slot (32 slots max)
    /// Set before issuing command, cleared by IRQ handler
    pending_requests: [32]?*io.IoRequest,

    /// Bitmask of commands currently issued (for IRQ handler)
    commands_issued: u32,

    /// Lock protecting pending_requests and commands_issued
    pending_lock: sync.Spinlock,

    /// Accumulated Interrupt Status (for sync commands)
    /// Updated by ISR, cleared/read by sync code
    last_is: std.atomic.Value(u32),

    /// Initialize port as inactive
    pub fn initInactive(num: u5) AhciPort {
        return AhciPort{
            .num = num,
            .base = 0,
            .active = false,
            .device_type = @enumFromInt(0),
            .cmd_list_phys = 0,
            .cmd_list_virt = 0,
            .fis_phys = 0,
            .fis_virt = 0,
            .cmd_tables_phys = [_]u64{0} ** 32,
            .cmd_tables_virt = [_]u64{0} ** 32,
            .cmd_list_dma = undefined,
            .fis_dma = undefined,
            .cmd_tables_dma = undefined,
            .using_iommu_dma = false,
            .identify = null,
            .pending_requests = [_]?*io.IoRequest{null} ** 32,
            .commands_issued = 0,
            .pending_lock = .{},
            .last_is = std.atomic.Value(u32).init(0),
        };
    }

    /// Get capacity in bytes (0 if not identified)
    pub fn capacityBytes(self: *const AhciPort) u64 {
        if (self.identify) |id| {
            return id.capacityBytes();
        }
        return 0;
    }

    /// Get capacity in sectors (0 if not identified)
    pub fn capacitySectors(self: *const AhciPort) u64 {
        if (self.identify) |id| {
            return id.totalSectors();
        }
        return 0;
    }
};

// ============================================================================
// AHCI Controller
// ============================================================================

/// AHCI Controller state
pub const AhciController = struct {
    /// HBA base address (virtual)
    hba_base: u64,

    /// HBA capabilities
    cap: hba.HbaCap,

    /// Port states
    ports: [MAX_PORTS]AhciPort,

    /// Number of active ports
    active_port_count: u8,

    /// PCI device reference
    pci_dev: *const pci.PciDevice,

    const Self = @This();

    /// Initialize controller from PCI device
    /// Note: Allocates resources directly into 'self', avoiding stack copy of large struct
    pub fn init(self: *Self, pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) AhciError!void {
        // Verify this is an AHCI controller
        if (pci_dev.class_code != hba.PciClass.CLASS or
            pci_dev.subclass != hba.PciClass.SUBCLASS or
            pci_dev.prog_if != hba.PciClass.PROG_IF_AHCI)
        {
            return AhciError.NotAhciController;
        }

        // Get ABAR (BAR5)
        const bar = pci_dev.bar[hba.ABAR_INDEX];
        if (!bar.isValid() or !bar.is_mmio) {
            console.err("AHCI: Invalid BAR5", .{});
            return AhciError.InvalidBar;
        }

        // Enable bus master and memory space
        const cmd = pci_access.readCommand(pci_dev.bus, pci_dev.device, pci_dev.func);
        pci_access.writeCommand(pci_dev.bus, pci_dev.device, pci_dev.func, cmd | pci.Command.BUS_MASTER | pci.Command.MEMORY_SPACE);

        // Map HBA memory
        const hba_virt = vmm.mapMmio(bar.base, bar.size) catch |err| {
            console.err("AHCI: Failed to map HBA memory: {}", .{err});
            return AhciError.MappingFailed;
        };

        // Initialize fields in-place
        self.hba_base = hba_virt;
        self.cap = hba.readCap(hba_virt);
        self.active_port_count = 0;
        self.pci_dev = pci_dev;

        // Initialize all ports as inactive
        for (0..MAX_PORTS) |i| {
            self.ports[i] = AhciPort.initInactive(@intCast(i));
        }

        // Log controller info
        const ver = hba.readVersion(hba_virt);
        console.info("AHCI: Controller at {x}:{x}.{x}", .{ pci_dev.bus, pci_dev.device, pci_dev.func });
        console.info("AHCI: Version {d}.{d}, ports={d}, slots={d}, 64-bit={}", .{
            ver.majorNum(),
            ver.minorNum(),
            self.cap.numPorts(),
            self.cap.numCommandSlots(),
            self.cap.s64a,
        });

        // Perform BIOS/OS handoff if supported
        try self.biosHandoff();

        // Enable AHCI mode
        try self.enableAhci();

        // Initialize ports
        try self.initPorts();
    }

    /// Perform BIOS/OS handoff
    fn biosHandoff(self: *Self) AhciError!void {
        const cap2 = hba.readCap2(self.hba_base);
        if (!cap2.boh) {
            return; // Handoff not supported
        }

        var bohc = hba.readBohc(self.hba_base);
        if (!bohc.bos) {
            return; // BIOS doesn't own the controller
        }

        // Request ownership
        bohc.oos = true;
        hba.writeBohc(self.hba_base, bohc);

        // Wait for BIOS to release (timeout 25ms per spec)
        const start = hal.timing.rdtsc();
        while (!hal.timing.hasTimedOut(start, Timeouts.BIOS_HANDOFF_US)) {
            bohc = hba.readBohc(self.hba_base);
            if (!bohc.bos and bohc.oos) {
                console.info("AHCI: BIOS/OS handoff complete", .{});
                return;
            }
            hal.cpu.pause();
        }

        // If BIOS busy, wait additional 2 seconds
        if (bohc.bb) {
            const start_bb = hal.timing.rdtsc();
            while (!hal.timing.hasTimedOut(start_bb, Timeouts.BIOS_BUSY_US)) {
                bohc = hba.readBohc(self.hba_base);
                if (!bohc.bb) break;
                hal.cpu.pause();
            }
        }

        console.warn("AHCI: BIOS/OS handoff may not be complete", .{});
    }

    /// Enable AHCI mode
    fn enableAhci(self: *Self) AhciError!void {
        var ghc = hba.readGhc(self.hba_base);

        // Enable AHCI mode if not already
        if (!ghc.ae) {
            ghc.ae = true;
            hba.writeGhc(self.hba_base, ghc);

            // Verify it's enabled
            ghc = hba.readGhc(self.hba_base);
            if (!ghc.ae) {
                console.err("AHCI: Failed to enable AHCI mode", .{});
                return AhciError.ResetTimeout;
            }
        }

        // Clear pending interrupts
        hba.clearInterruptStatus(self.hba_base, 0xFFFFFFFF);
    }

    /// Initialize all implemented ports
    fn initPorts(self: *Self) AhciError!void {
        const pi = hba.readPortsImplemented(self.hba_base);

        for (0..MAX_PORTS) |i| {
            if ((pi & (@as(u32, 1) << @intCast(i))) == 0) {
                continue; // Port not implemented
            }

            const port_base = port.portBase(self.hba_base, @intCast(i));
            self.ports[i].base = port_base;
            self.ports[i].num = @intCast(i);

            // Check if device is connected
            const ssts = port.readSsts(port_base);
            if (!ssts.isConnected()) {
                continue;
            }

            // Initialize the port
            self.initPort(@intCast(i)) catch |err| {
                console.warn("AHCI: Port {d} init failed: {}", .{ i, err });
                continue;
            };

            self.active_port_count += 1;
        }

        console.info("AHCI: {d} active ports", .{self.active_port_count});
    }

    /// Initialize a single port
    fn initPort(self: *Self, port_num: u5) AhciError!void {
        const p = &self.ports[port_num];
        const base = p.base;

        // Stop command engine
        if (!port.stopEngine(base)) {
            return AhciError.ResetTimeout;
        }

        // Get device BDF for IOMMU domain
        const bdf = iommu.DeviceBdf{
            .bus = self.pci_dev.bus,
            .device = self.pci_dev.device,
            .func = self.pci_dev.func,
        };

        // Allocate DMA memory using helper module
        const dma_ctx = init_mod.allocatePortDma(port_num, bdf, self.cap.s64a) catch {
            return AhciError.AllocationFailed;
        };

        // Copy DMA context to port struct
        p.cmd_list_phys = dma_ctx.cmd_list_phys;
        p.cmd_list_virt = dma_ctx.cmd_list_virt;
        p.fis_phys = dma_ctx.fis_phys;
        p.fis_virt = dma_ctx.fis_virt;
        p.cmd_tables_phys = dma_ctx.cmd_tables_phys;
        p.cmd_tables_virt = dma_ctx.cmd_tables_virt;
        p.cmd_list_dma = dma_ctx.cmd_list_dma;
        p.fis_dma = dma_ctx.fis_dma;
        p.cmd_tables_dma = dma_ctx.cmd_tables_dma;
        p.using_iommu_dma = dma_ctx.using_iommu_dma;

        // Configure port registers using helper module
        init_mod.configurePortRegisters(base, &dma_ctx);

        // Start command engine
        port.startEngine(base);

        // Wait for device to be ready (5s per AHCI spec BSY timeout)
        if (!port.waitReady(base, Timeouts.DEVICE_READY_US)) {
            console.warn("AHCI: Port {d} device not ready", .{port_num});
        }

        // Get device signature
        p.device_type = port.readSig(base);
        p.active = true;

        const ssts = port.readSsts(base);
        console.info("AHCI: Port {d}: {} at {s}", .{
            port_num,
            @intFromEnum(p.device_type),
            ssts.speedString(),
        });

        // Try to identify the device
        if (p.device_type == .ata) {
            self.identifyDevice(port_num) catch |err| {
                console.warn("AHCI: Port {d} identify failed: {}", .{ port_num, err });
            };
        }
    }

    /// Issue IDENTIFY DEVICE command
    fn identifyDevice(self: *Self, port_num: u5) AhciError!void {
        const p = &self.ports[port_num];

        // Get device BDF for IOMMU domain
        const bdf = iommu.DeviceBdf{
            .bus = self.pci_dev.bus,
            .device = self.pci_dev.device,
            .func = self.pci_dev.func,
        };

        // Allocate IOMMU-aware buffer for identify data
        const id_buffer = if (self.cap.s64a)
            dma.allocBuffer(bdf, 512, true) catch {
                console.err("AHCI: Port {d} failed to allocate identify buffer", .{port_num});
                return AhciError.AllocationFailed;
            }
        else
            dma.allocBuffer32(bdf, 512, true) catch |err| {
                console.err("AHCI: Port {d} 32-bit identify buffer alloc failed: {}", .{ port_num, err });
                return AhciError.AllocationFailed;
            };
        defer dma.freeBuffer(&id_buffer);

        // Set up command
        const cmd_list: *command.CommandList = @ptrFromInt(p.cmd_list_virt);
        const table: *command.CommandTableBase = @ptrFromInt(p.cmd_tables_virt[0]);

        // Build IDENTIFY command (uses device address for DMA)
        command.buildIdentify(table, id_buffer.device_addr);

        // Set up command header for read (1 sector)
        cmd_list[0].initRead(p.cmd_tables_phys[0], 1);

        // Set up PRDT entry (uses device address for hardware)
        const prdt: *command.PrdtEntry = @ptrFromInt(p.cmd_tables_virt[0] + @sizeOf(command.CommandTableBase));
        prdt.* = command.PrdtEntry.init(id_buffer.device_addr, 512, true);

        // Issue command
        try self.issueCommand(port_num, 0);

        // Copy identify data (use phys_addr for CPU access via HHDM)
        const id_ptr: *fis.IdentifyData = @ptrCast(hal.paging.physToVirt(id_buffer.phys_addr));
        p.identify = id_ptr.*;

        // Log device info
        const sectors = p.identify.?.totalSectors();
        const size_mb = (sectors * 512) / (1024 * 1024);
        console.info("AHCI: Port {d}: {d} MB", .{ port_num, size_mb });
    }

    /// Issue a command and wait for completion
    fn issueCommand(self: *Self, port_num: u5, slot: u5) AhciError!void {
        return self.issueCommandWithTimeout(port_num, slot, Timeouts.COMMAND_US);
    }

    /// Issue a command and wait for completion with custom timeout
    fn issueCommandWithTimeout(self: *Self, port_num: u5, slot: u5, timeout_us: u64) AhciError!void {
        const p = &self.ports[port_num];
        const base = p.base;

        // Wait for port to be ready (5s per AHCI spec BSY timeout)
        if (!port.waitReady(base, Timeouts.DEVICE_READY_US)) {
            return AhciError.CommandTimeout;
        }

        // Clear previous error status
        p.last_is.store(0, .release);

        // Issue the command
        port.writeCi(base, @as(u32, 1) << slot);

        // Wait for completion (poll CI bit)
        const start = hal.timing.rdtsc();
        var completed = false;
        while (!hal.timing.hasTimedOut(start, timeout_us)) {
            const ci = port.readCi(base);
            if ((ci & (@as(u32, 1) << slot)) == 0) {
                completed = true;
                break;
            }

            // Check for errors
            // Use last_is to catch errors even if ISR ran and cleared the register
            const is_reg = port.readIs(base);
            const is_val = @as(u32, @bitCast(is_reg));
            const last_is_val = p.last_is.load(.acquire);
            const combined_is = is_val | last_is_val;
            
            // Re-constitute PortInterrupt from integer
            const is_combined: port.PortInterrupt = @bitCast(combined_is);

            if (is_combined.hasError()) {
                port.clearIs(base, is_reg);
                return AhciError.DeviceError;
            }

            hal.cpu.pause();
        }

        if (!completed) {
            return AhciError.CommandTimeout;
        }

        // Check task file for errors
        const tfd = port.readTfd(base);
        if (tfd.hasError()) {
            return AhciError.DeviceError;
        }
    }

    /// Read sectors from a port with Scatter-Gather
    pub fn readSectors(
        self: *Self,
        port_num: u5,
        lba: u64,
        sector_count: u16,
        buffer: []u8,
    ) AhciError!void {
        const p = &self.ports[port_num];
        if (!p.active) {
            return AhciError.PortNotConnected;
        }

        if (sector_count == 0 or sector_count > MAX_SECTORS_PER_TRANSFER) {
            return AhciError.InvalidParameter;
        }

        if (buffer.len < @as(usize, sector_count) * SECTOR_SIZE) {
            return AhciError.InvalidParameter;
        }

        // Get device BDF for IOMMU domain
        const bdf = iommu.DeviceBdf{
            .bus = self.pci_dev.bus,
            .device = self.pci_dev.device,
            .func = self.pci_dev.func,
        };

        // Allocate IOMMU-aware DMA buffers for Scatter-Gather (Bounce Buffer)
        // Max 256 sectors (128KB) = 32 pages
        var dma_bufs: [32]dma.DmaBuffer = undefined;
        var buf_count: usize = 0;

        // Cleanup on error or return
        defer {
            for (0..buf_count) |i| {
                dma.freeBuffer(&dma_bufs[i]);
            }
        }

        const total_bytes = @as(usize, sector_count) * SECTOR_SIZE;
        var bytes_acc: usize = 0;

        while (bytes_acc < total_bytes) {
            // Allocate IOMMU-aware buffer (writable since device writes to it)
            const buf = if (self.cap.s64a)
                dma.allocBuffer(bdf, pmm.PAGE_SIZE, true) catch return AhciError.AllocationFailed
            else
                dma.allocBuffer32(bdf, pmm.PAGE_SIZE, true) catch return AhciError.AllocationFailed;

            dma_bufs[buf_count] = buf;
            buf_count += 1;
            bytes_acc += 4096;
        }

        // Set up command
        const cmd_list: *command.CommandList = @ptrFromInt(p.cmd_list_virt);
        const table: *command.CommandTableBase = @ptrFromInt(p.cmd_tables_virt[0]);

        // Build READ DMA EXT command
        command.buildReadDmaExt(table, @intCast(lba), sector_count);

        // Set up command header (PRDT length = buf_count)
        cmd_list[0].initRead(p.cmd_tables_phys[0], @intCast(buf_count));

        // Set up PRDT entries (use device_addr for hardware DMA)
        var prdt_ptr: [*]command.PrdtEntry = @ptrFromInt(p.cmd_tables_virt[0] + @sizeOf(command.CommandTableBase));

        var bytes_remaining = total_bytes;
        for (0..buf_count) |i| {
            const chunk_size = if (bytes_remaining > 4096) 4096 else @as(u32, @intCast(bytes_remaining));
            const is_last = (i == buf_count - 1);

            prdt_ptr[i] = command.PrdtEntry.init(dma_bufs[i].device_addr, chunk_size, is_last);
            bytes_remaining -= chunk_size;
        }

        // Issue command
        try self.issueCommand(port_num, 0);

        // Verify hardware-reported transfer size (PRDBC) matches expected
        // This mitigates TOCTOU attacks from malicious devices
        const actual_bytes = cmd_list[0].prdbc;
        const verified_bytes: usize = if (actual_bytes > total_bytes)
            total_bytes // Cap at expected - don't trust device to report more
        else
            @intCast(actual_bytes);

        // Copy verified amount to user buffer (use phys_addr for CPU access)
        var dest_offset: usize = 0;
        bytes_remaining = verified_bytes;

        for (0..buf_count) |i| {
            if (bytes_remaining == 0) break;
            const chunk_size = if (bytes_remaining > 4096) 4096 else @as(usize, @intCast(bytes_remaining));
            const src: [*]u8 = @ptrCast(hal.paging.physToVirt(dma_bufs[i].phys_addr));

            @memcpy(buffer[dest_offset .. dest_offset + chunk_size], src[0..chunk_size]);

            dest_offset += chunk_size;
            bytes_remaining -= chunk_size;
        }

        // Return error if transfer was short
        if (verified_bytes < total_bytes) {
            return AhciError.TransferError;
        }
    }

    /// Write sectors to a port with Scatter-Gather
    pub fn writeSectors(
        self: *Self,
        port_num: u5,
        lba: u64,
        sector_count: u16,
        buffer: []const u8,
    ) AhciError!void {
        const p = &self.ports[port_num];
        if (!p.active) {
            return AhciError.PortNotConnected;
        }

        if (sector_count == 0 or sector_count > MAX_SECTORS_PER_TRANSFER) {
            return AhciError.InvalidParameter;
        }

        if (buffer.len < @as(usize, sector_count) * SECTOR_SIZE) {
            return AhciError.InvalidParameter;
        }

        // Get device BDF for IOMMU domain
        const bdf = iommu.DeviceBdf{
            .bus = self.pci_dev.bus,
            .device = self.pci_dev.device,
            .func = self.pci_dev.func,
        };

        // Allocate IOMMU-aware DMA buffers for Scatter-Gather (Bounce Buffer)
        var dma_bufs: [32]dma.DmaBuffer = undefined;
        var buf_count: usize = 0;

        defer {
            for (0..buf_count) |i| {
                dma.freeBuffer(&dma_bufs[i]);
            }
        }

        const total_bytes = @as(usize, sector_count) * SECTOR_SIZE;
        var bytes_acc: usize = 0;
        var src_offset: usize = 0;

        // Allocate and fill buffers
        var bytes_remaining_fill = total_bytes;

        while (bytes_acc < total_bytes) {
            // Allocate IOMMU-aware buffer (writable=false since device reads from it)
            const buf = if (self.cap.s64a)
                dma.allocBuffer(bdf, pmm.PAGE_SIZE, false) catch return AhciError.AllocationFailed
            else
                dma.allocBuffer32(bdf, pmm.PAGE_SIZE, false) catch return AhciError.AllocationFailed;

            dma_bufs[buf_count] = buf;
            buf_count += 1;

            // Copy data immediately (use phys_addr for CPU access)
            const chunk_size = if (bytes_remaining_fill > 4096) 4096 else @as(usize, @intCast(bytes_remaining_fill));
            const dest: [*]u8 = @ptrCast(hal.paging.physToVirt(buf.phys_addr));

            @memcpy(dest[0..chunk_size], buffer[src_offset .. src_offset + chunk_size]);

            src_offset += chunk_size;
            bytes_remaining_fill -= chunk_size;
            bytes_acc += 4096;
        }

        // Set up command
        const cmd_list: *command.CommandList = @ptrFromInt(p.cmd_list_virt);
        const table: *command.CommandTableBase = @ptrFromInt(p.cmd_tables_virt[0]);

        // Build WRITE DMA EXT command
        command.buildWriteDmaExt(table, @intCast(lba), sector_count);

        // Set up command header (PRDT length = buf_count)
        cmd_list[0].initWrite(p.cmd_tables_phys[0], @intCast(buf_count));

        // Set up PRDT entries (use device_addr for hardware DMA)
        var prdt_ptr: [*]command.PrdtEntry = @ptrFromInt(p.cmd_tables_virt[0] + @sizeOf(command.CommandTableBase));

        var bytes_remaining_prdt = total_bytes;
        for (0..buf_count) |i| {
            const chunk_size = if (bytes_remaining_prdt > 4096) 4096 else @as(u32, @intCast(bytes_remaining_prdt));
            const is_last = (i == buf_count - 1);

            prdt_ptr[i] = command.PrdtEntry.init(dma_bufs[i].device_addr, chunk_size, is_last);
            bytes_remaining_prdt -= chunk_size;
        }

        // Issue command
        try self.issueCommand(port_num, 0);
    }

    /// Flush cache on a port
    pub fn flushCache(self: *Self, port_num: u5) AhciError!void {
        const p = &self.ports[port_num];
        if (!p.active) {
            return AhciError.PortNotConnected;
        }

        // Set up command
        const cmd_list: *command.CommandList = @ptrFromInt(p.cmd_list_virt);
        const table: *command.CommandTableBase = @ptrFromInt(p.cmd_tables_virt[0]);

        // Build FLUSH CACHE EXT command
        command.buildFlushCacheExt(table);

        // Set up command header (no data transfer)
        cmd_list[0].initNonData(p.cmd_tables_phys[0]);

        // Issue command with extended timeout (30s for cache flush per Linux kernel)
        try self.issueCommandWithTimeout(port_num, 0, Timeouts.FLUSH_US);
    }

    /// Get port by number
    pub fn getPort(self: *Self, port_num: u5) ?*AhciPort {
        if (port_num >= MAX_PORTS) {
            return null;
        }
        const p = &self.ports[port_num];
        if (!p.active) {
            return null;
        }
        return p;
    }

    /// Find first active ATA port
    pub fn findAtaPort(self: *Self) ?*AhciPort {
        for (&self.ports) |*p| {
            if (p.active and p.device_type == .ata) {
                return p;
            }
        }
        return null;
    }

    // ========================================================================
    // Async I/O Methods
    // ========================================================================

    /// Find a free command slot on a port (caller must hold pending_lock)
    fn findFreeSlotLocked(p: *AhciPort) ?u5 {
        // Find first unissued slot
        var slot: u5 = 0;
        while (slot < 32) : (slot += 1) {
            if ((p.commands_issued & (@as(u32, 1) << slot)) == 0) {
                return slot;
            }
        }
        return null;
    }

    /// Read sectors asynchronously (non-blocking)
    /// Caller provides an IoRequest from the reactor pool.
    /// The request will be completed by the IRQ handler.
    pub fn readSectorsAsync(
        self: *Self,
        port_num: u5,
        lba: u64,
        sector_count: u16,
        buf_phys: u64,
        request: *io.IoRequest,
    ) AhciError!void {
        const p = &self.ports[port_num];
        if (!p.active) {
            return AhciError.PortNotConnected;
        }

        if (sector_count == 0 or sector_count > MAX_SECTORS_PER_TRANSFER) {
            return AhciError.InvalidParameter;
        }

        // Hold lock from slot allocation through command issue to prevent race
        const flags = hal.cpu.disableInterruptsSaveFlags();
        const held = p.pending_lock.acquire();
        defer {
            held.release();
            hal.cpu.restoreInterrupts(flags);
        }

        // Find free command slot under lock
        const slot = findFreeSlotLocked(p) orelse return AhciError.AllocationFailed;

        // Set up request metadata
        request.op_data = .{ .disk = .{
            .lba = lba,
            .sector_count = sector_count,
            .port = port_num,
            .slot = slot,
            ._reserved = .{ 0, 0, 0, 0 },
        } };

        // Set up command table
        const cmd_list: *command.CommandList = @ptrFromInt(p.cmd_list_virt);
        const table: *command.CommandTableBase = @ptrFromInt(p.cmd_tables_virt[slot]);

        // Build READ DMA EXT command
        command.buildReadDmaExt(table, @intCast(lba), sector_count);

        // Set up command header
        cmd_list[slot].initRead(p.cmd_tables_phys[slot], 1);

        // Set up PRDT entry (single contiguous buffer)
        const prdt: *command.PrdtEntry = @ptrFromInt(p.cmd_tables_virt[slot] + @sizeOf(command.CommandTableBase));
        const total_bytes: u32 = @as(u32, sector_count) * @as(u32, @truncate(SECTOR_SIZE));
        prdt.* = command.PrdtEntry.init(buf_phys, total_bytes, true);

        // Register pending request (still under lock)
        p.pending_requests[slot] = request;
        p.commands_issued |= @as(u32, 1) << slot;

        // Transition request to in_progress
        _ = request.compareAndSwapState(.pending, .in_progress);

        // Issue the command (non-blocking - IRQ will complete it)
        port.writeCi(p.base, @as(u32, 1) << slot);
    }

    /// Write sectors asynchronously (non-blocking)
    pub fn writeSectorsAsync(
        self: *Self,
        port_num: u5,
        lba: u64,
        sector_count: u16,
        buf_phys: u64,
        request: *io.IoRequest,
    ) AhciError!void {
        const p = &self.ports[port_num];
        if (!p.active) {
            return AhciError.PortNotConnected;
        }

        if (sector_count == 0 or sector_count > MAX_SECTORS_PER_TRANSFER) {
            return AhciError.InvalidParameter;
        }

        // Hold lock from slot allocation through command issue to prevent race
        const flags = hal.cpu.disableInterruptsSaveFlags();
        const held = p.pending_lock.acquire();
        defer {
            held.release();
            hal.cpu.restoreInterrupts(flags);
        }

        // Find free command slot under lock
        const slot = findFreeSlotLocked(p) orelse return AhciError.AllocationFailed;

        // Set up request metadata
        request.op_data = .{ .disk = .{
            .lba = lba,
            .sector_count = sector_count,
            .port = port_num,
            .slot = slot,
            ._reserved = .{ 0, 0, 0, 0 },
        } };

        // Set up command table
        const cmd_list: *command.CommandList = @ptrFromInt(p.cmd_list_virt);
        const table: *command.CommandTableBase = @ptrFromInt(p.cmd_tables_virt[slot]);

        // Build WRITE DMA EXT command
        command.buildWriteDmaExt(table, @intCast(lba), sector_count);

        // Set up command header
        cmd_list[slot].initWrite(p.cmd_tables_phys[slot], 1);

        // Set up PRDT entry
        const prdt: *command.PrdtEntry = @ptrFromInt(p.cmd_tables_virt[slot] + @sizeOf(command.CommandTableBase));
        const total_bytes: u32 = @as(u32, sector_count) * @as(u32, @truncate(SECTOR_SIZE));
        prdt.* = command.PrdtEntry.init(buf_phys, total_bytes, true);

        // Register pending request (still under lock)
        p.pending_requests[slot] = request;
        p.commands_issued |= @as(u32, 1) << slot;

        // Transition request to in_progress
        _ = request.compareAndSwapState(.pending, .in_progress);

        // Issue the command
        port.writeCi(p.base, @as(u32, 1) << slot);
    }

    /// Handle AHCI interrupt - called from IRQ handler
    /// Checks all ports for completed commands and completes IoRequests
    pub fn handleInterrupt(self: *Self) void {
        // Read and clear global interrupt status
        const is = hba.readInterruptStatus(self.hba_base);
        if (is == 0) return;

        // Clear the bits we're handling
        hba.clearInterruptStatus(self.hba_base, is);

        // Process each port that has an interrupt pending
        var port_mask = is;
        while (port_mask != 0) {
            const port_num: u5 = @intCast(@ctz(port_mask));
            port_mask &= ~(@as(u32, 1) << port_num);

            self.handlePortInterrupt(port_num);
        }
    }

    /// Handle interrupt for a specific port
    fn handlePortInterrupt(self: *Self, port_num: u5) void {
        // Explicit bounds check for defense-in-depth (u5 max is 31, MAX_PORTS is 32)
        if (@as(usize, port_num) >= MAX_PORTS) return;

        const p = &self.ports[port_num];
        if (!p.active) return;

        // Read and clear port interrupt status
        // Read and clear port interrupt status
        const pis = port.readIs(p.base);
        port.clearIs(p.base, pis);

        // Accumulate status for sync commands
        _ = p.last_is.fetchOr(@as(u32, @bitCast(pis)), .acq_rel);

        // Check which commands completed
        const ci = port.readCi(p.base);

        // Commands that were issued but are no longer in CI have completed
        const completed = p.commands_issued & ~ci;

        if (completed == 0) return;

        // Check for global error conditions
        const tfd = port.readTfd(p.base);
        const port_has_error = tfd.hasError() or pis.hasError();

        // Get command list for PRDBC verification
        const cmd_list: *command.CommandList = @ptrFromInt(p.cmd_list_virt);

        // Complete each finished command's request with per-slot validation
        var slot_mask = completed;
        while (slot_mask != 0) {
            const slot: u5 = @intCast(@ctz(slot_mask));
            slot_mask &= ~(@as(u32, 1) << slot);

            // Get and clear pending request under lock
            var req: ?*io.IoRequest = null;
            {
                const held = p.pending_lock.acquire();
                defer held.release();

                req = p.pending_requests[slot];
                p.pending_requests[slot] = null;
                p.commands_issued &= ~(@as(u32, 1) << slot);
            }

            // Complete the IoRequest
            if (req) |request| {
                // Per-slot validation: check PRDBC (actual bytes transferred)
                const expected_bytes = @as(usize, request.op_data.disk.sector_count) * SECTOR_SIZE;
                const actual_bytes = cmd_list[slot].prdbc;

                // Determine if this specific slot had an error:
                // - Port-level error AND this was the only command = slot errored
                // - Transfer incomplete (PRDBC < expected) = slot errored
                // - Otherwise = successful
                const slot_error = port_has_error or (actual_bytes < expected_bytes);

                if (slot_error) {
                    _ = request.complete(.{ .err = error.EIO });
                } else {
                    // Success - return verified bytes transferred
                    // Cap at expected bytes for safety (don't trust device overreporting)
                    const verified_bytes: usize = if (actual_bytes > expected_bytes)
                        expected_bytes
                    else
                        @intCast(actual_bytes);
                    _ = request.complete(.{ .success = verified_bytes });
                }
            }
        }
    }
};

// ============================================================================
// Module-level initialization
// ============================================================================

/// Global AHCI controller instance
var controller_instance: ?*AhciController = null;

/// Initialize AHCI from a PCI device
pub fn initFromPci(pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) AhciError!*AhciController {
    // Allocate controller struct on heap to avoid stack overflow (~20KB)
    const alloc = heap.allocator();
    const controller = alloc.create(AhciController) catch return AhciError.AllocationFailed;

    // Initialize in-place
    controller.init(pci_dev, pci_access) catch |err| {
        alloc.destroy(controller);
        return err;
    };

    controller_instance = controller;
    return controller;
}

/// Get the global controller instance
pub fn getController() ?*AhciController {
    return controller_instance;
}

// ============================================================================
// IRQ Handler
// ============================================================================

/// AHCI IRQ handler - called from interrupt dispatcher
pub fn ahciIrqHandler(_: *hal.idt.InterruptFrame) void {
    if (controller_instance) |controller| {
        controller.handleInterrupt();
    }
}

/// Register AHCI IRQ handler with the interrupt system
/// Call this after initFromPci to enable interrupt-driven I/O
pub fn registerIrqHandler(controller: *AhciController) void {
    const irq = controller.pci_dev.irq_line;
    if (irq == 0 or irq == 255) {
        console.warn("AHCI: No valid IRQ line configured", .{});
        return;
    }

    // IRQ line + PIC offset (typically 32 for hardware IRQs)
    const vector = @as(u8, @intCast(irq)) + 32;

    // Register with interrupt system (uses global controller_instance)
    hal.interrupts.registerHandler(vector, ahciIrqHandler);

    // Enable global HBA interrupts
    var ghc = hba.readGhc(controller.hba_base);
    ghc.ie = true;
    hba.writeGhc(controller.hba_base, ghc);

    console.info("AHCI: IRQ handler registered on vector {d}", .{vector});
}

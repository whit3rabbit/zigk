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

pub const hba = @import("hba.zig");
pub const port = @import("port.zig");
pub const command = @import("command.zig");
pub const fis = @import("fis.zig");
pub const adapter = @import("adapter.zig");

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

    /// Command list physical address
    cmd_list_phys: u64,

    /// Command list virtual address
    cmd_list_virt: u64,

    /// FIS receive buffer physical address
    fis_phys: u64,

    /// FIS receive buffer virtual address
    fis_virt: u64,

    /// Command tables physical address (array of 32)
    cmd_tables_phys: [32]u64,

    /// Command tables virtual address (array of 32)
    cmd_tables_virt: [32]u64,

    /// Device identify data (if available)
    identify: ?fis.IdentifyData,

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
            .identify = null,
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
    pub fn init(self: *Self, pci_dev: *const pci.PciDevice, ecam: *const pci.Ecam) AhciError!void {
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
        const cmd = ecam.readCommand(pci_dev.bus, pci_dev.device, pci_dev.func);
        ecam.writeCommand(pci_dev.bus, pci_dev.device, pci_dev.func, cmd | pci.Command.BUS_MASTER | pci.Command.MEMORY_SPACE);

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

        // Allocate command list (1KB aligned)
        const cmd_list_phys = pmm.allocZeroedPages(1) orelse {
            return AhciError.AllocationFailed;
        };
        // Check 64-bit capability
        if (!self.cap.s64a and cmd_list_phys > 0xFFFFFFFF) {
            pmm.freePages(cmd_list_phys, 1);
            console.err("AHCI: Port {d} cmd list > 4GB but controller is 32-bit", .{port_num});
            return AhciError.AllocationFailed;
        }
        p.cmd_list_phys = cmd_list_phys;
        p.cmd_list_virt = @intFromPtr(hal.paging.physToVirt(cmd_list_phys));

        // Allocate FIS receive buffer (256 bytes, but allocate full page)
        const fis_phys = pmm.allocZeroedPages(1) orelse {
            return AhciError.AllocationFailed;
        };
        if (!self.cap.s64a and fis_phys > 0xFFFFFFFF) {
            pmm.freePages(fis_phys, 1);
            console.err("AHCI: Port {d} FIS > 4GB but controller is 32-bit", .{port_num});
            return AhciError.AllocationFailed;
        }
        p.fis_phys = fis_phys;
        p.fis_virt = @intFromPtr(hal.paging.physToVirt(fis_phys));

        // Allocate command tables (one page per table for simplicity)
        for (0..32) |slot| {
            const table_phys = pmm.allocZeroedPages(1) orelse {
                return AhciError.AllocationFailed;
            };
            if (!self.cap.s64a and table_phys > 0xFFFFFFFF) {
                pmm.freePages(table_phys, 1);
                console.err("AHCI: Port {d} table > 4GB but controller is 32-bit", .{port_num});
                return AhciError.AllocationFailed;
            }
            p.cmd_tables_phys[slot] = table_phys;
            p.cmd_tables_virt[slot] = @intFromPtr(hal.paging.physToVirt(table_phys));

            // Set up command header to point to this table
            const cmd_list: *command.CommandList = @ptrFromInt(p.cmd_list_virt);
            cmd_list[slot].setCommandTableAddr(table_phys);
        }

        // Set command list and FIS base addresses
        port.writeClb(base, p.cmd_list_phys);
        port.writeFb(base, p.fis_phys);

        // Clear SATA error
        port.clearSerr(base, 0xFFFFFFFF);

        // Clear interrupt status
        port.clearIs(base, @bitCast(@as(u32, 0xFFFFFFFF)));

        // Enable interrupts (D2H, error)
        port.writeIe(base, .{
            .dhrs = true, // Device to Host Register FIS
            .pss = true, // PIO Setup
            .dss = true, // DMA Setup
            .sdbs = true, // Set Device Bits
            .ufs = false,
            .dps = false,
            .pcs = false,
            .dmps = false,
            .prcs = false,
            .ipms = false,
            .ofs = true,
            .infs = true,
            .ifs = true,
            .hbds = true,
            .hbfs = true,
            .tfes = true,
            .cpds = false,
        });

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

        // Allocate buffer for identify data
        const buffer_pages = pmm.allocZeroedPages(1) orelse {
            return AhciError.AllocationFailed;
        };
        defer pmm.freePages(buffer_pages, 1);

        // Check 64-bit capability
        if (!self.cap.s64a and buffer_pages > 0xFFFFFFFF) {
            console.err("AHCI: Port {d} identify buffer > 4GB but controller is 32-bit", .{port_num});
            return AhciError.AllocationFailed;
        }

        // Set up command
        const cmd_list: *command.CommandList = @ptrFromInt(p.cmd_list_virt);
        const table: *command.CommandTableBase = @ptrFromInt(p.cmd_tables_virt[0]);

        // Build IDENTIFY command
        command.buildIdentify(table, buffer_pages);

        // Set up command header for read (1 sector)
        cmd_list[0].initRead(p.cmd_tables_phys[0], 1);

        // Set up PRDT entry
        const prdt: *command.PrdtEntry = @ptrFromInt(p.cmd_tables_virt[0] + @sizeOf(command.CommandTableBase));
        prdt.* = command.PrdtEntry.init(buffer_pages, 512, true);

        // Issue command
        try self.issueCommand(port_num, 0);

        // Copy identify data
        // Copy identify data
        const id_ptr: *fis.IdentifyData = @ptrCast(hal.paging.physToVirt(buffer_pages));
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
            const is = port.readIs(base);
            if (is.hasError()) {
                port.clearIs(base, is);
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

        // Allocate pages for Scatter-Gather (Bounce Buffer)
        // Max 256 sectors (128KB) = 32 pages
        var pages: [32]u64 = undefined;
        var page_count: usize = 0;
        
        // Cleanup on error or return
        defer {
            for (0..page_count) |i| {
                pmm.freePage(pages[i]);
            }
        }

        const total_bytes = @as(usize, sector_count) * SECTOR_SIZE;
        var bytes_acc: usize = 0;

        while (bytes_acc < total_bytes) {
            const page = pmm.allocZeroedPage() orelse return AhciError.AllocationFailed;
            
            // Check 64-bit capability
            if (!self.cap.s64a and page > 0xFFFFFFFF) {
                pmm.freePage(page);
                return AhciError.AllocationFailed;
            }
            
            pages[page_count] = page;
            page_count += 1;
            bytes_acc += 4096;
        }

        // Set up command
        const cmd_list: *command.CommandList = @ptrFromInt(p.cmd_list_virt);
        const table: *command.CommandTableBase = @ptrFromInt(p.cmd_tables_virt[0]);

        // Build READ DMA EXT command
        command.buildReadDmaExt(table, @intCast(lba), sector_count);

        // Set up command header (PRDT length = page_count)
        cmd_list[0].initRead(p.cmd_tables_phys[0], @intCast(page_count));

        // Set up PRDT entries
        var prdt_ptr: [*]command.PrdtEntry = @ptrFromInt(p.cmd_tables_virt[0] + @sizeOf(command.CommandTableBase));
        
        var bytes_remaining = total_bytes;
        for (0..page_count) |i| {
            const chunk_size = if (bytes_remaining > 4096) 4096 else @as(u32, @intCast(bytes_remaining));
            const is_last = (i == page_count - 1);
            
            prdt_ptr[i] = command.PrdtEntry.init(pages[i], chunk_size, is_last);
            bytes_remaining -= chunk_size;
        }

        // Issue command
        try self.issueCommand(port_num, 0);

        // Copy data to user buffer
        var dest_offset: usize = 0;
        bytes_remaining = total_bytes;
        
        for (0..page_count) |i| {
            const chunk_size = if (bytes_remaining > 4096) 4096 else @as(usize, @intCast(bytes_remaining));
            const src: [*]u8 = @ptrCast(hal.paging.physToVirt(pages[i]));
            
            @memcpy(buffer[dest_offset .. dest_offset + chunk_size], src[0..chunk_size]);
            
            dest_offset += chunk_size;
            bytes_remaining -= chunk_size;
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

        // Allocate pages for Scatter-Gather (Bounce Buffer)
        var pages: [32]u64 = undefined;
        var page_count: usize = 0;
        
        defer {
            for (0..page_count) |i| {
                pmm.freePage(pages[i]);
            }
        }

        const total_bytes = @as(usize, sector_count) * SECTOR_SIZE;
        var bytes_acc: usize = 0;
        var src_offset: usize = 0;

        // Allocate and fill pages
        var bytes_remaining_fill = total_bytes;
        
        while (bytes_acc < total_bytes) {
            const page = pmm.allocZeroedPage() orelse return AhciError.AllocationFailed;
            
             // Check 64-bit capability
            if (!self.cap.s64a and page > 0xFFFFFFFF) {
                pmm.freePage(page);
                return AhciError.AllocationFailed;
            }

            pages[page_count] = page;
            page_count += 1;
            
            // Copy data immediately
            const chunk_size = if (bytes_remaining_fill > 4096) 4096 else @as(usize, @intCast(bytes_remaining_fill));
            const dest: [*]u8 = @ptrCast(hal.paging.physToVirt(page));
            
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

        // Set up command header (PRDT length = page_count)
        cmd_list[0].initWrite(p.cmd_tables_phys[0], @intCast(page_count));

        // Set up PRDT entries
        var prdt_ptr: [*]command.PrdtEntry = @ptrFromInt(p.cmd_tables_virt[0] + @sizeOf(command.CommandTableBase));
        
        var bytes_remaining_prdt = total_bytes;
        for (0..page_count) |i| {
            const chunk_size = if (bytes_remaining_prdt > 4096) 4096 else @as(u32, @intCast(bytes_remaining_prdt));
            const is_last = (i == page_count - 1);
            
            prdt_ptr[i] = command.PrdtEntry.init(pages[i], chunk_size, is_last);
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
};

// ============================================================================
// Module-level initialization
// ============================================================================

/// Global AHCI controller instance
var controller_instance: ?*AhciController = null;

/// Initialize AHCI from a PCI device
pub fn initFromPci(pci_dev: *const pci.PciDevice, ecam: *const pci.Ecam) AhciError!*AhciController {
    // Allocate controller struct on heap to avoid stack overflow (~20KB)
    const alloc = heap.allocator();
    const controller = alloc.create(AhciController) catch return AhciError.AllocationFailed;
    
    // Initialize in-place
    controller.init(pci_dev, ecam) catch |err| {
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

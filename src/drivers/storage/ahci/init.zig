// AHCI Port Initialization
//
// Provides port initialization and device identification for AHCI controllers.
// Extracted from root.zig for better modularity.

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const pmm = @import("pmm");
const dma = @import("dma");
const iommu = @import("iommu");
const sync = @import("sync");
const io = @import("io");

const hba = @import("hba.zig");
const port = @import("port.zig");
const command = @import("command.zig");
const fis = @import("fis.zig");

// Timeout constants
pub const Timeouts = struct {
    // Real hardware timeouts
    pub const DEVICE_READY_US: u64 = 5_000_000; // 5s - BSY/DRQ clear (AHCI spec minimum)
    pub const COMMAND_US: u64 = 7_000_000; // 7s - Standard command timeout
    // Emulator timeouts
    pub const COMMAND_US_EMU: u64 = 1_000_000; // 1s
};

/// Check if running on emulator platform (QEMU TCG, unknown hypervisor)
fn isEmulatorPlatform() bool {
    const hv = hal.hypervisor.getHypervisor();
    return hv == .qemu_tcg or hv == .unknown;
}

/// Get command timeout based on platform
pub fn getCommandTimeout() u64 {
    return if (isEmulatorPlatform()) Timeouts.COMMAND_US_EMU else Timeouts.COMMAND_US;
}

/// Port DMA memory context
pub const PortDmaContext = struct {
    cmd_list_phys: u64,
    cmd_list_virt: u64,
    fis_phys: u64,
    fis_virt: u64,
    cmd_tables_phys: [32]u64,
    cmd_tables_virt: [32]u64,
    cmd_list_dma: dma.DmaBuffer,
    fis_dma: dma.DmaBuffer,
    cmd_tables_dma: [32]dma.DmaBuffer,
    using_iommu_dma: bool,
};

/// Allocate DMA memory for a port
/// Returns error if allocation fails
pub fn allocatePortDma(
    port_num: u5,
    bdf: iommu.DeviceBdf,
    supports_64bit: bool,
) !PortDmaContext {
    var ctx: PortDmaContext = undefined;
    ctx.cmd_list_phys = 0;
    ctx.fis_phys = 0;
    ctx.cmd_tables_phys = [_]u64{0} ** 32;

    // Track allocations for cleanup on error
    var cmd_list_allocated = false;
    var fis_allocated = false;
    var tables_allocated: usize = 0;

    errdefer {
        if (cmd_list_allocated) {
            dma.freeBuffer(&ctx.cmd_list_dma);
        }
        if (fis_allocated) {
            dma.freeBuffer(&ctx.fis_dma);
        }
        for (0..tables_allocated) |slot| {
            if (ctx.cmd_tables_phys[slot] != 0) {
                dma.freeBuffer(&ctx.cmd_tables_dma[slot]);
            }
        }
    }

    // Allocate command list with IOMMU-aware DMA (1KB aligned, page-sized)
    if (supports_64bit) {
        ctx.cmd_list_dma = dma.allocBuffer(bdf, pmm.PAGE_SIZE, true) catch {
            return error.AllocationFailed;
        };
    } else {
        // 32-bit controller requires addresses below 4GB
        ctx.cmd_list_dma = dma.allocBuffer32(bdf, pmm.PAGE_SIZE, true) catch |err| {
            if (err == dma.DmaError.AddressTooHigh) {
                console.err("AHCI: Port {d} cmd list > 4GB but controller is 32-bit", .{port_num});
            }
            return error.AllocationFailed;
        };
    }
    cmd_list_allocated = true;
    ctx.cmd_list_phys = ctx.cmd_list_dma.device_addr;
    ctx.cmd_list_virt = @intFromPtr(ctx.cmd_list_dma.getVirt());

    // Allocate FIS receive buffer with IOMMU-aware DMA
    if (supports_64bit) {
        ctx.fis_dma = dma.allocBuffer(bdf, pmm.PAGE_SIZE, true) catch {
            return error.AllocationFailed;
        };
    } else {
        ctx.fis_dma = dma.allocBuffer32(bdf, pmm.PAGE_SIZE, true) catch |err| {
            if (err == dma.DmaError.AddressTooHigh) {
                console.err("AHCI: Port {d} FIS > 4GB but controller is 32-bit", .{port_num});
            }
            return error.AllocationFailed;
        };
    }
    fis_allocated = true;
    ctx.fis_phys = ctx.fis_dma.device_addr;
    ctx.fis_virt = @intFromPtr(ctx.fis_dma.getVirt());

    // Allocate command tables with IOMMU-aware DMA (one page per table)
    for (0..32) |slot| {
        if (supports_64bit) {
            ctx.cmd_tables_dma[slot] = dma.allocBuffer(bdf, pmm.PAGE_SIZE, true) catch {
                return error.AllocationFailed;
            };
        } else {
            ctx.cmd_tables_dma[slot] = dma.allocBuffer32(bdf, pmm.PAGE_SIZE, true) catch |err| {
                if (err == dma.DmaError.AddressTooHigh) {
                    console.err("AHCI: Port {d} table > 4GB but controller is 32-bit", .{port_num});
                }
                return error.AllocationFailed;
            };
        }
        tables_allocated = slot + 1;
        ctx.cmd_tables_phys[slot] = ctx.cmd_tables_dma[slot].device_addr;
        ctx.cmd_tables_virt[slot] = @intFromPtr(ctx.cmd_tables_dma[slot].getVirt());

        // Set up command header to point to this table (using device address)
        const cmd_list: *command.CommandList = @ptrFromInt(ctx.cmd_list_virt);
        cmd_list[slot].setCommandTableAddr(ctx.cmd_tables_phys[slot]);
    }

    ctx.using_iommu_dma = dma.isIommuAvailable();
    return ctx;
}

/// Configure port registers after DMA memory is allocated
pub fn configurePortRegisters(base: u64, dma_ctx: *const PortDmaContext) void {
    // Set command list and FIS base addresses
    port.writeClb(base, dma_ctx.cmd_list_phys);
    port.writeFb(base, dma_ctx.fis_phys);

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
}

/// Issue IDENTIFY DEVICE command and return the identify data
pub fn identifyDevice(
    port_num: u5,
    port_base: u64,
    cmd_list_virt: u64,
    cmd_tables_virt: u64,
    cmd_tables_phys: u64,
    bdf: iommu.DeviceBdf,
    supports_64bit: bool,
    issueCommandFn: *const fn (u5, u5, u64) anyerror!void,
) !fis.IdentifyData {
    // Allocate IOMMU-aware buffer for identify data
    const id_buffer = if (supports_64bit)
        dma.allocBuffer(bdf, 512, true) catch {
            console.err("AHCI: Port {d} failed to allocate identify buffer", .{port_num});
            return error.AllocationFailed;
        }
    else
        dma.allocBuffer32(bdf, 512, true) catch |err| {
            console.err("AHCI: Port {d} 32-bit identify buffer alloc failed: {}", .{ port_num, err });
            return error.AllocationFailed;
        };
    defer dma.freeBuffer(&id_buffer);

    // Set up command
    const cmd_list: *command.CommandList = @ptrFromInt(cmd_list_virt);
    const table: *command.CommandTableBase = @ptrFromInt(cmd_tables_virt);

    // Build IDENTIFY command (uses device address for DMA)
    command.buildIdentify(table, id_buffer.device_addr);

    // Set up command header for read (1 sector)
    cmd_list[0].initRead(cmd_tables_phys, 1);

    // Set up PRDT entry (uses device address for hardware)
    const prdt: *command.PrdtEntry = @ptrFromInt(cmd_tables_virt + @sizeOf(command.CommandTableBase));
    prdt.* = command.PrdtEntry.init(id_buffer.device_addr, 512, true);

    // Issue command using provided function pointer
    _ = port_base; // Port base is used internally by issueCommandFn
    try issueCommandFn(port_num, 0, getCommandTimeout());

    // Copy identify data (use phys_addr for CPU access via HHDM)
    const id_ptr: *fis.IdentifyData = @ptrCast(hal.paging.physToVirt(id_buffer.phys_addr));
    return id_ptr.*;
}

/// Log device information after identification
pub fn logDeviceInfo(port_num: u5, identify: *const fis.IdentifyData) void {
    const sectors = identify.totalSectors();
    const size_mb = (sectors * 512) / (1024 * 1024);
    console.info("AHCI: Port {d}: {d} MB", .{ port_num, size_mb });
}

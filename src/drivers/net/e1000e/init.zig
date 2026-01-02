//! E1000e Initialization and Lifecycle

const std = @import("std");
const hal = @import("hal");
const pci = @import("pci");
const vmm = @import("vmm");
const pmm = @import("pmm");
const console = @import("console");
const thread = @import("thread");
const sched = @import("sched");
const net = @import("net");
const sync = @import("sync");
const dma = @import("dma");
const iommu = @import("iommu");

const MmioDevice = hal.mmio_device.MmioDevice;
const types = @import("types.zig");
const regs = @import("regs.zig");
const desc_mod = @import("desc.zig");
const ctl = @import("ctl.zig");
const config = @import("config.zig");
const pool_mod = @import("pool.zig");
const worker = @import("worker.zig"); // Forward reference to worker

const E1000e = types.E1000e;
const Reg = regs.Reg;
const RxDesc = desc_mod.RxDesc;
const TxDesc = desc_mod.TxDesc;
const DeviceCtl = ctl.DeviceCtl;
const ReceiveCtl = ctl.ReceiveCtl;
const TransmitCtl = ctl.TransmitCtl;

/// Static driver instance (singleton for now)
/// Explicit 64-byte alignment ensures @alignCast in worker thread succeeds
/// (E1000e contains arrays/pointers that may require high alignment)
var driver_instance: E1000e align(64) = undefined;
var driver_initialized: bool = false;

/// Initialize E1000 driver for a PCI device
/// Supports both legacy E1000 (82540EM) and PCIe E1000e (82574L)
pub fn init(pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) !*E1000e {
    // Guard against double-init using atomic compare-and-swap.
    // This prevents the TOCTOU race where two threads could both see
    // driver_initialized=false and proceed with concurrent initialization.
    if (@cmpxchgStrong(bool, &driver_initialized, false, true, .acq_rel, .acquire)) |_| {
        // cmpxchgStrong returns non-null if the exchange failed (already true)
        console.err("E1000e: Driver already initialized - call deinit() first", .{});
        return error.AlreadyInitialized;
    }
    // Successfully claimed initialization - reset to false on error
    errdefer @atomicStore(bool, &driver_initialized, false, .release);

    console.info("E1000e: Initializing {x:0>4}:{x:0>4}", .{
        pci_dev.vendor_id,
        pci_dev.device_id,
    });

    // Get MMIO BAR
    const bar = pci_dev.getMmioBar() orelse {
        console.err("E1000e: No MMIO BAR found", .{});
        return error.NoMmioBar;
    };

    console.info("E1000e: BAR0 at phys=0x{x:0>16} size={d}KB", .{
        bar.base,
        bar.size / 1024,
    });

    // Enable bus mastering and memory space
    pci_access.enableBusMaster(pci_dev.bus, pci_dev.device, pci_dev.func);
    pci_access.enableMemorySpace(pci_dev.bus, pci_dev.device, pci_dev.func);

    // Map MMIO region
    const mmio_base = vmm.mapMmio(bar.base, bar.size) catch |err| {
        console.err("E1000e: Failed to map MMIO: {}", .{err});
        return error.MmioMapFailed;
    };

    // Allocate driver state (using static for now, should use heap)
    const driver = &driver_instance;

    // Cleanup previous allocations if any (prevents memory leak on re-init)
    if (driver.rx_ring_phys != 0 or driver.tx_ring_phys != 0) {
        console.warn("E1000e: Cleaning up previous allocations before re-init", .{});
        freeRings(driver);
    }

    driver.* = E1000e{
        .regs = MmioDevice(Reg).init(mmio_base, bar.size),
        .mac_addr = [_]u8{0} ** 6,
        .rx_ring = undefined,
        .rx_ring_phys = 0,
        .tx_ring = undefined,
        .tx_ring_phys = 0,
        .rx_buffers = undefined,
        .rx_buffers_phys = [_]u64{0} ** types.RX_DESC_COUNT,
        .tx_buffers = undefined,
        .tx_buffers_phys = [_]u64{0} ** types.TX_DESC_COUNT,
        .rx_ring_dma = undefined,
        .tx_ring_dma = undefined,
        .rx_buf_dma = undefined,
        .tx_buf_dma = undefined,
        .using_iommu_dma = false,
        .rx_cur = 0,
        .tx_cur = 0,
        .pending_tx_requests = [_]?*@import("io").IoRequest{null} ** types.TX_DESC_COUNT,
        .tx_completion_idx = 0,
        .irq_line = pci_dev.irq_line,
        .lock = sync.Spinlock{},
        .rx_packets = 0,
        .tx_packets = 0,
        .rx_bytes = 0,
        .tx_bytes = 0,
        .rx_errors = 0,
        .rx_crc_errors = 0,
        .rx_dropped = 0,
        .tx_dropped = 0,
        .tx_watchdog_last_tdh = 0,
        .tx_watchdog_stall_count = 0,
        .worker_thread = null,
        .rx_callback = null,
        .msix_enabled = false,
        .msix_table_base = 0,
        .msix_table_size = 0,
        .msix_vectors = [_]u8{0} ** 3,
        .pci_dev = pci_dev,
        .pci_access = pci_access,
        .shutdown_requested = false,
    };

    // Reset device
    reset(driver);

    // Read MAC address
    readMacAddress(driver);
    console.info("E1000e: MAC address {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
        driver.mac_addr[0],
        driver.mac_addr[1],
        driver.mac_addr[2],
        driver.mac_addr[3],
        driver.mac_addr[4],
        driver.mac_addr[5],
    });

    // Allocate descriptor rings and buffers
    try allocateRings(driver);
    errdefer freeRings(driver); // Cleanup if subsequent init steps fail

    // Initialize RX
    initRx(driver);

    // Initialize TX
    initTx(driver);

    // Clear multicast table
    clearMulticastTable(driver);

    // Try to enable MSI-X (falls back to legacy if not available)
    initMsix(driver);

    // Enable interrupts (uses MSI-X or legacy based on initMsix result)
    enableInterrupts(driver);

    // driver_initialized was set to true by cmpxchgStrong at function entry.
    // errdefer will reset it to false if any error occurs before this point.

    // Create worker thread
    // Pass workerEntry directly from worker module
    driver.worker_thread = try thread.createKernelThread(worker.workerEntry, driver, .{
        .name = "net_worker",
        .priority = 10, // High priority
    });
    sched.addThread(driver.worker_thread.?);

    // Enable RX and TX
    enableRxTx(driver);

    console.info("E1000e: Initialization complete", .{});
    return driver;
}

pub fn reset(driver: *E1000e) void {
    console.info("E1000e: Resetting device...", .{});

    driver.writeCtrl(.{ .device_reset = true });

    const reset_mask = (DeviceCtl{ .device_reset = true }).toRaw();
    if (!driver.regs.pollTimed(.ctrl, reset_mask, 0, 100_000)) {
        console.warn("E1000e: Reset timeout (RST bit stuck)", .{});
    }

    driver.regs.write(.imc, 0xFFFFFFFF);
    _ = driver.regs.read(.icr);

    console.info("E1000e: Reset complete", .{});
}

fn readMacAddress(driver: *E1000e) void {
    const ral = driver.regs.read(.ral0);
    const rah = driver.regs.read(.rah0);

    driver.mac_addr[0] = @truncate(ral);
    driver.mac_addr[1] = @truncate(ral >> 8);
    driver.mac_addr[2] = @truncate(ral >> 16);
    driver.mac_addr[3] = @truncate(ral >> 24);
    driver.mac_addr[4] = @truncate(rah);
    driver.mac_addr[5] = @truncate(rah >> 8);
}

fn allocateRings(driver: *E1000e) !void {
    // Get device BDF for IOMMU domain
    const bdf = iommu.DeviceBdf{
        .bus = driver.pci_dev.bus,
        .device = driver.pci_dev.device,
        .func = driver.pci_dev.func,
    };

    const rx_ring_size = types.RX_DESC_COUNT * @sizeOf(RxDesc);
    const tx_ring_size = types.TX_DESC_COUNT * @sizeOf(TxDesc);

    // Allocate RX ring with IOMMU-aware DMA
    driver.rx_ring_dma = dma.allocBuffer(bdf, rx_ring_size, true) catch |err| {
        console.err("E1000e: Failed to allocate RX ring: {}", .{err});
        return error.OutOfMemory;
    };
    errdefer dma.freeBuffer(&driver.rx_ring_dma);

    driver.rx_ring_phys = driver.rx_ring_dma.device_addr;
    driver.rx_ring = @ptrCast(@volatileCast(driver.rx_ring_dma.getTypedPtr([types.RX_DESC_COUNT]RxDesc)));

    // Allocate TX ring with IOMMU-aware DMA
    driver.tx_ring_dma = dma.allocBuffer(bdf, tx_ring_size, true) catch |err| {
        console.err("E1000e: Failed to allocate TX ring: {}", .{err});
        return error.OutOfMemory;
    };
    errdefer dma.freeBuffer(&driver.tx_ring_dma);

    driver.tx_ring_phys = driver.tx_ring_dma.device_addr;
    driver.tx_ring = @ptrCast(@volatileCast(driver.tx_ring_dma.getTypedPtr([types.TX_DESC_COUNT]TxDesc)));

    // Allocate RX buffers
    var rx_buffers_allocated: usize = 0;
    errdefer {
        for (0..rx_buffers_allocated) |i| {
            dma.freeBuffer(&driver.rx_buf_dma[i]);
        }
    }

    for (0..types.RX_DESC_COUNT) |i| {
        driver.rx_buf_dma[i] = dma.allocBuffer(bdf, pmm.PAGE_SIZE, true) catch |err| {
            console.err("E1000e: Failed to allocate RX buffer {d}: {}", .{ i, err });
            return error.OutOfMemory;
        };
        driver.rx_buffers_phys[i] = driver.rx_buf_dma[i].device_addr;
        driver.rx_buffers[i] = driver.rx_buf_dma[i].getVirt();
        rx_buffers_allocated += 1;
    }

    // Allocate TX buffers
    var tx_buffers_allocated: usize = 0;
    errdefer {
        for (0..tx_buffers_allocated) |i| {
            dma.freeBuffer(&driver.tx_buf_dma[i]);
        }
    }

    for (0..types.TX_DESC_COUNT) |i| {
        driver.tx_buf_dma[i] = dma.allocBuffer(bdf, pmm.PAGE_SIZE, true) catch |err| {
            console.err("E1000e: Failed to allocate TX buffer {d}: {}", .{ i, err });
            return error.OutOfMemory;
        };
        driver.tx_buffers_phys[i] = driver.tx_buf_dma[i].device_addr;
        driver.tx_buffers[i] = driver.tx_buf_dma[i].getVirt();
        tx_buffers_allocated += 1;
    }

    driver.using_iommu_dma = dma.isIommuAvailable();

    console.info("E1000e: Allocated {d} RX and {d} TX descriptors (IOMMU: {})", .{
        types.RX_DESC_COUNT,
        types.TX_DESC_COUNT,
        driver.using_iommu_dma,
    });
}

pub fn freeRings(driver: *E1000e) void {
    // Free RX buffers (IOMMU-aware)
    for (0..types.RX_DESC_COUNT) |i| {
        if (driver.rx_buffers_phys[i] != 0) {
            dma.freeBuffer(&driver.rx_buf_dma[i]);
            driver.rx_buffers_phys[i] = 0;
        }
    }

    // Free TX buffers (IOMMU-aware)
    for (0..types.TX_DESC_COUNT) |i| {
        if (driver.tx_buffers_phys[i] != 0) {
            dma.freeBuffer(&driver.tx_buf_dma[i]);
            driver.tx_buffers_phys[i] = 0;
        }
    }

    // Free RX ring (IOMMU-aware)
    if (driver.rx_ring_phys != 0) {
        dma.freeBuffer(&driver.rx_ring_dma);
        driver.rx_ring_phys = 0;
    }

    // Free TX ring (IOMMU-aware)
    if (driver.tx_ring_phys != 0) {
        dma.freeBuffer(&driver.tx_ring_dma);
        driver.tx_ring_phys = 0;
    }

    driver.using_iommu_dma = false;
}

fn initRx(driver: *E1000e) void {
    for (0..types.RX_DESC_COUNT) |i| {
        driver.rx_ring[i] = RxDesc{
            .buffer_addr = driver.rx_buffers_phys[i],
            .length = 0,
            .checksum = 0,
            .status = 0,
            .errors = 0,
            .special = 0,
        };
    }

    driver.regs.write(.rdbal, @truncate(driver.rx_ring_phys));
    driver.regs.write(.rdbah, @truncate(driver.rx_ring_phys >> 32));
    driver.regs.write(.rdlen, types.RX_DESC_COUNT * @sizeOf(RxDesc));
    driver.regs.write(.rxcsum, regs.RXCSUM.IPOFL | regs.RXCSUM.TUOFL);
    driver.regs.write(.rdh, 0);
    driver.regs.write(.rdt, types.RX_DESC_COUNT - 1);
    driver.rx_cur = 0;
}

fn initTx(driver: *E1000e) void {
    for (0..types.TX_DESC_COUNT) |i| {
        driver.tx_ring[i] = TxDesc{
            .buffer_addr = driver.tx_buffers_phys[i],
            .length = 0,
            .cso = 0,
            .cmd = 0,
            .status = TxDesc.STATUS_DD,
            .css = 0,
            .special = 0,
        };
    }

    driver.regs.write(.tdbal, @truncate(driver.tx_ring_phys));
    driver.regs.write(.tdbah, @truncate(driver.tx_ring_phys >> 32));
    driver.regs.write(.tdlen, types.TX_DESC_COUNT * @sizeOf(TxDesc));
    driver.regs.write(.tdh, 0);
    driver.regs.write(.tdt, 0);
    driver.regs.write(.tipg, (10 << 0) | (10 << 10) | (10 << 20)); // 10, 10, 10 for IPG
    driver.tx_cur = 0;
}

fn clearMulticastTable(driver: *E1000e) void {
    const MTA_ENTRY_COUNT: usize = 128;
    for (0..MTA_ENTRY_COUNT) |i| {
        driver.regs.writeRaw(regs.MTA_BASE + @as(u64, i) * 4, 0);
    }
}

pub fn applyMulticastFilter(driver: *E1000e, iface: *const net.Interface) void {
    clearMulticastTable(driver);
    var rctl_val = driver.readRctl();

    const addrs = iface.getMulticastMacs();
    if (iface.accept_all_multicast or addrs.len == 0) {
        rctl_val.multicast_promisc = true;
        driver.writeRctl(rctl_val);
        return;
    }

    rctl_val.multicast_promisc = false;
    driver.writeRctl(rctl_val);

    for (addrs) |mac| {
        var crc = std.hash.crc.Crc32.init();
        crc.update(&mac);
        // Intel uses 12 MSB bits of reflected CRC (bits 31:20)
        const hash: u12 = @truncate(crc.final() >> 20);
        const reg_index = hash >> 5;
        const bit_index: u5 = @intCast(hash & 0x1F);

        const mta_offset = regs.MTA_BASE + @as(u64, reg_index) * 4;
        var val = driver.regs.readRaw(mta_offset);
        val |= @as(u32, 1) << bit_index;
        driver.regs.writeRaw(mta_offset, val);
    }
}

fn configureInterruptThrottle(driver: *E1000e) void {
    driver.regs.write(.rdtr, 256);
    driver.regs.write(.radv, 512);
    driver.regs.write(.tadv, 128);
}

fn initMsix(driver: *E1000e) void {
    const ecam_ptr: *const pci.Ecam = switch (driver.pci_access) {
        .ecam => |*e| e,
        .legacy => {
            console.info("E1000: Using legacy PCI mode, MSI-X not available", .{});
            return;
        },
    };

    const msix_cap = pci.findMsix(ecam_ptr, driver.pci_dev);
    if (msix_cap == null) {
        console.info("E1000e: MSI-X not available, using legacy interrupts", .{});
        return;
    }

    const cap = msix_cap.?;

    if (cap.table_size < 3) {
        console.warn("E1000e: Not enough MSI-X vectors ({d})", .{cap.table_size});
        return;
    }

    const alloc = pci.enableMsix(ecam_ptr, driver.pci_dev, &cap, 0);
    if (alloc == null) {
        console.warn("E1000e: Failed to enable MSI-X", .{});
        return;
    }

    driver.msix_table_base = alloc.?.table_base;
    driver.msix_table_size = alloc.?.vector_count;

    const dest_apic_id: u8 = 0;
    const base_vector: u8 = 0x30;
    driver.msix_vectors[0] = base_vector; // RX
    driver.msix_vectors[1] = base_vector + 1; // TX
    driver.msix_vectors[2] = base_vector + 2; // Other

    _ = pci.configureMsixEntry(driver.msix_table_base, driver.msix_table_size, 0, driver.msix_vectors[0], dest_apic_id);
    _ = pci.configureMsixEntry(driver.msix_table_base, driver.msix_table_size, 1, driver.msix_vectors[1], dest_apic_id);
    _ = pci.configureMsixEntry(driver.msix_table_base, driver.msix_table_size, 2, driver.msix_vectors[2], dest_apic_id);

    const ivar: u32 = (0 | (1 << 3)) | // RX0 -> vector 0, valid
        ((@as(u32, 1) << 8) | (1 << 11)) | // TX0 -> vector 1, valid
        ((@as(u32, 2) << 16) | (1 << 19)); // Other -> vector 2, valid
    driver.regs.write(.ivar, ivar);

    pci.enableMsixVectors(ecam_ptr, driver.pci_dev, &cap);
    pci.msi.disableIntx(ecam_ptr, driver.pci_dev);

    driver.msix_enabled = true;
    console.info("E1000e: MSI-X enabled with {d} vectors", .{@as(u8, 3)});
}

fn enableInterrupts(driver: *E1000e) void {
    configureInterruptThrottle(driver);

    if (driver.msix_enabled) {
        driver.regs.write(.eims, regs.INT.RXT0 | regs.INT.RXDMT0 | regs.INT.LSC | regs.INT.TXDW);
    } else {
        driver.regs.write(.ims, regs.INT.RXT0 | regs.INT.RXDMT0 | regs.INT.LSC);
    }
}

fn enableRxTx(driver: *E1000e) void {
    driver.writeRctl(.{
        .enable = true,
        .broadcast_accept = true,
        .multicast_promisc = true,
        .buffer_size = 0,
        .strip_crc = true,
    });

    driver.writeTctl(.{
        .enable = true,
        .pad_short_packets = true,
        .collision_threshold = 15,
        .collision_distance = 64,
    });

    var ctrl_val = driver.readCtrl();
    ctrl_val.set_link_up = true;
    driver.writeCtrl(ctrl_val);
}

/// Deinitialize driver and release resources
pub fn deinit(driver: *E1000e) void {
    console.info("E1000e: Deinitializing driver", .{});

    // Signal worker thread to exit
    @atomicStore(bool, &driver.shutdown_requested, true, .release);

    // Wake worker if it's blocked waiting for packets, then wait for exit.
    // Retry unblock multiple times to handle the race condition where the worker
    // checks shutdown_requested before we set it, but hasn't blocked yet when
    // we call unblock() - causing the unblock to be lost.
    if (driver.worker_thread) |wt| {
        // First unblock attempt
        sched.unblock(wt);

        // Small spin delay then retry - handles race between worker's
        // hasPackets() check and sched.block() call
        for (0..10) |_| {
            hal.cpu.pause();
        }
        sched.unblock(wt);

        // Wait for worker thread to reach Zombie state (exit cleanly).
        const timeout_ticks = 1000;
        if (!thread.joinWithTimeout(wt, timeout_ticks)) {
            console.err("E1000e: Worker thread join timed out - forcing cleanup", .{});
        } else {
            console.info("E1000e: Worker thread joined successfully", .{});
        }

        _ = thread.destroyThread(wt);
        driver.worker_thread = null;
    }

    // Disable interrupts
    driver.regs.write(.imc, 0xFFFFFFFF);

    // Disable RX and TX
    driver.writeRctl(.{});
    driver.writeTctl(.{});

    // Reset device to known state
    driver.writeCtrl(.{ .device_reset = true });

    // Free descriptor rings and buffers
    freeRings(driver);

    // Unmap MMIO
    vmm.unmapMmio(driver.regs.base, driver.regs.size);

    // Use release ordering to ensure all cleanup is visible before
    // other threads see driver_initialized = false
    @atomicStore(bool, &driver_initialized, false, .release);
    console.info("E1000e: Deinitialized", .{});
}

/// Get the driver instance (if initialized)
pub fn getDriver() ?*E1000e {
    if (@atomicLoad(bool, &driver_initialized, .acquire)) {
        return &driver_instance;
    }
    return null;
}

/// Initialize E1000 driver for the first found Intel E1000/E1000e NIC
/// Supports both legacy E1000 (82540EM, 82545EM) and PCIe E1000e (82574L)
pub fn initFromPci(devices: *const pci.DeviceList, pci_access: pci.PciAccess) !*E1000e {
    // Find any E1000 variant (legacy PCI or PCIe)
    const nic = devices.findE1000() orelse {
        console.warn("E1000e: No supported Intel E1000/E1000e NIC found", .{});
        return error.NoDevice;
    };

    const driver = try init(nic, pci_access);
    // driver_initialized is set inside init()
    return driver;
}

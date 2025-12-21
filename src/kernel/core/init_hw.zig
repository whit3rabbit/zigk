//! Hardware Initialization
//!
//! Orchestrates the initialization of hardware subsystems:
//! - PCI Bus (Enumeration and ECAM setup)
//! - Network (E1000e NIC, Loopback, TCP/IP stack)
//! - USB (XHCI/EHCI host controllers)
//! - Audio (AC97)
//! - Storage (AHCI SATA)
//! - VirtIO GPU (if present)
//!
//! Dependencies:
//! - PMM/VMM must be initialized.
//! - Scheduler must be initialized (for tick callbacks).
//! - ACPI RSDP must be set via setRsdpAddress().

const std = @import("std");
const console = @import("console");
const heap = @import("heap");
const sched = @import("sched");
const net = @import("net");
const pci = @import("pci");
const e1000e = @import("e1000e");
const usb = @import("usb");
const audio = @import("audio");
const ahci = @import("ahci");
const video_driver = @import("video_driver");
const hal = @import("hal");
const kernel_iommu = @import("kernel_iommu");

pub var net_interface: net.Interface = undefined;
pub var pci_devices: ?*const pci.DeviceList = null;
pub var pci_ecam: ?pci.Ecam = null;
pub var virtio_gpu_driver: ?*video_driver.VirtioGpuDriver = null;

/// Whether IOMMU is available and enabled
pub var iommu_enabled: bool = false;

/// RSDP address from boot info (set by main.zig during kernel init)
var rsdp_address: u64 = 0;

/// Set the RSDP address from BootInfo
/// Must be called before initIommu() or initNetwork()
pub fn setRsdpAddress(addr: u64) void {
    rsdp_address = addr;
}

/// Initialize IOMMU (VT-d) subsystem
/// Must be called BEFORE device initialization to ensure DMA isolation from the start.
/// If IOMMU is not available, devices will fall back to using physical addresses.
pub fn initIommu() void {
    console.print("\n");
    console.info("Initializing IOMMU subsystem...", .{});

    // 1. Get RSDP from boot protocol
    if (rsdp_address == 0) {
        console.warn("IOMMU: RSDP not found, IOMMU disabled", .{});
        return;
    }
    const rsdp_ptr: *align(1) const hal.acpi.Rsdp = @ptrFromInt(rsdp_address);

    // 2. Parse DMAR table
    const dmar_info = hal.acpi.parseDmar(rsdp_ptr) orelse {
        console.info("IOMMU: No DMAR table found (IOMMU not present)", .{});
        return;
    };

    hal.acpi.logDmarInfo(dmar_info);

    if (dmar_info.drhd_count == 0) {
        console.warn("IOMMU: No DMA remapping hardware units found", .{});
        return;
    }

    console.info("IOMMU: Found {d} DRHD unit(s)", .{dmar_info.drhd_count});

    // 3. Initialize each VT-d hardware unit
    var units_initialized: u8 = 0;
    for (dmar_info.drhd_units[0..dmar_info.drhd_count]) |*drhd| {
        const unit = hal.iommu.vtd.VtdUnit.init(drhd) catch |err| {
            console.err("IOMMU: Failed to init unit at 0x{x}: {}", .{ drhd.reg_base, err });
            continue;
        };

        unit.logInfo();
        hal.iommu.vtd.registerUnit(unit);
        units_initialized += 1;
    }

    if (units_initialized == 0) {
        console.err("IOMMU: No VT-d units successfully initialized", .{});
        return;
    }

    // 4. Initialize kernel IOMMU domain subsystem
    kernel_iommu.init();

    // 5. Initialize hardware tables (root table, context tables)
    if (!kernel_iommu.initHardware()) {
        console.err("IOMMU: Failed to initialize hardware tables", .{});
        return;
    }

    // 6. Program root table and enable translation for each unit
    const root_table_phys = kernel_iommu.domain_manager.getRootTablePhys() orelse {
        console.err("IOMMU: No root table available", .{});
        return;
    };

    var i: u8 = 0;
    while (i < hal.iommu.vtd.getUnitCount()) : (i += 1) {
        if (hal.iommu.vtd.getUnit(i)) |unit| {
            // Set root table address
            unit.setRootTable(root_table_phys);

            // Invalidate context cache (fresh start)
            unit.invalidateContextGlobal();

            // Invalidate IOTLB
            unit.invalidateIotlbGlobal();

            // Enable translation
            unit.enableTranslation();

            // Enable fault interrupts for debugging
            unit.enableFaultInterrupt();
        }
    }

    // 7. Initialize fault handler
    hal.iommu.fault.init();

    iommu_enabled = true;
    console.info("IOMMU: Enabled with {d} unit(s), DMA isolation active", .{units_initialized});
}

fn txWrapper(data: []const u8) bool {
    if (e1000e.getDriver()) |driver| {
        return e1000e.transmit(driver, data);
    }
    return false;
}

fn multicastUpdate(iface: *net.Interface) void {
    if (e1000e.getDriver()) |driver| {
        e1000e.applyMulticastFilter(driver, iface);
    }
}

fn rxCallbackAdapter(data: []u8) void {
    // Return buffer to packet pool when done (defer runs after processFrame)
    defer e1000e.packet_pool.release(data);

    // Wrap data in PacketBuffer and pass to network stack
    var pkt = net.PacketBuffer.init(data, data.len);
    _ = net.processFrame(&net_interface, &pkt);
}

/// Initialize the Network subsystem
/// - Discovers PCI devices via ACPI/ECAM
/// - Initializes E1000e NIC driver if found
/// - Sets up TCP/IP stack and Loopback interface
pub fn initNetwork() void {
    console.print("\n");
    console.info("Initializing network subsystem...", .{});

    // 1. Get RSDP for PCI ECAM
    if (rsdp_address == 0) {
        console.warn("RSDP not found, network disabled.", .{});
        return;
    }
    console.info("Debug: RSDP at 0x{x}", .{rsdp_address});
    console.info("Debug: Calling pci.initFromAcpi with 0x{x}", .{rsdp_address});

    // 2. Initialize PCI
    const pci_res = pci.initFromAcpi(heap.allocator(), rsdp_address) catch |err| {
        console.err("PCI init failed: {}", .{err});
        return;
    };

    // Save PCI state for other subsystems (USB, VirtIO, syscalls)
    pci_devices = pci_res.devices;

    // Also set in pci module for syscall access
    const ecam_opt: ?pci.Ecam = switch (pci_res.access) {
        .ecam => |e| e,
        .legacy => null,
    };
    pci.setGlobalState(pci_res.devices, ecam_opt);

    // Handle PCI Access Mechanism
    var nic_driver_opt: ?*e1000e.E1000e = null;

    switch (pci_res.access) {
        .ecam => |*ecam_ptr| {
             // Store ECAM for drivers that need it
             pci_ecam = ecam_ptr.*;

             // 3. Initialize E1000/E1000e NIC driver
             nic_driver_opt = e1000e.initFromPci(pci_res.devices, pci.PciAccess{ .ecam = ecam_ptr.* }) catch |err| blk: {
                console.warn("E1000 init failed (no supported NIC?): {}", .{err});
                break :blk null;
             };
        },
        .legacy => |legacy| {
            // 3. Initialize E1000 NIC driver (legacy mode - no MSI-X, uses INTx)
            nic_driver_opt = e1000e.initFromPci(pci_res.devices, pci.PciAccess{ .legacy = legacy }) catch |err| blk: {
                console.warn("E1000 init failed (no supported NIC?): {}", .{err});
                break :blk null;
            };
            // pci_ecam remains null, so USB/AHCI will be skipped
        }
    }

    // 4. Setup Network if Driver Available
    if (nic_driver_opt) |nic_driver| {
        // [NETSTACK MIGRATION]
        // Disable in-kernel network stack initialization.
        // We still initialize the driver hardware if needed, bu we don't bind it to the kernel stack
        // OR we skip driver initialization if the userspace driver is taking over.

        // For now, let's just log and skip.
        console.warn("[NETSTACK] Kernel network stack disabled for userspace migration.", .{});
        _ = nic_driver; // Unused
    } else {
        console.warn("Network stack skipped (no NIC driver)", .{});
    }
}

/// Initialize USB subsystem (XHCI/EHCI)
/// Requires PCI and ECAM to be initialized by `initNetwork` first.
pub fn initUsb() void {
    console.print("\n");
    console.info("Initializing USB subsystem...", .{});

    const devices = pci_devices orelse {
        console.warn("USB: PCI not initialized, skipping USB", .{});
        return;
    };

    const ecam = pci_ecam orelse {
        console.warn("USB: PCI ECAM not available, skipping USB", .{});
        return;
    };

    usb.initFromPci(devices, pci.PciAccess{ .ecam = ecam });
}

/// Initialize Audio subsystem (AC97)
/// Requires PCI and ECAM.
pub fn initAudio() void {
    console.print("\n");
    console.info("Initializing Audio subsystem...", .{});

    const devices = pci_devices orelse {
        console.warn("Audio: PCI not initialized, skipping Audio", .{});
        return;
    };

    const ecam = pci_ecam orelse {
        console.warn("Audio: PCI ECAM not available, skipping Audio", .{});
        return;
    };

    if (devices.findAc97Controller()) |dev| {
        console.info("Audio: Found AC97 Controller at {d}:{d}.{d}", .{ dev.bus, dev.device, dev.func });
        audio.ac97.initFromPci(dev, pci.PciAccess{ .ecam = ecam }) catch |err| {
            console.warn("Audio: Init failed: {}", .{err});
        };
    } else {
        console.info("Audio: No AC97 controller found", .{});
    }
}

/// Initialize Storage subsystem (AHCI SATA)
/// Scans for AHCI controllers and connected drives.
/// Registers found partitions with DevFS.
pub fn initStorage() void {
    console.print("\n");
    console.info("Initializing storage subsystem...", .{});

    const devices = pci_devices orelse {
        console.warn("Storage: PCI not initialized, skipping AHCI", .{});
        return;
    };

    const ecam = pci_ecam orelse {
        console.warn("Storage: PCI ECAM not available, skipping AHCI", .{});
        return;
    };

    // Search for AHCI controller (Class 0x01 Mass Storage, Subclass 0x06 SATA)
    var found_ahci = false;
    for (devices.devices[0..devices.count]) |*dev| {
        if (dev.class_code == 0x01 and dev.subclass == 0x06) {
            console.info("Storage: Found AHCI controller at {x:0>2}:{x:0>2}.{d}", .{
                dev.bus, dev.device, dev.func,
            });

            if (ahci.initFromPci(dev, pci.PciAccess{ .ecam = ecam })) |controller| {
                // Report detected drives and scan for partitions
                const partitions = @import("partitions");
                for (0..ahci.MAX_PORTS) |i| {
                    const port_num: u5 = @intCast(i);
                    if (controller.getPort(port_num)) |port| {
                        const dev_type_str = switch (port.device_type) {
                            .ata => "ATA",
                            .atapi => "ATAPI",
                            .semb => "SEMB",
                            .port_multiplier => "Port Multiplier",
                            else => "None",
                        };
                        console.info("  Port {d}: {s} device", .{ port_num, dev_type_str });

                        if (port.device_type == .ata) {
                            // Scan for partitions
                            partitions.scanAndRegister(port_num) catch |err| {
                                console.warn("  Partition scan failed: {}", .{err});
                            };
                        }
                    }
                }
                found_ahci = true;
                break; // Only initialize first controller
            } else |err| {
                console.warn("Storage: AHCI init failed: {}", .{err});
            }
        }
    }

    if (!found_ahci) {
        console.info("Storage: No AHCI controllers found", .{});
    }
}

/// Initialize VirtIO GPU driver
/// Returns the driver instance if successful, enabling the console to switch modes.
pub fn initVirtioGpu() ?*video_driver.VirtioGpuDriver {
    console.print("\n");
    console.info("Checking for VirtIO-GPU...", .{});

    const devices = pci_devices orelse {
        console.info("VirtIO-GPU: PCI not initialized, skipping", .{});
        return null;
    };

    const ecam = pci_ecam orelse {
        console.info("VirtIO-GPU: PCI ECAM not available, skipping", .{});
        return null;
    };

    // Scan for VirtIO-GPU device
    for (devices.devices[0..devices.count]) |*dev| {
        if (dev.isVirtioGpu()) {
            console.info("VirtIO-GPU: Found device at {d}:{d}.{d}", .{ dev.bus, dev.device, dev.func });

            // Try to initialize the driver
            if (video_driver.VirtioGpuDriver.init(dev, pci.PciAccess{ .ecam = ecam })) |driver| {
                virtio_gpu_driver = driver;
                return driver;
            } else {
                console.warn("VirtIO-GPU: Driver initialization failed", .{});
            }
        }
    }

    console.info("VirtIO-GPU: No device found, using framebuffer", .{});
    return null;
}

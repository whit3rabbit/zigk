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
const builtin = @import("builtin");
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
const acpi = @import("acpi");
const kernel_iommu = @import("kernel_iommu");
const dma = @import("dma");
const input = @import("input");
const virtio = @import("virtio");
const prng = @import("prng");

pub var net_interface: net.Interface = undefined;
pub var pci_devices: ?*const pci.DeviceList = null;
pub var pci_ecam: ?pci.Ecam = null;
pub var virtio_gpu_driver: ?*video_driver.VirtioGpuDriver = null;
// SVGA driver supports x86_64 (port I/O) and aarch64 (MMIO)
pub var svga_driver: if (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64) ?*video_driver.SvgaDriver else ?*void = null;
pub var vmmouse_enabled: bool = false;
pub var virtio_rng_driver: ?*virtio.VirtioRngDriver = null;

/// Detected hypervisor type
pub var detected_hypervisor: hal.hypervisor.HypervisorType = .none;

/// Whether IOMMU is available and enabled
pub var iommu_enabled: bool = false;

/// Callback for VMMouse to update SVGA hardware cursor position
/// Called when VMMouse reports absolute cursor coordinates
fn svgaCursorCallback(x: u32, y: u32) void {
    if (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64) {
        if (svga_driver) |driver| {
            driver.getCursor().setPosition(x, y);
        }
    }
}

/// RSDP address from boot info (set by main.zig during kernel init)
var rsdp_address: u64 = 0;

/// Set the RSDP address from BootInfo
/// Must be called before initIommu() or initNetwork()
pub fn setRsdpAddress(addr: u64) void {
    rsdp_address = addr;
}

/// Detect and log hypervisor type
/// Should be called early in boot to enable platform-specific optimizations
pub fn initHypervisor() void {
    const info = hal.hypervisor.detect.detect();
    detected_hypervisor = info.hypervisor;

    if (info.hypervisor == .none) {
        console.info("Platform: Bare metal (no hypervisor detected)", .{});
    } else {
        const sig = hal.hypervisor.detect.formatSignature(info.signature);
        console.info("Platform: {s} (signature: {s}, max_leaf: 0x{x})", .{
            info.hypervisor.name(),
            &sig,
            info.max_leaf,
        });

        // Log platform-specific hints
        if (info.hypervisor.isVmwareCompatible()) {
            console.info("  - VMware-compatible: VMMouse and SVGA available", .{});
        }
        if (info.hypervisor.isKvmCompatible()) {
            console.info("  - KVM-compatible: VirtIO devices available", .{});
        }
    }
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
    const rsdp_ptr: *align(1) const acpi.Rsdp = @ptrFromInt(rsdp_address);

    // 2. Parse DMAR table
    const dmar_info = acpi.parseDmar(rsdp_ptr) orelse {
        console.info("IOMMU: No DMAR table found (IOMMU not present)", .{});
        return;
    };

    acpi.logDmarInfo(&dmar_info);

    // Store DMAR info in kernel_iommu for RMRR lookups during device assignment
    kernel_iommu.setDmarInfo(dmar_info);

    // Load RMRR regions into domain manager for overlap checking
    kernel_iommu.domain_manager.loadRmrrRegions(&dmar_info);

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
    var units_enabled: u8 = 0;
    while (i < hal.iommu.vtd.getUnitCount()) : (i += 1) {
        if (hal.iommu.vtd.getUnit(i)) |unit| {
            // Set root table address
            unit.setRootTable(root_table_phys);

            // Invalidate context cache (fresh start)
            unit.invalidateContextGlobal() catch |err| {
                console.err("IOMMU: Unit {d} context invalidation failed: {}", .{ i, err });
                continue;
            };

            // Invalidate IOTLB
            unit.invalidateIotlbGlobal() catch |err| {
                console.err("IOMMU: Unit {d} IOTLB invalidation failed: {}", .{ i, err });
                continue;
            };

            // Enable translation
            unit.enableTranslation() catch |err| {
                console.err("IOMMU: Unit {d} translation enable failed: {}", .{ i, err });
                continue;
            };

            // Enable fault interrupts for debugging
            unit.enableFaultInterrupt();
            units_enabled += 1;
        }
    }

    if (units_enabled == 0) {
        console.err("IOMMU: No units successfully enabled", .{});
        return;
    }

    // 7. Initialize fault handler
    hal.iommu.fault.init();

    iommu_enabled = true;
    dma.enableIommu(); // Enable IOMMU integration in DMA module
    console.info("IOMMU: Enabled with {d} unit(s), DMA isolation active", .{units_enabled});
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

/// Legacy PCI probe for E1000/E1000e NIC
/// Fallback for ECAM timing issues on QEMU/TCG/macOS where device list may be corrupted.
fn probeE1000Legacy(ecam: pci.Ecam) ?*e1000e.E1000e {
    console.info("E1000e: Trying legacy PCI probe...", .{});
    const legacy = pci.Legacy.init();

    // E1000 device IDs: 0x100E (82540EM/QEMU), 0x100F (82545EM), 0x10D3 (82574L)
    const e1000_ids = [_]u16{ 0x100E, 0x100F, 0x10D3, 0x10F6, 0x150C };

    // Use u8 to avoid overflow when loop counter reaches 32
    var dev_num: u8 = 0;
    while (dev_num < 32) : (dev_num += 1) {
        const device: u5 = @truncate(dev_num);
        const vendor_id = legacy.read16(0, device, 0, 0x00);
        if (vendor_id != 0x8086) continue; // Must be Intel

        const device_id = legacy.read16(0, device, 0, 0x02);

        // Check if it's an E1000 variant
        var is_e1000 = false;
        for (e1000_ids) |id| {
            if (device_id == id) {
                is_e1000 = true;
                break;
            }
        }
        if (!is_e1000) continue;

        console.info("E1000e: Found via legacy probe at 00:{x:0>2}.0 (did={x:0>4})", .{ device, device_id });

        // Read BAR0 (MMIO, possibly 64-bit)
        const bar0_raw = legacy.read32(0, device, 0, 0x10);
        const bar1_raw = legacy.read32(0, device, 0, 0x14);

        // E1000 uses MMIO BAR (bit 0 = 0), check if 64-bit (bits 2:1 = 10)
        const is_mmio = (bar0_raw & 0x1) == 0;
        const is_64bit = ((bar0_raw >> 1) & 0x3) == 2;

        if (!is_mmio) {
            console.warn("E1000e: BAR0 is not MMIO, skipping", .{});
            continue;
        }

        const bar_base = if (is_64bit)
            (@as(u64, bar1_raw) << 32) | (@as(u64, bar0_raw) & 0xFFFFFFF0)
        else
            @as(u64, bar0_raw & 0xFFFFFFF0);

        // Build PciDevice struct
        var fixed_dev = pci.PciDevice{
            .bus = 0,
            .device = device,
            .func = 0,
            .vendor_id = vendor_id,
            .device_id = device_id,
            .revision = 0,
            .prog_if = 0,
            .subclass = 0x00, // Ethernet
            .class_code = 0x02, // Network
            .header_type = 0,
            .bar = undefined,
            .irq_line = legacy.read8(0, device, 0, 0x3C),
            .irq_pin = legacy.read8(0, device, 0, 0x3D),
            .gsi = 0,
            .subsystem_vendor = legacy.read16(0, device, 0, 0x2C),
            .subsystem_id = legacy.read16(0, device, 0, 0x2E),
        };

        // Initialize BAR array
        for (&fixed_dev.bar) |*bar| {
            bar.* = pci.Bar{
                .base = 0,
                .size = 0,
                .is_mmio = false,
                .is_64bit = false,
                .prefetchable = false,
                .bar_type = .unused,
            };
        }

        // Set BAR0 - E1000 uses 128KB MMIO
        fixed_dev.bar[0] = pci.Bar{
            .base = bar_base,
            .size = 0x20000, // 128KB for E1000
            .is_mmio = true,
            .is_64bit = is_64bit,
            .prefetchable = (bar0_raw & 0x8) != 0,
            .bar_type = if (is_64bit) .mmio_64bit else .mmio_32bit,
        };

        return e1000e.init(&fixed_dev, pci.PciAccess{ .ecam = ecam }) catch |err| {
            console.warn("E1000e: Legacy init failed: {}", .{err});
            return null;
        };
    }

    return null;
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

             // Fallback: Legacy PCI probe if ECAM device list has timing issues
             if (nic_driver_opt == null) {
                 nic_driver_opt = probeE1000Legacy(ecam_ptr.*);
             }
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
/// Uses Legacy PCI probe as fallback for ECAM timing issues on macOS/Apple Silicon.
pub fn initAudio() void {
    console.print("\n");
    console.info("Initializing Audio subsystem...", .{});

    const ecam = pci_ecam orelse {
        console.warn("Audio: PCI ECAM not available, skipping Audio", .{});
        return;
    };

    // First try device list (may have ECAM timing issues)
    if (pci_devices) |devices| {
        // Prefer Intel HDA (High Def Audio) - Modern QEMU, VirtualBox, VMware
        if (devices.findHdaController()) |dev| {
             console.info("Audio: Found Intel HDA Controller at {d}:{d}.{d}", .{ dev.bus, dev.device, dev.func });
             _ = audio.hda.init(dev, pci.PciAccess{ .ecam = ecam }) catch |err| {
                 console.warn("Audio: HDA Init failed: {}", .{err});
             };
             return;
        }

        // Fallback to AC97
        if (devices.findAc97Controller()) |dev| {
            console.info("Audio: Found AC97 Controller at {d}:{d}.{d}", .{ dev.bus, dev.device, dev.func });
            audio.ac97.initFromPci(dev, pci.PciAccess{ .ecam = ecam }) catch |err| {
                console.warn("Audio: Init failed: {}", .{err});
            };
            return;
        }
    }

    // Fallback: Legacy PCI I/O probe (ECAM may have timing issues on QEMU/TCG/macOS)
    console.info("Audio: Trying legacy PCI probe...", .{});
    const legacy = pci.Legacy.init();

    // Use u8 to avoid overflow when loop counter reaches 32
    var dev_num: u8 = 0;
    while (dev_num < 32) : (dev_num += 1) {
        const device: u5 = @truncate(dev_num);
        const vendor_id = legacy.read16(0, device, 0, 0x00);
        if (vendor_id == 0xFFFF) continue;

        const device_id = legacy.read16(0, device, 0, 0x02);

        // Intel AC97: VID=0x8086 DID=0x2415
        if (vendor_id == 0x8086 and device_id == 0x2415) {
            console.info("Audio: Found AC97 via legacy probe at 00:{x:0>2}.0", .{device});

            // Read BARs and build PciDevice struct
            const bar0_raw = legacy.read32(0, device, 0, 0x10);
            const bar1_raw = legacy.read32(0, device, 0, 0x14);

            // AC97 uses I/O BARs (bit 0 = 1)
            const bar0_io = (bar0_raw & 0x1) == 1;
            const bar1_io = (bar1_raw & 0x1) == 1;

            var fixed_dev = pci.PciDevice{
                .bus = 0,
                .device = device,
                .func = 0,
                .vendor_id = vendor_id,
                .device_id = device_id,
                .revision = 0,
                .prog_if = 0,
                .subclass = 0x01, // Audio controller
                .class_code = 0x04, // Multimedia
                .header_type = 0,
                .bar = undefined,
                .irq_line = legacy.read8(0, device, 0, 0x3C),
                .irq_pin = legacy.read8(0, device, 0, 0x3D),
                .gsi = 0,
                .subsystem_vendor = legacy.read16(0, device, 0, 0x2C),
                .subsystem_id = legacy.read16(0, device, 0, 0x2E),
            };

            // Initialize BAR array
            for (&fixed_dev.bar) |*bar| {
                bar.* = pci.Bar{
                    .base = 0,
                    .size = 0,
                    .is_mmio = false,
                    .is_64bit = false,
                    .prefetchable = false,
                    .bar_type = .unused,
                };
            }

            // Set BAR0 (NAMBAR - Native Audio Mixer)
            if (bar0_io) {
                fixed_dev.bar[0] = pci.Bar{
                    .base = @as(u64, bar0_raw & 0xFFFFFFFC),
                    .size = 256, // Mixer registers
                    .is_mmio = false,
                    .is_64bit = false,
                    .prefetchable = false,
                    .bar_type = .io,
                };
            }

            // Set BAR1 (NABMBAR - Native Audio Bus Master)
            if (bar1_io) {
                fixed_dev.bar[1] = pci.Bar{
                    .base = @as(u64, bar1_raw & 0xFFFFFFFC),
                    .size = 64, // Bus master registers
                    .is_mmio = false,
                    .is_64bit = false,
                    .prefetchable = false,
                    .bar_type = .io,
                };
            }

            audio.ac97.initFromPci(&fixed_dev, pci.PciAccess{ .ecam = ecam }) catch |err| {
                console.warn("Audio: Init failed: {}", .{err});
                return;
            };
            return;
        }
    }

    console.info("Audio: No AC97 controller found", .{});
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

/// Initialize Video subsystem
/// Tries VirtIO-GPU first (best for KVM/QEMU), then SVGA (VMware/VirtualBox)
/// Falls back to boot framebuffer if neither is available.
pub fn initVideo() void {
    console.print("\n");
    console.info("Initializing video subsystem...", .{});

    // First try VirtIO-GPU (best paravirtualized option)
    if (initVirtioGpu()) |driver| {
        console.info("Video: Using VirtIO-GPU driver", .{});
        _ = driver; // Driver stored in virtio_gpu_driver
        return;
    }

    // Try VMware SVGA II (x86_64: port I/O, aarch64: MMIO)
    if (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64) {
        if (video_driver.SvgaDriver.init()) |driver| {
            svga_driver = driver;
            console.info("Video: Using VMware SVGA II driver", .{});
            return;
        }
    }

    // Fall back to boot framebuffer
    console.info("Video: Using boot framebuffer (no GPU driver)", .{});
}

/// Initialize Input subsystem
/// Sets up the unified input queue and probes for enhanced input devices.
/// - VMMouse: Absolute positioning for VMware/VirtualBox
/// - Falls back to PS/2 mouse (relative positioning)
pub fn initInput() void {
    console.print("\n");
    console.info("Initializing input subsystem...", .{});

    // Initialize the unified input subsystem
    input.init();
    console.info("Input: Unified event queue initialized", .{});

    // Probe for VMMouse (VMware/VirtualBox absolute positioning)
    var vmmouse_driver = input.VmMouseDriver.init();
    if (vmmouse_driver.probe()) {
        vmmouse_enabled = true;
        console.info("Input: VMMouse detected - absolute positioning enabled", .{});

        // Register with input subsystem
        _ = input.registerDevice(.{
            .device_type = .vmmouse,
            .name = "VMware VMMouse",
            .capabilities = .{ .has_abs = true, .has_left = true, .has_right = true, .has_middle = true },
            .is_absolute = true,
        }) catch |err| {
            console.warn("Input: Failed to register VMMouse: {}", .{err});
        };

        // Set up polling (VMMouse needs periodic polling, not IRQ-driven)
        // The poll function should be called from a timer or main loop
        // For now, we'll rely on the scheduler tick callback or explicit polling

        // Integrate with SVGA hardware cursor if available (x86_64 and aarch64)
        if (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64) {
            if (svga_driver) |driver| {
                // Set screen size for coordinate scaling
                vmmouse_driver.setScreenSize(driver.width, driver.height);

                // Register cursor position callback for hardware cursor
                input.vmmouse.registerCursorCallback(&svgaCursorCallback);
                console.info("Input: VMMouse integrated with SVGA hardware cursor", .{});
            }
        }
    } else {
        console.info("Input: VMMouse not available, using PS/2 mouse", .{});
    }

    // PS/2 keyboard/mouse are initialized separately by the PS/2 controller driver
    // They will register themselves with the input subsystem when detected
}

/// Initialize VirtIO-RNG (entropy device)
/// Provides hardware entropy from hypervisor to kernel PRNG
pub fn initVirtioRng() void {
    console.print("\n");
    console.info("Checking for VirtIO-RNG...", .{});

    // Only probe on KVM-compatible hypervisors (QEMU, KVM, Proxmox)
    // VirtIO devices won't be present on VMware/VirtualBox
    if (detected_hypervisor != .none and
        !detected_hypervisor.isKvmCompatible() and
        detected_hypervisor != .unknown)
    {
        console.info("VirtIO-RNG: Skipping (not a KVM-compatible hypervisor)", .{});
        return;
    }

    if (virtio.VirtioRngDriver.init()) |driver| {
        virtio_rng_driver = driver;
        console.info("VirtIO-RNG: Driver initialized", .{});

        // Seed kernel PRNG with initial hardware entropy
        var entropy: [64]u8 = undefined;
        const bytes_read = driver.getEntropy(&entropy) catch |err| {
            console.warn("VirtIO-RNG: Failed to read initial entropy: {}", .{err});
            return;
        };

        if (bytes_read > 0) {
            // Mix entropy into kernel PRNG
            var i: usize = 0;
            while (i + 8 <= bytes_read) : (i += 8) {
                const val = @as(*align(1) const u64, @ptrCast(entropy[i..].ptr)).*;
                prng.mixEntropy(val);
            }
            console.info("VirtIO-RNG: Seeded kernel PRNG with {d} bytes", .{bytes_read});
        }
    } else {
        console.info("VirtIO-RNG: No device found", .{});
    }
}

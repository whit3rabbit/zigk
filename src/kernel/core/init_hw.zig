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
const nvme = @import("nvme");
const ide = @import("ide");
const virtio_scsi = @import("virtio_scsi");
const video_driver = @import("video_driver");
const hal = @import("hal");
const acpi = @import("acpi");
const kernel_iommu = @import("kernel_iommu");
const dma = @import("dma");
const input = @import("input");
const keyboard = @import("keyboard");
const virtio = @import("virtio");
const virtio_input = @import("virtio_input");
const virtio_sound = @import("virtio_sound");
const virtio_9p = @import("virtio_9p");
const virtio_fs = @import("virtio_fs");
const hgfs = @import("hgfs");
const vmmdev = @import("vmmdev");
const vboxsf = @import("vboxsf");
const virt_pci = @import("virt_pci");
const fs = @import("fs");
const prng = @import("prng");

// SECURITY NOTE (Global State Synchronization): These variables are written during
// single-threaded BSP boot (before SMP init) and only read after boot completes.
// No synchronization is required because:
// 1. BSP initialization is strictly sequential (initHypervisor -> initIommu -> initNetwork -> ...)
// 2. AP startup occurs AFTER BSP init, with proper memory barriers in the AP trampoline
// 3. These are never modified after init completes (effectively immutable post-boot)
// If future code modifies these at runtime, use std.atomic.Value for thread safety.
pub var net_interface: net.Interface = undefined;
pub var pci_devices: ?*const pci.DeviceList = null;
pub var pci_ecam: ?pci.Ecam = null;
pub var virtio_gpu_driver: ?*video_driver.VirtioGpuDriver = null;
// SVGA driver supports x86_64 (port I/O) and aarch64 (MMIO)
pub var svga_driver: if (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64) ?*video_driver.SvgaDriver else ?*void = null;
// BGA driver for Bochs/QEMU std VGA
pub var bga_driver: ?*video_driver.BgaDriver = null;
// Cirrus Logic CL-GD5446 driver for legacy VGA compatibility (x86_64 only)
pub var cirrus_driver: if (builtin.cpu.arch == .x86_64) ?*video_driver.CirrusDriver else ?*void = null;
// QXL paravirtualized graphics driver for SPICE (x86_64 only)
pub var qxl_driver: if (builtin.cpu.arch == .x86_64) ?*video_driver.QxlDriver else ?*void = null;
pub var vmmouse_enabled: bool = false;
pub var virtio_rng_driver: ?*virtio.VirtioRngDriver = null;
/// VirtualBox VMMDev driver (for Guest Additions / shared folders)
pub var vmmdev_driver: ?*vmmdev.VmmDevDevice = null;

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
    // SECURITY NOTE (RSDP Trust): The RSDP address comes from trusted UEFI boot firmware
    // via BootInfo. If the bootloader/hypervisor is compromised, the attacker has broader
    // attack surface (kernel image modification, page table poisoning). Additional range
    // validation here provides minimal benefit vs. cost. The ACPI parser validates structure.
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

    // SECURITY: Warn if partial IOMMU initialization occurred.
    // Devices on segments covered by failed units may not have DMA isolation.
    // This is still better than no IOMMU - protected segments benefit from isolation.
    if (units_enabled < units_initialized) {
        console.warn("IOMMU: Partial init - {d}/{d} units enabled. Some devices may lack DMA isolation.", .{
            units_enabled,
            units_initialized,
        });
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
        // SECURITY NOTE (Hardcoded BAR Size): This legacy fallback uses the datasheet-specified
        // 128KB size rather than PCI BAR sizing protocol. This is acceptable because:
        // 1. This is a fallback path only used when ECAM fails (which does proper sizing)
        // 2. A malicious hypervisor has broader attack surface than BAR size misreporting
        // 3. The E1000 driver bounds-checks all register accesses within this region
        // 4. Implementing BAR sizing in legacy I/O mode adds significant complexity
        fixed_dev.bar[0] = pci.Bar{
            .base = bar_base,
            .size = 0x20000, // 128KB per Intel E1000 datasheet
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
        console.debug("[NETSTACK] NIC available, no in-kernel stack (userspace driver expected)", .{});
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

    // On aarch64, MSI-X interrupts don't work (LAPIC is x86-specific).
    // Register a tick callback to poll XHCI events periodically.
    // This is essential for USB keyboard input to work on aarch64.
    if (builtin.cpu.arch == .aarch64) {
        if (usb.xhci.getController()) |ctrl| {
            if (ctrl.msix_vectors == null) {
                // In polling mode - register tick callback
                sched.setTickCallback(usbPollTickCallback);
                console.info("USB: Registered tick callback for aarch64 polling", .{});
            }
        }
    }
}

/// Tick callback to poll USB events on aarch64 (where MSI-X is unavailable)
var usb_poll_counter: u32 = 0;
fn usbPollTickCallback() void {
    _ = usb.xhci.pollEvents();
    usb_poll_counter +%= 1;
}

/// Initialize Audio subsystem (VirtIO-Sound, HDA, AC97)
/// Priority: VirtIO-Sound (KVM) > Intel HDA > AC97
/// Uses Legacy PCI probe as fallback for ECAM timing issues on macOS/Apple Silicon.
pub fn initAudio() void {
    console.print("\n");
    console.info("Initializing Audio subsystem...", .{});

    // For KVM-compatible hypervisors, try VirtIO-Sound first
    if (detected_hypervisor.isKvmCompatible() or detected_hypervisor == .none or detected_hypervisor == .unknown) {
        if (initVirtioSound()) {
            return; // VirtIO-Sound initialized successfully
        }
    }

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

            // SECURITY NOTE (Hardcoded BAR Sizes): Same rationale as E1000 legacy probe.
            // Sizes are per Intel AC97 specification. Primary ECAM path does proper sizing.
            // Set BAR0 (NAMBAR - Native Audio Mixer)
            if (bar0_io) {
                fixed_dev.bar[0] = pci.Bar{
                    .base = @as(u64, bar0_raw & 0xFFFFFFFC),
                    .size = 256, // Mixer registers per AC97 spec
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
                    .size = 64, // Bus master registers per AC97 spec
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

/// Initialize Storage subsystem (AHCI SATA and NVMe)
/// Scans for AHCI and NVMe controllers and connected drives.
/// Registers found partitions with DevFS.
pub fn initStorage() void {
    console.print("\n");
    console.info("Initializing storage subsystem...", .{});

    const devices = pci_devices orelse {
        console.warn("Storage: PCI not initialized, skipping storage init", .{});
        return;
    };

    const ecam = pci_ecam orelse {
        console.warn("Storage: PCI ECAM not available, skipping storage init", .{});
        return;
    };

    const partitions = @import("partitions");

    // Search for AHCI controller (Class 0x01 Mass Storage, Subclass 0x06 SATA)
    var found_ahci = false;
    for (devices.devices[0..devices.count]) |*dev| {
        if (dev.class_code == 0x01 and dev.subclass == 0x06) {
            console.info("Storage: Found AHCI controller at {x:0>2}:{x:0>2}.{d}", .{
                dev.bus, dev.device, dev.func,
            });

            if (ahci.initFromPci(dev, pci.PciAccess{ .ecam = ecam })) |controller| {
                // Report detected drives and scan for partitions
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

                // Register IRQ handler to enable interrupt-driven I/O
                ahci.registerIrqHandler(controller);

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

    // Search for NVMe controller (Class 0x01 Mass Storage, Subclass 0x08 NVM, Prog-IF 0x02 NVMe)
    var found_nvme = false;
    for (devices.devices[0..devices.count]) |*dev| {
        if (dev.class_code == 0x01 and dev.subclass == 0x08 and dev.prog_if == 0x02) {
            console.info("Storage: Found NVMe controller at {x:0>2}:{x:0>2}.{d}", .{
                dev.bus, dev.device, dev.func,
            });

            if (nvme.initFromPci(dev, pci.PciAccess{ .ecam = ecam })) |controller| {
                // Report detected namespaces
                console.info("  Namespaces: {d}", .{controller.namespace_count});

                for (0..controller.namespace_count) |i| {
                    if (controller.getNamespace(@intCast(i))) |ns| {
                        const size_mb = (ns.total_lbas * ns.lba_size) / (1024 * 1024);
                        console.info("  NS{d}: {d} MB ({d} LBAs, {d}B sectors)", .{
                            ns.nsid,
                            size_mb,
                            ns.total_lbas,
                            ns.lba_size,
                        });

                        // Scan for partitions on this namespace
                        partitions.scanAndRegisterNvme(@intCast(i), ns.nsid) catch |err| {
                            console.warn("  Partition scan failed for NS{d}: {}", .{ ns.nsid, err });
                        };
                    }
                }

                // Register interrupt handler (MSI-X preferred, legacy fallback)
                nvme.irq_mod.setupMsix(controller, pci.PciAccess{ .ecam = ecam }) catch {};
                nvme.irq_mod.registerLegacyIrq(controller);

                found_nvme = true;
                break; // Only initialize first controller
            } else |err| {
                console.warn("Storage: NVMe init failed: {}", .{err});
            }
        }
    }

    if (!found_nvme) {
        console.info("Storage: No NVMe controllers found", .{});
    }

    // Search for VirtIO-SCSI controller (VirtIO vendor, SCSI device)
    var found_virtio_scsi = false;
    for (devices.devices[0..devices.count]) |*dev| {
        if (virtio_scsi.isVirtioScsi(dev)) {
            console.info("Storage: Found VirtIO-SCSI at {x:0>2}:{x:0>2}.{d}", .{
                dev.bus, dev.device, dev.func,
            });

            if (virtio_scsi.initFromPci(dev, pci.PciAccess{ .ecam = ecam })) |controller| {
                // Report detected LUNs
                var lun_count: u8 = 0;
                for (0..controller.getLunCount()) |i| {
                    if (controller.getLun(@intCast(i))) |lun_info| {
                        if (lun_info.active) {
                            const size_mb = lun_info.capacity_bytes / (1024 * 1024);
                            console.info("  LUN{d}: {d} MB ({d} blocks, {d}B sectors) - {s} {s}", .{
                                i,
                                size_mb,
                                lun_info.total_blocks,
                                lun_info.block_size,
                                &lun_info.vendor,
                                &lun_info.product,
                            });

                            // Scan for partitions on this LUN
                            partitions.scanAndRegisterVirtioScsi(@intCast(i)) catch |err| {
                                console.warn("  Partition scan failed for LUN{d}: {}", .{ i, err });
                            };

                            lun_count += 1;
                        }
                    }
                }

                console.info("Storage: VirtIO-SCSI initialized with {d} LUNs", .{lun_count});

                // Register interrupt handler (MSI-X preferred, legacy fallback)
                virtio_scsi.irq.setupMsix(controller, pci.PciAccess{ .ecam = ecam }) catch {};
                virtio_scsi.irq.registerLegacyIrq(controller);

                found_virtio_scsi = true;
                break; // Only initialize first controller
            } else |err| {
                console.warn("Storage: VirtIO-SCSI init failed: {}", .{err});
            }
        }
    }

    if (!found_virtio_scsi) {
        console.info("Storage: No VirtIO-SCSI controllers found", .{});
    }

    // Search for IDE controller (Class 0x01 Mass Storage, Subclass 0x01 IDE)
    // IDE is lower priority than AHCI/NVMe/VirtIO-SCSI, but useful for legacy/PIIX support
    var found_ide = false;
    for (devices.devices[0..devices.count]) |*dev| {
        if (ide.isIdeController(dev)) {
            console.info("Storage: Found IDE controller at {x:0>2}:{x:0>2}.{d}", .{
                dev.bus, dev.device, dev.func,
            });

            if (ide.initFromPci(dev, pci.PciAccess{ .ecam = ecam })) |controller| {
                // Report detected drives
                console.info("  Drives detected: {d}", .{controller.drive_count});

                // Register IRQ handler for interrupt-driven I/O
                ide.registerIrqHandler(controller);

                found_ide = true;
                break; // Only initialize first controller
            } else |err| {
                console.warn("Storage: IDE init failed: {}", .{err});
            }
        }
    }

    // If no PCI IDE controller found, try legacy ISA ports
    if (!found_ide) {
        if (ide.probeLegacy()) |controller| {
            console.info("Storage: Found legacy IDE controller", .{});
            console.info("  Drives detected: {d}", .{controller.drive_count});
            ide.registerIrqHandler(controller);
            found_ide = true;
        } else |_| {
            console.info("Storage: No IDE controllers found", .{});
        }
    }

    // Initialize VirtIO-9P shared folders
    initVirtio9P();

    // Initialize VirtIO-FS shared folders (FUSE-based, better caching)
    initVirtioFs();

    // Initialize VMware HGFS shared folders
    initHgfs();

    // Initialize VirtualBox shared folders
    initVBoxSf();
}

/// Initialize VirtIO-9P shared folders driver
/// Enables host-guest file sharing via QEMU's -virtfs option
pub fn initVirtio9P() void {
    const devices = pci_devices orelse {
        return;
    };

    const ecam = pci_ecam orelse {
        return;
    };

    // Track mounted tags to skip duplicates (QEMU creates multiple PCI slots for same tag)
    const MountedTags = struct {
        var tags: [16][128]u8 = undefined;
        var lens: [16]usize = [_]usize{0} ** 16;
        var count: usize = 0;

        fn isAlreadyMounted(tag: []const u8) bool {
            for (0..count) |i| {
                if (lens[i] == tag.len and std.mem.eql(u8, tags[i][0..lens[i]], tag)) {
                    return true;
                }
            }
            return false;
        }

        fn recordTag(tag: []const u8) void {
            if (count < tags.len and tag.len <= 128) {
                @memcpy(tags[count][0..tag.len], tag);
                lens[count] = tag.len;
                count += 1;
            }
        }
    };

    for (devices.devices[0..devices.count]) |*dev| {
        if (virtio_9p.isVirtio9P(dev)) {
            const device = virtio_9p.initFromPci(dev, pci.PciAccess{ .ecam = ecam }) catch |err| {
                console.warn("VirtIO-9P: Init failed: {}", .{err});
                continue;
            };

            // Attach to root
            device.attach("") catch |err| {
                console.warn("VirtIO-9P: Attach failed: {}", .{err});
                continue;
            };

            const tag = device.getMountTag();

            // Skip duplicates silently (QEMU creates multiple PCI slots)
            if (MountedTags.isAlreadyMounted(tag)) {
                continue;
            }

            // Create VFS filesystem wrapper and mount
            const filesystem = fs.virtio9p.createFilesystem(device) catch |err| {
                console.warn("VirtIO-9P: VFS wrapper failed: {}", .{err});
                continue;
            };

            // Mount at /mnt/<tag> (e.g., /mnt/hostshare)
            var mount_path: [256]u8 = undefined;
            const path_slice = std.fmt.bufPrint(&mount_path, "/mnt/{s}", .{tag}) catch {
                console.warn("VirtIO-9P: Mount path too long", .{});
                continue;
            };

            fs.vfs.Vfs.mount(path_slice, filesystem) catch |err| {
                console.warn("VirtIO-9P: Mount at {s} failed: {}", .{ path_slice, err });
                continue;
            };

            // Record successfully mounted tag
            MountedTags.recordTag(tag);

            console.info("VirtIO-9P: Mounted at {s}", .{path_slice});
            // Continue to next device (support multiple unique mounts)
        }
    }
}

/// Initialize VirtIO-FS shared folders driver
/// Enables host-guest file sharing via QEMU's virtiofsd with FUSE protocol
/// Provides better performance than VirtIO-9P through TTL-based caching
pub fn initVirtioFs() void {
    const devices = pci_devices orelse {
        return;
    };

    const ecam = pci_ecam orelse {
        return;
    };

    // Track mounted tags to skip duplicates
    const MountedTags = struct {
        var tags: [16][128]u8 = undefined;
        var lens: [16]usize = [_]usize{0} ** 16;
        var count: usize = 0;

        fn isAlreadyMounted(tag: []const u8) bool {
            for (0..count) |i| {
                if (lens[i] == tag.len and std.mem.eql(u8, tags[i][0..lens[i]], tag)) {
                    return true;
                }
            }
            return false;
        }

        fn recordTag(tag: []const u8) void {
            if (count < tags.len and tag.len <= 128) {
                @memcpy(tags[count][0..tag.len], tag);
                lens[count] = tag.len;
                count += 1;
            }
        }
    };

    for (devices.devices[0..devices.count]) |*dev| {
        if (virtio_fs.isVirtioFs(dev)) {
            const device = virtio_fs.initFromPci(dev, pci.PciAccess{ .ecam = ecam }) catch |err| {
                console.warn("VirtIO-FS: Init failed: {}", .{err});
                continue;
            };

            const tag = device.getMountTag();

            // Skip duplicates silently
            if (MountedTags.isAlreadyMounted(tag)) {
                continue;
            }

            // Create VFS filesystem wrapper and mount
            const filesystem = fs.virtiofs.createFilesystem(device) catch |err| {
                console.warn("VirtIO-FS: VFS wrapper failed: {}", .{err});
                continue;
            };

            // Mount at /mnt/<tag> (e.g., /mnt/myfs)
            var mount_path: [256]u8 = undefined;
            const path_slice = std.fmt.bufPrint(&mount_path, "/mnt/{s}", .{tag}) catch {
                console.warn("VirtIO-FS: Mount path too long", .{});
                continue;
            };

            fs.vfs.Vfs.mount(path_slice, filesystem) catch |err| {
                console.warn("VirtIO-FS: Mount at {s} failed: {}", .{ path_slice, err });
                continue;
            };

            // Record successfully mounted tag
            MountedTags.recordTag(tag);

            console.info("VirtIO-FS: Mounted at {s}", .{path_slice});
        }
    }
}

/// Initialize VMware HGFS shared folders driver
/// Enables host-guest file sharing via VMware Workstation/Fusion/ESXi shared folders
pub fn initHgfs() void {
    // Only probe on VMware-compatible hypervisors
    if (!detected_hypervisor.isVmwareCompatible() and
        detected_hypervisor != .none and
        detected_hypervisor != .unknown)
    {
        return;
    }

    // Check if VMware backdoor interface is available
    if (!hal.vmware.detect()) {
        return;
    }

    console.info("HGFS: VMware backdoor detected, initializing...", .{});

    // Initialize HGFS driver
    const driver = hgfs.initDriver() catch |err| {
        console.warn("HGFS: Driver init failed: {}", .{err});
        return;
    };

    // Create VFS filesystem wrapper and mount at /mnt/hgfs
    const filesystem = fs.hgfs.createFilesystem(driver) catch |err| {
        console.warn("HGFS: VFS wrapper failed: {}", .{err});
        return;
    };

    fs.vfs.Vfs.mount("/mnt/hgfs", filesystem) catch |err| {
        console.warn("HGFS: Mount at /mnt/hgfs failed: {}", .{err});
        return;
    };

    console.info("HGFS: Mounted at /mnt/hgfs", .{});
}

/// Initialize VirtualBox VMMDev driver
/// Enables Guest Additions features including shared folders (VBoxSF)
pub fn initVmmDev() void {
    const devices = pci_devices orelse {
        return;
    };

    const ecam = pci_ecam orelse {
        return;
    };

    // Only probe on VirtualBox hypervisor
    if (detected_hypervisor != .virtualbox and detected_hypervisor != .none and detected_hypervisor != .unknown) {
        return;
    }

    for (devices.devices[0..devices.count]) |*dev| {
        if (vmmdev.isVmmDev(dev)) {
            console.info("VMMDev: Found device at {d}:{d}.{d}", .{
                dev.bus, dev.device, dev.func,
            });

            const driver = vmmdev.initFromPci(dev, pci.PciAccess{ .ecam = ecam }) catch |err| {
                console.warn("VMMDev: Init failed: {}", .{err});
                continue;
            };

            vmmdev_driver = driver;
            console.info("VMMDev: Driver initialized (HGCM={})", .{driver.hasHgcm()});
            return;
        }
    }
}

/// Initialize VirtIO GPU driver
/// Returns the driver instance if successful, enabling the console to switch modes.
pub fn initVirtioGpu() ?*video_driver.VirtioGpuDriver {
    console.print("\n");

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

    console.debug("VirtIO-GPU: No device found, using framebuffer", .{});
    return null;
}

/// Initialize Video subsystem
/// Tries VirtIO-GPU first (best for KVM/QEMU), then SVGA (VMware/VirtualBox),
/// then BGA (Bochs/QEMU std VGA). Falls back to boot framebuffer if none available.
pub fn initVideo() void {
    console.print("\n");
    console.info("Initializing video subsystem...", .{});

    // First try VirtIO-GPU (best paravirtualized option)
    if (initVirtioGpu()) |driver| {
        console.info("Video: Using VirtIO-GPU driver", .{});
        _ = driver; // Driver stored in virtio_gpu_driver
        return;
    }

    // Try QXL (QEMU/KVM with SPICE) - x86_64 only
    // QXL probed before SVGA as it's more feature-rich for SPICE environments
    if (builtin.cpu.arch == .x86_64) {
        if (video_driver.QxlDriver.init()) |driver| {
            qxl_driver = driver;
            console.info("Video: Using QXL driver", .{});
            return;
        }
    }

    // Try VMware SVGA II (x86_64: port I/O, aarch64: MMIO)
    if (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64) {
        if (video_driver.SvgaDriver.init()) |driver| {
            svga_driver = driver;
            console.info("Video: Using VMware SVGA II driver", .{});
            return;
        }
    }

    // Try Bochs VGA (QEMU default, VirtualBox VBoxVGA)
    if (video_driver.BgaDriver.init()) |driver| {
        bga_driver = driver;
        console.info("Video: Using Bochs VGA driver", .{});
        return;
    }

    // Try Cirrus Logic CL-GD5446 (legacy VGA) - x86_64 only
    // Cirrus probed after BGA as it's a fallback for older VM configurations
    if (builtin.cpu.arch == .x86_64) {
        if (video_driver.CirrusDriver.init()) |driver| {
            cirrus_driver = driver;
            console.info("Video: Using Cirrus VGA driver", .{});
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

    // Initialize PS/2 keyboard on x86_64 (uses i8042 controller)
    if (builtin.cpu.arch == .x86_64) {
        keyboard.init();
        hal.interrupts.setKeyboardHandler(&keyboard.handleIrq);
        // Route IRQ1 to vector 33 (KEYBOARD) and enable it
        hal.apic.routeIrq(1, hal.apic.Vectors.KEYBOARD, 0);
        hal.apic.enableIrq(1);
        console.info("Input: PS/2 keyboard initialized (IRQ1 -> vector {d})", .{hal.apic.Vectors.KEYBOARD});
    }

    // Probe for VirtIO-Input devices (keyboard/mouse/tablet)
    // On KVM/QEMU/TCG where VirtIO devices are expected, or bare metal (testing)
    if (detected_hypervisor.isKvmCompatible() or detected_hypervisor == .none or detected_hypervisor == .unknown) {
        initVirtioInput();
    }
}

/// Initialize VirtIO-Input devices
fn initVirtioInput() void {
    const devices = pci_devices orelse return;
    const ecam = pci_ecam orelse return;

    var found_count: u32 = 0;

    for (devices.devices[0..devices.count]) |*dev| {
        if (virtio_input.isVirtioInput(dev)) {
            console.info("VirtIO-Input: Found device at {d}:{d}.{d}", .{
                dev.bus, dev.device, dev.func,
            });

            const driver = virtio_input.initFromPci(dev, pci.PciAccess{ .ecam = ecam }) catch |err| {
                console.warn("VirtIO-Input: Init failed: {}", .{err});
                continue;
            };

            // Set up MSI-X interrupts
            virtio_input.irq.setupMsix(driver, pci.PciAccess{ .ecam = ecam }) catch |err| {
                console.warn("VirtIO-Input: MSI-X setup failed: {}, using polling", .{err});
            };

            found_count += 1;
        }
    }

    if (found_count > 0) {
        console.info("Input: Initialized {} VirtIO-Input device(s)", .{found_count});
    }
}

/// Initialize VirtIO-RNG (entropy device)
/// Provides hardware entropy from hypervisor to kernel PRNG
pub fn initVirtioRng() void {
    console.print("\n");

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
        // SECURITY: Zero-init to prevent stack data leaks if getEntropy returns partial data.
        // In ReleaseFast, `undefined` contains whatever was on the stack.
        var entropy = [_]u8{0} ** 64;
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
        console.debug("VirtIO-RNG: No device found", .{});
    }
}

/// Initialize Virtual PCI subsystem
/// Sets up the global device table for userspace-controlled virtual PCI devices.
/// Virtual devices are created at runtime via sys_vpci_create syscalls.
pub fn initVirtPci() void {
    virt_pci.init();
}

/// Probe unbound PCI devices against registered drivers.
/// Called after all subsystem inits are complete, as a catch-all for devices
/// that weren't claimed by the hardcoded init paths above.
pub fn probeRemainingDevices() void {
    const devices = pci_devices orelse return;
    const ecam = pci_ecam orelse return;
    pci.driver.probeAllDevices(devices, pci.PciAccess{ .ecam = ecam });
}

/// Initialize VirtIO-Sound device
/// Returns true if a VirtIO-Sound device was found and initialized
fn initVirtioSound() bool {
    const devices = pci_devices orelse return false;
    const ecam = pci_ecam orelse return false;

    for (devices.devices[0..devices.count]) |*dev| {
        if (virtio_sound.isVirtioSound(dev)) {
            console.info("VirtIO-Sound: Found device at {d}:{d}.{d}", .{
                dev.bus, dev.device, dev.func,
            });

            const driver = virtio_sound.initFromPci(dev, pci.PciAccess{ .ecam = ecam }) catch |err| {
                console.warn("VirtIO-Sound: Init failed: {}", .{err});
                continue;
            };

            // Set up MSI-X interrupts
            virtio_sound.irq.setupMsix(driver, pci.PciAccess{ .ecam = ecam }) catch |err| {
                console.warn("VirtIO-Sound: MSI-X setup failed: {}, using polling", .{err});
            };

            console.info("VirtIO-Sound: Driver initialized", .{});
            return true;
        }
    }

    return false;
}

/// Initialize VirtualBox Shared Folders
/// Connects to HGCM VBoxSharedFolders service and mounts available shares
pub fn initVBoxSf() void {
    // Only run on VirtualBox
    if (detected_hypervisor != .virtualbox) {
        return;
    }

    // VMMDev must be initialized first
    const device = vmmdev_driver orelse {
        console.debug("VBoxSF: VMMDev not available", .{});
        return;
    };

    // Check HGCM support
    if (!device.hasHgcm()) {
        console.warn("VBoxSF: HGCM not available on VMMDev", .{});
        return;
    }

    // Initialize VBoxSF driver
    const driver = vboxsf.init() catch |err| {
        console.warn("VBoxSF: Driver init failed: {}", .{err});
        return;
    };

    console.info("VBoxSF: Driver initialized", .{});

    // Try to mount common share names
    // VirtualBox doesn't have a "list shares" API, so we try known names
    const share_names = [_][]const u8{ "shared", "share", "vboxshare", "home" };

    for (share_names) |name| {
        var mount_path: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&mount_path, "/mnt/vbox/{s}", .{name}) catch continue;

        fs.vboxsf.mount(driver, name, path) catch |err| {
            // Silently skip shares that don't exist
            if (err != error.NotFound) {
                console.debug("VBoxSF: Mount '{s}' failed: {}", .{ name, err });
            }
            continue;
        };

        console.info("VBoxSF: Mounted '{s}' at {s}", .{ name, path });
    }
}

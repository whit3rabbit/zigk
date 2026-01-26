// IDE/PIIX Storage Driver
//
// Provides block device access to IDE/PATA drives using PIO mode.
// Supports both PCI IDE controllers and legacy ISA ports.
//
// Usage:
//   const ide = @import("ide");
//   if (ide.initFromPci(pci_dev, pci_access)) |controller| {
//       ide.registerIrqHandler(controller);
//   }
//
// Reference: ATA/ATAPI-7 Specification, Intel PIIX Datasheet

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const pci = @import("pci");
const heap = @import("heap");

pub const registers = @import("registers.zig");
pub const detect = @import("detect.zig");
pub const command = @import("command.zig");
pub const adapter = @import("adapter.zig");
pub const irq = @import("irq.zig");

// ============================================================================
// Constants
// ============================================================================

pub const SECTOR_SIZE: usize = 512;
pub const MAX_CHANNELS: usize = 2;
pub const MAX_DRIVES_PER_CHANNEL: usize = 2;
pub const MAX_DRIVES: usize = MAX_CHANNELS * MAX_DRIVES_PER_CHANNEL;

/// PCI Class/Subclass for IDE controllers
pub const PCI_CLASS_STORAGE: u8 = 0x01;
pub const PCI_SUBCLASS_IDE: u8 = 0x01;

// ============================================================================
// Error Types
// ============================================================================

pub const IdeError = error{
    NotIdeController,
    InitFailed,
    NoDrivesFound,
    Timeout,
    DeviceError,
};

// ============================================================================
// Drive State
// ============================================================================

pub const Drive = struct {
    channel_num: u1,
    drive_num: u1,
    info: detect.DriveInfo,
    channel: registers.Channel,

    /// Get drive reference for FileOps
    pub fn getRef(self: *const Drive) adapter.DriveRef {
        return .{
            .channel = self.channel_num,
            .drive = self.drive_num,
            .supports_lba48 = self.info.supports_lba48,
        };
    }

    /// Get device name (hda, hdb, hdc, hdd)
    pub fn getDeviceName(self: *const Drive) [3]u8 {
        const idx = @as(u8, self.channel_num) * 2 + @as(u8, self.drive_num);
        return .{ 'h', 'd', 'a' + idx };
    }
};

// ============================================================================
// Controller State
// ============================================================================

pub const Controller = struct {
    /// Primary channel (0x1F0)
    primary: ?registers.Channel,
    /// Secondary channel (0x170)
    secondary: ?registers.Channel,
    /// Detected drives
    drives: [MAX_DRIVES]?Drive,
    /// Number of drives found
    drive_count: usize,
    /// PCI device (null if legacy ISA)
    pci_device: ?*const pci.PciDevice,

    pub fn init() Controller {
        return .{
            .primary = null,
            .secondary = null,
            .drives = [_]?Drive{null} ** MAX_DRIVES,
            .drive_count = 0,
            .pci_device = null,
        };
    }

    /// Get drive by index (0-3: hda-hdd)
    pub fn getDrive(self: *const Controller, idx: usize) ?*const Drive {
        if (idx >= MAX_DRIVES) return null;
        if (self.drives[idx]) |*d| {
            return d;
        }
        return null;
    }

    /// Find drive by channel and drive number
    pub fn findDrive(self: *const Controller, channel_num: u1, drive_num: u1) ?*const Drive {
        const idx = @as(usize, channel_num) * 2 + @as(usize, drive_num);
        return self.getDrive(idx);
    }
};

// ============================================================================
// Global Controller Instance
// ============================================================================

var g_controller: ?*Controller = null;

/// Get global controller instance
pub fn getController() ?*Controller {
    return g_controller;
}

// ============================================================================
// Initialization
// ============================================================================

/// Initialize IDE controller from PCI device
pub fn initFromPci(pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) IdeError!*Controller {
    _ = pci_access;

    // Verify this is an IDE controller
    if (pci_dev.class_code != PCI_CLASS_STORAGE or pci_dev.subclass != PCI_SUBCLASS_IDE) {
        return error.NotIdeController;
    }

    console.info("IDE: Initializing controller at {x:0>2}:{x:0>2}.{d}", .{
        pci_dev.bus,
        pci_dev.device,
        pci_dev.func,
    });

    // Allocate controller
    const allocator = heap.allocator();
    const controller = allocator.create(Controller) catch {
        return error.InitFailed;
    };
    controller.* = Controller.init();
    controller.pci_device = pci_dev;

    // Check programming interface for native/compatibility mode
    // Bits 0-1: Primary channel mode (0 = compatibility, 1 = native)
    // Bits 2-3: Secondary channel mode
    const prog_if = pci_dev.prog_if;
    const primary_native = (prog_if & 0x01) != 0;
    const secondary_native = (prog_if & 0x04) != 0;

    // Set up channels
    if (primary_native) {
        // Use BAR0 and BAR1 for primary channel
        // For now, fall back to legacy ports
        controller.primary = registers.Channel.primary();
    } else {
        controller.primary = registers.Channel.primary();
    }

    if (secondary_native) {
        // Use BAR2 and BAR3 for secondary channel
        controller.secondary = registers.Channel.secondary();
    } else {
        controller.secondary = registers.Channel.secondary();
    }

    // Detect drives
    try detectDrives(controller);

    if (controller.drive_count == 0) {
        allocator.destroy(controller);
        return error.NoDrivesFound;
    }

    // Register devices with devfs
    registerDevices(controller);

    g_controller = controller;
    return controller;
}

/// Probe legacy ISA IDE ports (fallback when no PCI controller)
pub fn probeLegacy() IdeError!*Controller {
    console.info("IDE: Probing legacy ISA ports...", .{});

    const allocator = heap.allocator();
    const controller = allocator.create(Controller) catch {
        return error.InitFailed;
    };
    controller.* = Controller.init();

    // Check if primary channel responds
    const primary = registers.Channel.primary();
    if (registers.isChannelPresent(primary)) {
        controller.primary = primary;
        console.info("IDE: Primary channel present at 0x{x:0>3}", .{primary.io_base});
    }

    // Check if secondary channel responds
    const secondary = registers.Channel.secondary();
    if (registers.isChannelPresent(secondary)) {
        controller.secondary = secondary;
        console.info("IDE: Secondary channel present at 0x{x:0>3}", .{secondary.io_base});
    }

    if (controller.primary == null and controller.secondary == null) {
        allocator.destroy(controller);
        return error.NoDrivesFound;
    }

    // Detect drives
    try detectDrives(controller);

    if (controller.drive_count == 0) {
        allocator.destroy(controller);
        return error.NoDrivesFound;
    }

    // Register devices
    registerDevices(controller);

    g_controller = controller;
    return controller;
}

/// Detect drives on all channels
fn detectDrives(controller: *Controller) IdeError!void {
    // Disable interrupts during detection
    if (controller.primary) |ch| {
        irq.disableChannelInterrupts(ch);
    }
    if (controller.secondary) |ch| {
        irq.disableChannelInterrupts(ch);
    }

    // Scan primary channel
    if (controller.primary) |channel| {
        const drives = detect.scanChannel(channel);

        // Master drive (hda)
        if (drives[0].drive_type != .none) {
            controller.drives[0] = Drive{
                .channel_num = 0,
                .drive_num = 0,
                .info = drives[0],
                .channel = channel,
            };
            controller.drive_count += 1;
            detect.logDriveInfo("Primary", 0, &drives[0]);
        }

        // Slave drive (hdb)
        if (drives[1].drive_type != .none) {
            controller.drives[1] = Drive{
                .channel_num = 0,
                .drive_num = 1,
                .info = drives[1],
                .channel = channel,
            };
            controller.drive_count += 1;
            detect.logDriveInfo("Primary", 1, &drives[1]);
        }
    }

    // Scan secondary channel
    if (controller.secondary) |channel| {
        const drives = detect.scanChannel(channel);

        // Master drive (hdc)
        if (drives[0].drive_type != .none) {
            controller.drives[2] = Drive{
                .channel_num = 1,
                .drive_num = 0,
                .info = drives[0],
                .channel = channel,
            };
            controller.drive_count += 1;
            detect.logDriveInfo("Secondary", 0, &drives[0]);
        }

        // Slave drive (hdd)
        if (drives[1].drive_type != .none) {
            controller.drives[3] = Drive{
                .channel_num = 1,
                .drive_num = 1,
                .info = drives[1],
                .channel = channel,
            };
            controller.drive_count += 1;
            detect.logDriveInfo("Secondary", 1, &drives[1]);
        }
    }

    console.info("IDE: Found {d} drive(s)", .{controller.drive_count});
}

/// Register drives with devfs
pub fn registerDevices(controller: *Controller) void {
    const devfs = @import("devfs");

    for (controller.drives, 0..) |maybe_drive, i| {
        if (maybe_drive) |*drive| {
            const name = drive.getDeviceName();
            const name_slice = name[0..3];
            const ref = drive.getRef();

            devfs.registerDevice(name_slice, &adapter.block_ops, ref.encode()) catch |err| {
                console.warn("IDE: Failed to register /dev/{s}: {}", .{ name_slice, err });
                continue;
            };

            console.info("IDE: Registered /dev/{s}", .{name_slice});

            // TODO: Scan for partitions
            // partitions.scanAndRegisterIde(@intCast(i)) catch |err| {
            //     console.warn("IDE: Partition scan failed for drive {d}: {}", .{ i, err });
            // };
            _ = i;
        }
    }
}

/// Register IRQ handlers
pub fn registerIrqHandler(controller: *Controller) void {
    irq.registerIrqHandlers(controller, controller.primary, controller.secondary) catch |err| {
        console.warn("IDE: IRQ registration failed: {}", .{err});
    };

    // Enable interrupts on channels
    if (controller.primary) |ch| {
        irq.enableChannelInterrupts(ch);
    }
    if (controller.secondary) |ch| {
        irq.enableChannelInterrupts(ch);
    }
}

// ============================================================================
// Public Read/Write API
// ============================================================================

/// Read sectors from a drive
pub fn readSectors(
    drive_idx: usize,
    lba: u64,
    count: u16,
    buffer: []u8,
) IdeError!usize {
    const controller = g_controller orelse return error.InitFailed;
    const drive = controller.getDrive(drive_idx) orelse return error.DeviceError;

    if (drive.info.drive_type != .ata) {
        return error.DeviceError;
    }

    return command.readSectorsPio(
        drive.channel,
        drive.drive_num,
        lba,
        count,
        buffer,
        drive.info.supports_lba48,
    ) catch {
        return error.DeviceError;
    };
}

/// Write sectors to a drive
pub fn writeSectors(
    drive_idx: usize,
    lba: u64,
    count: u16,
    buffer: []const u8,
) IdeError!usize {
    const controller = g_controller orelse return error.InitFailed;
    const drive = controller.getDrive(drive_idx) orelse return error.DeviceError;

    if (drive.info.drive_type != .ata) {
        return error.DeviceError;
    }

    return command.writeSectorsPio(
        drive.channel,
        drive.drive_num,
        lba,
        count,
        buffer,
        drive.info.supports_lba48,
    ) catch {
        return error.DeviceError;
    };
}

// ============================================================================
// PCI Detection Helper
// ============================================================================

/// Check if PCI device is an IDE controller
pub fn isIdeController(dev: *const pci.PciDevice) bool {
    return dev.class_code == PCI_CLASS_STORAGE and dev.subclass == PCI_SUBCLASS_IDE;
}

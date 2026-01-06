// PCIe ECAM (Enhanced Configuration Access Mechanism)
//
// Provides memory-mapped access to PCI configuration space.
// Each device's 4KB config space is mapped at:
//   Address = ECAM_Base + (Bus << 20) | (Device << 15) | (Function << 12) | Offset
//
// Reference: PCI Express Base Specification 4.0, Section 7.2.2

const std = @import("std");
const hal = @import("hal");
const vmm = @import("vmm");
const console = @import("console");

const mmio = hal.mmio;

/// ECAM configuration space accessor
pub const Ecam = struct {
    /// Virtual base address of ECAM region (after VMM mapping)
    base_virt: u64,
    /// Physical base address (for debugging)
    base_phys: u64,
    /// First bus number covered by this ECAM region
    start_bus: u8,
    /// Last bus number covered by this ECAM region
    end_bus: u8,

    const Self = @This();

    /// Initialize ECAM accessor by mapping the MMIO region
    /// ecam_phys: Physical base address from MCFG table
    /// start_bus: First bus number covered
    /// end_bus: Last bus number covered
    ///
    /// SECURITY: Uses overflow-safe arithmetic for size calculation since
    /// bus range values come from ACPI MCFG table (untrusted firmware data).
    /// Also validates ECAM base alignment per PCIe spec requirements.
    pub fn init(ecam_phys: u64, start_bus: u8, end_bus: u8) !Self {
        // Validate bus range to prevent integer underflow
        if (end_bus < start_bus) {
            console.err("PCI ECAM: Invalid bus range {d}-{d} (end < start)", .{ start_bus, end_bus });
            return error.MappingFailed;
        }

        // SECURITY: Validate ECAM base alignment per PCIe spec.
        // ECAM base must be naturally aligned to its size (bus_count * 1MB).
        // At minimum, it should be 1MB aligned (single bus). For full 256-bus range,
        // it should be 256MB aligned. We enforce 1MB alignment as minimum.
        // This prevents address calculation errors from misaligned firmware data.
        const ecam_alignment: u64 = 0x100000; // 1MB minimum alignment
        if ((ecam_phys & (ecam_alignment - 1)) != 0) {
            console.err("PCI ECAM: Base address 0x{x} not 1MB aligned (ACPI firmware bug)", .{ecam_phys});
            return error.MappingFailed;
        }

        // Calculate size: (end_bus - start_bus + 1) buses * 32 devices * 8 functions * 4KB
        // SECURITY: Use overflow-safe multiplication since values come from ACPI (firmware).
        // Max theoretical size: 256 buses * 32 * 8 * 4096 = 256MB, fits in u64.
        const bus_count: u64 = @as(u64, end_bus - start_bus) + 1;
        const bytes_per_bus: u64 = 32 * 8 * 4096; // 1MB per bus (constant, no overflow)
        const size = std.math.mul(u64, bus_count, bytes_per_bus) catch {
            console.err("PCI ECAM: Size calculation overflow (bus_count={d})", .{bus_count});
            return error.MappingFailed;
        };

        console.info("PCI ECAM: Mapping phys=0x{x}, buses {d}-{d}, size={d}MB", .{
            ecam_phys,
            start_bus,
            end_bus,
            size / (1024 * 1024),
        });

        // Map ECAM region to virtual address space with an explicit ALIGNED mapping.
        // CRITICAL: The virtual address MUST be 1MB aligned because configAddr() uses
        // bitwise OR to calculate device addresses. Without proper alignment, the OR
        // operation produces incorrect addresses that alias to the same memory location.
        // ECAM is often in a high MMIO hole that may not be covered by the HHDM map.
        const ecam_alignment_usize: usize = @intCast(ecam_alignment);
        const base_virt = vmm.mapMmioExplicitAligned(ecam_phys, size, ecam_alignment_usize) catch |err| {
            console.err("PCI ECAM: Failed to map MMIO region: {}", .{err});
            return error.MappingFailed;
        };

        // SECURITY: Verify the virtual address is actually 1MB aligned.
        // This guards against VMM bugs that could cause address aliasing.
        if ((base_virt & (ecam_alignment - 1)) != 0) {
            console.err("PCI ECAM: VMM returned misaligned virtual address 0x{x}", .{base_virt});
            return error.MappingFailed;
        }

        return Self{
            .base_virt = base_virt,
            .base_phys = ecam_phys,
            .start_bus = start_bus,
            .end_bus = end_bus,
        };
    }

    /// Calculate virtual address for a device's config space register
    ///
    /// SECURITY: Uses pure bitwise OR for address calculation. This is safe because
    /// Ecam.init() validates that base_virt is at least 1MB aligned, ensuring the
    /// lower 20 bits are zero. The bus/device/func/offset fields occupy non-overlapping
    /// bit positions within those lower 20 bits (plus bus extending above).
    fn configAddr(self: *const Self, bus: u8, device: u5, func: u3, offset: u12) ?u64 {
        // Validate bus is in range
        if (bus < self.start_bus or bus > self.end_bus) {
            return null;
        }

        const relative_bus: u64 = bus - self.start_bus;
        // Pure bitwise OR is correct because base_virt is 1MB+ aligned (validated in init)
        // and the shifted fields occupy distinct bit ranges:
        //   bits 0-11:  offset (u12)
        //   bits 12-14: function (u3)
        //   bits 15-19: device (u5)
        //   bits 20+:   relative_bus
        return self.base_virt |
            (relative_bus << 20) |
            (@as(u64, device) << 15) |
            (@as(u64, func) << 12) |
            @as(u64, offset);
    }

    /// Read 8-bit value from config space
    pub fn read8(self: *const Self, bus: u8, device: u5, func: u3, offset: u12) u8 {
        const addr = self.configAddr(bus, device, func, offset) orelse return 0xFF;
        return mmio.read8(addr);
    }

    /// Read 16-bit value from config space
    /// Offset should be 2-byte aligned
    pub fn read16(self: *const Self, bus: u8, device: u5, func: u3, offset: u12) u16 {
        const addr = self.configAddr(bus, device, func, offset) orelse return 0xFFFF;
        return mmio.read16(addr);
    }

    /// Read 32-bit value from config space
    /// Offset should be 4-byte aligned
    pub fn read32(self: *const Self, bus: u8, device: u5, func: u3, offset: u12) u32 {
        const addr = self.configAddr(bus, device, func, offset) orelse return 0xFFFFFFFF;
        return mmio.read32(addr);
    }

    /// Write 8-bit value to config space
    pub fn write8(self: *const Self, bus: u8, device: u5, func: u3, offset: u12, value: u8) void {
        const addr = self.configAddr(bus, device, func, offset) orelse return;
        mmio.write8(addr, value);
    }

    /// Write 16-bit value to config space
    /// Offset should be 2-byte aligned
    pub fn write16(self: *const Self, bus: u8, device: u5, func: u3, offset: u12, value: u16) void {
        const addr = self.configAddr(bus, device, func, offset) orelse return;
        mmio.write16(addr, value);
    }

    /// Write 32-bit value to config space
    /// Offset should be 4-byte aligned
    pub fn write32(self: *const Self, bus: u8, device: u5, func: u3, offset: u12, value: u32) void {
        const addr = self.configAddr(bus, device, func, offset) orelse return;
        mmio.write32(addr, value);
    }

    /// Check if a device exists at the given location
    pub fn deviceExists(self: *const Self, bus: u8, device: u5, func: u3) bool {
        const vendor = self.read16(bus, device, func, 0x00);
        return vendor != 0xFFFF;
    }

    /// Read vendor ID
    pub fn readVendorId(self: *const Self, bus: u8, device: u5, func: u3) u16 {
        return self.read16(bus, device, func, 0x00);
    }

    /// Read device ID
    pub fn readDeviceId(self: *const Self, bus: u8, device: u5, func: u3) u16 {
        return self.read16(bus, device, func, 0x02);
    }

    /// Read header type
    pub fn readHeaderType(self: *const Self, bus: u8, device: u5, func: u3) u8 {
        return self.read8(bus, device, func, 0x0E);
    }

    /// Read class code (offset 0x0B)
    pub fn readClassCode(self: *const Self, bus: u8, device: u5, func: u3) u8 {
        return self.read8(bus, device, func, 0x0B);
    }

    /// Read subclass code (offset 0x0A)
    pub fn readSubclass(self: *const Self, bus: u8, device: u5, func: u3) u8 {
        return self.read8(bus, device, func, 0x0A);
    }

    /// Read command register
    pub fn readCommand(self: *const Self, bus: u8, device: u5, func: u3) u16 {
        return self.read16(bus, device, func, 0x04);
    }

    /// Write command register
    pub fn writeCommand(self: *const Self, bus: u8, device: u5, func: u3, value: u16) void {
        self.write16(bus, device, func, 0x04, value);
    }

    /// Enable bus mastering for a device
    pub fn enableBusMaster(self: *const Self, bus: u8, device: u5, func: u3) void {
        const cmd = self.readCommand(bus, device, func);
        self.writeCommand(bus, device, func, cmd | 0x04); // Bit 2 = Bus Master Enable
    }

    /// Enable memory space access for a device
    pub fn enableMemorySpace(self: *const Self, bus: u8, device: u5, func: u3) void {
        const cmd = self.readCommand(bus, device, func);
        self.writeCommand(bus, device, func, cmd | 0x02); // Bit 1 = Memory Space Enable
    }

    /// Read BAR (Base Address Register) at specified index (0-5)
    pub fn readBar(self: *const Self, bus: u8, device: u5, func: u3, bar_index: u3) u32 {
        const offset: u12 = 0x10 + @as(u12, bar_index) * 4;
        return self.read32(bus, device, func, offset);
    }

    /// Write BAR value
    pub fn writeBar(self: *const Self, bus: u8, device: u5, func: u3, bar_index: u3, value: u32) void {
        const offset: u12 = 0x10 + @as(u12, bar_index) * 4;
        self.write32(bus, device, func, offset, value);
    }

    /// Read interrupt line (IRQ number)
    pub fn readIrqLine(self: *const Self, bus: u8, device: u5, func: u3) u8 {
        return self.read8(bus, device, func, 0x3C);
    }

    /// Read interrupt pin (0=none, 1=INTA, 2=INTB, etc.)
    pub fn readIrqPin(self: *const Self, bus: u8, device: u5, func: u3) u8 {
        return self.read8(bus, device, func, 0x3D);
    }
};

/// Error type for ECAM operations
pub const EcamError = error{
    MappingFailed,
    InvalidBus,
    DeviceNotFound,
};

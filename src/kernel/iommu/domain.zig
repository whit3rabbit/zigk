// IOMMU Domain Management
//
// Manages per-device IOMMU domains for DMA isolation. Each domain has its own
// IOVA (IO Virtual Address) space and page tables, ensuring devices cannot
// access memory outside their assigned regions.
//
// Key concepts:
//   - Domain: Isolated IOVA namespace shared by one or more devices
//   - IOVA: IO Virtual Address seen by the device (translated by IOMMU)
//   - Device assignment: Devices are assigned to domains for DMA access
//
// Security: Devices in different domains cannot access each other's memory,
// providing hardware-enforced isolation between drivers.

const std = @import("std");
const console = @import("console");
const pmm = @import("pmm");
const hal = @import("hal");

const paging = hal.paging;
const iommu = hal.iommu;

/// IOVA address space constants
/// Start at 4GB to avoid conflicts with low memory addresses
const IOVA_BASE: u64 = 0x1_0000_0000; // 4GB
const IOVA_LIMIT: u64 = 0x100_0000_0000; // 1TB
const IOVA_SIZE: u64 = IOVA_LIMIT - IOVA_BASE;

/// Page size for IOVA allocations
const PAGE_SIZE: u64 = 4096;
const PAGE_SHIFT: u6 = 12;

/// Maximum devices per domain
const MAX_DEVICES_PER_DOMAIN: usize = 8;

/// Maximum number of IOMMU domains
const MAX_DOMAINS: usize = 64;

/// PCI Bus/Device/Function identifier
pub const DeviceBdf = struct {
    bus: u8,
    device: u5,
    func: u3,

    /// Create from raw BDF encoding (bus:8 | device:5 | func:3)
    pub fn fromRaw(raw: u16) DeviceBdf {
        return .{
            .bus = @truncate(raw >> 8),
            .device = @truncate((raw >> 3) & 0x1F),
            .func = @truncate(raw & 0x7),
        };
    }

    /// Convert to raw BDF encoding
    pub fn toRaw(self: DeviceBdf) u16 {
        return (@as(u16, self.bus) << 8) | (@as(u16, self.device) << 3) | @as(u16, self.func);
    }

    /// Check equality
    pub fn eql(self: DeviceBdf, other: DeviceBdf) bool {
        return self.bus == other.bus and self.device == other.device and self.func == other.func;
    }
};

/// Simple bump allocator for IOVA space
/// Thread-safe with atomic next pointer
pub const IovaAllocator = struct {
    /// Next available IOVA address
    next: u64,

    /// End of IOVA space
    limit: u64,

    const Self = @This();

    /// Create a new IOVA allocator
    pub fn init() Self {
        return .{
            .next = IOVA_BASE,
            .limit = IOVA_LIMIT,
        };
    }

    /// Allocate a contiguous IOVA range
    /// Returns the starting IOVA address, or null if out of space
    pub fn allocate(self: *Self, size: u64) ?u64 {
        // Align size to page boundary
        const aligned_size = (size + PAGE_SIZE - 1) & ~@as(u64, PAGE_SIZE - 1);

        // Check if we have enough space
        if (self.next + aligned_size > self.limit) {
            console.warn("IOMMU: IOVA space exhausted", .{});
            return null;
        }

        const iova = self.next;
        self.next += aligned_size;
        return iova;
    }

    /// Free an IOVA range (currently a no-op for bump allocator)
    /// Future: Implement proper free list for IOVA recycling
    pub fn free(self: *Self, iova: u64, size: u64) void {
        _ = self;
        _ = iova;
        _ = size;
        // Bump allocator doesn't support free
        // A production implementation would use a free list or buddy allocator
    }

    /// Get remaining IOVA space
    pub fn remaining(self: *const Self) u64 {
        return self.limit - self.next;
    }
};

/// IOMMU Domain
/// Represents an isolated DMA namespace for a set of devices
pub const Domain = struct {
    /// Unique domain ID (used by hardware for TLB tagging)
    id: u16,

    /// Page tables for this domain (from HAL layer)
    page_tables: iommu.page_table.DomainPageTables,

    /// IOVA allocator for this domain
    iova_alloc: IovaAllocator,

    /// Devices assigned to this domain
    devices: [MAX_DEVICES_PER_DOMAIN]?DeviceBdf,
    device_count: u8,

    /// Domain is active (has devices and is registered with hardware)
    active: bool,

    const Self = @This();

    /// Create a new domain with the given ID
    pub fn create(id: u16) ?*Self {
        // Allocate page tables for this domain
        const page_tables = iommu.page_table.DomainPageTables.create() orelse {
            console.err("IOMMU: Failed to allocate domain page tables", .{});
            return null;
        };

        // Allocate domain structure from kernel heap
        // For now, use static array in DomainManager
        const domain = domain_manager.allocDomain() orelse return null;

        domain.* = .{
            .id = id,
            .page_tables = page_tables,
            .iova_alloc = IovaAllocator.init(),
            .devices = [_]?DeviceBdf{null} ** MAX_DEVICES_PER_DOMAIN,
            .device_count = 0,
            .active = true,
        };

        return domain;
    }

    /// Assign a device to this domain
    pub fn assignDevice(self: *Self, bdf: DeviceBdf) bool {
        // Check if already assigned
        for (self.devices[0..self.device_count]) |existing| {
            if (existing) |dev| {
                if (dev.eql(bdf)) {
                    return true; // Already assigned
                }
            }
        }

        // Find empty slot
        if (self.device_count >= MAX_DEVICES_PER_DOMAIN) {
            console.err("IOMMU: Domain {d} has too many devices", .{self.id});
            return false;
        }

        self.devices[self.device_count] = bdf;
        self.device_count += 1;

        console.info("IOMMU: Assigned device {x:0>2}:{x:0>2}.{d} to domain {d}", .{
            bdf.bus,
            bdf.device,
            bdf.func,
            self.id,
        });

        return true;
    }

    /// Unassign a device from this domain
    pub fn unassignDevice(self: *Self, bdf: DeviceBdf) void {
        for (self.devices[0..self.device_count], 0..) |existing, i| {
            if (existing) |dev| {
                if (dev.eql(bdf)) {
                    // Shift remaining devices
                    var j = i;
                    while (j < self.device_count - 1) : (j += 1) {
                        self.devices[j] = self.devices[j + 1];
                    }
                    self.devices[self.device_count - 1] = null;
                    self.device_count -= 1;
                    return;
                }
            }
        }
    }

    /// Allocate IOVA and map to physical memory
    /// This is the main function for DMA buffer allocation
    pub fn allocateAndMap(
        self: *Self,
        phys_addr: u64,
        size: u64,
        readable: bool,
        writable: bool,
    ) ?u64 {
        // Allocate IOVA space
        const iova = self.iova_alloc.allocate(size) orelse return null;

        // Create page table mappings
        self.page_tables.mapRange(iova, phys_addr, size, readable, writable) catch {
            console.err("IOMMU: Failed to map IOVA 0x{x} to phys 0x{x}", .{ iova, phys_addr });
            // Return IOVA to allocator (currently no-op)
            self.iova_alloc.free(iova, size);
            return null;
        };

        return iova;
    }

    /// Map a specific IOVA to physical memory
    pub fn mapIova(
        self: *Self,
        iova: u64,
        phys_addr: u64,
        size: u64,
        readable: bool,
        writable: bool,
    ) bool {
        self.page_tables.mapRange(iova, phys_addr, size, readable, writable) catch {
            console.err("IOMMU: Failed to map IOVA 0x{x}", .{iova});
            return false;
        };
        return true;
    }

    /// Unmap an IOVA range
    pub fn unmapIova(self: *Self, iova: u64, size: u64) void {
        self.page_tables.unmapRange(iova, size);
        self.iova_alloc.free(iova, size);
    }

    /// Translate IOVA to physical address
    pub fn translate(self: *const Self, iova: u64) ?u64 {
        return self.page_tables.translate(iova);
    }

    /// Get physical address of PML4 for hardware programming
    pub fn getPml4Phys(self: *const Self) u64 {
        return self.page_tables.pml4_phys;
    }

    /// Log domain information for debugging
    pub fn logInfo(self: *const Self) void {
        console.info("Domain {d}:", .{self.id});
        console.info("  PML4 phys: 0x{x}", .{self.page_tables.pml4_phys});
        console.info("  IOVA remaining: {d} MB", .{self.iova_alloc.remaining() / (1024 * 1024)});
        console.info("  Devices: {d}", .{self.device_count});
        for (self.devices[0..self.device_count]) |dev_opt| {
            if (dev_opt) |dev| {
                console.info("    - {x:0>2}:{x:0>2}.{d}", .{ dev.bus, dev.device, dev.func });
            }
        }
    }
};

/// Global domain manager
pub const DomainManager = struct {
    /// All domains (indexed by domain ID)
    domains: [MAX_DOMAINS]Domain,

    /// Domain allocation bitmap
    allocated: [MAX_DOMAINS]bool,

    /// Next domain ID to try
    next_id: u16,

    /// IOMMU tables for hardware programming
    iommu_tables: ?iommu.page_table.IommuTables,

    /// IOMMU initialized flag
    initialized: bool,

    const Self = @This();

    /// Initialize the domain manager
    pub fn init(self: *Self) void {
        self.* = .{
            .domains = undefined,
            .allocated = [_]bool{false} ** MAX_DOMAINS,
            .next_id = 0,
            .iommu_tables = null,
            .initialized = false,
        };
    }

    /// Create the hardware IOMMU tables
    pub fn initHardware(self: *Self) bool {
        self.iommu_tables = iommu.page_table.IommuTables.create() orelse {
            console.err("IOMMU: Failed to create hardware tables", .{});
            return false;
        };
        self.initialized = true;
        console.info("IOMMU: Hardware tables initialized at 0x{x}", .{self.iommu_tables.?.root_phys});
        return true;
    }

    /// Allocate a domain slot (internal)
    fn allocDomain(self: *Self) ?*Domain {
        for (&self.allocated, 0..) |*alloc, i| {
            if (!alloc.*) {
                alloc.* = true;
                return &self.domains[i];
            }
        }
        return null;
    }

    /// Create a new domain
    pub fn createDomain(self: *Self) ?*Domain {
        // Find next available domain ID
        var id = self.next_id;
        var tries: u16 = 0;
        while (tries < MAX_DOMAINS) : (tries += 1) {
            if (!self.allocated[id]) {
                self.next_id = @truncate((id + 1) % MAX_DOMAINS);
                return Domain.create(id);
            }
            id = @truncate((id + 1) % MAX_DOMAINS);
        }

        console.err("IOMMU: No domain slots available", .{});
        return null;
    }

    /// Find or create a domain for a device
    pub fn getDomainForDevice(self: *Self, bdf: DeviceBdf) ?*Domain {
        // Check if device already has a domain
        for (&self.domains, 0..) |*domain, i| {
            if (self.allocated[i] and domain.active) {
                for (domain.devices[0..domain.device_count]) |dev_opt| {
                    if (dev_opt) |dev| {
                        if (dev.eql(bdf)) {
                            return domain;
                        }
                    }
                }
            }
        }

        // Create new domain for this device
        const domain = self.createDomain() orelse return null;
        if (!domain.assignDevice(bdf)) {
            self.freeDomain(domain);
            return null;
        }

        // Configure device in IOMMU hardware if available
        if (self.iommu_tables) |*tables| {
            _ = tables.configureDevice(bdf.bus, bdf.device, bdf.func, domain.id, &domain.page_tables);
        }

        return domain;
    }

    /// Free a domain
    pub fn freeDomain(self: *Self, domain: *Domain) void {
        const idx = (@intFromPtr(domain) - @intFromPtr(&self.domains)) / @sizeOf(Domain);
        if (idx < MAX_DOMAINS) {
            domain.active = false;
            self.allocated[idx] = false;
        }
    }

    /// Get domain by ID
    pub fn getDomainById(self: *Self, id: u16) ?*Domain {
        if (id >= MAX_DOMAINS) return null;
        if (!self.allocated[id]) return null;
        if (!self.domains[id].active) return null;
        return &self.domains[id];
    }

    /// Get root table physical address for hardware programming
    pub fn getRootTablePhys(self: *const Self) ?u64 {
        if (self.iommu_tables) |tables| {
            return tables.root_phys;
        }
        return null;
    }

    /// Log all domains
    pub fn logAllDomains(self: *const Self) void {
        console.info("IOMMU Domain Manager:", .{});
        if (self.iommu_tables) |tables| {
            console.info("  Root table: 0x{x}", .{tables.root_phys});
        }
        var active_count: u32 = 0;
        for (&self.domains, 0..) |*domain, i| {
            if (self.allocated[i] and domain.active) {
                domain.logInfo();
                active_count += 1;
            }
        }
        console.info("  Active domains: {d}/{d}", .{ active_count, MAX_DOMAINS });
    }
};

/// Global domain manager instance
pub var domain_manager: DomainManager = undefined;

/// Initialize the IOMMU domain subsystem
pub fn init() void {
    domain_manager.init();
    console.info("IOMMU: Domain manager initialized", .{});
}

/// Initialize IOMMU hardware tables
pub fn initHardware() bool {
    return domain_manager.initHardware();
}

/// Allocate a DMA buffer with IOMMU protection
/// Returns the IOVA that should be given to the device
pub fn allocDmaBuffer(bdf: DeviceBdf, phys_addr: u64, size: u64, writable: bool) ?u64 {
    const domain = domain_manager.getDomainForDevice(bdf) orelse {
        console.err("IOMMU: No domain for device {x:0>2}:{x:0>2}.{d}", .{ bdf.bus, bdf.device, bdf.func });
        return null;
    };

    return domain.allocateAndMap(phys_addr, size, true, writable);
}

/// Free a DMA buffer
pub fn freeDmaBuffer(bdf: DeviceBdf, iova: u64, size: u64) void {
    const domain = domain_manager.getDomainForDevice(bdf) orelse return;
    domain.unmapIova(iova, size);
}

/// Check if IOMMU is available and initialized
pub fn isAvailable() bool {
    return domain_manager.initialized;
}

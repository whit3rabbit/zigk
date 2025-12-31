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
const builtin = @import("builtin");
const console = @import("console");
const pmm = @import("pmm");
const hal = @import("hal");
const acpi = @import("acpi");

const paging = hal.paging;
const iommu = hal.iommu;

/// Maximum number of RMRR regions to track
const MAX_RMRR_REGIONS: usize = 8;

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

// ============================================================================
// Simple IRQ-safe Spinlock (inline, no external dependencies)
// ============================================================================

/// Minimal spinlock for IOVA allocator - uses HAL primitives directly
const IommuSpinlock = struct {
    locked: std.atomic.Value(u32) = .{ .raw = 0 },

    const Held = struct {
        lock: *IommuSpinlock,
        irq_state: bool,

        pub fn release(self: Held) void {
            self.lock.locked.store(0, .release);
            if (self.irq_state) {
                hal.cpu.enableInterrupts();
            }
        }
    };

    pub fn acquire(self: *IommuSpinlock) Held {
        const irq_was_enabled = hal.cpu.interruptsEnabled();
        hal.cpu.disableInterrupts();

        while (true) {
            const prev = self.locked.cmpxchgWeak(0, 1, .acquire, .monotonic);
            if (prev == null) break;
            // Spin with pause hint
            switch (builtin.cpu.arch) {
                .x86_64 => asm volatile ("pause"),
                .aarch64 => asm volatile ("yield"),
                else => {},
            }
        }

        return .{ .lock = self, .irq_state = irq_was_enabled };
    }
};

/// Bitmap-based IOVA allocator with proper free support
/// Uses 64KB allocation granularity to keep bitmap size reasonable
/// Thread-safe with spinlock protection
///
/// Memory usage: ~2MB bitmap for 1TB IOVA range at 64KB granularity
/// Formula: (IOVA_SIZE / ALLOC_GRANULARITY) / 8 bytes
pub const IovaAllocator = struct {
    /// Bitmap: 1 = allocated, 0 = free
    /// Each bit represents ALLOC_GRANULARITY bytes (64KB)
    /// Allocated from PMM (physical pages mapped via HHDM)
    bitmap: ?[]u8,

    /// Physical address of bitmap pages (for deallocation)
    bitmap_phys: u64,

    /// Number of pages allocated for bitmap
    bitmap_pages: usize,

    /// Lock for thread-safety
    lock: IommuSpinlock,

    /// Statistics
    allocated_units: u64,
    total_units: u64,

    /// Hint for next allocation (first-fit with locality)
    search_hint: usize,

    /// Allocation granularity (64KB = 16 pages per unit)
    /// This keeps bitmap at ~2MB for 1TB range instead of 32MB
    const ALLOC_GRANULARITY: u64 = 64 * 1024; // 64KB
    const UNITS_PER_BYTE: usize = 8;

    const Self = @This();

    /// Create a new IOVA allocator
    /// Bitmap is lazily allocated on first use
    pub fn init() Self {
        return .{
            .bitmap = null,
            .bitmap_phys = 0,
            .bitmap_pages = 0,
            .lock = .{},
            .allocated_units = 0,
            .total_units = IOVA_SIZE / ALLOC_GRANULARITY,
            .search_hint = 0,
        };
    }

    /// Ensure bitmap is allocated using PMM
    fn ensureBitmap(self: *Self) bool {
        if (self.bitmap != null) return true;

        // Calculate bitmap size
        const bitmap_bytes: usize = @intCast((self.total_units + 7) / 8);
        const pages_needed = (bitmap_bytes + PAGE_SIZE - 1) / PAGE_SIZE;

        // Allocate zeroed pages from PMM
        const phys = pmm.allocZeroedPages(pages_needed) orelse {
            console.err("IOMMU: Failed to allocate IOVA bitmap ({d} pages)", .{pages_needed});
            return false;
        };

        // Convert to virtual address via HHDM (always succeeds for valid physical addresses)
        const virt_ptr = paging.physToVirt(phys);

        self.bitmap_phys = phys;
        self.bitmap_pages = pages_needed;
        self.bitmap = virt_ptr[0..bitmap_bytes];

        console.info("IOMMU: IOVA bitmap allocated ({d} pages, {d} KB)", .{
            pages_needed,
            bitmap_bytes / 1024,
        });
        return true;
    }

    /// Allocate a contiguous IOVA range
    /// Returns the starting IOVA address, or null if out of space
    pub fn allocate(self: *Self, size: u64) ?u64 {
        if (size == 0) return null;

        // Calculate units needed (round up)
        const units_needed = std.math.divCeil(u64, size, ALLOC_GRANULARITY) catch return null;
        if (units_needed == 0) return null;
        if (units_needed > self.total_units - self.allocated_units) return null;

        const held = self.lock.acquire();
        defer held.release();

        // Lazy bitmap allocation
        if (!self.ensureBitmap()) return null;
        const bitmap = self.bitmap.?;

        // First-fit search starting from hint
        const found = self.findContiguous(bitmap, units_needed) orelse {
            console.warn("IOMMU: IOVA space exhausted (fragmented)", .{});
            return null;
        };

        // Mark units as allocated
        self.markRange(bitmap, found, units_needed, true);
        self.allocated_units += units_needed;

        // Update hint for locality
        self.search_hint = found + @as(usize, @intCast(units_needed));
        if (self.search_hint >= self.total_units) {
            self.search_hint = 0;
        }

        return IOVA_BASE + @as(u64, @intCast(found)) * ALLOC_GRANULARITY;
    }

    /// Free an IOVA range
    pub fn free(self: *Self, iova: u64, size: u64) void {
        if (iova < IOVA_BASE or iova >= IOVA_LIMIT) return;
        if (size == 0) return;

        const units = std.math.divCeil(u64, size, ALLOC_GRANULARITY) catch return;
        const start_unit = (iova - IOVA_BASE) / ALLOC_GRANULARITY;

        const held = self.lock.acquire();
        defer held.release();

        if (self.bitmap) |bitmap| {
            self.markRange(bitmap, @intCast(start_unit), units, false);
            if (self.allocated_units >= units) {
                self.allocated_units -= units;
            }

            // Update hint for locality (prefer reusing recently freed space)
            if (@as(usize, @intCast(start_unit)) < self.search_hint) {
                self.search_hint = @intCast(start_unit);
            }
        }
    }

    /// Find contiguous free units using first-fit with wrap-around
    fn findContiguous(self: *Self, bitmap: []u8, count: u64) ?usize {
        const total: usize = @intCast(self.total_units);

        // Search from hint to end
        if (self.searchRange(bitmap, self.search_hint, total, count)) |found| {
            return found;
        }

        // Wrap around: search from 0 to hint
        if (self.search_hint > 0) {
            if (self.searchRange(bitmap, 0, self.search_hint, count)) |found| {
                return found;
            }
        }

        return null;
    }

    fn searchRange(self: *Self, bitmap: []u8, start: usize, end: usize, count: u64) ?usize {
        _ = self;
        var run_start: usize = start;
        var run_length: u64 = 0;

        var unit = start;
        while (unit < end) : (unit += 1) {
            if (isBitSet(bitmap, unit)) {
                // Allocated unit - reset run
                run_start = unit + 1;
                run_length = 0;
            } else {
                run_length += 1;
                if (run_length >= count) {
                    return run_start;
                }
            }
        }
        return null;
    }

    fn isBitSet(bitmap: []u8, unit: usize) bool {
        const byte_idx = unit / UNITS_PER_BYTE;
        if (byte_idx >= bitmap.len) return true; // Out of bounds = allocated
        const bit_idx: u3 = @truncate(unit % UNITS_PER_BYTE);
        return (bitmap[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
    }

    fn markRange(self: *Self, bitmap: []u8, start: usize, count: u64, allocated: bool) void {
        _ = self;
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            const unit = start + @as(usize, @intCast(i));
            const byte_idx = unit / UNITS_PER_BYTE;
            if (byte_idx >= bitmap.len) continue;
            const bit_idx: u3 = @truncate(unit % UNITS_PER_BYTE);
            if (allocated) {
                bitmap[byte_idx] |= (@as(u8, 1) << bit_idx);
            } else {
                bitmap[byte_idx] &= ~(@as(u8, 1) << bit_idx);
            }
        }
    }

    /// Get remaining IOVA space in bytes
    pub fn remaining(self: *const Self) u64 {
        return (self.total_units - self.allocated_units) * ALLOC_GRANULARITY;
    }

    /// Deinitialize and free bitmap pages
    pub fn deinit(self: *Self) void {
        if (self.bitmap != null and self.bitmap_pages > 0) {
            pmm.freePages(self.bitmap_phys, self.bitmap_pages);
            self.bitmap = null;
            self.bitmap_phys = 0;
            self.bitmap_pages = 0;
        }
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
            self.iova_alloc.free(iova, size);
            return null;
        };

        // SECURITY: Invalidate IOTLB after mapping changes
        // This ensures hardware sees updated page tables before DMA proceeds.
        // Without this, stale TLB entries could allow access to wrong memory.
        self.invalidateIotlb() catch |err| {
            console.err("IOMMU: IOTLB invalidation failed for domain {d}: {}", .{ self.id, err });
            // Roll back mapping on invalidation failure - DMA would be unsafe
            self.page_tables.unmapRange(iova, size);
            self.iova_alloc.free(iova, size);
            return null;
        };

        return iova;
    }

    /// Invalidate IOTLB for this domain across all VT-d units
    fn invalidateIotlb(self: *Self) !void {
        var i: u8 = 0;
        while (i < iommu.getUnitCount()) : (i += 1) {
            if (iommu.getUnit(i)) |unit| {
                try unit.invalidateIotlbDomain(self.id);
            }
        }
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

        // SECURITY: Invalidate IOTLB after unmapping
        // Prevents stale TLB entries from allowing access to freed pages
        self.invalidateIotlb() catch |err| {
            console.warn("IOMMU: IOTLB invalidation after unmap failed: {}", .{err});
            // Continue anyway - unmap is best effort, and pages are freed
        };
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

/// RMRR (Reserved Memory Region Reporting) entry
/// These regions must be identity-mapped and never used for general IOVA allocation
pub const RmrrRegion = struct {
    /// Physical base address of reserved region
    phys_base: u64,
    /// Physical limit address (inclusive) of reserved region
    phys_limit: u64,
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

    /// RMRR regions to protect (firmware-reserved memory)
    rmrr_regions: [MAX_RMRR_REGIONS]RmrrRegion,
    rmrr_count: u8,

    const Self = @This();

    /// Initialize the domain manager
    pub fn init(self: *Self) void {
        self.* = .{
            .domains = undefined,
            .allocated = [_]bool{false} ** MAX_DOMAINS,
            .next_id = 0,
            .iommu_tables = null,
            .initialized = false,
            .rmrr_regions = undefined,
            .rmrr_count = 0,
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

    /// Load RMRR regions from parsed DMAR information
    /// These regions are firmware-reserved and must not be used for DMA remapping
    pub fn loadRmrrRegions(self: *Self, dmar_info: *const acpi.DmarInfo) void {
        self.rmrr_count = 0;

        for (dmar_info.rmrr_entries[0..dmar_info.rmrr_count]) |rmrr| {
            if (self.rmrr_count >= MAX_RMRR_REGIONS) {
                console.warn("IOMMU: Too many RMRR regions, some will be unprotected", .{});
                break;
            }

            self.rmrr_regions[self.rmrr_count] = RmrrRegion{
                .phys_base = rmrr.region_base,
                .phys_limit = rmrr.region_limit,
            };
            self.rmrr_count += 1;

            console.info("IOMMU: Protected RMRR 0x{x}-0x{x} ({d}KB)", .{
                rmrr.region_base,
                rmrr.region_limit,
                (rmrr.region_limit - rmrr.region_base + 1) / 1024,
            });
        }
    }

    /// Check if a physical address range overlaps any RMRR region
    /// SECURITY: Prevents DMA buffers from being allocated in firmware-reserved memory
    pub fn overlapsRmrr(self: *const Self, phys_start: u64, size: u64) bool {
        const phys_end = std.math.add(u64, phys_start, size) catch return true;

        for (self.rmrr_regions[0..self.rmrr_count]) |rmrr| {
            // Check for overlap: !(end1 <= start2 || start1 > limit2)
            // Note: region_limit is inclusive
            if (!(phys_end <= rmrr.phys_base or phys_start > rmrr.phys_limit)) {
                return true;
            }
        }
        return false;
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

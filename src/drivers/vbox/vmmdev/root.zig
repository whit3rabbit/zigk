//! VirtualBox VMMDev PCI Driver
//!
//! Provides communication with VirtualBox host via the VMMDev device.
//! This is the foundation for VBox Guest Additions features including
//! shared folders (VBoxSF/HGCM).
//!
//! PCI Device: Vendor 0x80EE, Device 0xCAFE
//!
//! Usage:
//!   const vmmdev = @import("vmmdev");
//!   const device = vmmdev.initFromPci(pci_dev, pci_access) catch return;
//!   const client_id = device.hgcmConnect("VBoxSharedFolders") catch return;

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const pci = @import("pci");
const vmm = @import("vmm");
const pmm = @import("pmm");
const heap = @import("heap");
const sync = @import("sync");
const dma = @import("dma");
const iommu = @import("iommu");

pub const regs = @import("regs.zig");
pub const types = @import("types.zig");
pub const hgcm = @import("hgcm.zig");

// ============================================================================
// Error Types
// ============================================================================

pub const VmmDevError = error{
    NotVmmDev,
    InvalidBar,
    MappingFailed,
    AllocationFailed,
    RequestFailed,
    Timeout,
    HgcmConnectFailed,
    HgcmDisconnectFailed,
    HgcmCallFailed,
    InvalidParameter,
    ServiceNotFound,
};

// ============================================================================
// Global State
// ============================================================================

/// Global VMMDev instance (singleton)
var g_device: ?*VmmDevDevice = null;

/// Get the global device instance
pub fn getDevice() ?*VmmDevDevice {
    return g_device;
}

// ============================================================================
// Device Detection
// ============================================================================

/// Check if a PCI device is a VirtualBox VMMDev
pub fn isVmmDev(dev: *const pci.PciDevice) bool {
    return dev.vendor_id == regs.PCI_VENDOR_VBOX and
        dev.device_id == regs.PCI_DEVICE_VMMDEV;
}

// ============================================================================
// VMMDev Device
// ============================================================================

pub const VmmDevDevice = struct {
    /// MMIO register access
    mmio: hal.mmio_device.MmioDevice(regs.Reg),

    /// DMA buffer for requests (4KB aligned, physically contiguous)
    request_dma: dma.DmaBuffer,

    /// PCI device reference
    pci_dev: *const pci.PciDevice,

    /// BDF for IOMMU
    bdf: iommu.DeviceBdf,

    /// Lock for request submission
    lock: sync.Spinlock,

    /// Device capabilities
    capabilities: u32,

    /// Host version
    host_version: u32,

    /// Initialized flag
    initialized: bool,

    const Self = @This();

    // ========================================================================
    // Initialization
    // ========================================================================

    /// Initialize VMMDev from PCI device
    pub fn init(self: *Self, pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) VmmDevError!void {
        self.pci_dev = pci_dev;
        self.initialized = false;
        self.capabilities = 0;
        self.host_version = 0;
        self.lock = .{};

        // Set up BDF for IOMMU
        self.bdf = iommu.DeviceBdf{
            .bus = pci_dev.bus,
            .device = pci_dev.device,
            .func = pci_dev.func,
        };

        // Verify device type
        if (!isVmmDev(pci_dev)) {
            return error.NotVmmDev;
        }

        // Get ECAM access
        const ecam = switch (pci_access) {
            .ecam => |e| e,
            .legacy => {
                console.err("VMMDev: Legacy PCI access not supported", .{});
                return error.InvalidBar;
            },
        };

        // Enable bus mastering and memory space
        ecam.enableBusMaster(pci_dev.bus, pci_dev.device, pci_dev.func);
        ecam.enableMemorySpace(pci_dev.bus, pci_dev.device, pci_dev.func);

        // Get BAR0 (MMIO)
        const bar0 = pci_dev.bar[0];
        if (!bar0.isValid() or !bar0.is_mmio) {
            console.err("VMMDev: Invalid BAR0", .{});
            return error.InvalidBar;
        }

        // Map MMIO region
        const mmio_virt = vmm.mapMmio(bar0.base, bar0.size) catch {
            console.err("VMMDev: Failed to map MMIO", .{});
            return error.MappingFailed;
        };

        // Initialize MMIO device wrapper
        self.mmio = hal.mmio_device.MmioDevice(regs.Reg).init(mmio_virt, bar0.size);

        // Allocate DMA buffer for requests (4KB page-aligned)
        self.request_dma = dma.allocBuffer(self.bdf, 4096, false) catch {
            console.err("VMMDev: Failed to allocate DMA buffer", .{});
            return error.AllocationFailed;
        };

        // Zero-initialize DMA buffer (security: prevent info leaks)
        @memset(self.getRequestBuf(), 0);

        // Read host version
        self.host_version = self.mmio.read(.HOST_VERSION);

        // Query capabilities
        self.capabilities = self.mmio.read(.CAPS_QUERY);

        // Report guest info to host
        try self.reportGuestInfo();

        // Get and log VMMDev version
        _ = self.getVersion() catch |err| {
            console.warn("VMMDev: Version query failed: {}", .{err});
            return;
        };

        self.initialized = true;
        g_device = self;

        console.info("VMMDev: Initialized (host_ver=0x{x}, caps=0x{x})", .{
            self.host_version,
            self.capabilities,
        });
    }

    // ========================================================================
    // Buffer Access
    // ========================================================================

    fn getRequestBuf(self: *Self) []u8 {
        const ptr = self.request_dma.getVirt();
        return ptr[0..@intCast(self.request_dma.size)];
    }

    fn getRequestPhys(self: *Self) u64 {
        return self.request_dma.phys_addr;
    }

    // ========================================================================
    // Request Submission
    // ========================================================================

    /// Submit a request to VMMDev and wait for completion
    fn submitRequest(self: *Self, request: anytype) VmmDevError!void {
        const held = self.lock.acquire();
        defer held.release();

        const req_buf = self.getRequestBuf();
        const req_phys = self.getRequestPhys();
        const req_size = @sizeOf(@TypeOf(request));

        // Zero-init buffer before copying (security: DMA hygiene)
        @memset(req_buf[0..req_size], 0);

        // Copy request to DMA buffer
        const req_bytes: [*]const u8 = @ptrCast(&request);
        @memcpy(req_buf[0..req_size], req_bytes[0..req_size]);

        // Memory barrier before submission
        asm volatile ("" ::: .{ .memory = true });

        // Submit request by writing physical address to REQUEST register
        self.mmio.write(.REQUEST, @truncate(req_phys));

        // Memory barrier after submission
        asm volatile ("" ::: .{ .memory = true });

        // Poll for completion (VMMDev is synchronous)
        // The device writes the result directly to the request buffer
        var timeout: u32 = 100000;
        while (timeout > 0) : (timeout -= 1) {
            // Read back the return code from the buffer
            const hdr: *types.RequestHeader = @ptrCast(@alignCast(req_buf.ptr));
            if (hdr.rc != 0 or timeout < 99900) {
                // Either got a result or initial check passed
                break;
            }
            hal.cpu.pause();
        }

        if (timeout == 0) {
            return error.Timeout;
        }

        // Check return code
        const hdr: *types.RequestHeader = @ptrCast(@alignCast(req_buf.ptr));
        if (!hdr.getReturnCode().isSuccess() and hdr.rc != 0) {
            console.warn("VMMDev: Request failed with rc={d}", .{hdr.rc});
            return error.RequestFailed;
        }
    }

    /// Submit a request and get back the response buffer
    fn submitRequestWithResponse(self: *Self, request: anytype, comptime ResponseType: type) VmmDevError!*ResponseType {
        const held = self.lock.acquire();
        defer held.release();

        const req_buf = self.getRequestBuf();
        const req_phys = self.getRequestPhys();
        const req_size = @sizeOf(@TypeOf(request));

        // Zero-init buffer before copying (security: DMA hygiene)
        @memset(req_buf[0..@max(req_size, @sizeOf(ResponseType))], 0);

        // Copy request to DMA buffer
        const req_bytes: [*]const u8 = @ptrCast(&request);
        @memcpy(req_buf[0..req_size], req_bytes[0..req_size]);

        // Memory barrier before submission
        asm volatile ("" ::: .{ .memory = true });

        // Submit request
        self.mmio.write(.REQUEST, @truncate(req_phys));

        // Memory barrier after submission
        asm volatile ("" ::: .{ .memory = true });

        // Poll for completion
        var timeout: u32 = 100000;
        while (timeout > 0) : (timeout -= 1) {
            const hdr: *types.RequestHeader = @ptrCast(@alignCast(req_buf.ptr));
            // VMMDev sets rc to non-zero when complete (success or error)
            // For GetVersion, success returns rc=0, so check if response fields are filled
            if (hdr.rc != 0) break;

            // For some requests, rc stays 0 on success - check if data is filled
            if (@TypeOf(request) == types.GetVersionRequest) {
                const resp: *types.GetVersionRequest = @ptrCast(@alignCast(req_buf.ptr));
                if (resp.major != 0) break;
            }

            if (timeout < 99900) break; // Give it some time
            hal.cpu.pause();
        }

        if (timeout == 0) {
            return error.Timeout;
        }

        // Cast response
        return @ptrCast(@alignCast(req_buf.ptr));
    }

    // ========================================================================
    // Basic Operations
    // ========================================================================

    /// Report guest information to host
    fn reportGuestInfo(self: *Self) VmmDevError!void {
        // Report as Linux 64-bit
        const req = types.ReportGuestInfoRequest.init(
            types.ReportGuestInfoRequest.OS_LINUX26 | types.ReportGuestInfoRequest.OS_64BIT,
        );
        try self.submitRequest(req);
    }

    /// Get VMMDev version from host
    pub fn getVersion(self: *Self) VmmDevError!struct { major: u32, minor: u32, build: u32 } {
        const req = types.GetVersionRequest.init();
        const resp = try self.submitRequestWithResponse(req, types.GetVersionRequest);

        console.info("VMMDev: Host version {d}.{d}.{d}", .{ resp.major, resp.minor, resp.build });

        return .{
            .major = resp.major,
            .minor = resp.minor,
            .build = resp.build,
        };
    }

    /// Check if HGCM is available
    pub fn hasHgcm(self: *Self) bool {
        return (self.capabilities & regs.Caps.HGCM) != 0;
    }

    // ========================================================================
    // HGCM Operations
    // ========================================================================

    /// Connect to an HGCM service by name
    pub fn hgcmConnect(self: *Self, service_name: []const u8) VmmDevError!u32 {
        if (!self.hasHgcm()) {
            console.err("VMMDev: HGCM not available", .{});
            return error.ServiceNotFound;
        }

        const req = hgcm.HgcmConnectRequest.init(service_name);
        const resp = try self.submitRequestWithResponse(req, hgcm.HgcmConnectRequest);

        if (!resp.header.getReturnCode().isSuccess()) {
            console.err("VMMDev: HGCM connect failed: rc={d}", .{resp.header.rc});
            return error.HgcmConnectFailed;
        }

        console.info("VMMDev: Connected to '{s}' (client_id={d})", .{ service_name, resp.client_id });
        return resp.client_id;
    }

    /// Disconnect from an HGCM service
    pub fn hgcmDisconnect(self: *Self, client_id: u32) VmmDevError!void {
        const req = hgcm.HgcmDisconnectRequest.init(client_id);
        try self.submitRequest(req);
    }

    /// Execute an HGCM call
    /// Caller provides a buffer with HgcmCallHeader + parameters already formatted
    pub fn hgcmCall(self: *Self, call_buf: []u8) VmmDevError!void {
        if (call_buf.len < hgcm.HgcmCallHeader.SIZE) {
            return error.InvalidParameter;
        }

        const held = self.lock.acquire();
        defer held.release();

        const req_buf = self.getRequestBuf();
        const req_phys = self.getRequestPhys();

        // Validate size fits in DMA buffer
        if (call_buf.len > req_buf.len) {
            return error.InvalidParameter;
        }

        // Zero-init and copy call buffer
        @memset(req_buf[0..call_buf.len], 0);
        @memcpy(req_buf[0..call_buf.len], call_buf);

        // Memory barrier
        asm volatile ("" ::: .{ .memory = true });

        // Submit
        self.mmio.write(.REQUEST, @truncate(req_phys));

        // Memory barrier
        asm volatile ("" ::: .{ .memory = true });

        // Poll for completion
        var timeout: u32 = 500000; // Longer timeout for HGCM calls
        while (timeout > 0) : (timeout -= 1) {
            const hdr: *types.RequestHeader = @ptrCast(@alignCast(req_buf.ptr));
            if (hdr.rc != 0) break;
            if (timeout < 499900) break;
            hal.cpu.pause();
        }

        if (timeout == 0) {
            return error.Timeout;
        }

        // Copy response back
        @memcpy(call_buf, req_buf[0..call_buf.len]);

        // Check result
        const hdr: *types.RequestHeader = @ptrCast(@alignCast(call_buf.ptr));
        if (hdr.rc < 0) {
            return error.HgcmCallFailed;
        }
    }

    /// Get the DMA buffer physical address for parameter buffers
    /// The caller can use offsets into this buffer for HGCM parameter pointers
    pub fn getDmaBufferPhys(self: *Self) u64 {
        return self.request_dma.phys_addr;
    }

    /// Get the DMA buffer virtual address
    pub fn getDmaBufferVirt(self: *Self) []u8 {
        return self.getRequestBuf();
    }
};

// ============================================================================
// Public Initialization Function
// ============================================================================

/// Initialize VMMDev from PCI device
pub fn initFromPci(pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) VmmDevError!*VmmDevDevice {
    // Allocate device structure
    const device = heap.allocator().create(VmmDevDevice) catch {
        return error.AllocationFailed;
    };

    // Initialize
    try device.init(pci_dev, pci_access);

    return device;
}

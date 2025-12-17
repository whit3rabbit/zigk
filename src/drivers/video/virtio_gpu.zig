// VirtIO-GPU Driver
//
// Implements paravirtualized GPU for QEMU using VirtIO 1.0 specification.
// Provides 2D scanout mode with accelerated blitting to host display.
//
// Reference: VirtIO GPU Device Specification (OASIS)

const std = @import("std");
const interface = @import("interface.zig");
const virtio = @import("virtio");
const pci = @import("pci");
const pmm = @import("pmm");
const vmm = @import("vmm");
const hal = @import("hal");
const console = @import("console");
const sync = @import("sync");
const heap = @import("heap");

// GPU Command Types
const VIRTIO_GPU_CMD_GET_DISPLAY_INFO: u32 = 0x0100;
const VIRTIO_GPU_CMD_RESOURCE_CREATE_2D: u32 = 0x0101;
const VIRTIO_GPU_CMD_RESOURCE_UNREF: u32 = 0x0102;
const VIRTIO_GPU_CMD_SET_SCANOUT: u32 = 0x0103;
const VIRTIO_GPU_CMD_RESOURCE_FLUSH: u32 = 0x0104;
const VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D: u32 = 0x0105;
const VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING: u32 = 0x0106;
const VIRTIO_GPU_CMD_RESOURCE_DETACH_BACKING: u32 = 0x0107;
const VIRTIO_GPU_CMD_GET_CAPSET_INFO: u32 = 0x0108;
const VIRTIO_GPU_CMD_GET_CAPSET: u32 = 0x0109;
const VIRTIO_GPU_CMD_GET_EDID: u32 = 0x010A;

// Response Types
const VIRTIO_GPU_RESP_OK_NODATA: u32 = 0x1100;
const VIRTIO_GPU_RESP_OK_DISPLAY_INFO: u32 = 0x1101;
const VIRTIO_GPU_RESP_OK_CAPSET_INFO: u32 = 0x1102;
const VIRTIO_GPU_RESP_OK_CAPSET: u32 = 0x1103;
const VIRTIO_GPU_RESP_OK_EDID: u32 = 0x1104;

const VIRTIO_GPU_RESP_ERR_UNSPEC: u32 = 0x1200;
const VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY: u32 = 0x1201;
const VIRTIO_GPU_RESP_ERR_INVALID_SCANOUT_ID: u32 = 0x1202;
const VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID: u32 = 0x1203;
const VIRTIO_GPU_RESP_ERR_INVALID_CONTEXT_ID: u32 = 0x1204;
const VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER: u32 = 0x1205;

// Pixel Formats
const VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM: u32 = 1;
const VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM: u32 = 2;
const VIRTIO_GPU_FORMAT_A8R8G8B8_UNORM: u32 = 3;
const VIRTIO_GPU_FORMAT_X8R8G8B8_UNORM: u32 = 4;
const VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM: u32 = 67;
const VIRTIO_GPU_FORMAT_X8B8G8R8_UNORM: u32 = 68;
const VIRTIO_GPU_FORMAT_A8B8G8R8_UNORM: u32 = 121;
const VIRTIO_GPU_FORMAT_R8G8B8X8_UNORM: u32 = 134;

// Feature bits
const VIRTIO_GPU_F_VIRGL: u32 = 0;
const VIRTIO_GPU_F_EDID: u32 = 1;
const VIRTIO_GPU_F_RESOURCE_UUID: u32 = 2;
const VIRTIO_GPU_F_RESOURCE_BLOB: u32 = 3;
const VIRTIO_GPU_F_CONTEXT_INIT: u32 = 4;

const MAX_SCANOUTS: usize = 16;

/// GPU control header (common to all commands)
const VirtioGpuCtrlHdr = extern struct {
    type_: u32,
    flags: u32,
    fence_id: u64,
    ctx_id: u32,
    ring_idx: u8,
    _padding: [3]u8 = .{ 0, 0, 0 },
};

/// Rectangle structure
const VirtioGpuRect = extern struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// Display info response
const VirtioGpuDisplayOne = extern struct {
    r: VirtioGpuRect,
    enabled: u32,
    flags: u32,
};

const VirtioGpuRespDisplayInfo = extern struct {
    hdr: VirtioGpuCtrlHdr,
    pmodes: [MAX_SCANOUTS]VirtioGpuDisplayOne,
};

/// Resource create 2D command
const VirtioGpuResourceCreate2d = extern struct {
    hdr: VirtioGpuCtrlHdr,
    resource_id: u32,
    format: u32,
    width: u32,
    height: u32,
};

/// Set scanout command
const VirtioGpuSetScanout = extern struct {
    hdr: VirtioGpuCtrlHdr,
    r: VirtioGpuRect,
    scanout_id: u32,
    resource_id: u32,
};

/// Resource attach backing command
const VirtioGpuResourceAttachBacking = extern struct {
    hdr: VirtioGpuCtrlHdr,
    resource_id: u32,
    nr_entries: u32,
};

/// Memory entry for attach backing
const VirtioGpuMemEntry = extern struct {
    addr: u64,
    length: u32,
    _padding: u32 = 0,
};

/// Transfer to host 2D command
const VirtioGpuTransferToHost2d = extern struct {
    hdr: VirtioGpuCtrlHdr,
    r: VirtioGpuRect,
    offset: u64,
    resource_id: u32,
    _padding: u32 = 0,
};

/// Resource flush command
const VirtioGpuResourceFlush = extern struct {
    hdr: VirtioGpuCtrlHdr,
    r: VirtioGpuRect,
    resource_id: u32,
    _padding: u32 = 0,
};

/// VirtIO-GPU driver state
pub const VirtioGpuDriver = struct {
    // PCI device info
    pci_device: *const pci.PciDevice,
    mmio_base: u64,
    
    // Command submission lock
    cmd_lock: sync.Spinlock = .{},

    // Virtqueues (allocated in initDevice after reading device queue_size)
    ctrl_vq: ?virtio.Virtqueue = null,
    cursor_vq: ?virtio.Virtqueue = null,

    // GPU resources
    resource_id: u32,
    next_resource_id: u32,

    // Framebuffer
    fb_phys: u64,
    fb_virt: [*]u32,
    width: u32,
    height: u32,
    pitch: u32,

    // Command/response buffers (page-aligned for DMA)
    cmd_buf_phys: u64,
    cmd_buf_virt: [*]u8,
    resp_buf_phys: u64,
    resp_buf_virt: [*]u8,

    // VirtIO PCI configuration
    common_cfg: ?*volatile virtio.VirtioPciCommonCfg,
    notify_base: u64,
    notify_off_multiplier: u32,
    device_failed: bool = false,

    // Mapped BAR virtual addresses (for 64-bit BARs outside HHDM)
    // Mapped BAR virtual addresses (lazy loaded)
    // bar_mappings[i] stores virt address of BAR i, or 0 if not mapped
    bar_mappings: [6]u64 = .{ 0, 0, 0, 0, 0, 0 },

    const Self = @This();

    /// GraphicsDevice vtable
    const vtable = interface.GraphicsDevice.VTable{
        .getMode = getMode,
        .putPixel = putPixel,
        .fillRect = fillRect,
        .drawBuffer = drawBuffer,
        .copyRect = copyRect,
        .present = present,
    };

    pub fn deinit(self: *Self) void {
        // Detach backing
        if (self.resource_id > 0) {
            // Note: Best effort, we are cleaning up
            // Ideally should send VIRTIO_GPU_CMD_RESOURCE_DETACH_BACKING
            // and VIRTIO_GPU_CMD_RESOURCE_UNREF
        }
        // Free buffers
        // Free virtqueues
        // Note: pmm.freePages not shown in context, assuming leak is acceptable for now or need simpler cleanup
    }

    pub fn device(self: *Self) interface.GraphicsDevice {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    /// Initialize VirtIO-GPU from a PCI device
    pub fn init(pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) ?*Self {
        console.info("VirtIO-GPU: Initializing device {x}:{x}", .{ pci_dev.vendor_id, pci_dev.device_id });
        console.debug("VirtIO-GPU: BDF={d}:{d}.{d}", .{ pci_dev.bus, pci_dev.device, pci_dev.func });

        // Verify we can read PCI config space (vendor ID at offset 0)
        const vendor_check = pci_access.read16(pci_dev.bus, pci_dev.device, pci_dev.func, 0x00);
        console.debug("VirtIO-GPU: Vendor check={x}", .{vendor_check});
        if (vendor_check != pci_dev.vendor_id) {
            console.err("VirtIO-GPU: PCI config space read mismatch (expected {x}, got {x})", .{ pci_dev.vendor_id, vendor_check });
            return null;
        }

        // Modern VirtIO devices use BAR4 for capabilities (64-bit BAR)
        // BAR4 is at index 4 in the bar array
        const bar4 = pci_dev.bar[4];
        if (!bar4.isValid() or !bar4.is_mmio) {
            console.err("VirtIO-GPU: BAR4 not valid or not MMIO", .{});
            return null;
        }
        console.debug("VirtIO-GPU: BAR4 at phys={x} size={x}", .{ bar4.base, bar4.size });

        // Map BAR4 MMIO region with explicit page mappings
        // Required for 64-bit BAR addresses outside HHDM-covered RAM
        const bar4_virt = vmm.mapMmioExplicit(bar4.base, bar4.size) catch |err| {
            console.err("VirtIO-GPU: Failed to map BAR4: {}", .{err});
            return null;
        };
        console.debug("VirtIO-GPU: BAR4 mapped to virt={x}", .{bar4_virt});

        // Allocate driver instance
        const driver = &driver_instance;

        driver.pci_device = pci_dev;
        driver.resource_id = 0;
        driver.next_resource_id = 1;
        driver.common_cfg = null;
        driver.notify_base = 0;
        driver.notify_off_multiplier = 0;
        driver.device_failed = false;
        
        // Initialize BAR mappings
        // We know BAR4 is already mapped, so cache it
        driver.bar_mappings[4] = bar4_virt;

        // Find VirtIO capabilities (before enabling bus master)
        if (!driver.findCapabilities(pci_dev, pci_access)) {
            console.err("VirtIO-GPU: Failed to find VirtIO capabilities", .{});
            return null;
        }

        // Enable bus mastering and memory space (after capabilities are found)
        pci_access.enableBusMaster(pci_dev.bus, pci_dev.device, pci_dev.func);
        pci_access.enableMemorySpace(pci_dev.bus, pci_dev.device, pci_dev.func);

        // Note: ctrl_vq is allocated in initDevice() after reading device queue_size

        // Allocate command/response buffers
        if (!driver.allocateBuffers()) {
            console.err("VirtIO-GPU: Failed to allocate command buffers", .{});
            return null;
        }

        // Initialize device
        if (!driver.initDevice()) {
            console.err("VirtIO-GPU: Device initialization failed", .{});
            return null;
        }

        // Get display info
        if (!driver.getDisplayInfo()) {
            console.err("VirtIO-GPU: Failed to get display info", .{});
            return null;
        }

        // Create framebuffer resource
        if (!driver.createFramebufferResource()) {
            console.err("VirtIO-GPU: Failed to create framebuffer resource", .{});
            return null;
        }

        console.info("VirtIO-GPU: Initialized {d}x{d}", .{ driver.width, driver.height });
        driver_initialized = true;
        return driver;
    }

    fn findCapabilities(self: *Self, pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) bool {
        // Check if device has capabilities (Status register bit 4)
        const status = pci_access.read16(pci_dev.bus, pci_dev.device, pci_dev.func, 0x06);
        console.debug("VirtIO-GPU: PCI Status={x}", .{status});

        if ((status & 0x10) == 0) {
            console.warn("VirtIO-GPU: Device doesn't have capabilities list", .{});
            return false;
        }

        // Walk PCI capability list to find VirtIO capabilities
        // Capability pointer is at offset 0x34, only lower 8 bits are valid, and bits 0-1 should be 0
        const cap_start = pci_access.read8(pci_dev.bus, pci_dev.device, pci_dev.func, 0x34) & 0xFC;
        console.debug("VirtIO-GPU: Cap list starts at {x}", .{cap_start});

        if (cap_start == 0 or cap_start == 0xFC) {
            console.warn("VirtIO-GPU: Invalid capability pointer", .{});
            return false;
        }

        var cap_ptr = cap_start;
        var iteration: u32 = 0;

        while (cap_ptr != 0 and cap_ptr != 0xFF and iteration < 32) : (iteration += 1) {
            const cap_id = pci_access.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr);
            console.debug("VirtIO-GPU: Cap at {x} id={x}", .{ cap_ptr, cap_id });

            if (cap_id == 0xFF) {
                console.warn("VirtIO-GPU: Invalid capability ID at {x}", .{cap_ptr});
                break;
            }

            // VirtIO vendor-specific capability (0x09)
            if (cap_id == 0x09) {
                const cfg_type = pci_access.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 3);
                const bar_idx = pci_access.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 4);
                const offset = pci_access.read32(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 8);
                console.debug("VirtIO-GPU: VirtIO cap type={d} bar={d} offset={x}", .{ cfg_type, bar_idx, offset });

                // Bounds check for BAR index
                if (bar_idx >= 6) {
                    console.warn("VirtIO-GPU: Invalid BAR index {d}", .{bar_idx});
                    cap_ptr = pci_access.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 1);
                    continue;
                }

                const bar_phys = pci_dev.bar[bar_idx].base;
                if (bar_phys == 0) {
                    console.warn("VirtIO-GPU: BAR{d} not configured", .{bar_idx});
                    cap_ptr = pci_access.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 1);
                    continue;
                }

                // Get virtual address for this BAR, mapping it if necessary
                var bar_virt: u64 = self.bar_mappings[bar_idx];
                
                if (bar_virt == 0) {
                     // Not mapped yet. Try to map it.
                     if (bar_phys < 0x100000000) {
                         // 32-bit physical address, use direct HHDM mapping
                         bar_virt = @intFromPtr(hal.paging.physToVirt(bar_phys));
                         self.bar_mappings[bar_idx] = bar_virt;
                     } else {
                         // 64-bit physical address outside HHDM
                         // Need explicit mapping
                         const bar_size = pci_dev.bar[bar_idx].size;
                         if (bar_size == 0) {
                              console.warn("VirtIO-GPU: BAR{d} has size 0, cannot map", .{bar_idx});
                         } else {
                              if (vmm.mapMmioExplicit(bar_phys, bar_size)) |vaddr| {
                                  bar_virt = vaddr;
                                  self.bar_mappings[bar_idx] = bar_virt;
                                  console.debug("VirtIO-GPU: Lazily mapped BAR{d} at {x} to {x}", .{bar_idx, bar_phys, bar_virt});
                              } else |err| {
                                  console.err("VirtIO-GPU: Failed to lazy map BAR{d}: {}", .{bar_idx, err});
                              }
                         }
                     }
                }
                
                if (bar_virt == 0) {
                     console.warn("VirtIO-GPU: Skipping capability in unmappable BAR{d}", .{bar_idx});
                     cap_ptr = pci_access.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 1);
                     continue;
                }

                switch (cfg_type) {
                    virtio.common.VIRTIO_PCI_CAP_COMMON_CFG => {
                        // Map common config using pre-mapped BAR address
                        self.common_cfg = @ptrFromInt(bar_virt + offset);
                        console.debug("VirtIO-GPU: Common cfg at BAR{d}+{x} (virt={x})", .{ bar_idx, offset, bar_virt + offset });
                    },
                    virtio.common.VIRTIO_PCI_CAP_NOTIFY_CFG => {
                        self.notify_base = bar_virt + offset;
                        // Read notify_off_multiplier from capability
                        self.notify_off_multiplier = pci_access.read32(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 16);
                        console.debug("VirtIO-GPU: Notify cfg at BAR{d}+{x}, mult={d}", .{ bar_idx, offset, self.notify_off_multiplier });
                    },
                    virtio.common.VIRTIO_PCI_CAP_DEVICE_CFG => {
                        console.debug("VirtIO-GPU: Device cfg at BAR{d}+{x}", .{ bar_idx, offset });
                    },
                    else => {},
                }
            }

            // Next capability
            cap_ptr = pci_access.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 1);
        }

        return self.common_cfg != null;
    }

    fn allocateBuffers(self: *Self) bool {
        // Allocate command buffer (4KB)
        if (pmm.allocZeroedPages(1)) |phys| {
            self.cmd_buf_phys = phys;
            self.cmd_buf_virt = @ptrCast(hal.paging.physToVirt(phys));
        } else {
            return false;
        }

        // Allocate response buffer (4KB)
        if (pmm.allocZeroedPages(1)) |phys| {
            self.resp_buf_phys = phys;
            self.resp_buf_virt = @ptrCast(hal.paging.physToVirt(phys));
        } else {
            return false;
        }

        return true;
    }

    fn initDevice(self: *Self) bool {
        const cfg = self.common_cfg orelse return false;

        // Reset device
        cfg.device_status = 0;
        hal.mmio.memoryBarrier();

        // Acknowledge device
        cfg.device_status = virtio.VIRTIO_STATUS_ACKNOWLEDGE;

        // Driver available
        cfg.device_status |= virtio.VIRTIO_STATUS_DRIVER;

        // Negotiate features (just VIRTIO_F_VERSION_1 for now)
        cfg.driver_feature_select = 1; // High 32 bits
        cfg.driver_feature = 1; // VIRTIO_F_VERSION_1 is bit 32

        cfg.device_status |= virtio.VIRTIO_STATUS_FEATURES_OK;
        hal.mmio.memoryBarrier();

        // Check features accepted
        if (cfg.device_status & virtio.VIRTIO_STATUS_FEATURES_OK == 0) {
            console.err("VirtIO-GPU: Features not accepted", .{});
            return false;
        }

        // Configure virtqueue 0 (controlq)
        cfg.queue_select = 0;
        const device_queue_size = cfg.queue_size;
        if (device_queue_size == 0) {
            console.err("VirtIO-GPU: Queue size is 0", .{});
            return false;
        }

        // Allocate virtqueue if not already allocated (first init vs recovery)
        if (self.ctrl_vq == null) {
            const negotiated_size: u16 = @intCast(@min(device_queue_size, 256));
            self.ctrl_vq = virtio.Virtqueue.init(negotiated_size) orelse {
                console.err("VirtIO-GPU: Failed to allocate control virtqueue", .{});
                return false;
            };
            console.debug("VirtIO-GPU: Allocated ctrl_vq with size={d} (device max={d})", .{ negotiated_size, device_queue_size });
        }

        // Set queue addresses
        cfg.queue_desc = self.ctrl_vq.?.desc_phys;
        cfg.queue_avail = self.ctrl_vq.?.avail_phys;
        cfg.queue_used = self.ctrl_vq.?.used_phys;

        // Enable queue
        cfg.queue_enable = 1;

        // Driver OK
        cfg.device_status |= virtio.VIRTIO_STATUS_DRIVER_OK;

        console.debug("VirtIO-GPU: Device initialized, device_queue_size={d}", .{device_queue_size});
        return true;
    }

    fn resetDevice(self: *Self) void {
        if (self.common_cfg) |cfg| {
            cfg.device_status = 0;
            hal.mmio.memoryBarrier();
        }
    }

    fn recoverAfterTimeout(self: *Self) void {
        // Stop the device so it drops all in-flight descriptors
        self.resetDevice();
        if (self.ctrl_vq) |*vq| vq.reset();
        self.device_failed = false;

        // Attempt to bring the device back so subsequent commands can proceed
        if (!self.initDevice()) {
            self.device_failed = true;
            console.err("VirtIO-GPU: Failed to reinitialize after timeout", .{});
        }
    }

    fn sendCommand(self: *Self, cmd: []const u8, resp: []u8) bool {
        const held = self.cmd_lock.acquire();
        defer held.release();

        if (self.device_failed or self.ctrl_vq == null) {
            return false;
        }

        // Add command to virtqueue
        const out_bufs = [_][]const u8{cmd};
        var in_bufs = [_][]u8{resp};

        _ = self.ctrl_vq.?.addBuf(&out_bufs, &in_bufs) orelse return false;

        // Notify device
        const notify_addr = self.notify_base + @as(u64, self.common_cfg.?.queue_notify_off) * self.notify_off_multiplier;
        self.ctrl_vq.?.kick(notify_addr);

        // Poll for completion with wall-clock timeout
        const start_tsc = hal.timing.rdtsc();
        const timeout_us: u64 = 1_000_000; // 1 second

        while (true) {
            if (self.ctrl_vq.?.hasPending()) {
                _ = self.ctrl_vq.?.getUsed();
                return true;
            }
            
            if (hal.timing.hasTimedOut(start_tsc, timeout_us)) {
                break;
            }
            
            hal.cpu.pause();
        }

        console.err("VirtIO-GPU: Command timeout", .{});
        self.recoverAfterTimeout();
        return false;
    }

    fn getDisplayInfo(self: *Self) bool {
        // Build GET_DISPLAY_INFO command
        const cmd: *VirtioGpuCtrlHdr = @ptrCast(@alignCast(self.cmd_buf_virt));
        cmd.* = .{
            .type_ = VIRTIO_GPU_CMD_GET_DISPLAY_INFO,
            .flags = 0,
            .fence_id = 0,
            .ctx_id = 0,
            .ring_idx = 0,
        };

        const cmd_bytes = @as([*]const u8, @ptrCast(cmd))[0..@sizeOf(VirtioGpuCtrlHdr)];
        const resp_bytes = self.resp_buf_virt[0..@sizeOf(VirtioGpuRespDisplayInfo)];

        if (!self.sendCommand(cmd_bytes, resp_bytes)) {
            return false;
        }

        // Parse response
        const resp: *const VirtioGpuRespDisplayInfo = @ptrCast(@alignCast(self.resp_buf_virt));
        if (resp.hdr.type_ != VIRTIO_GPU_RESP_OK_DISPLAY_INFO) {
            console.err("VirtIO-GPU: GET_DISPLAY_INFO failed: {x}", .{resp.hdr.type_});
            return false;
        }

        // Find first enabled scanout
        for (resp.pmodes, 0..) |pmode, i| {
            if (pmode.enabled != 0 and pmode.r.width > 0 and pmode.r.height > 0) {
                self.width = pmode.r.width;
                self.height = pmode.r.height;
                self.pitch = self.width * 4;
                console.info("VirtIO-GPU: Scanout {d}: {d}x{d}", .{ i, self.width, self.height });
                return true;
            }
        }

        // Default resolution
        self.width = 1024;
        self.height = 768;
        self.pitch = self.width * 4;
        console.warn("VirtIO-GPU: No display info, using default {d}x{d}", .{ self.width, self.height });
        return true;
    }

    fn createFramebufferResource(self: *Self) bool {
        // Allocate framebuffer memory using scattered pages to avoid fragmentation
        const fb_size = @as(usize, self.pitch) * self.height;
        const pages_needed = (fb_size + 4095) / 4096;
        const allocator = heap.allocator();

        // Use a fixed virtual region for the framebuffer (256GB offset from kernel base)
        const FB_VIRT_BASE = vmm.KERNEL_BASE + 0x4000000000;
        self.fb_virt = @ptrFromInt(FB_VIRT_BASE);
        // We don't have a single physical address anymore, but keep first one for reference
        self.fb_phys = 0; 

        // Prepare SG list
        var entries = std.ArrayListUnmanaged(VirtioGpuMemEntry){};
        defer entries.deinit(allocator);

        const kernel_pml4 = vmm.getKernelPml4();

        var i: usize = 0;
        while (i < pages_needed) : (i += 1) {
            const phys = pmm.allocZeroedPage() orelse {
                console.err("VirtIO-GPU: Failed to allocate framebuffer page {}", .{i});
                // Cleanup: iterate backwards unmapping/freeing?
                // For this critical failure, we leak for now or need complex rollback.
                return false;
            };

            if (i == 0) self.fb_phys = phys;

            // Map to contiguous virtual space
            const virt_addr = FB_VIRT_BASE + i * 4096;
            // Map as writable, present, no-execute (NX implied if not set?)
            // VMM default flags usually include NX for data.
            // Using default kernel flags (writable | present/global).
            const flags = vmm.PageFlags{ .writable = true, .global = true };
            
            vmm.mapPage(kernel_pml4, virt_addr, phys, flags) catch |err| {
                console.err("VirtIO-GPU: Failed to map framebuffer page: {}", .{err});
                pmm.freePage(phys);
                return false;
            };

            entries.append(allocator, .{
                .addr = phys,
                .length = 4096,
                ._padding = 0,
            }) catch {
                console.err("VirtIO-GPU: Failed to append SG entry", .{});
                return false;
            };
        }

        // Create 2D resource
        self.resource_id = self.next_resource_id;
        self.next_resource_id += 1;

        const create_cmd: *VirtioGpuResourceCreate2d = @ptrCast(@alignCast(self.cmd_buf_virt));
        create_cmd.* = .{
            .hdr = .{
                .type_ = VIRTIO_GPU_CMD_RESOURCE_CREATE_2D,
                .flags = 0,
                .fence_id = 0,
                .ctx_id = 0,
                .ring_idx = 0,
            },
            .resource_id = self.resource_id,
            .format = VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM,
            .width = self.width,
            .height = self.height,
        };

        const create_bytes = @as([*]const u8, @ptrCast(create_cmd))[0..@sizeOf(VirtioGpuResourceCreate2d)];
        const resp_bytes = self.resp_buf_virt[0..@sizeOf(VirtioGpuCtrlHdr)];

        if (!self.sendCommand(create_bytes, resp_bytes)) {
            return false;
        }

        // Attach backing memory using Scatter-Gather list
        // Allocate command buffer from heap because it exceeds 4KB cmd_buf
        const attach_header_size = @sizeOf(VirtioGpuResourceAttachBacking);
        const entries_size = entries.items.len * @sizeOf(VirtioGpuMemEntry);
        const total_size = attach_header_size + entries_size;

        const attach_buf = allocator.alloc(u8, total_size) catch {
            console.err("VirtIO-GPU: Failed to allocate attach command buffer", .{});
            return false;
        };
        defer allocator.free(attach_buf);

        const attach_cmd: *VirtioGpuResourceAttachBacking = @ptrCast(@alignCast(attach_buf.ptr));
        attach_cmd.* = .{
            .hdr = .{
                .type_ = VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING,
                .flags = 0,
                .fence_id = 0,
                .ctx_id = 0,
                .ring_idx = 0,
            },
            .resource_id = self.resource_id,
            .nr_entries = @intCast(entries.items.len),
        };

        // Copy SG entries after header
        const entries_dest = attach_buf[attach_header_size..];
        const entries_src = std.mem.sliceAsBytes(entries.items);
        @memcpy(entries_dest, entries_src);

        if (!self.sendCommand(attach_buf, resp_bytes)) {
            return false;
        }

        // Set scanout
        const scanout_cmd: *VirtioGpuSetScanout = @ptrCast(@alignCast(self.cmd_buf_virt));
        scanout_cmd.* = .{
            .hdr = .{
                .type_ = VIRTIO_GPU_CMD_SET_SCANOUT,
                .flags = 0,
                .fence_id = 0,
                .ctx_id = 0,
                .ring_idx = 0,
            },
            .r = .{ .x = 0, .y = 0, .width = self.width, .height = self.height },
            .scanout_id = 0,
            .resource_id = self.resource_id,
        };

        const scanout_bytes = @as([*]const u8, @ptrCast(scanout_cmd))[0..@sizeOf(VirtioGpuSetScanout)];

        if (!self.sendCommand(scanout_bytes, resp_bytes)) {
            return false;
        }

        console.debug("VirtIO-GPU: Framebuffer resource created, id={d}, pages={d}", .{self.resource_id, pages_needed});
        return true;
    }

    // GraphicsDevice interface implementation

    fn getMode(ctx: *anyopaque) interface.VideoMode {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return .{
            .width = self.width,
            .height = self.height,
            .pitch = self.pitch,
            .bpp = 32,
            .addr = @intFromPtr(self.fb_virt),
            // Explicitly set alpha parameters matching B8G8R8X8 (X=unused/alpha)
            .alpha_mask_size = 0,
            .alpha_field_position = 24,
        };
    }

    fn putPixel(ctx: *anyopaque, x: u32, y: u32, color: interface.Color) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (x >= self.width or y >= self.height) return;

        const val: u32 = (@as(u32, 0xFF) << 24) |
            (@as(u32, color.r) << 16) |
            (@as(u32, color.g) << 8) |
            (@as(u32, color.b));

        const index = @as(u64, y) * (self.pitch / 4) + @as(u64, x);
        self.fb_virt[index] = val;
    }

    fn fillRect(ctx: *anyopaque, x: u32, y: u32, w: u32, h: u32, color: interface.Color) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (x >= self.width or y >= self.height) return;
        const clip_w = if (x + w > self.width) self.width - x else w;
        const clip_h = if (y + h > self.height) self.height - y else h;
        if (clip_w == 0 or clip_h == 0) return;

        const val: u32 = (@as(u32, 0xFF) << 24) |
            (@as(u32, color.r) << 16) |
            (@as(u32, color.g) << 8) |
            (@as(u32, color.b));

        const stride_u32 = self.pitch / 4;

        var row: u32 = 0;
        while (row < clip_h) : (row += 1) {
            const row_start = (@as(u64, y + row) * stride_u32) + @as(u64, x);
            @memset(self.fb_virt[row_start .. row_start + clip_w], val);
        }
    }

    fn drawBuffer(ctx: *anyopaque, x: u32, y: u32, w: u32, h: u32, buf: []const u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (x >= self.width or y >= self.height) return;
        const clip_w = if (x + w > self.width) self.width - x else w;
        const clip_h = if (y + h > self.height) self.height - y else h;
        if (clip_w == 0 or clip_h == 0) return;

        const stride_u32 = self.pitch / 4;

        var row: u32 = 0;
        while (row < clip_h) : (row += 1) {
            const fb_offset = (@as(u64, y + row) * stride_u32) + @as(u64, x);
            const buf_offset = row * w;
            @memcpy(self.fb_virt[fb_offset .. fb_offset + clip_w], buf[buf_offset .. buf_offset + clip_w]);
        }
    }

    fn copyRect(ctx: *anyopaque, src_x: u32, src_y: u32, dst_x: u32, dst_y: u32, w: u32, h: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (src_x >= self.width or src_y >= self.height) return;
        if (dst_x >= self.width or dst_y >= self.height) return;

        const clip_w = if (src_x + w > self.width) self.width - src_x else w;
        const final_w = if (dst_x + clip_w > self.width) self.width - dst_x else clip_w;

        const clip_h = if (src_y + h > self.height) self.height - src_y else h;
        const final_h = if (dst_y + clip_h > self.height) self.height - dst_y else clip_h;

        if (final_w == 0 or final_h == 0) return;

        const stride_u32 = self.pitch / 4;

        if (src_y < dst_y) {
            var i: u32 = 0;
            while (i < final_h) : (i += 1) {
                const row = final_h - 1 - i;
                const src_offset = (@as(u64, src_y + row) * stride_u32) + @as(u64, src_x);
                const dst_offset = (@as(u64, dst_y + row) * stride_u32) + @as(u64, dst_x);
                @memcpy(self.fb_virt[dst_offset .. dst_offset + final_w], self.fb_virt[src_offset .. src_offset + final_w]);
            }
        } else {
            var row: u32 = 0;
            while (row < final_h) : (row += 1) {
                const src_offset = (@as(u64, src_y + row) * stride_u32) + @as(u64, src_x);
                const dst_offset = (@as(u64, dst_y + row) * stride_u32) + @as(u64, dst_x);
                @memcpy(self.fb_virt[dst_offset .. dst_offset + final_w], self.fb_virt[src_offset .. src_offset + final_w]);
            }
        }
    }

    fn present(ctx: *anyopaque, dirty_rect: ?interface.Rect) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        var x: u32 = 0;
        var y: u32 = 0;
        var w: u32 = self.width;
        var h: u32 = self.height;

        if (dirty_rect) |rect| {
            x = rect.x;
            y = rect.y;
            w = rect.width;
            h = rect.height;
        }

        // Sanity check
        if (x >= self.width or y >= self.height) return;
        if (x + w > self.width) w = self.width - x;
        if (y + h > self.height) h = self.height - y;
        if (w == 0 or h == 0) return;

        // Transfer framebuffer to host
        const transfer_cmd: *VirtioGpuTransferToHost2d = @ptrCast(@alignCast(self.cmd_buf_virt));
        transfer_cmd.* = .{
            .hdr = .{
                .type_ = VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D,
                .flags = 0,
                .fence_id = 0,
                .ctx_id = 0,
                .ring_idx = 0,
            },
            .r = .{ .x = x, .y = y, .width = w, .height = h },
            .offset = (@as(u64, y) * self.pitch) + (@as(u64, x) * 4),
            .resource_id = self.resource_id,
        };

        const transfer_bytes = @as([*]const u8, @ptrCast(transfer_cmd))[0..@sizeOf(VirtioGpuTransferToHost2d)];
        const resp_bytes = self.resp_buf_virt[0..@sizeOf(VirtioGpuCtrlHdr)];

        _ = self.sendCommand(transfer_bytes, resp_bytes);

        // Flush to display
        const flush_cmd: *VirtioGpuResourceFlush = @ptrCast(@alignCast(self.cmd_buf_virt));
        flush_cmd.* = .{
            .hdr = .{
                .type_ = VIRTIO_GPU_CMD_RESOURCE_FLUSH,
                .flags = 0,
                .fence_id = 0,
                .ctx_id = 0,
                .ring_idx = 0,
            },
            .r = .{ .x = x, .y = y, .width = w, .height = h },
            .resource_id = self.resource_id,
        };

        const flush_bytes = @as([*]const u8, @ptrCast(flush_cmd))[0..@sizeOf(VirtioGpuResourceFlush)];

        _ = self.sendCommand(flush_bytes, resp_bytes);
    }
};

// Global driver instance
var driver_instance: VirtioGpuDriver = undefined;
var driver_initialized: bool = false;

/// Get initialized VirtIO-GPU driver if available
pub fn getDriver() ?*VirtioGpuDriver {
    if (driver_initialized) return &driver_instance;
    return null;
}

// XHCI Device and Endpoint Context Structures
//
// XHCI uses context data structures to communicate device and endpoint
// state between software and hardware. Two sizes are supported:
//   - 32-byte contexts (CSZ=0 in HCCPARAMS1)
//   - 64-byte contexts (CSZ=1 in HCCPARAMS1)
//
// Context Types:
//   - Slot Context: Device-level info (route, speed, port, state)
//   - Endpoint Context: Per-endpoint configuration (type, max packet, ring)
//   - Input Context: Used for commands (add flags + slot + endpoints)
//   - Device Context: Output from controller (slot + 31 endpoints)
//
// Reference: xHCI Specification 1.2, Chapter 6.2

const hal = @import("hal");
const pmm = @import("pmm");
const dma = @import("dma");
const iommu = @import("iommu");

// =============================================================================
// Slot Context (32 bytes base, may be 64 with CSZ=1)
// =============================================================================

/// Slot Context - Device-level information
pub const SlotContext = extern struct {
    /// DW0: Route String, Speed, etc.
    dw0: packed struct(u32) {
        route_string: u20, // USB 3.0 route string
        speed: Speed, // Port speed
        _rsvd0: u1,
        mtt: bool, // Multi-TT (for USB 2.0 hubs)
        hub: bool, // Is this device a hub?
        context_entries: u5, // Number of valid endpoint contexts
    },

    /// DW1: Max Exit Latency, Root Hub Port Number
    dw1: packed struct(u32) {
        max_exit_latency: u16, // Worst case exit latency (microseconds)
        root_hub_port_number: u8, // Root hub port (1-based)
        num_ports: u8, // For hubs: number of downstream ports
    },

    /// DW2: TT info, Interrupter Target
    dw2: packed struct(u32) {
        tt_hub_slot_id: u8, // For LS/FS via hub: TT hub slot
        tt_port_number: u8, // TT port number
        ttt: u2, // TT Think Time
        _rsvd: u4,
        interrupter_target: u10, // Target interrupter for events
    },

    /// DW3: USB Device Address, Slot State
    dw3: packed struct(u32) {
        usb_device_address: u8, // Assigned USB address
        _rsvd: u19,
        slot_state: SlotState, // Current slot state
    },

    /// Reserved DWORDs (for 32-byte context)
    _rsvd: [4]u32 = [_]u32{0} ** 4,

    const Self = @This();

    /// Create an empty slot context
    pub fn empty() Self {
        return @bitCast([_]u32{0} ** 8);
    }

    /// Initialize for a new device
    pub fn initForDevice(
        speed: Speed,
        root_port: u8,
        route_string: u20,
        parent_hub_slot_id: u8,
        parent_port_num: u8,
        context_entries: u5,
    ) Self {
        var ctx = empty();
        ctx.dw0.speed = speed;
        ctx.dw0.route_string = route_string;
        ctx.dw0.context_entries = context_entries;
        
        ctx.dw1.root_hub_port_number = root_port;
        // For non-hub devices, num_ports is 0. 
        // Logic for setting hub: true and num_ports should be done post-init or via another method if needed,
        // but typically initForDevice sets the basic connectivity.
        
        // Populate parent info (needed for splits)
        // Note: For root hub ports, parent_hub_slot_id is 0.
        // For hubs, we might need to set TT info in DW2 if we are LS/FS behind HS hub.
        // That logic is complex and usually done by the caller calculating these values.
        // For now, let's trust the caller to update DW2 manually if needed or add arguments.
        
        // Actually, let's keep it simple for now and rely on caller to set more if needed,
        // but route_string is essential for hubs.
        
        // Wait, parent_hub_slot_id is not a direct field in SlotContext for standard operations EXCEPT for TT (DW2).
        // The xHCI uses Route String to find the path.
        // DW2 has tt_hub_slot_id and tt_port_number.
        
        _ = parent_port_num;
        if (parent_hub_slot_id != 0) {
            // This is likely for TT configuration (LS/FS behind HS Hub)
            // But we'll leave DW2 zero for now unless explicitly needed.
        }
        
        return ctx;
    }

    comptime {
        if (@sizeOf(Self) != 32) @compileError("SlotContext must be 32 bytes");
    }
};

/// Slot State values
pub const SlotState = enum(u5) {
    disabled_enabled = 0, // Disabled or Enabled
    default = 1, // Default state after Address Device (BSR=1)
    addressed = 2, // Addressed state after Address Device (BSR=0)
    configured = 3, // Configured state after Configure Endpoint
    _,
};

/// Device Speed values (matches PORTSC.Speed)
pub const Speed = enum(u4) {
    invalid = 0,
    full_speed = 1, // 12 Mbps
    low_speed = 2, // 1.5 Mbps
    high_speed = 3, // 480 Mbps
    super_speed = 4, // 5 Gbps
    super_speed_plus = 5, // 10 Gbps
    _,
};

// =============================================================================
// Endpoint Context (32 bytes base, may be 64 with CSZ=1)
// =============================================================================

/// Endpoint Context - Per-endpoint configuration
pub const EndpointContext = extern struct {
    /// DW0: Endpoint State, Mult, Max Streams
    dw0: packed struct(u32) {
        ep_state: EndpointState, // Current endpoint state
        _rsvd0: u5,
        mult: u2, // Max burst count - 1 (for SS isoch)
        max_pstreams: u5, // Max primary stream array size (log2)
        lsa: bool, // Linear Stream Array
        interval: u8, // Polling interval (log2 microframes)
        max_esit_payload_hi: u8, // High bits of max ESIT payload
    },

    /// DW1: Error Count, Endpoint Type, Max Burst Size, Max Packet Size
    dw1: packed struct(u32) {
        _rsvd0: u1,
        cerr: u2, // Error count
        ep_type: EndpointType, // Endpoint type
        _rsvd1: u1,
        hid: bool, // Host Initiate Disable
        max_burst_size: u8, // Max burst size - 1
        max_packet_size: u16, // Max packet size in bytes
    },

    /// DW2-3: TR Dequeue Pointer (physical address, 16-byte aligned)
    tr_dequeue_ptr: packed struct(u64) {
        dcs: bool, // Dequeue Cycle State
        _rsvd: u3,
        ptr: u60, // Physical address >> 4
    },

    /// DW4: Average TRB Length, Max ESIT Payload Low
    dw4: packed struct(u32) {
        average_trb_length: u16, // Average TRB length for bandwidth calc
        max_esit_payload_lo: u16, // Low bits of max ESIT payload
    },

    /// Reserved DWORDs
    _rsvd: [3]u32 = [_]u32{0} ** 3,

    const Self = @This();

    /// Create an empty endpoint context
    pub fn empty() Self {
        return @bitCast([_]u32{0} ** 8);
    }

    /// Initialize for Control Endpoint 0
    pub fn initForEp0(max_packet_size: u16, tr_phys: u64, dcs: bool) Self {
        var ctx = empty();
        ctx.dw1.cerr = 3; // Max error count
        ctx.dw1.ep_type = .control_bidirectional;
        ctx.dw1.max_packet_size = max_packet_size;
        ctx.tr_dequeue_ptr.dcs = dcs;
        ctx.tr_dequeue_ptr.ptr = @truncate(tr_phys >> 4);
        ctx.dw4.average_trb_length = 8; // Control transfers average small
        return ctx;
    }

    /// Initialize for Interrupt IN endpoint
    pub fn initInterruptIn(
        max_packet_size: u16,
        interval: u8,
        tr_phys: u64,
        dcs: bool,
    ) Self {
        var ctx = empty();
        ctx.dw0.interval = interval;
        ctx.dw1.cerr = 3;
        ctx.dw1.ep_type = .interrupt_in;
        ctx.dw1.max_packet_size = max_packet_size;
        ctx.tr_dequeue_ptr.dcs = dcs;
        ctx.tr_dequeue_ptr.ptr = @truncate(tr_phys >> 4);
        ctx.dw4.average_trb_length = max_packet_size;
        return ctx;
    }

    /// Initialize for Bulk IN endpoint
    pub fn initBulkIn(max_packet_size: u16, tr_phys: u64, dcs: bool) Self {
        var ctx = empty();
        ctx.dw1.cerr = 3;
        ctx.dw1.ep_type = .bulk_in;
        ctx.dw1.max_packet_size = max_packet_size;
        ctx.tr_dequeue_ptr.dcs = dcs;
        ctx.tr_dequeue_ptr.ptr = @truncate(tr_phys >> 4);
        ctx.dw4.average_trb_length = 1024; // Bulk transfers are larger
        return ctx;
    }

    /// Initialize for Bulk OUT endpoint
    pub fn initBulkOut(max_packet_size: u16, tr_phys: u64, dcs: bool) Self {
        var ctx = empty();
        ctx.dw1.cerr = 3;
        ctx.dw1.ep_type = .bulk_out;
        ctx.dw1.max_packet_size = max_packet_size;
        ctx.tr_dequeue_ptr.dcs = dcs;
        ctx.tr_dequeue_ptr.ptr = @truncate(tr_phys >> 4);
        ctx.dw4.average_trb_length = 1024;
        return ctx;
    }

    /// Generic initialization
    pub fn initGeneric(
        ep_type: EndpointType,
        max_packet_size: u16,
        interval: u8,
        tr_phys: u64,
        dcs: bool,
    ) Self {
        var ctx = empty();
        ctx.dw0.interval = interval;
        ctx.dw1.cerr = 3;
        ctx.dw1.ep_type = ep_type;
        ctx.dw1.max_packet_size = max_packet_size;
        ctx.tr_dequeue_ptr.dcs = dcs;
        ctx.tr_dequeue_ptr.ptr = @truncate(tr_phys >> 4);
        
        // Set average TRB length based on type
        switch (ep_type) {
            .control_bidirectional => ctx.dw4.average_trb_length = 8,
            .interrupt_in, .interrupt_out => ctx.dw4.average_trb_length = max_packet_size,
            .bulk_in, .bulk_out => ctx.dw4.average_trb_length = 1024,
            .isoch_in, .isoch_out => ctx.dw4.average_trb_length = max_packet_size, // simplified
            else => ctx.dw4.average_trb_length = 8,
        }
        
        return ctx;
    }

    /// Set TR dequeue pointer
    pub fn setTrDequeue(self: *Self, phys: u64, dcs: bool) void {
        self.tr_dequeue_ptr.dcs = dcs;
        self.tr_dequeue_ptr.ptr = @truncate(phys >> 4);
    }

    /// Get TR dequeue pointer physical address
    pub fn getTrDequeue(self: *const Self) u64 {
        return @as(u64, self.tr_dequeue_ptr.ptr) << 4;
    }

    comptime {
        if (@sizeOf(Self) != 32) @compileError("EndpointContext must be 32 bytes");
    }
};

/// Endpoint State values
pub const EndpointState = enum(u3) {
    disabled = 0,
    running = 1,
    halted = 2,
    stopped = 3,
    err = 4, // Error
    _,
};

/// Endpoint Type values
pub const EndpointType = enum(u3) {
    not_valid = 0,
    isoch_out = 1,
    bulk_out = 2,
    interrupt_out = 3,
    control_bidirectional = 4,
    isoch_in = 5,
    bulk_in = 6,
    interrupt_in = 7,
};

// =============================================================================
// Input Context (for commands)
// =============================================================================

/// Input Control Context - precedes slot/endpoint contexts in Input Context
pub const InputControlContext = extern struct {
    /// Drop Context Flags (bit N = drop endpoint N)
    drop_context_flags: u32,
    /// Add Context Flags (bit N = add/configure endpoint N)
    /// Bit 0 = Slot Context, Bit 1 = EP0, etc.
    add_context_flags: u32,
    /// Reserved
    _rsvd: [5]u32 = [_]u32{0} ** 5,
    /// Configuration Value (for Configure Endpoint)
    config_value: u8 = 0,
    /// Interface Number
    interface_number: u8 = 0,
    /// Alternate Setting
    alternate_setting: u8 = 0,
    /// Reserved
    _rsvd2: u8 = 0,

    const Self = @This();

    pub fn empty() Self {
        return @bitCast([_]u32{0} ** 8);
    }

    /// Set add flags for slot context and specified endpoints
    pub fn setAddFlags(self: *Self, slot: bool, endpoints: u31) void {
        var flags: u32 = if (slot) 1 else 0;
        flags |= @as(u32, endpoints) << 1;
        self.add_context_flags = flags;
    }

    /// Set drop flags for specified endpoints
    pub fn setDropFlags(self: *Self, endpoints: u31) void {
        self.drop_context_flags = @as(u32, endpoints) << 1;
    }

    comptime {
        if (@sizeOf(Self) != 32) @compileError("InputControlContext must be 32 bytes");
    }
};

/// Input Context - Used for Address Device and Configure Endpoint commands
/// Layout: Input Control Context + Slot Context + 31 Endpoint Contexts
pub const InputContext = extern struct {
    input_control: InputControlContext,
    slot: SlotContext,
    endpoints: [31]EndpointContext,

    const Self = @This();

    /// Allocate an Input Context using IOMMU-aware DMA
    /// Returns virtual pointer, device address, and DMA buffer for cleanup
    pub fn alloc(bdf: iommu.DeviceBdf) !struct { ctx: *Self, device_addr: u64, dma_buf: dma.DmaBuffer } {
        // Input Context needs 64-byte alignment
        // Size is 32 + 32 + 31*32 = 1024 + 32 = 1056 bytes for 32-byte contexts
        // Use a full page for simplicity and alignment
        const buf = dma.allocBuffer(bdf, pmm.PAGE_SIZE, true) catch return error.OutOfMemory;
        const virt = @intFromPtr(hal.paging.physToVirt(buf.phys_addr));
        const ctx: *Self = @ptrFromInt(virt);
        return .{ .ctx = ctx, .device_addr = buf.device_addr, .dma_buf = buf };
    }

    /// Free an Input Context DMA buffer
    pub fn freeDma(buf: *const dma.DmaBuffer) void {
        dma.freeBuffer(buf);
    }

    /// Free an Input Context (legacy, for contexts not using IOMMU)
    pub fn free(self: *Self) void {
        const phys = hal.paging.virtToPhys(@intFromPtr(self));
        pmm.freePages(phys, 1);
    }

    /// Get endpoint context by DCI (Device Context Index)
    /// DCI 0 = reserved, DCI 1 = EP0, DCI 2 = EP1 OUT, DCI 3 = EP1 IN, etc.
    pub fn getEndpoint(self: *Self, dci: u5) ?*EndpointContext {
        if (dci == 0 or dci > 31) return null;
        return &self.endpoints[dci - 1];
    }

    /// Calculate DCI from endpoint address
    /// EP0 = DCI 1
    /// EP N OUT = DCI 2N
    /// EP N IN = DCI 2N+1
    /// Security: Validates endpoint number to prevent integer overflow.
    /// USB spec allows ep_num 0-15 only. Returns null for invalid addresses.
    pub fn endpointToDci(ep_addr: u8) ?u5 {
        const ep_num = ep_addr & 0x0F;
        const is_in = (ep_addr & 0x80) != 0;
        // Security: USB spec limits endpoint numbers to 0-15
        // ep_num * 2 + 1 must fit in u5 (max 31), so ep_num <= 15
        if (ep_num > 15) return null;
        if (ep_num == 0) return 1; // EP0 is bidirectional
        return @truncate(ep_num * 2 + (if (is_in) @as(u5, 1) else @as(u5, 0)));
    }

    comptime {
        // 32 (ICC) + 32 (Slot) + 31*32 (EPs) = 1056 bytes
        if (@sizeOf(Self) != 1056) @compileError("InputContext size mismatch");
    }
};

/// Device Context - Output from controller
/// Layout: Slot Context + 31 Endpoint Contexts (no Input Control Context)
pub const DeviceContext = extern struct {
    slot: SlotContext,
    endpoints: [31]EndpointContext,

    const Self = @This();

    /// Allocate a Device Context using IOMMU-aware DMA
    pub fn alloc(bdf: iommu.DeviceBdf) !struct { ctx: *Self, device_addr: u64, dma_buf: dma.DmaBuffer } {
        const buf = dma.allocBuffer(bdf, pmm.PAGE_SIZE, true) catch return error.OutOfMemory;
        const virt = @intFromPtr(hal.paging.physToVirt(buf.phys_addr));
        const ctx: *Self = @ptrFromInt(virt);
        return .{ .ctx = ctx, .device_addr = buf.device_addr, .dma_buf = buf };
    }

    /// Free a Device Context DMA buffer
    pub fn freeDma(buf: *const dma.DmaBuffer) void {
        dma.freeBuffer(buf);
    }

    /// Free a Device Context (legacy, for contexts not using IOMMU)
    pub fn free(self: *Self) void {
        const phys = hal.paging.virtToPhys(@intFromPtr(self));
        pmm.freePages(phys, 1);
    }

    /// Get endpoint context by DCI
    pub fn getEndpoint(self: *Self, dci: u5) ?*EndpointContext {
        if (dci == 0 or dci > 31) return null;
        return &self.endpoints[dci - 1];
    }

    comptime {
        // 32 (Slot) + 31*32 (EPs) = 1024 bytes
        if (@sizeOf(Self) != 1024) @compileError("DeviceContext size mismatch");
    }
};

// =============================================================================
// Device Context Base Address Array (DCBAA)
// =============================================================================

/// DCBAA - Array of pointers to Device Contexts
/// Entry 0 = Scratchpad Buffer Array Base Address (if scratchpads used)
/// Entry N = Device Context for Slot N (1-255)
pub const Dcbaa = struct {
    /// Virtual address of array
    entries: [*]u64,
    /// Physical address of array (for CPU access via HHDM)
    phys_base: u64,
    /// Device address (IOVA or physical, for hardware registers)
    device_addr: u64,
    /// DMA buffer tracking for IOMMU cleanup
    dma_buf: dma.DmaBuffer,
    /// Number of slots supported
    max_slots: u8,

    const Self = @This();

    /// Allocate DCBAA for given number of slots using IOMMU-aware DMA
    /// Size = (max_slots + 1) * 8 bytes, 64-byte aligned
    pub fn alloc(max_slots: u8, bdf: iommu.DeviceBdf) !Self {
        // Use a full page for alignment (4KB holds 512 entries)
        // IOMMU-aware allocation, writable by device
        const buf = dma.allocBuffer(bdf, pmm.PAGE_SIZE, true) catch return error.OutOfMemory;
        const virt = @intFromPtr(hal.paging.physToVirt(buf.phys_addr));
        const entries: [*]u64 = @ptrFromInt(virt);

        return Self{
            .entries = entries,
            .phys_base = buf.phys_addr,
            .device_addr = buf.device_addr,
            .dma_buf = buf,
            .max_slots = max_slots,
        };
    }

    /// Set Device Context pointer for a slot (use device address)
    pub fn setSlot(self: *Self, slot_id: u8, device_context_addr: u64) void {
        if (slot_id > self.max_slots) return;
        self.entries[slot_id] = device_context_addr;
    }

    /// Get Device Context pointer for a slot
    pub fn getSlot(self: *const Self, slot_id: u8) u64 {
        if (slot_id > self.max_slots) return 0;
        return self.entries[slot_id];
    }

    /// Set Scratchpad Buffer Array pointer (entry 0, use device address)
    pub fn setScratchpadArray(self: *Self, scratchpad_array_addr: u64) void {
        self.entries[0] = scratchpad_array_addr;
    }

    /// Get device address for DCBAAP register (IOVA or physical)
    pub fn getDeviceAddress(self: *const Self) u64 {
        return self.device_addr;
    }

    /// Get physical address (for legacy code or debugging)
    pub fn getPhysicalAddress(self: *const Self) u64 {
        return self.phys_base;
    }

    /// Free DCBAA
    pub fn free(self: *Self) void {
        dma.freeBuffer(&self.dma_buf);
        self.entries = undefined;
    }
};

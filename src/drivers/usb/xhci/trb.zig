// XHCI Transfer Request Block (TRB) Definitions
//
// TRBs are 16-byte structures used for all communication between software
// and the XHCI controller. They are organized into rings:
//   - Command Ring: Software -> Controller commands
//   - Event Ring: Controller -> Software notifications
//   - Transfer Rings: Per-endpoint data transfers
//
// All TRBs are 16-byte aligned and share a common structure with
// type-specific interpretations of the fields.
//
// Reference: xHCI Specification 1.2, Chapter 6

// =============================================================================
// Common TRB Structure
// =============================================================================

/// Generic TRB structure (16 bytes, 16-byte aligned)
/// All TRB types share this layout with different field interpretations
pub const Trb = extern struct {
    parameter: u64 align(16), // Type-specific parameter - align first field for struct alignment
    status: u32, // Type-specific status/length
    control: Control, // Type and flags

    /// TRB Control field breakdown
    pub const Control = packed struct(u32) {
        cycle: bool, // Cycle bit - must match producer cycle state
        ent: bool, // Evaluate Next TRB (for multi-TRB commands)
        _rsvd0: u2,
        chain: bool, // Chain bit - links TRBs together
        ioc: bool, // Interrupt On Completion
        idt: bool, // Immediate Data - parameter contains data, not pointer
        _rsvd1: u3,
        trb_type: TrbType, // TRB type code
        _rsvd2: u16,

        /// Create control word with type and flags
        pub fn init(trb_type: TrbType, flags: ControlFlags) Control {
            return .{
                .cycle = flags.cycle,
                .ent = flags.ent,
                ._rsvd0 = 0,
                .chain = flags.chain,
                .ioc = flags.ioc,
                .idt = flags.idt,
                ._rsvd1 = 0,
                .trb_type = trb_type,
                ._rsvd2 = 0,
            };
        }
    };

    /// Flags for TRB control field
    pub const ControlFlags = struct {
        cycle: bool = false,
        ent: bool = false,
        chain: bool = false,
        ioc: bool = false,
        idt: bool = false,
    };

    /// Create an empty TRB
    pub fn empty() Trb {
        return .{
            .parameter = 0,
            .status = 0,
            .control = @bitCast(@as(u32, 0)),
        };
    }

    /// Get raw control word
    pub fn rawControl(self: Trb) u32 {
        return @bitCast(self.control);
    }

    comptime {
        if (@sizeOf(Trb) != 16) @compileError("TRB must be exactly 16 bytes");
        if (@alignOf(Trb) < 16) @compileError("TRB must be 16-byte aligned");
    }
};

// =============================================================================
// TRB Types
// =============================================================================

/// TRB Type codes (6 bits)
pub const TrbType = enum(u6) {
    // Transfer TRB Types
    Normal = 1,
    SetupStage = 2,
    DataStage = 3,
    StatusStage = 4,
    Isoch = 5,
    Link = 6,
    EventData = 7,
    NoOpTransfer = 8,

    // Command TRB Types
    EnableSlotCmd = 9,
    DisableSlotCmd = 10,
    AddressDeviceCmd = 11,
    ConfigureEndpointCmd = 12,
    EvaluateContextCmd = 13,
    ResetEndpointCmd = 14,
    StopEndpointCmd = 15,
    SetTRDequeuePointerCmd = 16,
    ResetDeviceCmd = 17,
    ForceEventCmd = 18,
    NegotiateBandwidthCmd = 19,
    SetLatencyToleranceCmd = 20,
    GetPortBandwidthCmd = 21,
    ForceHeaderCmd = 22,
    NoOpCmd = 23,
    GetExtendedPropertyCmd = 24,
    SetExtendedPropertyCmd = 25,

    // Event TRB Types
    TransferEvent = 32,
    CommandCompletionEvent = 33,
    PortStatusChangeEvent = 34,
    BandwidthRequestEvent = 35,
    DoorbellEvent = 36,
    HostControllerEvent = 37,
    DeviceNotificationEvent = 38,
    MFINDEXWrapEvent = 39,

    _,
};

// =============================================================================
// Command TRBs
// =============================================================================

/// No-Op Command TRB - Used to test command ring
pub const NoOpCmdTrb = extern struct {
    _rsvd0: u64 = 0,
    _rsvd1: u32 = 0,
    control: Trb.Control,

    pub fn init(cycle: bool) NoOpCmdTrb {
        return .{
            .control = Trb.Control.init(.NoOpCmd, .{ .cycle = cycle }),
        };
    }

    pub fn toTrb(self: NoOpCmdTrb) Trb {
        return Trb{
            .parameter = 0,
            .status = 0,
            .control = self.control,
        };
    }
};

/// Enable Slot Command TRB - Request a device slot
pub const EnableSlotCmdTrb = extern struct {
    _rsvd0: u64 align(16) = 0,
    _rsvd1: u32 = 0,
    control: packed struct(u32) {
        cycle: bool,
        _rsvd0: u9,
        trb_type: TrbType,
        slot_type: u5 = 0, // 0 = default
        _rsvd1: u11,
    },

    pub fn init(cycle: bool) EnableSlotCmdTrb {
        return .{
            .control = .{
                .cycle = cycle,
                ._rsvd0 = 0,
                .trb_type = .EnableSlotCmd,
                .slot_type = 0,
                ._rsvd1 = 0,
            },
        };
    }

    pub fn asTrb(self: *EnableSlotCmdTrb) *Trb {
        return @ptrCast(@alignCast(self));
    }
};

/// Disable Slot Command TRB - Release a device slot
pub const DisableSlotCmdTrb = extern struct {
    _rsvd0: u64 align(16) = 0,
    _rsvd1: u32 = 0,
    control: packed struct(u32) {
        cycle: bool,
        _rsvd0: u9,
        trb_type: TrbType,
        _rsvd1: u8,
        slot_id: u8,
    },

    pub fn init(slot_id: u8, cycle: bool) DisableSlotCmdTrb {
        return .{
            .control = .{
                .cycle = cycle,
                ._rsvd0 = 0,
                .trb_type = .DisableSlotCmd,
                ._rsvd1 = 0,
                .slot_id = slot_id,
            },
        };
    }

    pub fn asTrb(self: *DisableSlotCmdTrb) *Trb {
        return @ptrCast(@alignCast(self));
    }
};

/// Address Device Command TRB - Assign USB address to device
pub const AddressDeviceCmdTrb = extern struct {
    input_context_ptr: u64 align(16), // Physical address of Input Context (16-byte aligned)
    _rsvd: u32 = 0,
    control: packed struct(u32) {
        cycle: bool,
        _rsvd0: u8,
        bsr: bool, // Block Set Address Request
        trb_type: TrbType,
        _rsvd1: u8,
        slot_id: u8,
    },

    pub fn init(input_context_phys: u64, slot_id: u8, bsr: bool, cycle: bool) AddressDeviceCmdTrb {
        return .{
            .input_context_ptr = input_context_phys,
            .control = .{
                .cycle = cycle,
                ._rsvd0 = 0,
                .bsr = bsr,
                .trb_type = .AddressDeviceCmd,
                ._rsvd1 = 0,
                .slot_id = slot_id,
            },
        };
    }

    pub fn asTrb(self: *AddressDeviceCmdTrb) *Trb {
        return @ptrCast(@alignCast(self));
    }
};

/// Configure Endpoint Command TRB - Configure device endpoints
pub const ConfigureEndpointCmdTrb = extern struct {
    input_context_ptr: u64 align(16), // Physical address of Input Context
    _rsvd: u32 = 0,
    control: packed struct(u32) {
        cycle: bool,
        _rsvd0: u8,
        dc: bool, // Deconfigure
        trb_type: TrbType,
        _rsvd1: u8,
        slot_id: u8,
    },

    pub fn init(input_context_phys: u64, slot_id: u8, deconfigure: bool, cycle: bool) ConfigureEndpointCmdTrb {
        return .{
            .input_context_ptr = input_context_phys,
            .control = .{
                .cycle = cycle,
                ._rsvd0 = 0,
                .dc = deconfigure,
                .trb_type = .ConfigureEndpointCmd,
                ._rsvd1 = 0,
                .slot_id = slot_id,
            },
        };
    }

    pub fn asTrb(self: *ConfigureEndpointCmdTrb) *Trb {
        return @ptrCast(@alignCast(self));
    }
};

/// Evaluate Context Command TRB - Update endpoint parameters
pub const EvaluateContextCmdTrb = extern struct {
    input_context_ptr: u64 align(16),
    _rsvd: u32 = 0,
    control: packed struct(u32) {
        cycle: bool,
        _rsvd0: u9,
        trb_type: TrbType,
        _rsvd1: u8,
        slot_id: u8,
    },

    pub fn init(input_context_phys: u64, slot_id: u8, cycle: bool) EvaluateContextCmdTrb {
        return .{
            .input_context_ptr = input_context_phys,
            .control = .{
                .cycle = cycle,
                ._rsvd0 = 0,
                .trb_type = .EvaluateContextCmd,
                ._rsvd1 = 0,
                .slot_id = slot_id,
            },
        };
    }

    pub fn asTrb(self: *EvaluateContextCmdTrb) *Trb {
        return @ptrCast(@alignCast(self));
    }
};

/// Reset Endpoint Command TRB - Reset stalled endpoint
pub const ResetEndpointCmdTrb = extern struct {
    _rsvd0: u64 align(16) = 0,
    _rsvd1: u32 = 0,
    control: packed struct(u32) {
        cycle: bool,
        _rsvd0: u8,
        tsp: bool, // Transfer State Preserve
        trb_type: TrbType,
        ep_id: u5, // Endpoint ID (DCI)
        _rsvd1: u3,
        slot_id: u8,
    },

    pub fn init(slot_id: u8, ep_id: u5, preserve_state: bool, cycle: bool) ResetEndpointCmdTrb {
        return .{
            .control = .{
                .cycle = cycle,
                ._rsvd0 = 0,
                .tsp = preserve_state,
                .trb_type = .ResetEndpointCmd,
                .ep_id = ep_id,
                ._rsvd1 = 0,
                .slot_id = slot_id,
            },
        };
    }

    pub fn asTrb(self: *ResetEndpointCmdTrb) *Trb {
        return @ptrCast(@alignCast(self));
    }
};

/// Stop Endpoint Command TRB - Stop an endpoint (for disconnect cleanup)
/// xHCI Spec 6.4.3.8: Used to stop endpoint before disabling slot
pub const StopEndpointCmdTrb = extern struct {
    _rsvd0: u64 align(16) = 0,
    _rsvd1: u32 = 0,
    control: packed struct(u32) {
        cycle: bool,
        _rsvd0: u8,
        sp: bool, // Suspend - if true, endpoint is suspended (can be resumed), else stopped
        trb_type: TrbType,
        ep_id: u5, // Endpoint ID (DCI)
        _rsvd1: u3,
        slot_id: u8,
    },

    pub fn init(slot_id: u8, ep_id: u5, do_suspend: bool, cycle: bool) StopEndpointCmdTrb {
        return .{
            .control = .{
                .cycle = cycle,
                ._rsvd0 = 0,
                .sp = do_suspend,
                .trb_type = .StopEndpointCmd,
                .ep_id = ep_id,
                ._rsvd1 = 0,
                .slot_id = slot_id,
            },
        };
    }

    pub fn asTrb(self: *StopEndpointCmdTrb) *Trb {
        return @ptrCast(@alignCast(self));
    }
};

// =============================================================================
// Transfer TRBs
// =============================================================================

/// Normal Transfer TRB - Bulk/Interrupt data transfer
pub const NormalTrb = extern struct {
    data_buffer_ptr: u64 align(16), // Physical address of data buffer
    status: packed struct(u32) {
        trb_transfer_length: u17, // Bytes to transfer
        td_size: u5, // Remaining packets in TD
        interrupter_target: u10,
    },
    control: packed struct(u32) {
        cycle: bool,
        ent: bool, // Evaluate Next TRB
        isp: bool, // Interrupt on Short Packet
        ns: bool, // No Snoop
        chain: bool,
        ioc: bool, // Interrupt On Completion
        idt: bool, // Immediate Data
        _rsvd0: u2,
        bei: bool, // Block Event Interrupt
        trb_type: TrbType,
        _rsvd1: u16,
    },

    pub fn init(buffer_phys: u64, length: u17, flags: TransferFlags, cycle: bool) NormalTrb {
        return .{
            .data_buffer_ptr = buffer_phys,
            .status = .{
                .trb_transfer_length = length,
                .td_size = 0,
                .interrupter_target = 0,
            },
            .control = .{
                .cycle = cycle,
                .ent = false,
                .isp = flags.isp,
                .ns = false,
                .chain = flags.chain,
                .ioc = flags.ioc,
                .idt = flags.idt,
                ._rsvd0 = 0,
                .bei = false,
                .trb_type = .Normal,
                ._rsvd1 = 0,
            },
        };
    }

    pub fn asTrb(self: *NormalTrb) *Trb {
        return @ptrCast(@alignCast(self));
    }
};

/// Transfer TRB flags
pub const TransferFlags = struct {
    isp: bool = false, // Interrupt on Short Packet
    chain: bool = false,
    ioc: bool = false, // Interrupt On Completion
    idt: bool = false, // Immediate Data
};

/// Setup Stage TRB - First TRB of control transfer
pub const SetupStageTrb = extern struct {
    setup_data: SetupData align(16), // 8-byte USB Setup Packet
    status: packed struct(u32) {
        trb_transfer_length: u17 = 8, // Always 8 for setup
        _rsvd: u5 = 0,
        interrupter_target: u10 = 0,
    },
    control: packed struct(u32) {
        cycle: bool,
        _rsvd0: u4,
        ioc: bool,
        idt: bool = true, // Always immediate for setup
        _rsvd1: u3,
        trb_type: TrbType = .SetupStage,
        trt: TransferType, // Transfer type (direction)
        _rsvd2: u14,
    },

    /// Transfer type for control transfers
    pub const TransferType = enum(u2) {
        no_data = 0, // No data stage
        out = 2, // OUT data stage
        in = 3, // IN data stage
        _,
    };

    pub fn init(setup: SetupData, trt: TransferType, cycle: bool) SetupStageTrb {
        return .{
            .setup_data = setup,
            .status = .{
                .trb_transfer_length = 8,
                ._rsvd = 0,
                .interrupter_target = 0,
            },
            .control = .{
                .cycle = cycle,
                ._rsvd0 = 0,
                .ioc = false,
                .idt = true,
                ._rsvd1 = 0,
                .trb_type = .SetupStage,
                .trt = trt,
                ._rsvd2 = 0,
            },
        };
    }

    pub fn asTrb(self: *SetupStageTrb) *Trb {
        return @ptrCast(@alignCast(self));
    }
};

/// USB Setup Packet (8 bytes) - Embedded in Setup Stage TRB
pub const SetupData = packed struct(u64) {
    bm_request_type: u8, // Request type bitmap
    b_request: u8, // Request code
    w_value: u16, // Value (request-specific)
    w_index: u16, // Index (request-specific)
    w_length: u16, // Data stage length

    comptime {
        if (@sizeOf(SetupData) != 8) @compileError("SetupData must be 8 bytes");
    }
};

/// Data Stage TRB - Data phase of control transfer
pub const DataStageTrb = extern struct {
    data_buffer_ptr: u64 align(16), // Physical address of data buffer
    status: packed struct(u32) {
        trb_transfer_length: u17,
        td_size: u5 = 0,
        interrupter_target: u10 = 0,
    },
    control: packed struct(u32) {
        cycle: bool,
        ent: bool = false,
        isp: bool = false,
        ns: bool = false,
        chain: bool,
        ioc: bool,
        idt: bool = false, // Usually not immediate for data stage
        _rsvd0: u3,
        trb_type: TrbType = .DataStage,
        dir: bool, // Direction: 0=OUT, 1=IN
        _rsvd1: u15,
    },

    pub fn init(buffer_phys: u64, length: u17, dir_in: bool, ioc: bool, chain: bool, cycle: bool) DataStageTrb {
        return .{
            .data_buffer_ptr = buffer_phys,
            .status = .{
                .trb_transfer_length = length,
                .td_size = 0,
                .interrupter_target = 0,
            },
            .control = .{
                .cycle = cycle,
                .ent = false,
                .isp = false,
                .ns = false,
                .chain = chain,
                .ioc = ioc,
                .idt = false,
                ._rsvd0 = 0,
                .trb_type = .DataStage,
                .dir = dir_in,
                ._rsvd1 = 0,
            },
        };
    }

    pub fn asTrb(self: *DataStageTrb) *Trb {
        return @ptrCast(@alignCast(self));
    }
};

/// Status Stage TRB - Final TRB of control transfer
pub const StatusStageTrb = extern struct {
    _rsvd0: u64 align(16) = 0,
    status: packed struct(u32) {
        _rsvd: u22 = 0,
        interrupter_target: u10 = 0,
    } = .{},
    control: packed struct(u32) {
        cycle: bool,
        ent: bool = false,
        _rsvd0: u2,
        chain: bool = false, // Should be 0 for status
        ioc: bool,
        _rsvd1: u4,
        trb_type: TrbType = .StatusStage,
        dir: bool, // Direction: opposite of data stage
        _rsvd2: u15,
    },

    pub fn init(dir_in: bool, ioc: bool, cycle: bool) StatusStageTrb {
        return .{
            .control = .{
                .cycle = cycle,
                .ent = false,
                ._rsvd0 = 0,
                .chain = false,
                .ioc = ioc,
                ._rsvd1 = 0,
                .trb_type = .StatusStage,
                .dir = dir_in,
                ._rsvd2 = 0,
            },
        };
    }

    pub fn asTrb(self: *StatusStageTrb) *Trb {
        return @ptrCast(@alignCast(self));
    }
};

/// Link TRB - Wraps ring back to start or chains segments
pub const LinkTrb = extern struct {
    ring_segment_ptr: u64 align(16), // Physical address of next segment (16-byte aligned)
    _rsvd: u32 = 0,
    control: packed struct(u32) {
        cycle: bool,
        tc: bool, // Toggle Cycle - flip cycle bit when following link
        _rsvd0: u2,
        chain: bool = false,
        ioc: bool = false, // Usually 0 for link
        _rsvd1: u4,
        trb_type: TrbType = .Link,
        _rsvd2: u16,
    },

    pub fn init(next_segment_phys: u64, toggle_cycle: bool, cycle: bool) LinkTrb {
        return .{
            .ring_segment_ptr = next_segment_phys,
            .control = .{
                .cycle = cycle,
                .tc = toggle_cycle,
                ._rsvd0 = 0,
                .chain = false,
                .ioc = false,
                ._rsvd1 = 0,
                .trb_type = .Link,
                ._rsvd2 = 0,
            },
        };
    }

    pub fn asTrb(self: *LinkTrb) *Trb {
        return @ptrCast(@alignCast(self));
    }
};

// =============================================================================
// Event TRBs
// =============================================================================

/// Transfer Event TRB - Completion notification for transfers
pub const TransferEventTrb = extern struct {
    trb_pointer: u64, // Physical address of TRB that caused event
    status: packed struct(u32) {
        trb_transfer_length: u24, // Bytes NOT transferred (residual)
        completion_code: CompletionCode,
    },
    control: packed struct(u32) {
        cycle: bool,
        _rsvd0: u1,
        ed: bool, // Event Data (if set, trb_pointer is event data)
        _rsvd1: u7,
        trb_type: TrbType,
        ep_id: u5, // Endpoint ID
        _rsvd2: u3,
        slot_id: u8,
    },

    pub fn fromTrb(trb: *const Trb) *const TransferEventTrb {
        return @ptrCast(trb);
    }
};

/// Command Completion Event TRB - Result of command TRB
pub const CommandCompletionEventTrb = extern struct {
    command_trb_pointer: u64, // Physical address of command TRB
    status: packed struct(u32) {
        _rsvd: u24 = 0,
        completion_code: CompletionCode,
    },
    control: packed struct(u32) {
        cycle: bool,
        _rsvd0: u9,
        trb_type: TrbType,
        vf_id: u8, // Virtual Function ID
        slot_id: u8, // Slot ID (for slot-related commands)
    },

    pub fn fromTrb(trb: *const Trb) *const CommandCompletionEventTrb {
        return @ptrCast(trb);
    }

    /// Get slot ID from completion (for EnableSlot, etc.)
    pub fn getSlotId(self: *const CommandCompletionEventTrb) u8 {
        return self.control.slot_id;
    }
};

/// Port Status Change Event TRB - Port state changed
pub const PortStatusChangeEventTrb = extern struct {
    _rsvd0: u64 = 0, // Bits 31:24 contain port ID
    port_id_raw: u32, // Actually bits [31:24] = port ID
    status: packed struct(u32) {
        _rsvd: u24,
        completion_code: CompletionCode,
    },
    control: packed struct(u32) {
        cycle: bool,
        _rsvd0: u9,
        trb_type: TrbType,
        _rsvd1: u16,
    },

    pub fn fromTrb(trb: *const Trb) *const PortStatusChangeEventTrb {
        return @ptrCast(trb);
    }

    /// Get port ID (1-based)
    pub fn getPortId(self: *const PortStatusChangeEventTrb) u8 {
        // Port ID is in bits 31:24 of the first DWORD at offset 0
        // But we need to read it from the parameter field
        const param = @as(*const extern struct { lo: u32, hi: u32 }, @ptrCast(&self._rsvd0));
        return @truncate(param.lo >> 24);
    }
};

/// Host Controller Event TRB - Controller-level notifications
pub const HostControllerEventTrb = extern struct {
    _rsvd0: u64 = 0,
    status: packed struct(u32) {
        _rsvd: u24,
        completion_code: CompletionCode,
    },
    control: packed struct(u32) {
        cycle: bool,
        _rsvd0: u9,
        trb_type: TrbType,
        _rsvd1: u16,
    },

    pub fn fromTrb(trb: *const Trb) *const HostControllerEventTrb {
        return @ptrCast(trb);
    }
};

// =============================================================================
// Completion Codes
// =============================================================================

/// TRB Completion Codes
pub const CompletionCode = enum(u8) {
    Invalid = 0,
    Success = 1,
    DataBufferError = 2,
    BabbleDetectedError = 3,
    USBTransactionError = 4,
    TRBError = 5,
    StallError = 6,
    ResourceError = 7,
    BandwidthError = 8,
    NoSlotsAvailableError = 9,
    InvalidStreamTypeError = 10,
    SlotNotEnabledError = 11,
    EndpointNotEnabledError = 12,
    ShortPacket = 13,
    RingUnderrun = 14,
    RingOverrun = 15,
    VFEventRingFullError = 16,
    ParameterError = 17,
    BandwidthOverrunError = 18,
    ContextStateError = 19,
    NoPingResponseError = 20,
    EventRingFullError = 21,
    IncompatibleDeviceError = 22,
    MissedServiceError = 23,
    CommandRingStopped = 24,
    CommandAborted = 25,
    Stopped = 26,
    StoppedLengthInvalid = 27,
    StoppedShortPacket = 28,
    MaxExitLatencyTooLargeError = 29,
    IsochBufferOverrun = 31,
    EventLostError = 32,
    UndefinedError = 33,
    InvalidStreamIDError = 34,
    SecondaryBandwidthError = 35,
    SplitTransactionError = 36,
    _,

    pub fn isSuccess(self: CompletionCode) bool {
        return self == .Success;
    }

    pub fn isError(self: CompletionCode) bool {
        return @intFromEnum(self) >= 2 and @intFromEnum(self) != @intFromEnum(CompletionCode.ShortPacket);
    }
};

// =============================================================================
// Ring Management Types
// =============================================================================

/// Event Ring Segment Table Entry (16 bytes)
pub const ErstEntry = extern struct {
    ring_segment_base: u64, // Physical address of event ring segment (64-byte aligned)
    ring_segment_size: u16, // Number of TRBs in segment
    _rsvd0: u16 = 0,
    _rsvd1: u32 = 0,

    pub fn init(base_phys: u64, size: u16) ErstEntry {
        return .{
            .ring_segment_base = base_phys,
            .ring_segment_size = size,
            ._rsvd0 = 0,
            ._rsvd1 = 0,
        };
    }

    comptime {
        if (@sizeOf(ErstEntry) != 16) @compileError("ERST Entry must be 16 bytes");
    }
};

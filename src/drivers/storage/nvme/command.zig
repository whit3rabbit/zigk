// NVMe Command Builders
//
// Provides functions to build Admin and I/O (NVM) commands for NVMe controllers.
// Each builder function populates a SubmissionEntry with the appropriate opcode
// and command-specific fields.
//
// Reference: NVM Express Base Specification 2.0, Sections 5 (Admin) and 6 (NVM)

const std = @import("std");
const queue = @import("queue.zig");

const SubmissionEntry = queue.SubmissionEntry;
const VolatileSqe = *volatile SubmissionEntry;

// ============================================================================
// Admin Command Opcodes
// ============================================================================

pub const AdminOpcode = enum(u8) {
    delete_io_sq = 0x00,
    create_io_sq = 0x01,
    get_log_page = 0x02,
    delete_io_cq = 0x04,
    create_io_cq = 0x05,
    identify = 0x06,
    abort = 0x08,
    set_features = 0x09,
    get_features = 0x0A,
    async_event_request = 0x0C,
    namespace_management = 0x0D,
    firmware_commit = 0x10,
    firmware_download = 0x11,
    device_self_test = 0x14,
    namespace_attachment = 0x15,
    keep_alive = 0x18,
    directive_send = 0x19,
    directive_receive = 0x1A,
    virtualization_management = 0x1C,
    nvme_mi_send = 0x1D,
    nvme_mi_receive = 0x1E,
    doorbell_buffer_config = 0x7C,
    format_nvm = 0x80,
    security_send = 0x81,
    security_receive = 0x82,
    sanitize = 0x84,
    get_lba_status = 0x86,
};

// ============================================================================
// I/O (NVM) Command Opcodes
// ============================================================================

pub const IoOpcode = enum(u8) {
    flush = 0x00,
    write = 0x01,
    read = 0x02,
    write_uncorrectable = 0x04,
    compare = 0x05,
    write_zeros = 0x08,
    dataset_management = 0x09,
    verify = 0x0C,
    reservation_register = 0x0D,
    reservation_report = 0x0E,
    reservation_acquire = 0x11,
    reservation_release = 0x15,
    copy = 0x19,
};

// ============================================================================
// Identify CNS Values
// ============================================================================

pub const IdentifyCns = enum(u8) {
    namespace = 0x00,
    controller = 0x01,
    active_namespace_list = 0x02,
    namespace_id_descriptor_list = 0x03,
    nvmset_list = 0x04,
    io_command_set_namespace = 0x05,
    io_command_set_controller = 0x06,
    active_ns_list_iocs = 0x07,
    allocated_namespace_list = 0x10,
    identify_namespace_allocated = 0x11,
    controller_list_nsid = 0x12,
    controller_list = 0x13,
    primary_controller_capabilities = 0x14,
    secondary_controller_list = 0x15,
    namespace_granularity_list = 0x16,
    uuid_list = 0x17,
    domain_list = 0x18,
    endurance_group_list = 0x19,
    allocated_ns_list_iocs = 0x1A,
    identify_ns_allocated_iocs = 0x1B,
    io_command_set = 0x1C,
};

// ============================================================================
// Feature Identifiers
// ============================================================================

pub const FeatureId = enum(u8) {
    arbitration = 0x01,
    power_management = 0x02,
    lba_range_type = 0x03,
    temperature_threshold = 0x04,
    error_recovery = 0x05,
    volatile_write_cache = 0x06,
    number_of_queues = 0x07,
    interrupt_coalescing = 0x08,
    interrupt_vector_config = 0x09,
    write_atomicity_normal = 0x0A,
    async_event_config = 0x0B,
    autonomous_power_state_transition = 0x0C,
    host_memory_buffer = 0x0D,
    timestamp = 0x0E,
    keep_alive_timer = 0x0F,
    host_controlled_thermal = 0x10,
    non_operational_power_state = 0x11,
    read_recovery_level = 0x12,
    predictable_latency_mode = 0x13,
    predictable_latency_event = 0x14,
    lba_status_info_alerts = 0x15,
    host_behavior_support = 0x16,
    sanitize_config = 0x17,
    endurance_group_event = 0x18,
    software_progress_marker = 0x80,
    host_identifier = 0x81,
    reservation_notification_mask = 0x82,
    reservation_persistence = 0x83,
    namespace_write_protection = 0x84,
};

// ============================================================================
// Admin Command Builders
// ============================================================================

/// Build Identify Controller command (CNS = 0x01)
/// Returns controller information in a 4KB buffer
pub fn buildIdentifyController(entry: VolatileSqe, prp1: u64) void {
    entry.* = SubmissionEntry.init();
    entry.cdw0.opc = @intFromEnum(AdminOpcode.identify);
    entry.prp1 = prp1;
    entry.cdw10 = @intFromEnum(IdentifyCns.controller); // CNS = 01h
}

/// Build Identify Namespace command (CNS = 0x00)
/// Returns namespace information in a 4KB buffer
pub fn buildIdentifyNamespace(entry: VolatileSqe, nsid: u32, prp1: u64) void {
    entry.* = SubmissionEntry.init();
    entry.cdw0.opc = @intFromEnum(AdminOpcode.identify);
    entry.nsid = nsid;
    entry.prp1 = prp1;
    entry.cdw10 = @intFromEnum(IdentifyCns.namespace); // CNS = 00h
}

/// Build Identify Active Namespace List command (CNS = 0x02)
/// Returns list of active NSIDs greater than NSID in CDW1
pub fn buildIdentifyActiveNsList(entry: VolatileSqe, start_nsid: u32, prp1: u64) void {
    entry.* = SubmissionEntry.init();
    entry.cdw0.opc = @intFromEnum(AdminOpcode.identify);
    entry.nsid = start_nsid;
    entry.prp1 = prp1;
    entry.cdw10 = @intFromEnum(IdentifyCns.active_namespace_list); // CNS = 02h
}

/// Build Create I/O Completion Queue command
/// qid: Queue Identifier (1-65535)
/// size: Queue size (0-based, so actual entries = size + 1)
/// prp1: Physical address of queue (must be page-aligned)
/// iv: Interrupt Vector (for MSI-X)
/// ien: Interrupt Enable
/// pc: Physically Contiguous
pub fn buildCreateIoCq(
    entry: VolatileSqe,
    qid: u16,
    size: u16,
    prp1: u64,
    iv: u16,
    ien: bool,
    pc: bool,
) void {
    entry.* = SubmissionEntry.init();
    entry.cdw0.opc = @intFromEnum(AdminOpcode.create_io_cq);
    entry.prp1 = prp1;

    // CDW10: QSIZE (31:16) | QID (15:0)
    entry.cdw10 = (@as(u32, size) << 16) | @as(u32, qid);

    // CDW11: IV (31:16) | IEN (1) | PC (0)
    entry.cdw11 = (@as(u32, iv) << 16) |
        (@as(u32, @intFromBool(ien)) << 1) |
        @as(u32, @intFromBool(pc));
}

/// Build Create I/O Submission Queue command
/// qid: Queue Identifier (1-65535)
/// size: Queue size (0-based, so actual entries = size + 1)
/// prp1: Physical address of queue (must be page-aligned)
/// cqid: Associated Completion Queue ID
/// qprio: Queue Priority (0=Urgent, 1=High, 2=Medium, 3=Low)
/// pc: Physically Contiguous
pub fn buildCreateIoSq(
    entry: VolatileSqe,
    qid: u16,
    size: u16,
    prp1: u64,
    cqid: u16,
    qprio: u2,
    pc: bool,
) void {
    entry.* = SubmissionEntry.init();
    entry.cdw0.opc = @intFromEnum(AdminOpcode.create_io_sq);
    entry.prp1 = prp1;

    // CDW10: QSIZE (31:16) | QID (15:0)
    entry.cdw10 = (@as(u32, size) << 16) | @as(u32, qid);

    // CDW11: CQID (31:16) | QPRIO (2:1) | PC (0)
    entry.cdw11 = (@as(u32, cqid) << 16) |
        (@as(u32, qprio) << 1) |
        @as(u32, @intFromBool(pc));
}

/// Build Delete I/O Submission Queue command
pub fn buildDeleteIoSq(entry: VolatileSqe, qid: u16) void {
    entry.* = SubmissionEntry.init();
    entry.cdw0.opc = @intFromEnum(AdminOpcode.delete_io_sq);
    entry.cdw10 = @as(u32, qid);
}

/// Build Delete I/O Completion Queue command
pub fn buildDeleteIoCq(entry: VolatileSqe, qid: u16) void {
    entry.* = SubmissionEntry.init();
    entry.cdw0.opc = @intFromEnum(AdminOpcode.delete_io_cq);
    entry.cdw10 = @as(u32, qid);
}

/// Build Set Features command
pub fn buildSetFeatures(
    entry: VolatileSqe,
    fid: FeatureId,
    cdw11: u32,
    save: bool,
) void {
    entry.* = SubmissionEntry.init();
    entry.cdw0.opc = @intFromEnum(AdminOpcode.set_features);
    // CDW10: SV (31) | FID (7:0)
    entry.cdw10 = (@as(u32, @intFromBool(save)) << 31) | @as(u32, @intFromEnum(fid));
    entry.cdw11 = cdw11;
}

/// Build Get Features command
pub fn buildGetFeatures(
    entry: VolatileSqe,
    fid: FeatureId,
    sel: u3,
) void {
    entry.* = SubmissionEntry.init();
    entry.cdw0.opc = @intFromEnum(AdminOpcode.get_features);
    // CDW10: SEL (10:8) | FID (7:0)
    entry.cdw10 = (@as(u32, sel) << 8) | @as(u32, @intFromEnum(fid));
}

/// Build Set Number of Queues feature command
/// Returns the actual number of queues allocated by controller in completion DW0
pub fn buildSetNumQueues(entry: VolatileSqe, nsqa: u16, ncqa: u16) void {
    entry.* = SubmissionEntry.init();
    entry.cdw0.opc = @intFromEnum(AdminOpcode.set_features);
    entry.cdw10 = @intFromEnum(FeatureId.number_of_queues);
    // CDW11: NCQA (31:16) | NSQA (15:0), both 0-based
    entry.cdw11 = (@as(u32, ncqa) << 16) | @as(u32, nsqa);
}

/// Build Abort command
pub fn buildAbort(entry: VolatileSqe, sqid: u16, cid: u16) void {
    entry.* = SubmissionEntry.init();
    entry.cdw0.opc = @intFromEnum(AdminOpcode.abort);
    // CDW10: CID (31:16) | SQID (15:0)
    entry.cdw10 = (@as(u32, cid) << 16) | @as(u32, sqid);
}

// ============================================================================
// I/O (NVM) Command Builders
// ============================================================================

/// Build Read command
/// nsid: Namespace ID
/// slba: Starting LBA
/// nlb: Number of Logical Blocks (0-based, so actual = nlb + 1)
/// prp1: First PRP entry (physical address of first data page)
/// prp2: Second PRP entry or PRP list (physical address)
pub fn buildRead(
    entry: VolatileSqe,
    nsid: u32,
    slba: u64,
    nlb: u16,
    prp1: u64,
    prp2: u64,
) void {
    entry.* = SubmissionEntry.init();
    entry.cdw0.opc = @intFromEnum(IoOpcode.read);
    entry.nsid = nsid;
    entry.prp1 = prp1;
    entry.prp2 = prp2;
    // CDW10: SLBA lower 32 bits
    entry.cdw10 = @truncate(slba);
    // CDW11: SLBA upper 32 bits
    entry.cdw11 = @truncate(slba >> 32);
    // CDW12: NLB (15:0), 0-based
    entry.cdw12 = @as(u32, nlb);
}

/// Build Write command
/// nsid: Namespace ID
/// slba: Starting LBA
/// nlb: Number of Logical Blocks (0-based, so actual = nlb + 1)
/// prp1: First PRP entry (physical address of first data page)
/// prp2: Second PRP entry or PRP list (physical address)
pub fn buildWrite(
    entry: VolatileSqe,
    nsid: u32,
    slba: u64,
    nlb: u16,
    prp1: u64,
    prp2: u64,
) void {
    entry.* = SubmissionEntry.init();
    entry.cdw0.opc = @intFromEnum(IoOpcode.write);
    entry.nsid = nsid;
    entry.prp1 = prp1;
    entry.prp2 = prp2;
    // CDW10: SLBA lower 32 bits
    entry.cdw10 = @truncate(slba);
    // CDW11: SLBA upper 32 bits
    entry.cdw11 = @truncate(slba >> 32);
    // CDW12: NLB (15:0), 0-based
    entry.cdw12 = @as(u32, nlb);
}

/// Build Flush command
/// Commits data and metadata to non-volatile media
pub fn buildFlush(entry: VolatileSqe, nsid: u32) void {
    entry.* = SubmissionEntry.init();
    entry.cdw0.opc = @intFromEnum(IoOpcode.flush);
    entry.nsid = nsid;
}

/// Build Write Zeros command
/// Deallocates LBAs (like TRIM) by setting them to zeros
pub fn buildWriteZeros(
    entry: VolatileSqe,
    nsid: u32,
    slba: u64,
    nlb: u16,
    deac: bool,
) void {
    entry.* = SubmissionEntry.init();
    entry.cdw0.opc = @intFromEnum(IoOpcode.write_zeros);
    entry.nsid = nsid;
    entry.cdw10 = @truncate(slba);
    entry.cdw11 = @truncate(slba >> 32);
    // CDW12: DEAC (25) | NLB (15:0)
    entry.cdw12 = (@as(u32, @intFromBool(deac)) << 25) | @as(u32, nlb);
}

/// Build Dataset Management command (TRIM/Deallocate)
/// range_count: Number of ranges (0-based, so actual = range_count + 1)
/// prp1: Physical address of range buffer
/// ad: Attribute - Deallocate
pub fn buildDatasetManagement(
    entry: VolatileSqe,
    nsid: u32,
    range_count: u8,
    prp1: u64,
    ad: bool,
) void {
    entry.* = SubmissionEntry.init();
    entry.cdw0.opc = @intFromEnum(IoOpcode.dataset_management);
    entry.nsid = nsid;
    entry.prp1 = prp1;
    // CDW10: NR (7:0), 0-based
    entry.cdw10 = @as(u32, range_count);
    // CDW11: AD (2)
    entry.cdw11 = @as(u32, @intFromBool(ad)) << 2;
}

/// Dataset Management Range structure (16 bytes)
pub const DsmRange = extern struct {
    /// Context Attributes
    cattr: u32,
    /// Length in Logical Blocks
    nlb: u32,
    /// Starting LBA
    slba: u64,

    pub fn init(slba: u64, nlb: u32) DsmRange {
        return DsmRange{
            .cattr = 0,
            .nlb = nlb,
            .slba = slba,
        };
    }
};

comptime {
    if (@sizeOf(DsmRange) != 16) {
        @compileError("DsmRange must be exactly 16 bytes");
    }
}

// ============================================================================
// Command ID Tracking
// ============================================================================

/// Simple atomic command ID allocator
/// For production, each queue should have its own CID space
var global_cid: std.atomic.Value(u16) = std.atomic.Value(u16).init(0);

/// Allocate a unique command ID
pub fn allocCommandId() u16 {
    return global_cid.fetchAdd(1, .monotonic);
}

/// Reset command ID counter (for testing)
pub fn resetCommandIdCounter() void {
    global_cid.store(0, .monotonic);
}

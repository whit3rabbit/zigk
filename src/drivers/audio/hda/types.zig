// Intel HDA Driver Types

const std = @import("std");
const sync = @import("sync");

/// CORB Entry (command) - 32 bits
pub const CorbEntry = packed struct {
    payload: u32,

    pub fn init(codec: u4, node: u8, verb: u20) CorbEntry {
        return CorbEntry{
            .payload = (@as(u32, codec) << 28) | (@as(u32, node) << 20) | verb,
        };
    }
};

/// RIRB Entry (response) - 64 bits
pub const RirbEntry = packed struct {
    payload: u32,
    response_ex: u32, // Codec, unsolicited flag, etc.

    pub fn getResponse(self: RirbEntry) u32 {
        return self.payload;
    }
};

/// Buffer Descriptor List (BDL) Entry - 128 bits (16 bytes)
pub const BdlEntry = extern struct {
    addr_low: u32,
    addr_high: u32,
    length: u32,
    flags: u32, // Bit 0: IOC (Interrupt On Completion)

    pub fn init(phys_addr: u64, len: u32, ioc: bool) BdlEntry {
        return BdlEntry{
            .addr_low = @truncate(phys_addr),
            .addr_high = @truncate(phys_addr >> 32),
            .length = len,
            .flags = if (ioc) 1 else 0,
        };
    }
};

/// HDA Driver Instance
pub const Hda = struct {
    // Memory Mapped Registers
    mmio_base: u64,
    mmio_size: u64,

    // CORB/RIRB Ring Buffers
    corb_phys: u64,
    corb_virt: [*]volatile u32,
    corb_entries: u16,
    
    rirb_phys: u64,
    rirb_virt: [*]volatile RirbEntry,
    rirb_entries: u16,

    // State
    codecs_found: u16, // Bitmask of detected codecs
    irq_line: u8,
    
    // Lock for command submission (CORB/RIRB access)
    lock: sync.Spinlock,
};

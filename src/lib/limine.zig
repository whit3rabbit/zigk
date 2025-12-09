// Minimal Limine Boot Protocol Bindings for Zig 0.15.x
//
// This is a local implementation of essential Limine protocol structures.
// Created because the upstream limine-zig uses `usingnamespace` which was
// removed in Zig 0.15.x.
//
// Reference: https://github.com/limine-bootloader/limine/blob/trunk/PROTOCOL.md
//
// IMPORTANT: When declaring request variables in kernel code, use:
//   pub export var my_request linksection(".limine_requests") = limine.SomeRequest{};
// This ensures Limine can find and patch the response pointers.

// Magic numbers for request identification
fn id(a: u64, b: u64) [4]u64 {
    return .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, a, b };
}

// Base Revision - required for protocol compatibility check
// Limine sets magic[0] to 0 if revision is supported
pub const BaseRevision = extern struct {
    magic: [2]u64 = .{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc },
    revision: u64,

    pub fn is_supported(self: *const BaseRevision) bool {
        return self.magic[0] == 0;
    }
};

// Framebuffer Request and Response
pub const FramebufferRequest = extern struct {
    id: [4]u64 = id(0x9d5827dcd881dd75, 0xa3148604f6fab11b),
    revision: u64 = 0,
    response: ?*FramebufferResponse = null,
};

pub const FramebufferResponse = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers_ptr: [*]*Framebuffer,

    pub fn framebuffers(self: *const FramebufferResponse) []*Framebuffer {
        return self.framebuffers_ptr[0..self.framebuffer_count];
    }
};

pub const Framebuffer = extern struct {
    address: u64,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    unused: [7]u8,
    edid_size: u64,
    edid: u64,
    // Video mode count and modes (revision 1+)
    mode_count: u64,
    modes: u64,
};

// HHDM (Higher Half Direct Map) Request and Response
pub const HhdmRequest = extern struct {
    id: [4]u64 = id(0x48dcf1cb8ad2b852, 0x63984e959a98244b),
    revision: u64 = 0,
    response: ?*HhdmResponse = null,
};

pub const HhdmResponse = extern struct {
    revision: u64,
    offset: u64,
};

// Memory Map Request and Response
pub const MemoryMapRequest = extern struct {
    id: [4]u64 = id(0x67cf3d9d378a806f, 0xe304acdfc50c3c62),
    revision: u64 = 0,
    response: ?*MemoryMapResponse = null,
};

pub const MemoryMapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries_ptr: [*]*MemoryMapEntry,

    pub fn entries(self: *const MemoryMapResponse) []*MemoryMapEntry {
        return self.entries_ptr[0..self.entry_count];
    }
};

pub const MemoryMapEntry = extern struct {
    base: u64,
    length: u64,
    kind: MemoryKind,
};

pub const MemoryKind = enum(u64) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad_memory = 4,
    bootloader_reclaimable = 5,
    kernel_and_modules = 6,
    framebuffer = 7,
};

// Module Request and Response (for InitRD)
pub const ModuleRequest = extern struct {
    id: [4]u64 = id(0x3e7e279702be32af, 0xca1c4f3bd1280cee),
    revision: u64 = 0,
    response: ?*ModuleResponse = null,
    // Internal modules (revision 1+)
    internal_module_count: u64 = 0,
    internal_modules: ?[*]*InternalModule = null,
};

pub const ModuleResponse = extern struct {
    revision: u64,
    module_count: u64,
    modules_ptr: [*]*Module,

    pub fn modules(self: *const ModuleResponse) []*Module {
        return self.modules_ptr[0..self.module_count];
    }
};

pub const Module = extern struct {
    address: u64,
    size: u64,
    path: [*:0]const u8,
    cmdline: [*:0]const u8,
    media_type: u32,
    _unused: u32,
    tftp_ip: u32,
    tftp_port: u32,
    partition_index: u32,
    mbr_disk_id: u32,
    gpt_disk_uuid: Uuid,
    gpt_part_uuid: Uuid,
    part_uuid: Uuid,
};

pub const InternalModule = extern struct {
    path: [*:0]const u8,
    cmdline: [*:0]const u8,
    flags: u64,
};

pub const Uuid = extern struct {
    a: u32,
    b: u16,
    c: u16,
    d: [8]u8,
};

// Kernel Address Request (for getting kernel physical/virtual addresses)
pub const KernelAddressRequest = extern struct {
    id: [4]u64 = id(0x71ba76863cc55f63, 0xb2644a48c516a487),
    revision: u64 = 0,
    response: ?*KernelAddressResponse = null,
};

pub const KernelAddressResponse = extern struct {
    revision: u64,
    physical_base: u64,
    virtual_base: u64,
};

// Stack Size Request
pub const StackSizeRequest = extern struct {
    id: [4]u64 = id(0x224ef0460a8e8926, 0xe1cb0fc25f46ea3d),
    revision: u64 = 0,
    response: ?*StackSizeResponse = null,
    stack_size: u64,
};

pub const StackSizeResponse = extern struct {
    revision: u64,
};

// Entry Point Request - allows specifying a custom entry point
pub const EntryPointRequest = extern struct {
    id: [4]u64 = id(0x13d86c035a1cd3e1, 0x2b0caa89d8f3026a),
    revision: u64 = 0,
    response: ?*EntryPointResponse = null,
    entry: ?*const fn () callconv(.C) noreturn = null,
};

pub const EntryPointResponse = extern struct {
    revision: u64,
};

// Global Descriptor Table (GDT) and Task State Segment (TSS)
//
// x86_64 Long Mode GDT setup with TSS for kernel/user transitions.
//
// Segment Layout:
//   0x00: Null descriptor (required)
//   0x08: Kernel code (DPL 0, long mode)
//   0x10: Kernel data (DPL 0)
//   0x18: User data (DPL 3) - must come before user code
//   0x20: User code (DPL 3, long mode)
//   0x28: TSS descriptor (16 bytes, spans two slots)
//
// TSS provides:
//   - RSP0: Kernel stack pointer for privilege level transitions
//   - IST[1-7]: Interrupt Stack Table for specific interrupts (e.g., double fault)

const cpu = @import("cpu.zig");

// Segment selectors (byte offsets into GDT)
pub const KERNEL_CODE: u16 = 0x08;
pub const KERNEL_DATA: u16 = 0x10;
pub const USER_DATA: u16 = 0x18 | 3; // RPL = 3
pub const USER_CODE: u16 = 0x20 | 3; // RPL = 3
pub const TSS_SELECTOR: u16 = 0x28;

// GDT Entry (8 bytes) for code/data segments
// In long mode, most fields are ignored except for:
// - Present, DPL, Type, L (long mode), D (default operand size)
pub const GdtEntry = packed struct(u64) {
    limit_low: u16 = 0,
    base_low: u16 = 0,
    base_mid: u8 = 0,
    access: u8 = 0,
    flags_limit_high: u8 = 0,
    base_high: u8 = 0,

    const Self = @This();

    /// Create a null/empty descriptor
    pub fn empty() Self {
        return .{};
    }

    /// Create a code segment descriptor
    /// For long mode: L=1, D=0
    pub fn codeSegment(dpl: u2) Self {
        return .{
            .limit_low = 0xFFFF,
            .base_low = 0,
            .base_mid = 0,
            // Access byte: P=1, DPL, S=1 (code/data), E=1 (executable), RW=1 (readable)
            .access = 0x9A | (@as(u8, dpl) << 5),
            // Flags: G=1 (4KB granularity), L=1 (long mode), D=0
            // Limit high: 0xF
            .flags_limit_high = 0xAF,
            .base_high = 0,
        };
    }

    /// Create a data segment descriptor
    pub fn dataSegment(dpl: u2) Self {
        return .{
            .limit_low = 0xFFFF,
            .base_low = 0,
            .base_mid = 0,
            // Access byte: P=1, DPL, S=1 (code/data), E=0 (data), RW=1 (writable)
            .access = 0x92 | (@as(u8, dpl) << 5),
            // Flags: G=1, D/B=1 (32-bit stack), L=0
            .flags_limit_high = 0xCF,
            .base_high = 0,
        };
    }

    // Compile-time verification of struct size for hardware compatibility
    comptime {
        if (@sizeOf(Self) != 8) @compileError("GdtEntry must be exactly 8 bytes");
    }
};

// TSS Descriptor (16 bytes, spans two GDT slots)
// In long mode, TSS descriptor is 16 bytes instead of 8
pub const TssDescriptor = packed struct(u128) {
    limit_low: u16,
    base_low: u16,
    base_mid_low: u8,
    access: u8,
    flags_limit_high: u8,
    base_mid_high: u8,
    base_high: u32,
    reserved: u32 = 0,

    const Self = @This();

    /// Create a TSS descriptor from base address
    pub fn fromBase(base: u64, limit: u16) Self {
        // TSS limit is small (< 256 bytes), so high bits are always 0
        // flags_limit_high: low 4 bits = limit[16:19], high 4 bits = flags
        const limit_high: u8 = @truncate(@as(u32, limit) >> 16);
        return .{
            .limit_low = limit,
            .base_low = @truncate(base),
            .base_mid_low = @truncate(base >> 16),
            // Access: P=1, DPL=0, Type=0x9 (64-bit TSS available)
            .access = 0x89,
            // Flags: G=0 (byte granularity), limit high bits (typically 0 for small TSS)
            .flags_limit_high = limit_high,
            .base_mid_high = @truncate(base >> 24),
            .base_high = @truncate(base >> 32),
            .reserved = 0,
        };
    }

    // Compile-time verification of struct size for hardware compatibility
    comptime {
        if (@sizeOf(Self) != 16) @compileError("TssDescriptor must be exactly 16 bytes");
    }
};

// Task State Segment (TSS) structure for x86_64
// Size: 104 bytes (matches Intel SDM Table 7-2)
// Uses align(1) on all fields to match hardware layout without C ABI padding
pub const Tss = extern struct {
    reserved0: u32 align(1) = 0,
    // RSP values for privilege level transitions (ring 3 -> ring 0, etc.)
    rsp0: u64 align(1) = 0, // Kernel stack pointer (used on syscall/interrupt from ring 3)
    rsp1: u64 align(1) = 0,
    rsp2: u64 align(1) = 0,
    reserved1: u64 align(1) = 0,
    // Interrupt Stack Table (IST) - separate stacks for specific interrupts
    // IST[0] is unused (index 1-7 in hardware)
    ist1: u64 align(1) = 0, // Double fault stack
    ist2: u64 align(1) = 0,
    ist3: u64 align(1) = 0,
    ist4: u64 align(1) = 0,
    ist5: u64 align(1) = 0,
    ist6: u64 align(1) = 0,
    ist7: u64 align(1) = 0,
    reserved2: u64 align(1) = 0,
    reserved3: u16 align(1) = 0,
    iopb_offset: u16 align(1) = 104, // I/O permission bitmap offset (points past TSS = no IOPB)

    // Compile-time verification of struct size and field offsets for hardware compatibility
    comptime {
        if (@sizeOf(Tss) != 104) @compileError("Tss must be exactly 104 bytes");
        if (@offsetOf(Tss, "rsp0") != 4) @compileError("rsp0 must be at offset 4");
        if (@offsetOf(Tss, "iopb_offset") != 102) @compileError("iopb_offset must be at offset 102");
    }
};

// GDT structure with all entries
const GDT_ENTRIES = 7; // null + kernel code + kernel data + user data + user code + TSS (2 slots)

pub const Gdt = extern struct {
    null_desc: GdtEntry align(8) = GdtEntry.empty(),
    kernel_code: GdtEntry = GdtEntry.codeSegment(0),
    kernel_data: GdtEntry = GdtEntry.dataSegment(0),
    user_data: GdtEntry = GdtEntry.dataSegment(3),
    user_code: GdtEntry = GdtEntry.codeSegment(3),
    tss_low: u64 = 0, // TSS descriptor low 8 bytes
    tss_high: u64 = 0, // TSS descriptor high 8 bytes

    // Compile-time verification of struct size and alignment
    comptime {
        // 5 GdtEntry (8 bytes each) + 2 u64 (8 bytes each) = 56 bytes
        if (@sizeOf(Gdt) != 56) @compileError("Gdt must be exactly 56 bytes");
        if (@alignOf(Gdt) < 8) @compileError("Gdt must be at least 8-byte aligned");
    }
};

// GDT pointer structure for LGDT instruction
const GdtPtr = packed struct(u80) {
    limit: u16,
    base: u64,
};

// Static GDT and TSS instances
var gdt: Gdt = .{};
var tss: Tss = .{};

// Stacks for IST entries
var double_fault_stack: [4096]u8 align(16) = undefined;

/// Initialize GDT and TSS
pub fn init() void {
    // Set up TSS
    // RSP0 will be set later when we have a proper kernel stack
    tss.rsp0 = 0;

    // Set up IST1 for double fault handler (uses separate stack)
    // Stack grows downward, so point to end of array
    const df_stack_top = @intFromPtr(&double_fault_stack) + double_fault_stack.len;
    tss.ist1 = df_stack_top;

    // Create TSS descriptor
    const tss_base = @intFromPtr(&tss);
    const tss_desc = TssDescriptor.fromBase(tss_base, @sizeOf(Tss) - 1);

    // Split TSS descriptor into two 64-bit parts
    const tss_bytes: u128 = @bitCast(tss_desc);
    gdt.tss_low = @truncate(tss_bytes);
    gdt.tss_high = @truncate(tss_bytes >> 64);

    // Load GDT
    const gdt_ptr = GdtPtr{
        .limit = @sizeOf(Gdt) - 1,
        .base = @intFromPtr(&gdt),
    };

    loadGdt(&gdt_ptr);

    // Reload segment registers with new selectors
    reloadSegments();

    // Load TSS
    loadTss(TSS_SELECTOR);
}

/// Set the kernel stack pointer (RSP0) in TSS
/// Called when switching to a thread to set up the kernel stack for syscalls
pub fn setKernelStack(stack_top: u64) void {
    tss.rsp0 = stack_top;
}

/// Get current kernel stack pointer from TSS
pub fn getKernelStack() u64 {
    return tss.rsp0;
}

// Assembly helper defined in asm_helpers.S
extern fn _asm_lgdt(ptr: *const GdtPtr) void;

/// Load GDT using LGDT instruction
fn loadGdt(gdt_ptr: *const GdtPtr) void {
    _asm_lgdt(gdt_ptr);
}

/// Reload segment registers after loading new GDT
/// Sets data segment selectors. CS is set by Bootloader and remains valid.
/// In long mode, segment bases are ignored (except FS/GS), only DPL matters.
fn reloadSegments() void {
    // Bootloader already set CS to a valid kernel code segment
    // We just need to reload data segment registers
    asm volatile (
        \\mov %[ds], %%ds
        \\mov %[ds], %%es
        \\mov %[ds], %%ss
        \\xor %%eax, %%eax
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        :
        : [ds] "r" (@as(u16, KERNEL_DATA)),
        : .{ .rax = true }
    );
}

/// Load TSS using LTR instruction
fn loadTss(selector: u16) void {
    asm volatile ("ltr %[sel]"
        :
        : [sel] "r" (selector),
    );
}

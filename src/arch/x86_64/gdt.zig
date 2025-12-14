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

// =============================================================================
// GDT Access Byte and Flags Packed Structs
// =============================================================================
// Type-safe bitfield representations for GDT descriptor fields.
// Reference: Intel SDM Vol 3A, Section 3.4.5 "Segment Descriptors"

/// GDT Access Byte bit layout (bits 40-47 of GDT entry)
/// Replaces magic numbers like 0x9A, 0x92, 0x89 with self-documenting fields.
pub const AccessByte = packed struct(u8) {
    accessed: bool = false,         // Bit 0: Accessed (set by CPU)
    rw: bool = false,               // Bit 1: Readable (code) / Writable (data)
    dc: bool = false,               // Bit 2: Direction (data: 0=up) / Conforming (code: 0=non-conforming)
    executable: bool = false,       // Bit 3: 1=code segment, 0=data segment
    descriptor_type: bool = false,  // Bit 4: 1=code/data, 0=system (TSS, LDT, etc.)
    dpl: u2 = 0,                    // Bits 5-6: Descriptor Privilege Level (0=kernel, 3=user)
    present: bool = false,          // Bit 7: Segment present in memory

    /// Kernel code segment: Present, DPL=0, Code/Data, Executable, Readable
    /// Raw value: 0x9A = 0b10011010
    pub fn kernelCode() AccessByte {
        return .{
            .present = true,
            .dpl = 0,
            .descriptor_type = true,  // Code/data segment
            .executable = true,       // Code segment
            .rw = true,               // Readable
            .dc = false,              // Non-conforming
            .accessed = false,
        };
    }

    /// User code segment: Present, DPL=3, Code/Data, Executable, Readable
    /// Raw value: 0xFA = 0b11111010
    pub fn userCode() AccessByte {
        return .{
            .present = true,
            .dpl = 3,
            .descriptor_type = true,
            .executable = true,
            .rw = true,
            .dc = false,
            .accessed = false,
        };
    }

    /// Kernel data segment: Present, DPL=0, Code/Data, Data, Writable
    /// Raw value: 0x92 = 0b10010010
    pub fn kernelData() AccessByte {
        return .{
            .present = true,
            .dpl = 0,
            .descriptor_type = true,
            .executable = false,      // Data segment
            .rw = true,               // Writable
            .dc = false,              // Grows up
            .accessed = false,
        };
    }

    /// User data segment: Present, DPL=3, Code/Data, Data, Writable
    /// Raw value: 0xF2 = 0b11110010
    pub fn userData() AccessByte {
        return .{
            .present = true,
            .dpl = 3,
            .descriptor_type = true,
            .executable = false,
            .rw = true,
            .dc = false,
            .accessed = false,
        };
    }

    /// TSS descriptor: Present, DPL=0, System, Type=0x9 (64-bit TSS available)
    /// Raw value: 0x89 = 0b10001001
    pub fn tssDescriptor() AccessByte {
        return .{
            .present = true,
            .dpl = 0,
            .descriptor_type = false, // System descriptor
            .executable = true,       // Type bit 3 = 1 (part of 0x9 = 1001)
            .rw = false,              // Type bit 1 = 0
            .dc = false,              // Type bit 2 = 0
            .accessed = true,         // Type bit 0 = 1
        };
    }

    pub fn toRaw(self: AccessByte) u8 {
        return @bitCast(self);
    }

    pub fn withDpl(self: AccessByte, dpl: u2) AccessByte {
        var result = self;
        result.dpl = dpl;
        return result;
    }

    // Comptime verification that our factories produce correct values
    comptime {
        if (kernelCode().toRaw() != 0x9A) {
            @compileError("AccessByte.kernelCode() must produce 0x9A");
        }
        if (kernelData().toRaw() != 0x92) {
            @compileError("AccessByte.kernelData() must produce 0x92");
        }
        if (userCode().toRaw() != 0xFA) {
            @compileError("AccessByte.userCode() must produce 0xFA");
        }
        if (userData().toRaw() != 0xF2) {
            @compileError("AccessByte.userData() must produce 0xF2");
        }
        if (tssDescriptor().toRaw() != 0x89) {
            @compileError("AccessByte.tssDescriptor() must produce 0x89");
        }
    }
};

/// GDT Flags and Limit High nibble (bits 48-55 of GDT entry)
/// Lower 4 bits: limit[19:16], Upper 4 bits: flags
pub const FlagsLimitHigh = packed struct(u8) {
    limit_high: u4 = 0,             // Bits 0-3: limit[19:16]
    available: bool = false,        // Bit 4: Available for software use
    long_mode: bool = false,        // Bit 5: L - 64-bit code segment (must be 1 for long mode code)
    db: bool = false,               // Bit 6: D/B - Default operand size (0 for long mode code)
    granularity: bool = false,      // Bit 7: G - Granularity (1=4KB, 0=1 byte)

    /// Long mode code segment: G=1, L=1, D=0, limit_high=0xF
    /// Raw value: 0xAF = 0b10101111
    pub fn longModeCode() FlagsLimitHigh {
        return .{
            .limit_high = 0xF,
            .available = false,
            .long_mode = true,        // 64-bit code
            .db = false,              // Must be 0 for long mode
            .granularity = true,      // 4KB granularity
        };
    }

    /// Data segment: G=1, D/B=1, L=0, limit_high=0xF
    /// Raw value: 0xCF = 0b11001111
    pub fn dataSegment() FlagsLimitHigh {
        return .{
            .limit_high = 0xF,
            .available = false,
            .long_mode = false,
            .db = true,               // 32-bit stack operations
            .granularity = true,
        };
    }

    pub fn toRaw(self: FlagsLimitHigh) u8 {
        return @bitCast(self);
    }

    // Comptime verification
    comptime {
        if (longModeCode().toRaw() != 0xAF) {
            @compileError("FlagsLimitHigh.longModeCode() must produce 0xAF");
        }
        if (dataSegment().toRaw() != 0xCF) {
            @compileError("FlagsLimitHigh.dataSegment() must produce 0xCF");
        }
    }
};

// =============================================================================
// GDT Entry Structure
// =============================================================================

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
            .access = AccessByte.kernelCode().withDpl(dpl).toRaw(),
            .flags_limit_high = FlagsLimitHigh.longModeCode().toRaw(),
            .base_high = 0,
        };
    }

    /// Create a data segment descriptor
    pub fn dataSegment(dpl: u2) Self {
        return .{
            .limit_low = 0xFFFF,
            .base_low = 0,
            .base_mid = 0,
            .access = AccessByte.kernelData().withDpl(dpl).toRaw(),
            .flags_limit_high = FlagsLimitHigh.dataSegment().toRaw(),
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
        // flags_limit_high: low 4 bits = limit[16:19], high 4 bits = flags (G=0)
        const limit_high: u8 = @truncate(@as(u32, limit) >> 16);
        return .{
            .limit_low = limit,
            .base_low = @truncate(base),
            .base_mid_low = @truncate(base >> 16),
            .access = AccessByte.tssDescriptor().toRaw(),
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
var tss_instance: Tss = .{};

// Stacks for IST entries
var double_fault_stack: [4096]u8 align(16) = undefined;

/// Initialize GDT and TSS
pub fn init() void {
    // Set up TSS
    // RSP0 will be set later when we have a proper kernel stack
    tss_instance.rsp0 = 0;

    // Set up IST1 for double fault handler (uses separate stack)
    // Stack grows downward, so point to end of array
    const df_stack_top = @intFromPtr(&double_fault_stack) + double_fault_stack.len;
    tss_instance.ist1 = df_stack_top;

    // Create TSS descriptor
    const tss_base = @intFromPtr(&tss_instance);
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
    tss_instance.rsp0 = stack_top;
}

/// Get current kernel stack pointer from TSS
pub fn getKernelStack() u64 {
    return tss_instance.rsp0;
}

/// Reload GDT and segment registers (for AP boot)
/// Uses the already-initialized GDT from BSP
pub fn reload() void {
    const gdt_ptr = GdtPtr{
        .limit = @sizeOf(Gdt) - 1,
        .base = @intFromPtr(&gdt),
    };
    loadGdt(&gdt_ptr);
    reloadSegments();
    loadTss(TSS_SELECTOR);
}

// Assembly helper defined in asm_helpers.S
extern fn _asm_lgdt(ptr: *const GdtPtr) void;

/// Load GDT using LGDT instruction
fn loadGdt(gdt_ptr: *const GdtPtr) void {
    _asm_lgdt(gdt_ptr);
}

/// Reload segment registers after loading new GDT
/// Must reload CS via far return since MOV to CS is not allowed in long mode.
/// Limine's GDT layout differs from ours, so we MUST reload CS.
fn reloadSegments() void {
    // Reload CS using a far return (push new CS:RIP, then retfq)
    // This is required because Limine's GDT has different layout
    asm volatile (
        // Push new SS and reload data segments
        \\mov %[ds], %%ds
        \\mov %[ds], %%es
        \\mov %[ds], %%ss
        \\xor %%eax, %%eax
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        // Reload CS via far return: push CS, push RIP, retfq
        \\pushq %[cs]
        \\lea 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        :
        : [ds] "r" (@as(u16, KERNEL_DATA)),
          [cs] "r" (@as(u64, KERNEL_CODE)),
        : .{ .rax = true, .memory = true }
    );
}

/// Load TSS using LTR instruction
fn loadTss(selector: u16) void {
    asm volatile ("ltr %[sel]"
        :
        : [sel] "r" (selector),
    );
}

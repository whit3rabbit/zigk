// FPU/SSE State Management for x86_64
// HAL layer - only place where FPU state access is permitted
//
// Provides FXSAVE/FXRSTOR operations for saving and restoring
// floating-point and SIMD state during context switches.
// The kernel itself runs with SSE/MMX disabled, but we preserve
// state for userland threads that may use these features.

const cpu = @import("cpu.zig");

/// FXSAVE area size - Intel requires 512 bytes, 16-byte aligned
pub const FXSAVE_SIZE: usize = 512;

/// Alignment requirement for FXSAVE area
pub const FXSAVE_ALIGN: usize = 16;

/// FPU State structure - matches FXSAVE/FXRSTOR layout
/// Must be 16-byte aligned per Intel specification
pub const FpuState = struct {
    /// Raw FXSAVE area - 512 bytes, contains:
    /// - Bytes 0-1: FCW (FPU Control Word)
    /// - Bytes 2-3: FSW (FPU Status Word)
    /// - Bytes 4: FTW (FPU Tag Word, abridged)
    /// - Byte 5: Reserved
    /// - Bytes 6-7: FOP (FPU Opcode)
    /// - Bytes 8-15: FIP (FPU Instruction Pointer)
    /// - Bytes 16-23: FDP (FPU Data Pointer)
    /// - Bytes 24-27: MXCSR
    /// - Bytes 28-31: MXCSR_MASK
    /// - Bytes 32-159: ST0-ST7 (FPU registers, 16 bytes each)
    /// - Bytes 160-415: XMM0-XMM15 (SSE registers, 16 bytes each)
    /// - Bytes 416-511: Reserved
    data: [FXSAVE_SIZE]u8 align(FXSAVE_ALIGN) = [_]u8{0} ** FXSAVE_SIZE,

    /// Create a new FPU state initialized to default values
    pub fn init() FpuState {
        var state = FpuState{};
        // Initialize MXCSR to default value (0x1F80)
        // This masks all SIMD floating-point exceptions
        state.setMxcsr(0x1F80);
        // Initialize FCW to default value (0x037F)
        // This masks all x87 floating-point exceptions
        state.setFcw(0x037F);
        return state;
    }

    /// Get MXCSR value from saved state
    pub fn getMxcsr(self: *const FpuState) u32 {
        const bytes = self.data[24..28];
        return @as(u32, bytes[0]) |
            (@as(u32, bytes[1]) << 8) |
            (@as(u32, bytes[2]) << 16) |
            (@as(u32, bytes[3]) << 24);
    }

    /// Set MXCSR value in saved state
    pub fn setMxcsr(self: *FpuState, value: u32) void {
        self.data[24] = @truncate(value);
        self.data[25] = @truncate(value >> 8);
        self.data[26] = @truncate(value >> 16);
        self.data[27] = @truncate(value >> 24);
    }

    /// Get FCW (FPU Control Word) from saved state
    pub fn getFcw(self: *const FpuState) u16 {
        return @as(u16, self.data[0]) | (@as(u16, self.data[1]) << 8);
    }

    /// Set FCW (FPU Control Word) in saved state
    pub fn setFcw(self: *FpuState, value: u16) void {
        self.data[0] = @truncate(value);
        self.data[1] = @truncate(value >> 8);
    }
};

// CPUID feature bits
const CPUID_FEAT_EDX_FXSR: u32 = 1 << 24; // FXSAVE/FXRSTOR support
const CPUID_FEAT_EDX_SSE: u32 = 1 << 25; // SSE support
const CPUID_FEAT_EDX_SSE2: u32 = 1 << 26; // SSE2 support

/// Check if CPU supports FXSAVE/FXRSTOR instructions
pub fn hasFxsaveSupport() bool {
    const result = cpu.cpuid(1, 0);
    return (result.edx & CPUID_FEAT_EDX_FXSR) != 0;
}

/// Check if CPU supports SSE
pub fn hasSseSupport() bool {
    const result = cpu.cpuid(1, 0);
    return (result.edx & CPUID_FEAT_EDX_SSE) != 0;
}

/// Save FPU/SSE state to memory using FXSAVE
/// The destination must be 16-byte aligned
pub fn fxsave(state: *FpuState) void {
    // Use explicit register and memory dereference
    const addr = @intFromPtr(&state.data);
    asm volatile (
        \\mov %[ptr], %%rax
        \\fxsave (%%rax)
        :
        : [ptr] "r" (addr),
        : .{ .rax = true, .memory = true }
    );
}

/// Restore FPU/SSE state from memory using FXRSTOR
/// The source must be 16-byte aligned
pub fn fxrstor(state: *const FpuState) void {
    // Use explicit register and memory dereference
    const addr = @intFromPtr(&state.data);
    asm volatile (
        \\mov %[ptr], %%rax
        \\fxrstor (%%rax)
        :
        : [ptr] "r" (addr),
        : .{ .rax = true, .memory = true }
    );
}

/// Initialize the FPU to a known state
/// This should be called once at boot, before any FPU operations
pub fn initFpu() void {
    // Clear any pending FPU exceptions and initialize FPU
    asm volatile ("fninit");

    // Set MXCSR to default value (mask all SIMD exceptions)
    // Use sub rsp to create stack space, store value, ldmxcsr, restore rsp
    asm volatile (
        \\sub $4, %%rsp
        \\movl $0x1F80, (%%rsp)
        \\ldmxcsr (%%rsp)
        \\add $4, %%rsp
    );
}

/// Enable OSFXSR bit in CR4 (required for FXSAVE/FXRSTOR)
/// Must be called before any FXSAVE/FXRSTOR operations
pub fn enableOsfxsr() void {
    var cr4 = cpu.readCr4();
    cr4 |= (1 << 9); // CR4.OSFXSR
    cpu.writeCr4(cr4);
}

/// Enable OSXMMEXCPT bit in CR4 (enables #XM exception for SIMD errors)
pub fn enableOsxmmexcpt() void {
    var cr4 = cpu.readCr4();
    cr4 |= (1 << 10); // CR4.OSXMMEXCPT
    cpu.writeCr4(cr4);
}

/// Initialize FPU subsystem - call during HAL init
/// Enables FXSAVE support and initializes FPU state
pub fn init() void {
    // Enable OSFXSR to allow FXSAVE/FXRSTOR
    enableOsfxsr();

    // Enable OSXMMEXCPT for proper SIMD exception handling
    enableOsxmmexcpt();

    // Initialize FPU to known state
    initFpu();
}

// CR0.TS bit for lazy FPU switching
const CR0_TS: u64 = 1 << 3;

/// Set CR0.TS (Task Switched) flag
/// When TS is set, using any FPU/SSE instruction causes #NM exception
/// Used for lazy FPU context switching
pub fn setTaskSwitched() void {
    var cr0 = cpu.readCr0();
    cr0 |= CR0_TS;
    cpu.writeCr0(cr0);
}

/// Clear CR0.TS (Task Switched) flag
/// Called from #NM handler to allow FPU usage
pub fn clearTaskSwitched() void {
    // Use CLTS instruction which is faster than read-modify-write
    asm volatile ("clts");
}

/// Check if CR0.TS is set
pub fn isTaskSwitched() bool {
    return (cpu.readCr0() & CR0_TS) != 0;
}

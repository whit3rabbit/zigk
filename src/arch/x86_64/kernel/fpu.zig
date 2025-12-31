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

// =============================================================================
// XSAVE Support for Extended FPU State (AVX, AVX-512, etc.)
// =============================================================================

// CPUID feature bits for XSAVE
const CPUID_FEAT_ECX_XSAVE: u32 = 1 << 26; // XSAVE/XRSTOR supported
const CPUID_FEAT_ECX_OSXSAVE: u32 = 1 << 27; // OSXSAVE (CR4.OSXSAVE set)
const CPUID_FEAT_ECX_AVX: u32 = 1 << 28; // AVX supported

// XCR0 feature bits (XSAVE state components)
const XCR0_X87: u64 = 1 << 0; // x87 FPU state (mandatory)
const XCR0_SSE: u64 = 1 << 1; // SSE state (XMM registers)
const XCR0_AVX: u64 = 1 << 2; // AVX state (YMM upper halves)
// AVX-512 components (optional, for future)
// const XCR0_OPMASK: u64 = 1 << 5;    // AVX-512 opmask registers
// const XCR0_ZMM_HI256: u64 = 1 << 6; // AVX-512 ZMM upper halves
// const XCR0_HI16_ZMM: u64 = 1 << 7;  // AVX-512 ZMM16-ZMM31

// CR4 bits for XSAVE
const CR4_OSXSAVE: u64 = 1 << 18;

// Cached XSAVE state - initialized once at boot
var xsave_supported: bool = false;
var xsave_area_size: usize = FXSAVE_SIZE; // Default to FXSAVE size
var xcr0_mask: u64 = 0;
var xsave_initialized: bool = false;

/// Alignment requirement for XSAVE area (64 bytes per Intel spec)
pub const XSAVE_ALIGN: usize = 64;

/// Check if CPU supports XSAVE/XRSTOR instructions
pub fn hasXsaveSupport() bool {
    if (xsave_initialized) return xsave_supported;
    const result = cpu.cpuid(1, 0);
    return (result.ecx & CPUID_FEAT_ECX_XSAVE) != 0;
}

/// Get the required XSAVE area size for all enabled features
/// Returns FXSAVE_SIZE (512) if XSAVE is not supported
pub fn getXsaveAreaSize() usize {
    return xsave_area_size;
}

/// Get whether XSAVE is enabled and active
pub fn isXsaveEnabled() bool {
    return xsave_initialized and xsave_supported;
}

/// Read XCR0 (Extended Control Register 0)
fn readXcr0() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("xgetbv"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [xcr] "{ecx}" (@as(u32, 0)),
    );
    return (@as(u64, high) << 32) | low;
}

/// Write XCR0 (Extended Control Register 0)
fn writeXcr0(value: u64) void {
    const low: u32 = @truncate(value);
    const high: u32 = @truncate(value >> 32);
    asm volatile ("xsetbv"
        :
        : [xcr] "{ecx}" (@as(u32, 0)),
          [low] "{eax}" (low),
          [high] "{edx}" (high),
    );
}

/// Initialize XSAVE subsystem
/// Detects supported features, enables them in XCR0, queries size
/// Must be called after init() and on every CPU (BSP and APs)
pub fn initXsave() void {
    // Only detect once (on BSP), but enable on all CPUs
    if (!xsave_initialized) {
        const cpuid1 = cpu.cpuid(1, 0);
        xsave_supported = (cpuid1.ecx & CPUID_FEAT_ECX_XSAVE) != 0;

        if (!xsave_supported) {
            xsave_initialized = true;
            return;
        }

        // Build XCR0 mask based on supported features
        xcr0_mask = XCR0_X87 | XCR0_SSE; // Always enable x87 and SSE

        // Enable AVX if supported
        if ((cpuid1.ecx & CPUID_FEAT_ECX_AVX) != 0) {
            xcr0_mask |= XCR0_AVX;
        }

        // AVX-512 detection would require CPUID leaf 7, skipped for now
    }

    if (!xsave_supported) {
        xsave_initialized = true;
        return;
    }

    // Enable XSAVE in CR4 (must be done on each CPU)
    var cr4 = cpu.readCr4();
    cr4 |= CR4_OSXSAVE;
    cpu.writeCr4(cr4);

    // Write XCR0 to enable selected features (must be done on each CPU)
    writeXcr0(xcr0_mask);

    // Query actual size for enabled features (only once on BSP)
    if (!xsave_initialized) {
        // CPUID.(EAX=0DH, ECX=0): EBX = size for currently enabled features
        const cpuid_0d_0 = cpu.cpuid(0x0D, 0);
        xsave_area_size = cpuid_0d_0.ebx;

        // Ensure minimum alignment (64 bytes for XSAVE)
        xsave_area_size = (xsave_area_size + (XSAVE_ALIGN - 1)) & ~(XSAVE_ALIGN - 1);

        // Sanity check: must be at least FXSAVE size
        if (xsave_area_size < FXSAVE_SIZE) {
            xsave_area_size = FXSAVE_SIZE;
        }

        xsave_initialized = true;
    }
}

/// Save extended FPU state using XSAVE (or FXSAVE fallback)
/// The buffer must be properly aligned (64 bytes for XSAVE, 16 for FXSAVE)
/// and sized according to getXsaveAreaSize()
pub fn xsave(state: []u8) void {
    if (!xsave_supported or state.len < FXSAVE_SIZE) {
        // Fallback to FXSAVE
        if (state.len >= FXSAVE_SIZE) {
            const fpu_state: *FpuState = @ptrCast(@alignCast(state.ptr));
            fxsave(fpu_state);
        }
        return;
    }

    const addr = @intFromPtr(state.ptr);
    // XSAVE with all enabled components (EDX:EAX = -1 for full mask)
    asm volatile (
        \\mov $0xFFFFFFFF, %%eax
        \\mov $0xFFFFFFFF, %%edx
        \\xsave (%[ptr])
        :
        : [ptr] "r" (addr),
        : .{ .rax = true, .rdx = true, .memory = true }
    );
}

/// Restore extended FPU state using XRSTOR (or FXRSTOR fallback)
/// The buffer must be properly aligned and sized
pub fn xrstor(state: []const u8) void {
    if (!xsave_supported or state.len < FXSAVE_SIZE) {
        // Fallback to FXRSTOR
        if (state.len >= FXSAVE_SIZE) {
            const fpu_state: *const FpuState = @ptrCast(@alignCast(state.ptr));
            fxrstor(fpu_state);
        }
        return;
    }

    const addr = @intFromPtr(state.ptr);
    // XRSTOR with all enabled components
    asm volatile (
        \\mov $0xFFFFFFFF, %%eax
        \\mov $0xFFFFFFFF, %%edx
        \\xrstor (%[ptr])
        :
        : [ptr] "r" (addr),
        : .{ .rax = true, .rdx = true, .memory = true }
    );
}

/// Save FPU state to a slice (convenience wrapper)
/// Uses XSAVE if available, otherwise FXSAVE
pub fn saveState(state: []u8) void {
    xsave(state);
}

/// Restore FPU state from a slice (convenience wrapper)
/// Uses XRSTOR if available, otherwise FXRSTOR
pub fn restoreState(state: []const u8) void {
    xrstor(state);
}

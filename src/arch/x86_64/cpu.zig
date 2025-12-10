// CPU control operations for x86_64
// HAL layer - only place where CPU register access is permitted
//
// Provides control register access, MSR operations, and interrupt control.
// All kernel code outside of src/arch/ MUST use the hal module interface.

// Common MSR addresses
pub const IA32_EFER: u32 = 0xC0000080;
pub const IA32_STAR: u32 = 0xC0000081;
pub const IA32_LSTAR: u32 = 0xC0000082;
pub const IA32_CSTAR: u32 = 0xC0000083;
pub const IA32_FMASK: u32 = 0xC0000084;
pub const IA32_FS_BASE: u32 = 0xC0000100;
pub const IA32_GS_BASE: u32 = 0xC0000101;
pub const IA32_KERNEL_GS_BASE: u32 = 0xC0000102;

// Control Register Operations

/// Read CR0 (system control flags)
pub inline fn readCr0() u64 {
    return asm volatile ("mov %%cr0, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

/// Write CR0
pub inline fn writeCr0(value: u64) void {
    asm volatile ("mov %[value], %%cr0"
        :
        : [value] "r" (value),
    );
}

/// Read CR2 (page fault linear address)
pub inline fn readCr2() u64 {
    return asm volatile ("mov %%cr2, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

/// Read CR3 (page table base register)
pub inline fn readCr3() u64 {
    return asm volatile ("mov %%cr3, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

/// Write CR3 (switch page tables, flushes TLB)
pub inline fn writeCr3(value: u64) void {
    asm volatile ("mov %[value], %%cr3"
        :
        : [value] "r" (value),
        : .{ .memory = true }
    );
}

/// Read CR4 (architectural extensions)
pub inline fn readCr4() u64 {
    return asm volatile ("mov %%cr4, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

/// Write CR4
pub inline fn writeCr4(value: u64) void {
    asm volatile ("mov %[value], %%cr4"
        :
        : [value] "r" (value),
    );
}

// Model-Specific Register Operations

/// Read a Model-Specific Register
pub inline fn readMsr(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, high) << 32) | low;
}

/// Write a Model-Specific Register
pub inline fn writeMsr(msr: u32, value: u64) void {
    const low: u32 = @truncate(value);
    const high: u32 = @truncate(value >> 32);
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (low),
          [high] "{edx}" (high),
    );
}

// Interrupt Control

/// Enable interrupts (STI)
pub inline fn enableInterrupts() void {
    asm volatile ("sti");
}

/// Disable interrupts (CLI)
pub inline fn disableInterrupts() void {
    asm volatile ("cli");
}

/// Check if interrupts are enabled via RFLAGS.IF
pub inline fn interruptsEnabled() bool {
    const rflags = asm volatile ("pushfq; pop %[ret]"
        : [ret] "=r" (-> u64),
    );
    // IF (Interrupt Flag) is bit 9
    return (rflags & (1 << 9)) != 0;
}

/// Halt CPU until next interrupt
pub inline fn halt() void {
    asm volatile ("hlt");
}


/// Halt with interrupts disabled (for panic)
pub inline fn haltForever() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
}

/// Atomically enable interrupts and halt
/// Used for race-free idle loops: guarantees CPU halts even if interrupt
/// occurred immediately after STI but before HLT
pub inline fn enableAndHalt() void {
    asm volatile ("sti; hlt");
}


// TLB Operations

/// Invalidate TLB entry for a specific address
/// The invlpg instruction only needs the address, not memory contents
pub inline fn invlpg(addr: u64) void {
    // Use invlpg with memory operand syntax - the address is passed directly
    // We cast to a pointer type that Zig can use with the "m" constraint
    // but the instruction only uses the address, not the contents
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (addr),
        : .{ .memory = true }
    );
}

/// Flush entire TLB by reloading CR3
pub inline fn flushTlb() void {
    writeCr3(readCr3());
}

/// Flush entire TLB including global pages
/// Requires toggling CR4.PGE (Page Global Enable)
pub inline fn flushTlbGlobal() void {
    const cr4 = readCr4();
    // Clear PGE (bit 7)
    writeCr4(cr4 & ~@as(u64, 1 << 7));
    // Restore PGE (bit 7)
    writeCr4(cr4 | (1 << 7));
}

// CPUID

/// Result of CPUID instruction
pub const CpuidResult = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

/// Execute CPUID instruction
pub inline fn cpuid(leaf: u32, subleaf: u32) CpuidResult {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );

    return .{
        .eax = eax,
        .ebx = ebx,
        .ecx = ecx,
        .edx = edx,
    };
}

//! VMware Hypercall Interface (AArch64)
//!
//! VMware on ARM64 uses a different mechanism than x86:
//! - x86: I/O port 0x5658 with `in eax, dx` instruction
//! - ARM64: System register trap via `mrs xzr, mdccsr_el0`
//!
//! The hypervisor traps access to MDCCSR_EL0 (Monitor Debug Configuration
//! Status Register) and interprets pre-loaded registers x0-x7 as hypercall
//! parameters.
//!
//! Reference: Linux kernel vmwgfx ARM64 patches (drm/vmwgfx)

const std = @import("std");

pub const HYPERCALL_PORT: u16 = 0x5658;
pub const HYPERCALL_MAGIC: u32 = 0x564D5868;

/// Magic value indicating x86 I/O port emulation mode in x7
const X86_IO_MAGIC: u64 = 0x86;

/// ARM64 hypercall register state (internal, 64-bit)
/// Layout matches the assembly helper expectations: 8 consecutive u64 values.
const HypercallRegs = extern struct {
    x0: u64, // eax equivalent
    x1: u64, // ebx equivalent
    x2: u64, // ecx equivalent
    x3: u64, // edx equivalent
    x4: u64, // esi equivalent
    x5: u64, // edi equivalent
    x6: u64, // bp equivalent (high-bandwidth base pointer)
    x7: u64, // control word: (X86_IO_MAGIC << 32) | flags
};

/// External assembly function for VMware hypercall.
/// Defined in src/arch/aarch64/lib/asm_helpers.S
extern fn _asm_vmware_hypercall(regs: *HypercallRegs) void;

/// Low-level register state for hypercall.
/// API compatible with x86_64 version for cross-architecture code.
///
/// Note: On ARM64, the actual hypercall uses 64-bit registers internally,
/// but we expose a 32-bit interface for compatibility with existing code
/// (syscall handlers, VMMouse driver, vmware_tools service).
pub const Registers = extern struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
    esi: u32 = 0,
    edi: u32 = 0,
};

/// Command IDs for the hypercall
pub const Command = enum(u16) {
    GetVersion = 10,
    GetCursorPos = 0x04,
    SetCursorPos = 0x05,
    GetClipboardLen = 0x06,
    GetClipboardData = 0x07,
    SetClipboardLen = 0x08,
    SetClipboardData = 0x09,
    // VMMouse specific
    AbsPointerData = 39,
    AbsPointerStatus = 40,
    AbsPointerCmd = 41,
    // Time synchronization
    GetTimeFull = 46,
    GetTimeDiff = 47,
};

/// Check if the VMware hypercall interface is available.
/// Sends GET_VERSION command and checks for magic response.
pub fn detect() bool {
    var regs = HypercallRegs{
        .x0 = HYPERCALL_MAGIC,
        .x1 = ~@as(u64, HYPERCALL_MAGIC), // Initialize with non-magic
        .x2 = @intFromEnum(Command.GetVersion),
        .x3 = HYPERCALL_PORT,
        .x4 = 0,
        .x5 = 0,
        .x6 = 0,
        .x7 = X86_IO_MAGIC << 32, // Indicate x86 I/O port emulation
    };

    _asm_vmware_hypercall(&regs);

    // If successful, x1 (ebx equivalent) should contain the magic value
    return @as(u32, @truncate(regs.x1)) == HYPERCALL_MAGIC;
}

/// Execute a hypercall command using the ARM64 mechanism.
///
/// The VMware hypervisor intercepts the `mrs xzr, mdccsr_el0` instruction
/// and interprets the register state as a hypercall.
///
/// This function maintains API compatibility with x86_64 by accepting the
/// same Registers struct, internally converting to 64-bit ARM registers.
pub inline fn call(regs: *Registers) void {
    // Convert x86-style 32-bit registers to ARM64 64-bit registers
    var arm_regs = HypercallRegs{
        .x0 = regs.eax,
        .x1 = regs.ebx,
        .x2 = regs.ecx,
        .x3 = regs.edx,
        .x4 = regs.esi,
        .x5 = regs.edi,
        .x6 = 0, // Not used for low-bandwidth calls
        .x7 = X86_IO_MAGIC << 32, // Indicate x86 I/O port emulation mode
    };

    _asm_vmware_hypercall(&arm_regs);

    // Convert results back to 32-bit
    regs.eax = @truncate(arm_regs.x0);
    regs.ebx = @truncate(arm_regs.x1);
    regs.ecx = @truncate(arm_regs.x2);
    regs.edx = @truncate(arm_regs.x3);
    regs.esi = @truncate(arm_regs.x4);
    regs.edi = @truncate(arm_regs.x5);
}

/// Helper for VMMouse commands which often use simple command ID in EAX
pub fn sendCommand(cmd: Command) void {
    var regs = Registers{
        .eax = HYPERCALL_MAGIC,
        .ebx = @intFromEnum(cmd),
        .ecx = 0,
        .edx = HYPERCALL_PORT,
    };
    call(&regs);
}

/// Helper specifically for VMMouse data exchange.
/// VMMouse uses the hypercall interface for cursor position and button state.
pub fn sendVMMouseCommand(sub_cmd: u32, data: u32) Registers {
    var regs = Registers{
        .eax = HYPERCALL_MAGIC,
        .ebx = sub_cmd,
        .ecx = data,
        .edx = HYPERCALL_PORT,
        .esi = 0,
        .edi = 0,
    };
    call(&regs);
    return regs;
}

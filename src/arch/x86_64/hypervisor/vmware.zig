//! VMware/VirtualBox Backdoor Interface
//!
//! Provides access to the "Backdoor" I/O port interface used by VMware and VirtualBox
//! for guest-host communication (mouse integration, time sync, clipboard, etc.).
//!
//! Magic Port: 0x5658 ("VX")
//! Magic Value: 0x564D5868 ("VMXh")

const std = @import("std");

pub const BACKDOOR_PORT: u16 = 0x5658;
pub const BACKDOOR_MAGIC: u32 = 0x564D5868;

/// Low-level register state for backdoor calls.
/// Layout must match the assembly helper expectations (6 consecutive u32 fields).
pub const Registers = extern struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
    esi: u32 = 0,
    edi: u32 = 0,
};

/// External assembly function for VMware backdoor call.
/// Defined in src/arch/x86_64/lib/asm_helpers.S
extern fn _asm_vmware_backdoor_call(regs: *Registers) void;

/// Command IDs for the backdoor
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
};

/// Check if the backdoor is available
pub fn detect() bool {
    var regs = Registers{
        .eax = @intFromEnum(Command.GetVersion),
        .ebx = ~BACKDOOR_MAGIC, // Initialize with non-magic
        .ecx = 0,
        .edx = BACKDOOR_PORT, // Port goes in DX (sometimes modified by in/out but port is fixed)
    };

    call(&regs);

    // If successful, EBX should contain the magic value 0x564D5868
    // and EAX should usually be valid (not -1 or garbage, though version specific)
    return regs.ebx == BACKDOOR_MAGIC;
}

/// Execute a backdoor command.
///
/// The VMware backdoor instruction is `in eax, dx` with specific values in
/// other registers. The hypervisor traps this specific I/O operation.
/// Uses external assembly due to Zig 0.16 inline asm limitations with
/// multiple register outputs.
pub inline fn call(regs: *Registers) void {
    _asm_vmware_backdoor_call(regs);
}

/// Helper for VMMouse commands which often use simple command ID in EAX
pub fn sendCommand(cmd: Command) void {
    var regs = Registers{
        .eax = BACKDOOR_MAGIC,
        .ebx = @intFromEnum(cmd),
        .ecx = 0,
        .edx = BACKDOOR_PORT,
    };
    call(&regs);
}

/// Helper specifically for VMMouse data exchange
pub fn sendVMMouseCommand(sub_cmd: u32, data: u32) Registers {
    var regs = Registers{
        .eax = BACKDOOR_MAGIC,
        .ebx = sub_cmd,
        .ecx = data,
        .edx = BACKDOOR_PORT,
        .esi = 0,
        .edi = 0,
    };
    // VMMouse uses "Set" commands or "Data" commands via the AbsPointerCmd (41) usually?
    // Actually, VMMouse protocol is slightly different:
    // It sets EBX to the VMMouse command word.
    
    // Low level call
    call(&regs);
    return regs;
}

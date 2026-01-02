//! Hypervisor Syscalls
//!
//! Provides userspace access to hypervisor interfaces (VMware backdoor, etc.)
//! Requires CAP_HYPERVISOR capability for security.
//!
//! Security Design:
//! - Only allowlisted VMware backdoor commands are permitted
//! - Dangerous commands (clipboard, RPCI messaging) are blocked by default
//! - The HypervisorCapability.vmware_backdoor field must be true

const std = @import("std");
const uapi = @import("uapi");
const hal = @import("hal");
const sched = @import("sched");
const process_mod = @import("process");
const user_mem = @import("user_mem");

const SyscallError = uapi.errno.SyscallError;

/// VMware backdoor register state (matches hal.vmware.Registers layout)
pub const VmwareBackdoorRegs = extern struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
    esi: u32,
    edi: u32,
};

/// VMware backdoor command IDs
/// Reference: https://wiki.osdev.org/VMware_tools
const VmwareCommand = struct {
    // Safe commands (allowlisted)
    const GET_VERSION: u16 = 10;
    const GET_CURSOR_POS: u16 = 4;
    const SET_CURSOR_POS: u16 = 5;
    const GET_TIME_FULL: u16 = 46;
    const GET_TIME_DIFF: u16 = 47;
    const ABS_POINTER_DATA: u16 = 39;
    const ABS_POINTER_STATUS: u16 = 40;
    const ABS_POINTER_CMD: u16 = 41;

    // Dangerous commands (blocked) - documented for security review
    // const GET_CLIPBOARD_LEN: u16 = 6;   // Can exfiltrate host clipboard
    // const GET_CLIPBOARD_DATA: u16 = 7;  // Can exfiltrate host clipboard
    // const SET_CLIPBOARD_LEN: u16 = 8;   // Can inject into host clipboard
    // const SET_CLIPBOARD_DATA: u16 = 9;  // Can inject into host clipboard
    // const MESSAGE_OPEN: u16 = 30;       // RPCI channel - arbitrary host interaction
    // const MESSAGE_SEND: u16 = 31;       // RPCI channel - arbitrary host interaction
    // const MESSAGE_RECEIVE: u16 = 32;    // RPCI channel - arbitrary host interaction
    // const MESSAGE_CLOSE: u16 = 33;      // RPCI channel - arbitrary host interaction
};

/// Allowlist of safe VMware backdoor commands
/// These commands only provide read-only guest utilities (time, cursor, version)
/// and do not allow data exfiltration or host interaction.
const allowed_commands = [_]u16{
    VmwareCommand.GET_VERSION,
    VmwareCommand.GET_CURSOR_POS,
    VmwareCommand.SET_CURSOR_POS,
    VmwareCommand.GET_TIME_FULL,
    VmwareCommand.GET_TIME_DIFF,
    VmwareCommand.ABS_POINTER_DATA,
    VmwareCommand.ABS_POINTER_STATUS,
    VmwareCommand.ABS_POINTER_CMD,
};

/// Check if a VMware backdoor command is in the allowlist
fn isCommandAllowed(cmd: u16) bool {
    for (allowed_commands) |allowed| {
        if (cmd == allowed) return true;
    }
    return false;
}

/// Execute VMware backdoor command
///
/// Arguments:
///   regs_ptr: Pointer to VmwareBackdoorRegs structure (in/out)
///
/// Returns: 0 on success, -EPERM if not permitted, -EFAULT if bad pointer
///
/// Security:
/// - Requires CAP_HYPERVISOR capability with vmware_backdoor=true
/// - Only allowlisted commands are permitted (blocks clipboard, RPCI)
/// - Only allowed when running under a VMware-compatible hypervisor
pub fn sys_vmware_backdoor(regs_ptr: usize) SyscallError!usize {
    // Permission check
    const current = sched.getCurrentThread() orelse return error.EPERM;
    const proc_opaque = current.process orelse return error.EPERM;
    const proc: *process_mod.Process = @ptrCast(@alignCast(proc_opaque));

    // Check for hypervisor capability AND that vmware_backdoor is enabled
    const hv_cap = proc.getHypervisorCapability() orelse return error.EPERM;
    if (!hv_cap.vmware_backdoor) return error.EPERM;

    // Check if VMware backdoor is available
    if (!hal.vmware.detect()) return error.ENODEV;

    // Copy registers from userspace using safe copy primitives (SMAP-compliant)
    // copyFromUser returns bytes NOT copied (0 on success)
    // Zero-initialize first for defense-in-depth (per CLAUDE.md security guidelines)
    var user_regs: VmwareBackdoorRegs = .{
        .eax = 0,
        .ebx = 0,
        .ecx = 0,
        .edx = 0,
        .esi = 0,
        .edi = 0,
    };
    const bytes_not_copied_in = user_mem.copyFromUser(
        std.mem.asBytes(&user_regs),
        regs_ptr,
    );
    if (bytes_not_copied_in != 0) return error.EFAULT;

    // Extract command from ECX (low 16 bits contain the command ID)
    // VMware backdoor protocol: command in low 16 bits of ECX
    const cmd: u16 = @truncate(user_regs.ecx);

    // Security: Only allow safe commands from the allowlist
    // This blocks clipboard operations (6-9) and RPCI messaging (30-33)
    // which could be used for data exfiltration or host interaction
    if (!isCommandAllowed(cmd)) {
        return error.EPERM;
    }

    var kernel_regs = hal.vmware.Registers{
        .eax = user_regs.eax,
        .ebx = user_regs.ebx,
        .ecx = user_regs.ecx,
        .edx = user_regs.edx,
        .esi = user_regs.esi,
        .edi = user_regs.edi,
    };

    // Execute backdoor call
    hal.vmware.call(&kernel_regs);

    // Copy results back to kernel buffer
    user_regs.eax = kernel_regs.eax;
    user_regs.ebx = kernel_regs.ebx;
    user_regs.ecx = kernel_regs.ecx;
    user_regs.edx = kernel_regs.edx;
    user_regs.esi = kernel_regs.esi;
    user_regs.edi = kernel_regs.edi;

    // Copy results back to userspace using safe copy primitives (SMAP-compliant)
    // copyToUser returns bytes NOT copied (0 on success)
    const bytes_not_copied_out = user_mem.copyToUser(
        regs_ptr,
        std.mem.asBytes(&user_regs),
    );
    if (bytes_not_copied_out != 0) return error.EFAULT;

    return 0;
}

/// Get hypervisor type
///
/// Returns: Hypervisor type as integer:
///   0 = none (bare metal)
///   1 = vmware
///   2 = virtualbox
///   3 = kvm
///   4 = hyperv
///   5 = xen
///   6 = qemu_tcg
///   7 = parallels
///   8 = acrn
///   9 = unknown
///
/// SECURITY NOTE: This syscall intentionally has NO capability check because:
/// - CPUID is a user-accessible instruction (Ring 3)
/// - Any unprivileged process can detect the hypervisor directly via CPUID
/// - Gating this syscall would provide security theater, not actual protection
/// - The HypervisorCapability.detect_hypervisor field exists for future use
///   if we ever want to block this for sandboxed processes
pub fn sys_get_hypervisor() SyscallError!usize {
    const info = hal.hypervisor.detect.detect();
    return @intFromEnum(info.hypervisor);
}

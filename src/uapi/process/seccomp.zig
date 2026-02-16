// Seccomp Syscall Filtering Constants and Structures
//
// Provides Linux-compatible seccomp ABI for process sandboxing.
// Seccomp allows restricting syscall availability via:
// - SECCOMP_MODE_STRICT: Whitelist of 4 syscalls (read/write/exit/sigreturn)
// - SECCOMP_MODE_FILTER: Classic BPF program-based filtering

const std = @import("std");

// =============================================================================
// Seccomp Modes
// =============================================================================

/// No filtering active
pub const SECCOMP_MODE_DISABLED: u8 = 0;

/// Strict mode: only read/write/exit/sigreturn allowed
pub const SECCOMP_MODE_STRICT: u8 = 1;

/// Filter mode: BPF program filtering
pub const SECCOMP_MODE_FILTER: u8 = 2;

// =============================================================================
// Seccomp Operations (for sys_seccomp)
// =============================================================================

/// Enable strict mode
pub const SECCOMP_SET_MODE_STRICT: usize = 0;

/// Install BPF filter
pub const SECCOMP_SET_MODE_FILTER: usize = 1;

/// Query action availability
pub const SECCOMP_GET_ACTION_AVAIL: usize = 2;

// =============================================================================
// BPF Filter Return Values
// =============================================================================

/// Kill the entire process
pub const SECCOMP_RET_KILL_PROCESS: u32 = 0x80000000;

/// Kill the calling thread
pub const SECCOMP_RET_KILL_THREAD: u32 = 0x00000000;

/// Alias for KILL_THREAD (Linux compatibility)
pub const SECCOMP_RET_KILL: u32 = SECCOMP_RET_KILL_THREAD;

/// Deny syscall with errno (low 16 bits = errno value)
pub const SECCOMP_RET_ERRNO: u32 = 0x00050000;

/// Allow syscall
pub const SECCOMP_RET_ALLOW: u32 = 0x7fff0000;

/// Mask to extract action code (high 16 bits)
pub const SECCOMP_RET_ACTION_FULL: u32 = 0xffff0000;

/// Mask to extract data field (low 16 bits, e.g., errno value)
pub const SECCOMP_RET_DATA: u32 = 0x0000ffff;

// =============================================================================
// Seccomp Data Structure (passed to BPF filter)
// =============================================================================

/// Data structure passed to seccomp BPF filters
/// This is treated as a 64-byte "packet" by the classic BPF interpreter
pub const SeccompData = extern struct {
    /// Syscall number (i32 for Linux compatibility)
    nr: i32,
    /// Architecture identifier (AUDIT_ARCH_*)
    arch: u32,
    /// Instruction pointer at syscall entry
    instruction_pointer: u64,
    /// Syscall arguments (up to 6)
    args: [6]u64,
};

comptime {
    std.debug.assert(@sizeOf(SeccompData) == 64);
}

// =============================================================================
// AUDIT_ARCH Constants
// =============================================================================

/// x86_64 architecture (EM_X86_64 | __AUDIT_ARCH_64BIT | __AUDIT_ARCH_LE)
pub const AUDIT_ARCH_X86_64: u32 = 0xC000003E;

/// AArch64 architecture (EM_AARCH64 | __AUDIT_ARCH_64BIT | __AUDIT_ARCH_LE)
pub const AUDIT_ARCH_AARCH64: u32 = 0xC00000B7;

// =============================================================================
// Classic BPF Instruction Structure
// =============================================================================

/// Classic BPF instruction (8 bytes)
pub const SockFilterInsn = extern struct {
    /// Opcode (combines class + size + mode)
    code: u16,
    /// Jump offset if condition true
    jt: u8,
    /// Jump offset if condition false
    jf: u8,
    /// Generic multiuse field (immediate value, offset, etc.)
    k: u32,
};

comptime {
    std.debug.assert(@sizeOf(SockFilterInsn) == 8);
}

/// BPF program descriptor (passed from userspace)
pub const SockFprog = extern struct {
    /// Number of filter instructions
    len: u16,
    /// Padding for alignment
    _pad: u16 = 0,
    _pad2: u32 = 0,
    /// Pointer to SockFilterInsn array (as u64 for ABI compatibility)
    filter: u64,
};

// =============================================================================
// Classic BPF Opcodes
// =============================================================================

// Instruction classes
pub const BPF_LD: u16 = 0x00; // Load
pub const BPF_LDX: u16 = 0x01; // Load into X
pub const BPF_ST: u16 = 0x02; // Store
pub const BPF_STX: u16 = 0x03; // Store X
pub const BPF_ALU: u16 = 0x04; // Arithmetic/logic
pub const BPF_JMP: u16 = 0x05; // Jump
pub const BPF_RET: u16 = 0x06; // Return
pub const BPF_MISC: u16 = 0x07; // Miscellaneous

// Size modifiers
pub const BPF_W: u16 = 0x00; // 32-bit word
pub const BPF_H: u16 = 0x08; // 16-bit halfword
pub const BPF_B: u16 = 0x10; // 8-bit byte

// Addressing modes
pub const BPF_IMM: u16 = 0x00; // Immediate value K
pub const BPF_ABS: u16 = 0x20; // Absolute offset in packet (seccomp_data)
pub const BPF_IND: u16 = 0x40; // Indirect (X + offset)
pub const BPF_MEM: u16 = 0x60; // Scratch memory M[]
pub const BPF_LEN: u16 = 0x80; // Packet length (64 for seccomp_data)
pub const BPF_MSH: u16 = 0xa0; // Not used in seccomp

// ALU operations
pub const BPF_ADD: u16 = 0x00;
pub const BPF_SUB: u16 = 0x10;
pub const BPF_MUL: u16 = 0x20;
pub const BPF_DIV: u16 = 0x30;
pub const BPF_OR: u16 = 0x40;
pub const BPF_AND: u16 = 0x50;
pub const BPF_LSH: u16 = 0x60; // Left shift
pub const BPF_RSH: u16 = 0x70; // Right shift
pub const BPF_NEG: u16 = 0x80;
pub const BPF_MOD: u16 = 0x90;
pub const BPF_XOR: u16 = 0xa0;

// Jump conditions
pub const BPF_JA: u16 = 0x00; // Unconditional jump
pub const BPF_JEQ: u16 = 0x10; // Jump if equal
pub const BPF_JGT: u16 = 0x20; // Jump if greater than
pub const BPF_JGE: u16 = 0x30; // Jump if greater or equal
pub const BPF_JSET: u16 = 0x40; // Jump if bit set

// Source operand for ALU/JMP
pub const BPF_K: u16 = 0x00; // Use immediate K value
pub const BPF_X: u16 = 0x08; // Use X register

// MISC operations
pub const BPF_TAX: u16 = 0x00; // Transfer A to X
pub const BPF_TXA: u16 = 0x80; // Transfer X to A

// =============================================================================
// Limits
// =============================================================================

/// Maximum BPF program length
pub const BPF_MAXINSNS: usize = 4096;

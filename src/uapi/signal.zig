// Signal API
//
// Defines signal sets and operations compatible with Linux x86_64.

pub const SIG_BLOCK: usize = 0;
pub const SIG_UNBLOCK: usize = 1;
pub const SIG_SETMASK: usize = 2;

pub const SIGKILL: usize = 9;
pub const SIGSTOP: usize = 19;

/// Signal set (64 bits)
/// Compatible with Linux sigset_t for x86_64 which is 1024 bits (128 bytes),
/// but sys_rt_sigprocmask usually deals with 8 bytes (64 bits) unless sigsetsize is larger.
/// However, zig's integer types are handy.
///
/// Linux kernel treats sigset_t as an array of longs.
///
/// For MVP, we will assume 64 signals.
pub const SigSet = u64;

/// Helper to check if a signal is in the set
pub fn sigismember(set: SigSet, sig: usize) bool {
    if (sig == 0 or sig > 64) return false;
    return (set & (@as(u64, 1) << @truncate(sig - 1))) != 0;
}

/// Helper to add a signal to the set
pub fn sigaddset(set: *SigSet, sig: usize) void {
    if (sig == 0 or sig > 64) return;
    set.* |= (@as(u64, 1) << @truncate(sig - 1));
}

/// Helper to remove a signal from the set
pub fn sigdelset(set: *SigSet, sig: usize) void {
    if (sig == 0 or sig > 64) return;
    set.* &= ~(@as(u64, 1) << @truncate(sig - 1));
}

// Signal action flags
pub const SA_NOCLDSTOP: u64 = 0x00000001;
pub const SA_NOCLDWAIT: u64 = 0x00000002;
pub const SA_SIGINFO: u64 = 0x00000004;
pub const SA_ONSTACK: u64 = 0x08000000;
pub const SA_RESTART: u64 = 0x10000000;
pub const SA_NODEFER: u64 = 0x40000000;
pub const SA_RESETHAND: u64 = 0x80000000;
pub const SA_RESTORER: u64 = 0x04000000;

/// Signal action structure (matches Linux struct sigaction)
pub const SigAction = extern struct {
    handler: usize,
    flags: u64,
    restorer: usize,
    mask: SigSet,
};

/// Machine context (registers)
pub const MContext = extern struct {
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rbx: u64,
    rdx: u64,
    rax: u64,
    rcx: u64,
    rsp: u64,
    rip: u64,
    rflags: u64,
    cs: u16,
    gs: u16,
    fs: u16,
    pad0: u16,
    err: u64,
    trapno: u64,
    oldmask: u64,
    cr2: u64,
    fpstate: usize, // Pointer to FPU state
    reserved: [8]u64,
    ss: u64, // Added at end to match Linux logic often putting ss/rsp at end of gregset
};

/// Stack information
pub const StackT = extern struct {
    sp: usize,
    flags: i32,
    pad: i32 = 0,
    size: usize,
};

/// User Context
pub const UContext = extern struct {
    flags: u64,
    link: usize, // pointer to next ucontext
    stack: StackT,
    mcontext: MContext,
    sigmask: SigSet,
    _pad: [128]u8, // Padding for future expansion / FPU state space
};

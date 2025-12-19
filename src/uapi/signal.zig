// Signal API
//
// Defines signal sets and operations compatible with Linux x86_64.

pub const SIG_BLOCK: usize = 0;
pub const SIG_UNBLOCK: usize = 1;
pub const SIG_SETMASK: usize = 2;

// Standard signal numbers (Linux x86_64)
pub const SIGHUP: usize = 1;
pub const SIGINT: usize = 2;
pub const SIGQUIT: usize = 3;
pub const SIGILL: usize = 4;
pub const SIGTRAP: usize = 5;
pub const SIGABRT: usize = 6;
pub const SIGIOT: usize = 6; // Alias for SIGABRT
pub const SIGBUS: usize = 7;
pub const SIGFPE: usize = 8;
pub const SIGKILL: usize = 9;
pub const SIGUSR1: usize = 10;
pub const SIGSEGV: usize = 11;
pub const SIGUSR2: usize = 12;
pub const SIGPIPE: usize = 13;
pub const SIGALRM: usize = 14;
pub const SIGTERM: usize = 15;
pub const SIGSTKFLT: usize = 16;
pub const SIGCHLD: usize = 17;
pub const SIGCONT: usize = 18;
pub const SIGSTOP: usize = 19;
pub const SIGTSTP: usize = 20;
pub const SIGTTIN: usize = 21;
pub const SIGTTOU: usize = 22;
pub const SIGURG: usize = 23;
pub const SIGXCPU: usize = 24;
pub const SIGXFSZ: usize = 25;
pub const SIGVTALRM: usize = 26;
pub const SIGPROF: usize = 27;
pub const SIGWINCH: usize = 28;
pub const SIGIO: usize = 29;
pub const SIGPOLL: usize = 29; // Alias for SIGIO
pub const SIGPWR: usize = 30;
pub const SIGSYS: usize = 31;

/// Maximum signal number
pub const NSIG: usize = 64;

/// Default signal action types
pub const SigDefaultAction = enum {
    /// Terminate the process
    Terminate,
    /// Terminate with core dump
    Core,
    /// Ignore the signal
    Ignore,
    /// Stop the process
    Stop,
    /// Continue if stopped
    Continue,
};

/// Get the default action for a signal
pub fn getDefaultAction(signum: usize) SigDefaultAction {
    return switch (signum) {
        // Ignore
        SIGCHLD, SIGURG, SIGWINCH => .Ignore,
        // Stop
        SIGSTOP, SIGTSTP, SIGTTIN, SIGTTOU => .Stop,
        // Continue
        SIGCONT => .Continue,
        // Core dump
        SIGQUIT, SIGILL, SIGTRAP, SIGABRT, SIGBUS, SIGFPE, SIGSEGV, SIGXCPU, SIGXFSZ, SIGSYS => .Core,
        // Terminate (default for all others)
        else => .Terminate,
    };
}

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

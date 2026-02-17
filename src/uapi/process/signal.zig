// Signal API
//
// Defines signal sets and operations compatible with Linux x86_64.

pub const SIG_BLOCK: usize = 0;
pub const SIG_UNBLOCK: usize = 1;
pub const SIG_SETMASK: usize = 2;

// Special signal handler values
pub const SIG_DFL: usize = 0; // Default action
pub const SIG_IGN: usize = 1; // Ignore signal

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

// Sigaltstack flags
pub const SS_ONSTACK: i32 = 1; // Currently executing on alternate stack
pub const SS_DISABLE: i32 = 2; // Alternate stack is disabled

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

// =============================================================================
// Signal Info Codes (Phase 20)
// =============================================================================

/// Signal info codes (si_code values)
pub const SI_USER: i32 = 0; // Sent by kill, sigsend, raise
pub const SI_KERNEL: i32 = 0x80; // Sent by kernel
pub const SI_QUEUE: i32 = -1; // Sent by sigqueue
pub const SI_TIMER: i32 = -2; // POSIX timer expired
pub const SI_MESGQ: i32 = -3; // POSIX message queue state changed
pub const SI_ASYNCIO: i32 = -4; // AIO completed
pub const SI_SIGIO: i32 = -5; // Queued SIGIO
pub const SI_TKILL: i32 = -6; // Sent by tkill/tgkill

/// TIMER_ABSTIME flag for clock_nanosleep
pub const TIMER_ABSTIME: u32 = 1;

// =============================================================================
// Per-Thread Signal Info Queue (Phase 29)
// =============================================================================

/// Kernel-internal siginfo entry for per-thread signal queue.
/// Carries signal metadata through the kernel from sender to consumer.
pub const KernelSigInfo = struct {
    signo: u8, // Signal number (1-64)
    code: i32, // SI_USER, SI_QUEUE, SI_KERNEL, SI_TIMER, SI_TKILL, etc.
    pid: u32, // Sender PID (0 for kernel)
    uid: u32, // Sender UID (0 for kernel)
    value: usize, // si_value (union of int and pointer, use usize)
};

/// Fixed-capacity ring buffer for per-thread siginfo queue.
/// Capacity 32 is sufficient for a microkernel (Linux defaults to 128 per UID).
/// Standard signals (1-31) coalesce via pending_signals bitmask before enqueue.
/// RT signals (32-64) can queue multiple instances.
pub const SIGINFO_QUEUE_CAPACITY: usize = 32;

pub const SigInfoQueue = struct {
    entries: [SIGINFO_QUEUE_CAPACITY]KernelSigInfo,
    head: u8, // Next slot to dequeue from
    tail: u8, // Next slot to enqueue into
    count: u8, // Number of entries in queue

    pub fn init() SigInfoQueue {
        return .{
            .entries = undefined,
            .head = 0,
            .tail = 0,
            .count = 0,
        };
    }

    /// Enqueue a siginfo entry. Returns false if queue is full.
    pub fn enqueue(self: *SigInfoQueue, info: KernelSigInfo) bool {
        if (self.count >= SIGINFO_QUEUE_CAPACITY) return false;
        self.entries[self.tail] = info;
        self.tail = @intCast((@as(u16, self.tail) + 1) % SIGINFO_QUEUE_CAPACITY);
        self.count += 1;
        return true;
    }

    /// Dequeue the oldest entry. Returns null if empty.
    pub fn dequeue(self: *SigInfoQueue) ?KernelSigInfo {
        if (self.count == 0) return null;
        const entry = self.entries[self.head];
        self.head = @intCast((@as(u16, self.head) + 1) % SIGINFO_QUEUE_CAPACITY);
        self.count -= 1;
        return entry;
    }

    /// Dequeue the first entry matching a specific signal number.
    /// Used by signal consumption paths that need a specific signal.
    /// Returns null if no matching entry exists.
    pub fn dequeueBySignal(self: *SigInfoQueue, signo: u8) ?KernelSigInfo {
        if (self.count == 0) return null;
        // Linear scan from head to find first match
        var i: u8 = 0;
        while (i < self.count) : (i += 1) {
            const idx = @as(u8, @intCast((@as(u16, self.head) + i) % SIGINFO_QUEUE_CAPACITY));
            if (self.entries[idx].signo == signo) {
                // Found match -- remove it by shifting remaining entries
                const result = self.entries[idx];
                // Compact: shift entries after idx toward head
                var j: u8 = i;
                while (j + 1 < self.count) : (j += 1) {
                    const src = @as(u8, @intCast((@as(u16, self.head) + j + 1) % SIGINFO_QUEUE_CAPACITY));
                    const dst = @as(u8, @intCast((@as(u16, self.head) + j) % SIGINFO_QUEUE_CAPACITY));
                    self.entries[dst] = self.entries[src];
                }
                self.count -= 1;
                self.tail = @intCast((@as(u16, self.head) + self.count) % SIGINFO_QUEUE_CAPACITY);
                return result;
            }
        }
        return null;
    }

    /// Dequeue first entry matching any signal in the given bitmask.
    /// Used by rt_sigtimedwait and signalfd.
    pub fn dequeueByMask(self: *SigInfoQueue, mask: u64) ?KernelSigInfo {
        if (self.count == 0) return null;
        var i: u8 = 0;
        while (i < self.count) : (i += 1) {
            const idx = @as(u8, @intCast((@as(u16, self.head) + i) % SIGINFO_QUEUE_CAPACITY));
            const signo = self.entries[idx].signo;
            if (signo >= 1 and signo <= 64) {
                const sig_bit: u64 = @as(u64, 1) << @intCast(signo - 1);
                if ((mask & sig_bit) != 0) {
                    const result = self.entries[idx];
                    // Compact
                    var j: u8 = i;
                    while (j + 1 < self.count) : (j += 1) {
                        const src = @as(u8, @intCast((@as(u16, self.head) + j + 1) % SIGINFO_QUEUE_CAPACITY));
                        const dst = @as(u8, @intCast((@as(u16, self.head) + j) % SIGINFO_QUEUE_CAPACITY));
                        self.entries[dst] = self.entries[src];
                    }
                    self.count -= 1;
                    self.tail = @intCast((@as(u16, self.head) + self.count) % SIGINFO_QUEUE_CAPACITY);
                    return result;
                }
            }
        }
        return null;
    }

    /// Check if any entry matches the given signal number (without removing).
    pub fn hasSignal(self: *const SigInfoQueue, signo: u8) bool {
        var i: u8 = 0;
        while (i < self.count) : (i += 1) {
            const idx = @as(u8, @intCast((@as(u16, self.head) + i) % SIGINFO_QUEUE_CAPACITY));
            if (self.entries[idx].signo == signo) return true;
        }
        return false;
    }
};

# Data Model: Linux Compatibility Layer - Runtime Infrastructure

**Feature Branch**: `007-linux-compat-layer`
**Date**: 2025-12-05

This document defines the data structures and entities required for Linux runtime infrastructure.

---

## Entity Relationship Overview

```
Process (1) ─────────── (1) FileDescriptorTable
    │                           │
    │                           └─── (N) FileDescriptor
    │
    ├─── parent_pid ────── (1) Process (parent)
    │
    └─── state: ZOMBIE ─── ZombieEntry (when terminated)

KernelState (singleton)
    ├─── PRNG (xoroshiro128+)
    ├─── TSCCalibration
    └─── ZombieTable (bounded pool)
```

---

## 1. File Descriptor Entities

### FileDescriptorKind
```zig
/// Type of resource a file descriptor points to
pub const FileDescriptorKind = enum(u8) {
    /// FD is available for allocation
    Closed = 0,
    /// FD 0: Keyboard input (PS/2 scancode buffer)
    Keyboard = 1,
    /// FD 1/2: Console output (Serial + Framebuffer)
    Console = 2,
    /// FD 3+: File from InitRD
    InitRDFile = 3,
    /// Future: UDP socket
    Socket = 4,
};
```

### FileDescriptor
```zig
/// Individual file descriptor entry
pub const FileDescriptor = struct {
    /// What type of resource this FD references
    kind: FileDescriptorKind = .Closed,

    /// For InitRDFile: pointer to file metadata
    /// Null for devices (Keyboard, Console) and closed FDs
    initrd_entry: ?*const InitRDFileEntry = null,

    /// Current read/write position (for InitRDFile)
    position: u64 = 0,

    /// Open flags (O_RDONLY=0, O_WRONLY=1, O_RDWR=2)
    flags: u32 = 0,

    /// Check if FD is in use
    pub fn isOpen(self: *const FileDescriptor) bool {
        return self.kind != .Closed;
    }

    /// Reset FD to closed state
    pub fn close(self: *FileDescriptor) void {
        self.* = .{};
    }
};
```

### FileDescriptorTable
```zig
/// Per-process file descriptor table
/// Maximum 16 FDs per process (0-15)
pub const FileDescriptorTable = struct {
    pub const MAX_FDS = 16;
    pub const STDIN_FD = 0;
    pub const STDOUT_FD = 1;
    pub const STDERR_FD = 2;
    pub const FIRST_USER_FD = 3;

    /// Array of file descriptors indexed by FD number
    fds: [MAX_FDS]FileDescriptor = [_]FileDescriptor{.{}} ** MAX_FDS,

    /// Initialize with standard FDs pre-opened
    pub fn init(self: *FileDescriptorTable) void {
        // Pre-open stdin, stdout, stderr
        self.fds[STDIN_FD] = .{ .kind = .Keyboard, .flags = 0 }; // O_RDONLY
        self.fds[STDOUT_FD] = .{ .kind = .Console, .flags = 1 }; // O_WRONLY
        self.fds[STDERR_FD] = .{ .kind = .Console, .flags = 1 }; // O_WRONLY

        // Mark remaining FDs as closed
        for (FIRST_USER_FD..MAX_FDS) |i| {
            self.fds[i] = .{};
        }
    }

    /// Allocate lowest available FD (POSIX requirement)
    pub fn allocate(self: *FileDescriptorTable) ?u32 {
        for (0..MAX_FDS) |i| {
            if (!self.fds[i].isOpen()) {
                return @intCast(i);
            }
        }
        return null; // Table full (-EMFILE)
    }

    /// Get FD entry with bounds check
    pub fn get(self: *FileDescriptorTable, fd: u32) ?*FileDescriptor {
        if (fd >= MAX_FDS) return null;
        const entry = &self.fds[fd];
        return if (entry.isOpen()) entry else null;
    }
};
```

---

## 2. Process/Zombie Entities

### ProcessState (Extended)
```zig
/// Process execution state
pub const ProcessState = enum(u8) {
    /// Ready to run, in scheduler queue
    Ready = 0,
    /// Currently executing on CPU
    Running = 1,
    /// Blocked waiting for I/O or event
    Blocked = 2,
    /// Blocked in wait4() for child
    WaitingForChild = 3,
    /// Terminated, awaiting parent's wait4()
    Zombie = 4,
    /// Fully terminated and reaped
    Dead = 5,
};
```

### Process (Extended Fields)
```zig
/// Process control block - extended for wait4 support
pub const Process = struct {
    // ... existing fields from 003 spec ...

    /// Process identifier (unique)
    pid: u32,

    /// Parent process ID (0 for init process)
    parent_pid: u32 = 0,

    /// Current execution state
    state: ProcessState = .Ready,

    /// Exit code (valid when state == .Zombie)
    exit_code: i32 = 0,

    /// Signal that killed process (0 if normal exit)
    exit_signal: u8 = 0,

    /// Core dump flag (for wait4 status encoding)
    core_dumped: bool = false,

    /// Per-process file descriptor table
    fd_table: FileDescriptorTable = .{},

    /// Initialize process with pre-opened FDs
    pub fn init(self: *Process, pid: u32, parent_pid: u32) void {
        self.pid = pid;
        self.parent_pid = parent_pid;
        self.state = .Ready;
        self.fd_table.init();
    }

    /// Transition to zombie state on exit
    pub fn becomeZombie(self: *Process, code: i32) void {
        self.exit_code = code;
        self.exit_signal = 0;
        self.state = .Zombie;
        // Note: FD table and memory will be freed when reaped
    }

    /// Encode exit status for wait4
    pub fn encodeWaitStatus(self: *const Process) i32 {
        if (self.exit_signal == 0) {
            // Normal exit: code in bits 8-15
            return (@as(i32, self.exit_code) & 0xFF) << 8;
        } else {
            // Killed by signal: signal in bits 0-6, core dump in bit 7
            var status: i32 = self.exit_signal & 0x7F;
            if (self.core_dumped) status |= 0x80;
            return status;
        }
    }
};
```

### ZombieEntry
```zig
/// Minimal data retained for zombie processes
/// Used when parent hasn't called wait4 yet
pub const ZombieEntry = struct {
    /// Process ID
    pid: u32,
    /// Parent process ID
    parent_pid: u32,
    /// Encoded wait status (exit code or signal)
    status: i32,
    /// Whether this entry is in use
    valid: bool = false,
};
```

### ZombieTable
```zig
/// Bounded pool for zombie process entries
pub const ZombieTable = struct {
    pub const MAX_ZOMBIES = 64;

    entries: [MAX_ZOMBIES]ZombieEntry = [_]ZombieEntry{.{}} ** MAX_ZOMBIES,
    count: u32 = 0,

    /// Add zombie entry when process exits
    pub fn add(self: *ZombieTable, pid: u32, parent_pid: u32, status: i32) bool {
        if (self.count >= MAX_ZOMBIES) {
            // Table full - log warning, oldest zombie may be lost
            return false;
        }

        for (&self.entries) |*entry| {
            if (!entry.valid) {
                entry.* = .{
                    .pid = pid,
                    .parent_pid = parent_pid,
                    .status = status,
                    .valid = true,
                };
                self.count += 1;
                return true;
            }
        }
        return false;
    }

    /// Find and remove zombie for wait4
    pub fn reap(self: *ZombieTable, pid: i32, parent_pid: u32) ?ZombieEntry {
        for (&self.entries) |*entry| {
            if (!entry.valid) continue;
            if (entry.parent_pid != parent_pid) continue;

            // Match based on pid argument
            const matches = switch (pid) {
                -1 => true, // Any child
                0 => true,  // Any child in process group (simplified: same as -1)
                else => |p| if (p > 0) entry.pid == @as(u32, @intCast(p)) else true,
            };

            if (matches) {
                const result = entry.*;
                entry.valid = false;
                self.count -= 1;
                return result;
            }
        }
        return null;
    }

    /// Check if parent has any children (for ECHILD detection)
    pub fn hasChildren(self: *const ZombieTable, parent_pid: u32) bool {
        for (self.entries) |entry| {
            if (entry.valid and entry.parent_pid == parent_pid) {
                return true;
            }
        }
        return false;
    }
};
```

---

## 3. Time Entities

### Timespec
```zig
/// Linux-compatible time structure (16 bytes on x86_64)
pub const Timespec = extern struct {
    /// Seconds component
    tv_sec: i64,
    /// Nanoseconds component (0-999,999,999)
    tv_nsec: i64,

    pub fn fromNanoseconds(ns: u64) Timespec {
        return .{
            .tv_sec = @intCast(ns / 1_000_000_000),
            .tv_nsec = @intCast(ns % 1_000_000_000),
        };
    }

    pub fn toNanoseconds(self: Timespec) u64 {
        return @as(u64, @intCast(self.tv_sec)) * 1_000_000_000 +
               @as(u64, @intCast(self.tv_nsec));
    }
};
```

### ClockID
```zig
/// Linux clock identifiers
pub const ClockID = enum(i32) {
    /// Wall-clock time since Unix epoch
    CLOCK_REALTIME = 0,
    /// Time since boot, monotonically increasing
    CLOCK_MONOTONIC = 1,
    // Future: CLOCK_PROCESS_CPUTIME_ID = 2
    // Future: CLOCK_THREAD_CPUTIME_ID = 3
    _,

    pub fn isValid(id: i32) bool {
        return id == 0 or id == 1;
    }
};
```

### TSCCalibration
```zig
/// TSC frequency calibration data
pub const TSCCalibration = struct {
    /// TSC ticks per second (Hz)
    frequency_hz: u64 = 0,
    /// TSC value at boot (for monotonic base)
    boot_tsc: u64 = 0,
    /// Whether calibration succeeded
    calibrated: bool = false,

    /// Convert TSC ticks to nanoseconds
    pub fn tscToNanoseconds(self: *const TSCCalibration, tsc: u64) u64 {
        if (self.frequency_hz == 0) return 0;
        // (tsc * 1e9) / freq, handling overflow
        const seconds = tsc / self.frequency_hz;
        const remainder = tsc % self.frequency_hz;
        return seconds * 1_000_000_000 + (remainder * 1_000_000_000) / self.frequency_hz;
    }
};
```

---

## 4. Entropy/PRNG Entities

### Xoroshiro128Plus
```zig
/// Fast PRNG for getrandom syscall
/// Period: 2^128-1, passes BigCrush
pub const Xoroshiro128Plus = struct {
    s0: u64,
    s1: u64,

    /// Generate next 64-bit random value
    pub fn next(self: *Xoroshiro128Plus) u64 {
        const result = self.s0 +% self.s1;
        const s1 = self.s0 ^ self.s1;
        self.s0 = rotl(self.s0, 24) ^ s1 ^ (s1 << 16);
        self.s1 = rotl(s1, 37);
        return result;
    }

    /// Fill buffer with random bytes
    pub fn fill(self: *Xoroshiro128Plus, buf: []u8) void {
        var i: usize = 0;
        while (i < buf.len) {
            const rand = self.next();
            const bytes = @as(*const [8]u8, @ptrCast(&rand));
            const to_copy = @min(8, buf.len - i);
            @memcpy(buf[i..][0..to_copy], bytes[0..to_copy]);
            i += to_copy;
        }
    }

    fn rotl(x: u64, comptime k: u6) u64 {
        return (x << k) | (x >> (64 - k));
    }
};
```

### EntropyState
```zig
/// Kernel entropy state (singleton)
pub const EntropyState = struct {
    /// Main PRNG for getrandom
    prng: Xoroshiro128Plus = undefined,
    /// Whether PRNG has been seeded
    initialized: bool = false,
    /// RDRAND available (CPUID check)
    has_rdrand: bool = false,

    /// Initialize with hardware entropy
    pub fn init(self: *EntropyState) void {
        self.has_rdrand = checkRDRAND();

        var seed0: u64 = 0;
        var seed1: u64 = 0;

        if (self.has_rdrand) {
            seed0 = rdrandOrTsc();
            seed1 = rdrandOrTsc();
        } else {
            // RDTSC-based seeding with jitter
            seed0 = collectTscEntropy();
            seed1 = collectTscEntropy();
        }

        // Ensure non-zero (PRNG requirement)
        if (seed0 == 0) seed0 = 0x853c49e6748fea9b;
        if (seed1 == 0) seed1 = 0xda3e39cb94b95bdb;

        self.prng = .{ .s0 = seed0, .s1 = seed1 };
        self.initialized = true;
    }
};
```

---

## 5. Syscall Parameter Structures

### Wait4Options
```zig
/// Options for wait4 syscall
pub const Wait4Options = struct {
    pub const WNOHANG: u32 = 0x1;    // Return immediately if no child exited
    pub const WUNTRACED: u32 = 0x2;  // Also return for stopped children (not MVP)
    pub const WCONTINUED: u32 = 0x8; // Also return for continued children (not MVP)
};
```

### GetrandomFlags
```zig
/// Flags for getrandom syscall
pub const GetrandomFlags = struct {
    pub const GRND_NONBLOCK: u32 = 0x1; // Return -EAGAIN if would block
    pub const GRND_RANDOM: u32 = 0x2;   // Use /dev/random (MVP: same as default)
};
```

---

## 6. Error Codes

```zig
/// Linux errno values used by this feature
pub const Errno = struct {
    pub const ECHILD: i32 = 10;  // No child processes
    pub const EAGAIN: i32 = 11;  // Resource temporarily unavailable
    pub const EFAULT: i32 = 14;  // Bad address
    pub const EBADF: i32 = 9;    // Bad file descriptor
    pub const EINVAL: i32 = 22;  // Invalid argument
    pub const EMFILE: i32 = 24;  // Too many open files
};
```

---

## 7. Kernel Global State

```zig
/// Global kernel state for this feature (singleton)
pub const LinuxCompatState = struct {
    /// TSC calibration data
    tsc: TSCCalibration = .{},

    /// Entropy/PRNG state
    entropy: EntropyState = .{},

    /// Zombie process table
    zombies: ZombieTable = .{},

    /// Boot epoch for CLOCK_REALTIME (2025-01-01 00:00:00 UTC)
    boot_epoch_seconds: u64 = 1735689600,

    /// Initialize all subsystems
    pub fn init(self: *LinuxCompatState) void {
        self.tsc = calibrateTSC();
        self.entropy.init();
        // zombies start empty
    }
};

/// Global instance
pub var linux_compat: LinuxCompatState = .{};
```

---

## Validation Rules

### File Descriptor Validation
- FD must be in range [0, 15]
- FD must be open (kind != .Closed)
- FD kind must support requested operation (e.g., can't write to Keyboard)

### wait4 Validation
- Caller must have at least one child process
- If pid > 0, must match a child's PID
- wstatus pointer must be valid user address (or null)
- options must not have reserved bits set

### clock_gettime Validation
- clock_id must be 0 (REALTIME) or 1 (MONOTONIC)
- timespec pointer must be valid user address
- timespec must be 8-byte aligned

### getrandom Validation
- buf pointer must be valid user address
- buflen must be reasonable (kernel may limit to 256 bytes per call)
- flags must not have reserved bits set

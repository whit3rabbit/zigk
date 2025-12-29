const std = @import("std");
const root = @import("root");
const builtin = @import("builtin");

/// Userspace syscall wrappers (inlined to avoid module conflicts)
const userspace = struct {
    pub fn syscall2(number: usize, arg1: usize, arg2: usize) usize {
        if (comptime builtin.cpu.arch == .x86_64) {
            var ret: usize = undefined;
            asm volatile ("syscall"
                : [ret] "={rax}" (ret)
                : [number] "{rax}" (number),
                  [arg1] "{rdi}" (arg1),
                  [arg2] "{rsi}" (arg2)
                : .{ .rcx = true, .r11 = true, .memory = true }
            );
            return ret;
        } else if (comptime builtin.cpu.arch == .aarch64) {
            var ret: usize = undefined;
            asm volatile ("svc #0"
                : [ret] "={x0}" (ret)
                : [number] "{x8}" (number),
                  [arg1] "{x0}" (arg1),
                  [arg2] "{x1}" (arg2)
                : .{ .memory = true }
            );
            return ret;
        }
        return 0;
    }

    pub fn syscall3(number: usize, arg1: usize, arg2: usize, arg3: usize) usize {
        if (comptime builtin.cpu.arch == .x86_64) {
            var ret: usize = undefined;
            asm volatile ("syscall"
                : [ret] "={rax}" (ret)
                : [number] "{rax}" (number),
                  [arg1] "{rdi}" (arg1),
                  [arg2] "{rsi}" (arg2),
                  [arg3] "{rdx}" (arg3)
                : .{ .rcx = true, .r11 = true, .memory = true }
            );
            return ret;
        } else if (comptime builtin.cpu.arch == .aarch64) {
            var ret: usize = undefined;
            asm volatile ("svc #0"
                : [ret] "={x0}" (ret)
                : [number] "{x8}" (number),
                  [arg1] "{x0}" (arg1),
                  [arg2] "{x1}" (arg2),
                  [arg3] "{x2}" (arg3)
                : .{ .memory = true }
            );
            return ret;
        }
        return 0;
    }
};

pub const entropy = struct {
    pub fn getHardwareEntropy() u64 {
        if (@hasDecl(root, "hal")) {
            return root.hal.entropy.getHardwareEntropy();
        } else {
            // Userspace: use getrandom syscall (SYS_GETRANDOM = 318)
            // SECURITY: Zero-initialize buffer to prevent stack data leakage
            // if syscall returns partial data before we detect and panic.
            // Defense-in-depth per CLAUDE.md security guidelines.
            var buf: [8]u8 = [_]u8{0} ** 8;
            const ret = userspaceGetrandom(&buf, 8, 0);
            if (ret == 8) {
                return std.mem.readInt(u64, &buf, .little);
            }
            // Syscall failed - this is a security-critical failure
            // Return a value that will cause obvious failures rather than
            // silently using weak entropy
            @panic("getrandom syscall failed - cannot provide secure entropy");
        }
    }

    pub fn getRandomU64() u64 {
        if (@hasDecl(root, "random")) {
            return root.random.getU64();
        } else {
            // Userspace: use hardware entropy directly as a simple PRNG
            return getHardwareEntropy();
        }
    }


    /// Make getrandom syscall (userspace only)
    /// SYS_GETRANDOM = 318 on x86_64 Linux ABI
    fn userspaceGetrandom(buf: [*]u8, count: usize, flags: u32) isize {
        const SYS_GETRANDOM: usize = 318;
        if (builtin.cpu.arch == .x86_64) {
            const ret = userspace.syscall3(SYS_GETRANDOM, @intFromPtr(buf), count, flags);
            return @as(isize, @bitCast(ret));
        }
        return -1;
    }
};

pub const timing = struct {
    pub fn rdtsc() u64 {
        if (@hasDecl(root, "hal")) {
            return root.hal.timing.rdtsc();
        } else {
            // Userspace: use clock_gettime(CLOCK_MONOTONIC) via syscall
            return userspaceGetMonotonicNs();
        }
    }

    pub fn hasTimedOut(start: u64, timeout_us: u64) bool {
        if (@hasDecl(root, "hal")) {
            return root.hal.timing.hasTimedOut(start, timeout_us);
        } else {
            // Userspace: compare monotonic timestamps in nanoseconds
            const now = userspaceGetMonotonicNs();
            const elapsed_ns = now -| start; // saturating subtract
            const timeout_ns = std.math.mul(u64, timeout_us, 1000) catch std.math.maxInt(u64);
            return elapsed_ns >= timeout_ns;
        }
    }

    /// Timespec for clock_gettime
    const Timespec = extern struct {
        tv_sec: i64,
        tv_nsec: i64,
    };

    /// Get monotonic time in nanoseconds via syscall
    fn userspaceGetMonotonicNs() u64 {
        const SYS_CLOCK_GETTIME: usize = 228;
        const CLOCK_MONOTONIC: usize = 1;
        // Security: Zero-init to prevent undefined behavior on syscall failure (CLAUDE.md)
        var ts: Timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
        var ret: isize = -1;

        if (builtin.cpu.arch == .x86_64) {
            const ret_val = userspace.syscall2(SYS_CLOCK_GETTIME, CLOCK_MONOTONIC, @intFromPtr(&ts));
            ret = @as(isize, @bitCast(ret_val));
        } else {
            ret = -1;
        }

        if (ret < 0) {
            // Syscall failed - return 0 and let caller handle
            return 0;
        }

        const sec_ns: u64 = @intCast(ts.tv_sec);
        const nsec: u64 = @intCast(ts.tv_nsec);
        const sec_total = std.math.mul(u64, sec_ns, 1_000_000_000) catch std.math.maxInt(u64);
        return std.math.add(u64, sec_total, nsec) catch std.math.maxInt(u64);
    }
};

pub const cpu = struct {
    pub fn disableInterrupts() void {
        if (@hasDecl(root, "hal")) {
            root.hal.cpu.disableInterrupts();
        }
    }

    pub fn disableInterruptsSaveFlags() u64 {
        if (@hasDecl(root, "hal")) {
            return root.hal.cpu.disableInterruptsSaveFlags();
        }
        return 0;
    }

    pub fn restoreInterrupts(flags: u64) void {
        if (@hasDecl(root, "hal")) {
            root.hal.cpu.restoreInterrupts(flags);
        }
    }

    pub fn enableInterrupts() void {
        if (@hasDecl(root, "hal")) {
            root.hal.cpu.enableInterrupts();
        }
    }

    pub fn halt() void {
        if (@hasDecl(root, "hal")) {
            root.hal.cpu.halt();
        } else {
            // Userspace yield
            // syscall.sched_yield();
        }
    }
};

const std = @import("std");
const root = @import("root");
const builtin = @import("builtin");

pub const entropy = struct {
    pub fn getHardwareEntropy() u64 {
        if (@hasDecl(root, "hal")) {
            return root.hal.entropy.getHardwareEntropy();
        } else {
            // Userspace: use getrandom syscall (SYS_GETRANDOM = 318)
            var buf: [8]u8 = undefined;
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

    /// Make getrandom syscall directly via inline assembly (userspace only)
    /// SYS_GETRANDOM = 318 on x86_64 Linux ABI
    fn userspaceGetrandom(buf: [*]u8, count: usize, flags: u32) isize {
        const SYS_GETRANDOM: usize = 318;
        var ret: isize = undefined;
        asm volatile ("syscall"
            : [ret] "={rax}" (ret)
            : [number] "{rax}" (SYS_GETRANDOM),
              [arg1] "{rdi}" (@intFromPtr(buf)),
              [arg2] "{rsi}" (count),
              [arg3] "{rdx}" (flags),
            : .{ .rcx = true, .r11 = true, .memory = true }
        );
        return ret;
    }
};

pub const timing = struct {
    pub fn rdtsc() u64 {
        if (@hasDecl(root, "hal")) {
            return root.hal.timing.rdtsc();
        } else {
            // Userspace: use dummy or rdtsc if allowed
            // Ideally we use clock_gettime via syscall, but for simple timing loops:
            return 0; // TODO
        }
    }

    pub fn hasTimedOut(start: u64, timeout_us: u64) bool {
        if (@hasDecl(root, "hal")) {
            return root.hal.timing.hasTimedOut(start, timeout_us);
        } else {
            // Userspace timeout check
            // For now always return false or handle properly
            return false;
        }
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

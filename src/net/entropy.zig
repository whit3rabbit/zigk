const std = @import("std");
const root = @import("root");

pub fn getEntropy() u64 {
    if (@hasDecl(root, "hal")) {
        // Kernel mode
        return root.hal.entropy.getHardwareEntropy();
    } else {
        // Userspace: use getrandom syscall (SYS_GETRANDOM = 318)
        var buf: [8]u8 = undefined;
        const ret = userspaceGetrandom(&buf, 8, 0);
        if (ret == 8) {
            return std.mem.readInt(u64, &buf, .little);
        }
        // Syscall failed - this is a security-critical failure
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

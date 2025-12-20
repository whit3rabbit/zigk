const std = @import("std");
const root = @import("root");

const EINTR: usize = 4; // Interrupted system call

pub fn getEntropy() u64 {
    if (@hasDecl(root, "hal")) {
        // Kernel mode
        return root.hal.entropy.getHardwareEntropy();
    } else {
        // Userspace: use getrandom syscall (SYS_GETRANDOM = 318)
        // Zero-init to prevent reading uninitialized memory on error paths
        var buf: [8]u8 = .{0} ** 8;
        var total: usize = 0;

        while (total < 8) {
            const ret = userspaceGetrandom(buf[total..].ptr, 8 - total, 0);
            if (ret < 0) {
                const errno: usize = @intCast(-ret);
                if (errno == EINTR) {
                    continue; // Retry on signal interruption
                }
                @panic("getrandom syscall failed - cannot provide secure entropy");
            }
            total += @intCast(ret);
        }
        return std.mem.readInt(u64, &buf, .little);
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

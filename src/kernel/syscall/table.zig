// Syscall Dispatch Table
//
// Dispatches syscalls to their handlers based on syscall number.
// All syscall numbers are imported from uapi.syscalls to ensure
// kernel/userland consistency (single source of truth).
//
// Syscall Convention (x86_64 Linux ABI):
//   RAX = syscall number
//   RDI, RSI, RDX, R10, R8, R9 = arguments 1-6
//   RAX = return value (or negative errno on error)

const uapi = @import("uapi");
const handlers = @import("handlers.zig");
const random = @import("random.zig");
const syscalls = uapi.syscalls;
const console = @import("console");
const hal = @import("hal");

/// Syscall frame from arch-specific entry
pub const SyscallFrame = hal.syscall.SyscallFrame;

/// Type signature for all syscall handlers
/// Takes 6 arguments (unused args are ignored by handlers)
const SyscallHandler = *const fn (arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize, arg6: usize) isize;

/// Dispatch a syscall and return the result
/// Called from the assembly syscall entry point
pub export fn dispatch_syscall(frame: *SyscallFrame) callconv(.c) void {
    const syscall_num = frame.getSyscallNumber();
    const args = frame.getArgs();

    // Dispatch based on syscall number
    const result = switch (syscall_num) {
        // Linux x86_64 ABI syscalls - I/O
        syscalls.SYS_READ => handlers.sys_read(args[0], args[1], args[2]),
        syscalls.SYS_WRITE => handlers.sys_write(args[0], args[1], args[2]),
        syscalls.SYS_OPEN => handlers.sys_open(args[0], args[1], args[2]),
        syscalls.SYS_CLOSE => handlers.sys_close(args[0]),

        // Memory management (stubs)
        syscalls.SYS_MMAP => handlers.sys_mmap(args[0], args[1], args[2], args[3], args[4], args[5]),
        syscalls.SYS_MPROTECT => handlers.sys_mprotect(args[0], args[1], args[2]),
        syscalls.SYS_MUNMAP => handlers.sys_munmap(args[0], args[1]),
        syscalls.SYS_BRK => handlers.sys_brk(args[0]),

        // Scheduling
        syscalls.SYS_SCHED_YIELD => handlers.sys_sched_yield(),
        syscalls.SYS_NANOSLEEP => handlers.sys_nanosleep(args[0], args[1]),

        // Process info
        syscalls.SYS_GETPID => handlers.sys_getpid(),
        syscalls.SYS_GETPPID => handlers.sys_getppid(),
        syscalls.SYS_GETUID => handlers.sys_getuid(),
        syscalls.SYS_GETGID => handlers.sys_getgid(),

        // Networking (stubs for Phase 7)
        syscalls.SYS_SOCKET => handlers.sys_socket(args[0], args[1], args[2]),
        syscalls.SYS_SENDTO => handlers.sys_sendto(args[0], args[1], args[2], args[3], args[4], args[5]),
        syscalls.SYS_RECVFROM => handlers.sys_recvfrom(args[0], args[1], args[2], args[3], args[4], args[5]),

        // Process control (stubs)
        syscalls.SYS_FORK => handlers.sys_fork(),
        syscalls.SYS_EXECVE => handlers.sys_execve(args[0], args[1], args[2]),
        syscalls.SYS_EXIT => handlers.sys_exit(args[0]),
        syscalls.SYS_WAIT4 => handlers.sys_wait4(args[0], args[1], args[2], args[3]),
        syscalls.SYS_EXIT_GROUP => handlers.sys_exit_group(args[0]),

        // Thread state
        syscalls.SYS_ARCH_PRCTL => handlers.sys_arch_prctl(args[0], args[1]),

        // Time
        syscalls.SYS_CLOCK_GETTIME => handlers.sys_clock_gettime(args[0], args[1]),

        // Random
        syscalls.SYS_GETRANDOM => random.sys_getrandom(args[0], args[1], @truncate(args[2])),

        // ZigK custom syscalls
        syscalls.SYS_DEBUG_LOG => handlers.sys_debug_log(args[0], args[1]),
        syscalls.SYS_GET_FB_INFO => handlers.sys_get_fb_info(args[0]),
        syscalls.SYS_MAP_FB => handlers.sys_map_fb(),
        syscalls.SYS_READ_SCANCODE => handlers.sys_read_scancode(),
        syscalls.SYS_GETCHAR => handlers.sys_getchar(),
        syscalls.SYS_PUTCHAR => handlers.sys_putchar(args[0]),

        // Unknown syscall
        else => blk: {
            console.debug("Unknown syscall: {d}", .{syscall_num});
            break :blk uapi.errno.ENOSYS.toReturn();
        },
    };

    // Set return value in frame
    frame.setReturnSigned(result);
}

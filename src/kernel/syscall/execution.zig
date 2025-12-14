// Execution Syscall Handlers
//
// Implements process execution and architecture-specific syscalls:
// - sys_fork: Create child process
// - sys_execve: Execute program
// - sys_arch_prctl: Architecture-specific thread state (TLS)
// - sys_get_fb_info, sys_map_fb: Framebuffer access
// - Network stubs (socket, sendto, recvfrom)

const std = @import("std");
const base = @import("base.zig");
const uapi = @import("uapi");
const console = @import("console");
const hal = @import("hal");
const sched = @import("sched");
const process_mod = @import("process");
const thread = @import("thread");
const vmm = @import("vmm");
const pmm = @import("pmm");
const heap = @import("heap");
const elf = @import("elf");
const framebuffer = @import("framebuffer");
const fs = @import("fs");
const user_mem = @import("user_mem");
const user_vmm = @import("user_vmm");

const SyscallError = base.SyscallError;
const UserPtr = base.UserPtr;
const isValidUserPtr = base.isValidUserPtr;
const Process = base.Process;

// =============================================================================
// Network Stubs
// =============================================================================

/// sys_socket (41) - Create a socket
/// MVP: Returns -ENOSYS (networking not implemented)
pub fn sys_socket(domain: usize, sock_type: usize, protocol: usize) SyscallError!usize {
    _ = domain;
    _ = sock_type;
    _ = protocol;
    // Networking will be implemented in Phase 7
    return error.ENOSYS;
}

/// sys_sendto (44) - Send a message on a socket
/// MVP: Returns -ENOSYS (networking not implemented)
pub fn sys_sendto(fd: usize, buf_ptr: usize, len: usize, flags: usize, addr_ptr: usize, addrlen: usize) SyscallError!usize {
    _ = fd;
    _ = buf_ptr;
    _ = len;
    _ = flags;
    _ = addr_ptr;
    _ = addrlen;
    return error.ENOSYS;
}

/// sys_recvfrom (45) - Receive a message from a socket
/// MVP: Returns -ENOSYS (networking not implemented)
pub fn sys_recvfrom(fd: usize, buf_ptr: usize, len: usize, flags: usize, addr_ptr: usize, addrlen_ptr: usize) SyscallError!usize {
    _ = fd;
    _ = buf_ptr;
    _ = len;
    _ = flags;
    _ = addr_ptr;
    _ = addrlen_ptr;
    return error.ENOSYS;
}

// =============================================================================
// Process Execution
// =============================================================================

/// sys_fork (57) - Create a child process
///
/// Creates a new process by duplicating the calling process.
/// The child process has:
///   - Copied address space (all VMAs and their contents)
///   - Duplicated file descriptor table
///   - Parent set to the calling process
///
/// Returns:
///   - Child PID to parent process
///   - 0 to child process
///   - Negative errno on error
pub fn sys_fork(frame: *hal.syscall.SyscallFrame) SyscallError!usize {
    // Get current process
    const parent_proc = base.getCurrentProcess();

    // Fork the process (copies address space and FDs)
    const child_proc = process_mod.forkProcess(parent_proc) catch |err| {
        console.err("sys_fork: Failed to fork process: {}", .{err});
        return error.ENOMEM;
    };

    // Get current thread to copy its state
    const parent_thread = sched.getCurrentThread() orelse {
        // No current thread - this shouldn't happen
        process_mod.destroyProcess(child_proc);
        return error.ESRCH;
    };

    // Create child thread
    // The child thread needs to be set up to return 0 from this syscall
    const child_thread = thread.createUserThread(
        0, // Entry point will be set from parent's saved state
        .{
            .name = parent_thread.getName(),
            .cr3 = child_proc.cr3,
            .user_stack_top = parent_thread.user_stack_top,
            .process = @ptrCast(child_proc),
        },
    ) catch {
        process_mod.destroyProcess(child_proc);
        return error.ENOMEM;
    };

    // Copy parent's kernel stack frame to child
    // This makes the child resume at the same point as parent
    copyThreadState(frame, parent_thread, child_thread);

    // Set child's return value to 0 (RAX in syscall return)
    // The return value is stored in the saved interrupt frame
    setForkChildReturn(child_thread);

    // Set up parent-child relationship in thread hierarchy
    thread.addChild(parent_thread, child_thread);

    // Add child thread to scheduler
    sched.addThread(child_thread);

    // Return child PID to parent
    return child_proc.pid;
}

/// Copy thread state from parent to child for fork
fn copyThreadState(
    parent_frame: *hal.syscall.SyscallFrame,
    parent: *thread.Thread,
    child: *thread.Thread,
) void {
    // Build a fresh interrupt frame for the child using the live syscall frame.
    const child_frame: *hal.idt.InterruptFrame = @ptrFromInt(child.kernel_rsp);

    child_frame.* = .{
        .r15 = parent_frame.r15,
        .r14 = parent_frame.r14,
        .r13 = parent_frame.r13,
        .r12 = parent_frame.r12,
        .r11 = 0, // Clobbered by SYSCALL, leave zeroed for cleanliness
        .r10 = parent_frame.r10,
        .r9 = parent_frame.r9,
        .r8 = parent_frame.r8,
        .rdi = parent_frame.rdi,
        .rsi = parent_frame.rsi,
        .rbp = parent_frame.rbp,
        .rdx = parent_frame.rdx,
        .rcx = parent_frame.rcx, // RCX is clobbered by SYSCALL; keep value for parity
        .rbx = parent_frame.rbx,
        .rax = parent_frame.rax,
        .vector = 0,
        .error_code = 0,
        .rip = parent_frame.getReturnRip(),
        .cs = hal.gdt.USER_CODE,
        .rflags = parent_frame.r11,
        .rsp = parent_frame.getUserRsp(),
        .ss = hal.gdt.USER_DATA,
    };

    // Copy FS base (TLS)
    child.fs_base = parent.fs_base;
}

/// Set the child's return value to 0 for fork
/// Modifies RAX in the saved interrupt frame
fn setForkChildReturn(child: *thread.Thread) void {
    // The interrupt frame has RAX as the first GPR after vec/err
    // Stack layout (from bottom, growing down):
    // [SS, RSP, RFLAGS, CS, RIP, err, vec, RAX, RBX, ...]
    // RAX is at offset 14*8 from the top of the frame

    // The child's kernel_rsp points to the bottom of the saved frame
    // RAX is at offset (frame_size - 8*1) from kernel_rsp
    // Actually, RAX is the first GPR pushed, so it's at the highest address
    // in the GPR section

    // Frame layout from low to high addresses (kernel_rsp points here):
    // R15, R14, R13, R12, R11, R10, R9, R8, RDI, RSI, RBP, RDX, RCX, RBX, RAX
    // vec, err, RIP, CS, RFLAGS, RSP, SS

    const frame: *hal.idt.InterruptFrame = @ptrFromInt(child.kernel_rsp);
    frame.rax = 0; // Child gets 0 from fork()
}

/// sys_execve (59) - Execute a program
///
/// Replaces the current process image with a new program.
/// The new program is loaded from the specified path (InitRD lookup).
///
/// Args:
///   frame: SyscallFrame pointer (needed to redirect execution on success)
///   path_ptr: Pointer to null-terminated path string
///   argv_ptr: Pointer to null-terminated array of argument pointers
///   envp_ptr: Pointer to null-terminated array of environment pointers
///
/// Returns:
///   Does not return on success (new program starts)
///   -ENOENT if executable not found
///   -EFAULT for invalid pointers
///   -ENOEXEC for invalid executable format
///
/// Note: Currently only supports executables loaded via InitRD modules.
/// Filesystem-based executables require VFS implementation.
pub fn sys_execve(frame: *hal.syscall.SyscallFrame, path_ptr: usize, argv_ptr: usize, envp_ptr: usize) SyscallError!usize {
    // Allocate path buffer on heap to preserve stack space
    const path_buf = heap.allocator().alloc(u8, user_mem.MAX_PATH_LEN) catch {
        return error.ENOMEM;
    };
    defer heap.allocator().free(path_buf);

    // Validate and read path string from userspace
    const path = user_mem.copyStringFromUser(path_buf, path_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };

    if (path.len == 0) {
        return error.ENOENT;
    }

    console.debug("sys_execve: path='{s}'", .{path});

    // Parse argv and envp (collect up to 64 arguments each)
    // Heap-allocate the data buffer (128KB like Linux) to avoid stack overflow
    // and return proper E2BIG error if arguments exceed limit.
    const MAX_ARG_SIZE = 128 * 1024; // 128KB like Linux ARG_MAX
    const MAX_ARG_STRLEN = 4096; // 4KB per-argument limit (like Linux PAGE_SIZE)
    const alloc = heap.allocator();
    const arg_data_buf = alloc.alloc(u8, MAX_ARG_SIZE) catch {
        return error.ENOMEM;
    };
    defer alloc.free(arg_data_buf);

    var arg_data_idx: usize = 0;
    var argv_storage: [64][]const u8 = undefined;
    var argc: usize = 0;

    if (argv_ptr != 0) {
        var i: usize = 0;
        while (argc < 64) : (i += 1) {
            const ptr_addr = argv_ptr + i * @sizeOf(usize);
            const arg_ptr = UserPtr.from(ptr_addr).readValue(usize) catch break;

            if (arg_ptr == 0) break; // Null terminator of argv array

            const remaining_space = arg_data_buf[arg_data_idx..];
            // Return E2BIG if we've exhausted the argument buffer
            if (remaining_space.len == 0) {
                return error.E2BIG;
            }

            const arg_slice = user_mem.copyStringFromUser(remaining_space, arg_ptr) catch |err| {
                if (err == error.NameTooLong) return error.E2BIG;
                return error.EFAULT;
            };

            // Per-argument length limit (security hardening)
            if (arg_slice.len > MAX_ARG_STRLEN) {
                return error.E2BIG;
            }

            argv_storage[argc] = arg_slice;
            arg_data_idx += arg_slice.len + 1; // +1 for null terminator space
            argc += 1;
        }
        // Check if we hit the 64 argument limit
        if (argc == 64) {
            const ptr_addr = argv_ptr + 64 * @sizeOf(usize);
            if (UserPtr.from(ptr_addr).readValue(usize)) |arg_ptr| {
                if (arg_ptr != 0) return error.E2BIG; // More than 64 args
            } else |_| {}
        }
    }

    const argv = argv_storage[0..argc];

    // Parse envp (collect up to 64 environment variables)
    var envp_storage: [64][]const u8 = undefined;
    var envc: usize = 0;

    if (envp_ptr != 0) {
        var i: usize = 0;
        while (envc < 64) : (i += 1) {
            const ptr_addr = envp_ptr + i * @sizeOf(usize);
            const env_ptr = UserPtr.from(ptr_addr).readValue(usize) catch break;

            if (env_ptr == 0) break;

            const remaining_space = arg_data_buf[arg_data_idx..];
            // Return E2BIG if we've exhausted the argument buffer
            if (remaining_space.len == 0) {
                return error.E2BIG;
            }

            const env_slice = user_mem.copyStringFromUser(remaining_space, env_ptr) catch |err| {
                if (err == error.NameTooLong) return error.E2BIG;
                return error.EFAULT;
            };

            // Per-argument length limit (security hardening)
            if (env_slice.len > MAX_ARG_STRLEN) {
                return error.E2BIG;
            }

            envp_storage[envc] = env_slice;
            arg_data_idx += env_slice.len + 1; // +1 for null terminator space
            envc += 1;
        }
    }

    const envp = envp_storage[0..envc];

    // argv and envp are parsed and ready for ELF loader
    // Using them below in elf.exec

    console.debug("sys_execve: argc={}, envc={}", .{ argc, envc });

    // Look up executable in InitRD
    const file = fs.initrd.InitRD.instance.findFile(path) orelse {
        // Executable not found
        return error.ENOENT;
    };

    // Load and execute ELF
    // This creates a new address space and sets up the stack
    const result = elf.exec(file.data, argv, envp) catch |err| {
        console.err("sys_execve: Failed to exec: {}", .{err});
        return error.ENOEXEC;
    };

    console.debug("sys_execve: Loaded ELF entry={x} stack={x} cr3={x}", .{
        result.entry_point,
        result.stack_pointer,
        result.pml4_phys,
    });

    // Vulnerability Fix: Ensure entry_point is canonical low-half address
    // sysretq throws #GP if RCX (return RIP) is non-canonical.
    if (!user_mem.isValidUserPtr(result.entry_point, 1)) {
        return error.EFAULT;
    }

    const current_thread = sched.getCurrentThread().?;
    const current_proc = base.getCurrentProcess();

    // Save old CR3 to destroy later
    // Save old CR3 to destroy later
    const old_cr3 = current_proc.cr3;

    // Update process/thread state
    current_proc.cr3 = result.pml4_phys;
    current_proc.heap_start = result.heap_start;
    current_proc.heap_break = result.heap_start;
    current_thread.cr3 = result.pml4_phys;

    // Switch to new address space immediately
    hal.cpu.writeCr3(result.pml4_phys);

    // Update the SyscallFrame to return to the new entry point with new stack.
    // Using the typed SyscallFrame struct instead of magic offsets ensures
    // correctness even if the frame layout changes in asm_helpers.S.
    frame.setReturnRip(result.entry_point);
    frame.setUserRsp(result.stack_pointer);

    // Clear inherited register state so the new program starts with clean GPRs.
    zeroExecveRegisters(frame);

    // Destroy old address space
    vmm.destroyAddressSpace(old_cr3);

    // Return 0 - this gets placed in RAX by the dispatcher.
    // On successful execve, this value becomes the argc seen by _start
    // (though typically argc comes from the stack, not RAX).
    return 0;
}

/// Zero general-purpose registers in the syscall frame for execve
/// Keeps RIP (rcx) and RSP intact; sets RFLAGS to a clean user value.
fn zeroExecveRegisters(frame: *hal.syscall.SyscallFrame) void {
    frame.r15 = 0;
    frame.r14 = 0;
    frame.r13 = 0;
    frame.r12 = 0;
    frame.rbp = 0;
    frame.rbx = 0;
    frame.r9 = 0;
    frame.r8 = 0;
    frame.r10 = 0;
    frame.rdx = 0;
    frame.rsi = 0;
    frame.rdi = 0;
    frame.rax = 0;
    // rcx holds return RIP for SYSRET; keep as set by setReturnRip
    // Provide clean user RFLAGS (IF=1, reserved bit 1 set)
    frame.r11 = 0x202;
}

// =============================================================================
// Architecture Control
// =============================================================================

// arch_prctl operation codes (Linux ABI)
const ARCH_SET_GS: usize = 0x1001;
const ARCH_SET_FS: usize = 0x1002;
const ARCH_GET_FS: usize = 0x1003;
const ARCH_GET_GS: usize = 0x1004;

/// sys_arch_prctl (158) - Set architecture-specific thread state
///
/// Manages FS/GS segment bases for Thread Local Storage (TLS).
/// Only FS operations are supported; GS is reserved for kernel use.
///
/// Args:
///   code - Operation: ARCH_SET_FS (0x1002) or ARCH_GET_FS (0x1003)
///   addr - For SET: new FS base value. For GET: pointer to store current value.
///
/// Returns:
///   0 on success
///   -EINVAL for unsupported operation codes
///   -EFAULT for invalid user pointer (GET only)
pub fn sys_arch_prctl(code: usize, addr: usize) SyscallError!usize {
    const curr = sched.getCurrentThread() orelse {
        // No current thread - should not happen in normal operation
        return error.ESRCH;
    };

    switch (code) {
        ARCH_SET_FS => {
            // Store FS base in thread struct for context switch restoration
            curr.fs_base = addr;
            // Write to IA32_FS_BASE MSR for immediate effect
            hal.cpu.writeMsr(hal.cpu.IA32_FS_BASE, addr);
            return 0;
        },
        ARCH_GET_FS => {
            // Validate user pointer
            if (!isValidUserPtr(addr, @sizeOf(u64))) {
                return error.EFAULT;
            }
            // Write current FS base to user pointer using safe copy
            UserPtr.from(addr).writeValue(curr.fs_base) catch {
                return error.EFAULT;
            };
            return 0;
        },
        ARCH_SET_GS, ARCH_GET_GS => {
            // GS is reserved for kernel use (SWAPGS, per-CPU data)
            return error.EINVAL;
        },
        else => {
            return error.EINVAL;
        },
    }
}

// =============================================================================
// Framebuffer Syscalls
// =============================================================================

/// sys_get_fb_info (1001) - Get framebuffer info
///
/// Copies framebuffer dimensions and pixel format to userspace struct.
/// Returns 0 on success, -ENODEV if no framebuffer available,
/// -EFAULT for invalid pointer.
pub fn sys_get_fb_info(info_ptr: usize) SyscallError!usize {
    // FramebufferInfo is 24 bytes: 4*u32 + 6*u8 + 2*u8 padding
    const info_size: usize = 24;

    // Get framebuffer state from module (returns null if not available)
    const fb_state = framebuffer.getState() orelse {
        return error.ENODEV;
    };

    // Build framebuffer info in kernel buffer first
    // Struct layout must match FramebufferInfo in user/lib/syscall.zig
    var info_buf: [info_size]u8 = undefined;

    // Width (u32, offset 0)
    std.mem.writeInt(u32, info_buf[0..4], fb_state.width, .little);
    // Height (u32, offset 4)
    std.mem.writeInt(u32, info_buf[4..8], fb_state.height, .little);
    // Pitch (u32, offset 8)
    std.mem.writeInt(u32, info_buf[8..12], fb_state.pitch, .little);
    // Bpp (u32, offset 12) - extend u8 to u32 for struct field
    std.mem.writeInt(u32, info_buf[12..16], @as(u32, fb_state.bpp), .little);
    // Red shift (u8, offset 16)
    info_buf[16] = fb_state.red_shift;
    // Red mask size (u8, offset 17)
    info_buf[17] = fb_state.red_mask_size;
    // Green shift (u8, offset 18)
    info_buf[18] = fb_state.green_shift;
    // Green mask size (u8, offset 19)
    info_buf[19] = fb_state.green_mask_size;
    // Blue shift (u8, offset 20)
    info_buf[20] = fb_state.blue_shift;
    // Blue mask size (u8, offset 21)
    info_buf[21] = fb_state.blue_mask_size;
    // Reserved bytes (offset 22-23)
    info_buf[22] = 0;
    info_buf[23] = 0;

    // Copy to userspace using safe copy (handles faults gracefully)
    const uptr = UserPtr.from(info_ptr);
    _ = uptr.copyFromKernel(&info_buf) catch {
        return error.EFAULT;
    };

    console.debug("sys_get_fb_info: {d}x{d}x{d}", .{
        fb_state.width,
        fb_state.height,
        fb_state.bpp,
    });

    return 0;
}

/// sys_map_fb (1002) - Map framebuffer into process address space
///
/// Maps the physical framebuffer memory into the calling process's
/// address space at a fixed virtual address. Returns the virtual
/// address on success, or negative errno on failure.
///
/// Returns:
///   Virtual address on success (positive)
///   -ENODEV if no framebuffer available
///   -ENOMEM if mapping failed
pub fn sys_map_fb() SyscallError!usize {
    // Get framebuffer state from module
    const fb_state = framebuffer.getState() orelse {
        return error.ENODEV;
    };

    // Get current process for page table
    const proc = base.getCurrentProcess();

    // Fixed virtual address for framebuffer in user space
    // Using high address to avoid conflicts with heap/stack
    const fb_virt_base: u64 = 0x0000_4000_0000_0000; // 64 TB mark

    // Calculate page-aligned size
    const fb_size = std.mem.alignForward(usize, fb_state.size, pmm.PAGE_SIZE);

    // Page flags for framebuffer: user accessible, writable, write-through for MMIO
    // Note: present/accessed/dirty are set automatically by the page table code
    const flags = hal.paging.PageFlags{
        .writable = true,
        .user = true,
        .write_through = true, // Write-through for framebuffer coherency
        .cache_disable = false,
        .global = false,
        .no_execute = true, // Framebuffer is data, not code
    };

    // Map framebuffer physical memory into user address space
    vmm.mapRange(proc.cr3, fb_virt_base, fb_state.phys_addr, fb_size, flags) catch |err| {
        console.err("sys_map_fb: Failed to map FB: {}", .{err});
        return error.ENOMEM;
    };

    const fb_vma = proc.user_vmm.createVma(
        fb_virt_base,
        fb_virt_base + fb_size,
        user_vmm.PROT_READ | user_vmm.PROT_WRITE,
        user_vmm.MAP_SHARED | user_vmm.MAP_DEVICE,
    ) catch {
        var offset: usize = 0;
        while (offset < fb_size) : (offset += pmm.PAGE_SIZE) {
            vmm.unmapPage(proc.cr3, fb_virt_base + offset) catch {};
        }
        return error.ENOMEM;
    };
    proc.user_vmm.insertVma(fb_vma);
    proc.user_vmm.total_mapped += fb_size;

    console.debug("sys_map_fb: Mapped FB at virt={x} (phys={x}, size={d})", .{
        fb_virt_base,
        fb_state.phys_addr,
        fb_size,
    });

    // Return the mapped virtual address
    return @intCast(fb_virt_base);
}

// =============================================================================
// Threading (Stubs)
// =============================================================================

/// sys_clone (56) - Create a child process/thread
///
/// Clone is used for both fork() and thread creation, depending on flags.
/// MVP: Returns ENOSYS (threading not implemented)
///
/// For full implementation, clone needs to:
/// - Create a new thread/process structure
/// - Handle CLONE_VM (share address space for threads)
/// - Handle CLONE_THREAD (create thread, not process)
/// - Handle CLONE_PARENT_SETTID, CLONE_CHILD_SETTID, etc.
pub fn sys_clone(flags: usize, stack: usize, parent_tid: usize, child_tid: usize, tls: usize) SyscallError!usize {
    _ = flags;
    _ = stack;
    _ = parent_tid;
    _ = child_tid;
    _ = tls;
    // For now, recommend using fork() instead
    return error.ENOSYS;
}

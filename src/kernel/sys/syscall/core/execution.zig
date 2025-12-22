// Execution Syscall Handlers
//
// Implements process execution and architecture-specific syscalls:
// - sys_fork: Create child process
// - sys_execve: Execute program
// - sys_arch_prctl: Architecture-specific thread state (TLS)
// - sys_get_fb_info, sys_map_fb: Framebuffer access

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
const aslr = @import("aslr");
// Access virtio_gpu through the video_driver module
const video_driver = @import("video_driver");
const virtio_gpu = video_driver.virtio_gpu;

const SyscallError = base.SyscallError;
const UserPtr = base.UserPtr;
const isValidUserAccess = base.isValidUserAccess;
const AccessMode = base.AccessMode;
const Process = base.Process;

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

    // SECURITY: Save parent's FPU state before fork to ensure proper isolation.
    // Due to lazy FPU switching, the parent's FPU registers may not have been
    // saved to the thread struct yet. If we fork and the child runs first on the
    // same CPU, there's a window where FPU state could leak. Explicitly saving
    // here ensures the parent's sensitive FPU data (e.g., from crypto operations)
    // is captured in the thread struct before the child is created.
    // Note: The child gets fresh FPU state from createUserThread (fpu_used=false).
    if (parent_thread.fpu_used) {
        hal.fpu.fxsave(&parent_thread.fpu_state);
    }

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
    // SECURITY: Acquire process_tree_lock to prevent TOCTOU with wait4()
    {
        const held = sched.process_tree_lock.acquireWrite();
        defer held.release();
        thread.addChild(parent_thread, child_thread);
    }

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
    // Stack hardening: heap-allocate argv/envp pointer arrays to reduce stack pressure
    // in deep call chains. Each array is 64 * 16 = 1024 bytes.
    const argv_storage = alloc.alloc([]const u8, 64) catch {
        return error.ENOMEM;
    };
    defer alloc.free(argv_storage);
    var argc: usize = 0;

    if (argv_ptr != 0) {
        var i: usize = 0;
        while (argc < 64) : (i += 1) {
            const ptr_addr = argv_ptr + i * @sizeOf(usize);
            // Read pointer from argv array - fault is a real error, not silent termination
            const arg_ptr = UserPtr.from(ptr_addr).readValue(usize) catch {
                return error.EFAULT; // Pointer read failed
            };

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
    const envp_storage = alloc.alloc([]const u8, 64) catch {
        return error.ENOMEM;
    };
    defer alloc.free(envp_storage);
    var envc: usize = 0;

    if (envp_ptr != 0) {
        var i: usize = 0;
        while (envc < 64) : (i += 1) {
            const ptr_addr = envp_ptr + i * @sizeOf(usize);
            // Read pointer from envp array - fault is a real error, not silent termination
            const env_ptr = UserPtr.from(ptr_addr).readValue(usize) catch {
                return error.EFAULT; // Pointer read failed
            };

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
    const vdso = @import("vdso");

    // Generate new ASLR offsets for the new address space
    // execve replaces the entire address space, so we need fresh randomization
    // SECURITY: This will fail if entropy is weak (per CLAUDE.md "Fail Secure" policy)
    const aslr_offsets = aslr.generateOffsets() catch |err| {
        console.err("sys_execve: Failed to generate ASLR offsets: {}", .{err});
        return error.ENOMEM; // Security failure - cannot proceed without ASLR
    };

    // Generate new randomized VDSO base for the new program
    const vdso_base = vdso.generateBase();

    const result = elf.exec(
        file.data,
        argv,
        envp,
        vdso_base,
        aslr_offsets.stack_top, // ASLR stack top
        aslr.getPieBase(&aslr_offsets), // ASLR PIE base
    ) catch |err| {
        console.err("sys_execve: Failed to exec: {}", .{err});
        // Map ELF loader errors to appropriate syscall errors
        return switch (err) {
            error.OutOfMemory => error.ENOMEM,
            error.InvalidExecutable => error.ENOEXEC,
        };
    };

    // Map VDSO into new address space
    _ = vdso.mapToPml4(result.pml4_phys, vdso_base) catch |err| blk: {
        console.warn("sys_execve: Failed to map VDSO: {}", .{err});
        // Continue anyway - libc will fallback
        break :blk;
    };

    // Store the new VDSO base and ASLR offsets in the process struct
    // These are needed for fork() to inherit the address layout
    const current_proc_for_aslr = base.getCurrentProcess();
    current_proc_for_aslr.vdso_base = vdso_base;
    current_proc_for_aslr.aslr_offsets = aslr_offsets;

    // SECURITY: Clear inherited capabilities on execve.
    // Capabilities must NOT be laundered to arbitrary programs via fork+execve.
    // This prevents a compromised driver from granting its hardware access
    // to an untrusted program by forking and exec'ing it.
    current_proc_for_aslr.capabilities.clearRetainingCapacity();

    // SECURITY: Reset DMA allocation counter on execve.
    // New program starts with zero DMA allocations regardless of what
    // the previous program had allocated.
    current_proc_for_aslr.dma_allocated_pages = 0;

    console.debug("sys_execve: Loaded ELF entry={x} stack={x} cr3={x}", .{
        result.entry_point,
        result.stack_pointer,
        result.pml4_phys,
    });

    // Vulnerability Fix: Ensure entry_point is canonical low-half address
    // sysretq throws #GP if RCX (return RIP) is non-canonical.
    if (!isValidUserAccess(result.entry_point, 1, AccessMode.Execute)) {
        return error.EFAULT;
    }

    const current_thread = sched.getCurrentThread().?;
    const current_proc = base.getCurrentProcess();

    // SECURITY: Atomically verify this is a single-threaded process before execve.
    //
    // TOCTOU PREVENTION: A simple load-then-check would create a race window where
    // another thread could call clone() between checking refcount==1 and switching
    // CR3. That would leave the new thread executing in the old (about to be
    // destroyed) address space, causing memory corruption or crashes.
    //
    // We use cmpxchg to atomically:
    // 1. Verify refcount is exactly 1 (single-threaded)
    // 2. Set a sentinel value (0x80000000 | 1) to indicate "execve in progress"
    //
    // sys_clone checks for this sentinel and fails with EAGAIN if seen, preventing
    // new thread creation during the critical section.
    const EXECVE_IN_PROGRESS_BIT: u32 = 0x80000000;
    const expected_single_thread: u32 = 1;
    const execve_sentinel: u32 = EXECVE_IN_PROGRESS_BIT | 1;

    if (current_proc.refcount.cmpxchgStrong(
        expected_single_thread,
        execve_sentinel,
        .acq_rel,
        .acquire,
    )) |actual| {
        // CAS failed - either multi-threaded or another execve in progress
        console.warn("sys_execve: Cannot execve - refcount={x} (expected 1)", .{actual});
        vmm.destroyAddressSpace(result.pml4_phys);
        if (actual & EXECVE_IN_PROGRESS_BIT != 0) {
            return error.EBUSY; // Another execve in progress
        }
        return error.EAGAIN; // Multi-threaded, caller should terminate other threads
    }
    // CAS succeeded: we now own the execve lock (refcount = 0x80000001)
    // Must restore to 1 on success or error below
    errdefer current_proc.refcount.store(1, .release);

    // Save old CR3 to destroy after switching
    const old_cr3 = current_proc.cr3;

    // SECURITY: Close FDs with O_CLOEXEC flag set before entering new program.
    // This prevents file descriptor leakage to exec'd programs.
    current_proc.fd_table.closeCloexec();

    // Update process/thread state
    current_proc.cr3 = result.pml4_phys;
    // Apply ASLR heap gap to heap start
    const heap_with_gap = aslr.getHeapStart(result.heap_start, &aslr_offsets);
    current_proc.heap_start = heap_with_gap;
    current_proc.heap_break = heap_with_gap;
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

    // SECURITY: Reset signal handlers to default behavior.
    // Executed programs must not inherit signal handlers from the previous process,
    // as the handler addresses are no longer valid in the new address space.
    current_thread.signal_actions = [_]uapi.signal.SigAction{std.mem.zeroes(uapi.signal.SigAction)} ** 64;

    // SECURITY: Clear alternate signal stack.
    // The alternate stack pointer is no longer valid.
    current_thread.alternate_stack = .{ .sp = 0, .flags = 2, .size = 0 }; // SS_DISABLE

    // SECURITY: Restore refcount to 1 now that execve has completed successfully.
    // The sentinel value (0x80000001) prevented concurrent clone() during the
    // critical section. Now that we're safely in the new address space, we restore
    // normal operation.
    current_proc.refcount.store(1, .release);

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
            // SECURITY: Validate FS base is within userspace bounds.
            // A kernel address could be exploited with speculative execution
            // vulnerabilities or if kernel code erroneously uses FS-relative accesses.
            // Also reject non-canonical addresses that would cause #GP on access.
            if (addr != 0) {
                // Check address is in canonical lower half (userspace)
                if (addr >= user_mem.USER_SPACE_END or addr < user_mem.USER_SPACE_START) {
                    return error.EINVAL;
                }
            }
            // Store FS base in thread struct for context switch restoration
            curr.fs_base = addr;
            // Write to IA32_FS_BASE MSR for immediate effect
            hal.cpu.writeMsr(hal.cpu.IA32_FS_BASE, addr);
            return 0;
        },
        ARCH_GET_FS => {
            // Validate user pointer
            if (!isValidUserAccess(addr, @sizeOf(u64), AccessMode.Write)) {
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
///   -EPERM if process lacks display server or MMIO capability
///   -EBUSY if framebuffer is already owned by another process
///   -ENOMEM if mapping failed
///
/// Security: Requires DisplayServer capability (preferred) or legacy MMIO capability.
/// Only one process can own the framebuffer at a time (exclusive access).
pub fn sys_map_fb() SyscallError!usize {
    // Get framebuffer state from module
    const fb_state = framebuffer.getState() orelse {
        return error.ENODEV;
    };

    // Get current process for page table and capability check
    const proc = base.getCurrentProcess();

    // SECURITY: Check for DisplayServer capability (preferred) or legacy MMIO capability.
    // DisplayServer is the semantic capability for display server access.
    // MMIO is kept for backwards compatibility with existing setups.
    const has_display_cap = proc.hasDisplayServerCapability();
    const has_mmio_cap = proc.hasMmioCapability(fb_state.phys_addr, fb_state.size);

    if (!has_display_cap and !has_mmio_cap) {
        console.warn("sys_map_fb: Process pid={} lacks display capability", .{proc.pid});
        return error.EPERM;
    }

    // SECURITY: Claim exclusive framebuffer ownership.
    // Only one process can map the framebuffer at a time to prevent race conditions
    // and display corruption. This enforces the display server model.
    if (!framebuffer.claimOwnership(proc.pid)) {
        console.warn("sys_map_fb: Framebuffer already owned by pid={}", .{framebuffer.getOwnerPid()});
        return error.EBUSY;
    }
    // Release ownership if we fail to complete the mapping
    errdefer framebuffer.releaseOwnership(proc.pid);

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

    // Disable graphical console - userspace now owns the framebuffer exclusively.
    // Kernel output continues on serial only to avoid overwriting userspace graphics.
    console.disableGraphicalBackend();
    console.info("Framebuffer: Transferred to userspace (serial-only mode)", .{});

    // Return the mapped virtual address
    return @intCast(fb_virt_base);
}

/// sys_fb_flush (1006) - Flush framebuffer to display
///
/// Triggers a display update (present) for the framebuffer.
/// Required for devices that use a shadow framebuffer (e.g., VirtIO-GPU).
pub fn sys_fb_flush() SyscallError!usize {
    // Check if framebuffer exists using generic state
    if (!framebuffer.isAvailable()) {
        return error.ENODEV;
    }

    // Try to get VirtIO-GPU driver instance
    if (virtio_gpu.getDriver()) |drv| {
        // Trigger generic present (updates full screen if no rect provided)
        const dev = drv.device();
        dev.vtable.present(dev.ptr, null);
        return 0;
    }

    // If not VirtIO-GPU (e.g. UEFI framebuffer), flush is a no-op (memory mapped directly)
    // but we return success so userland logic is consistent.
    return 0;
}

// =============================================================================
// Threading
// =============================================================================

/// sys_clone (56) - Create a child process/thread
///
/// Clone is used for both fork() and thread creation, depending on flags.
/// Implements CLONE_THREAD for multi-threading support.
pub fn sys_clone(frame: *hal.syscall.SyscallFrame) SyscallError!usize {
    // Extract arguments from syscall frame (since this is called from asm entry)
    // Args: flags, stack, parent_tid, child_tid, tls
    const flags = frame.rdi;
    const stack = frame.rsi;
    // const parent_tid_ptr = frame.rdx;
    // const child_tid_ptr = frame.r10;
    const tls = frame.r8;

    // Check for CLONE_THREAD
    if ((flags & uapi.sched.CLONE_THREAD) != 0) {
        // Multi-threading: Create a new thread in the SAME process
        // Must also specify CLONE_VM (threads share address space) and CLONE_SIGHAND
        if ((flags & uapi.sched.CLONE_VM) == 0 or (flags & uapi.sched.CLONE_SIGHAND) == 0) {
            return error.EINVAL;
        }

        const parent_proc = base.getCurrentProcess();
        const parent_thread = sched.getCurrentThread() orelse return error.ESRCH;

        // Fast path: reject if process already exiting (re-checked after refcount increment)
        if (parent_proc.state != .Running) {
            return error.ESRCH;
        }

        // Enforce per-process thread limit atomically and detect execve.
        // - MAX_THREADS_PER_PROCESS prevents fork bomb DoS
        // - EXECVE_IN_PROGRESS_BIT (0x80000000) prevents creating threads during
        //   execve's critical section (between refcount check and CR3 switch)
        const MAX_THREADS_PER_PROCESS: u32 = 256;
        const EXECVE_IN_PROGRESS_BIT: u32 = 0x80000000;
        var refcount = parent_proc.refcount.load(.acquire);
        while (true) {
            // Check if execve is in progress. Creating a thread now would
            // result in the new thread running in an address space that's about to
            // be destroyed, causing memory corruption.
            if (refcount & EXECVE_IN_PROGRESS_BIT != 0) {
                console.warn("sys_clone: Process pid={} has execve in progress - blocking clone", .{parent_proc.pid});
                return error.EAGAIN;
            }
            if (refcount >= MAX_THREADS_PER_PROCESS) {
                console.warn("sys_clone: Process pid={} reached thread limit ({})", .{ parent_proc.pid, MAX_THREADS_PER_PROCESS });
                return error.EAGAIN;
            }
            if (parent_proc.refcount.cmpxchgWeak(refcount, refcount + 1, .acq_rel, .acquire) == null) {
                break;
            }
            refcount = parent_proc.refcount.load(.acquire);
        }
        errdefer _ = parent_proc.unref();

        // Recheck state after refcount increment to close the window where another
        // thread could exit between our initial check and refcount increment.
        // If process transitioned to Zombie/Dead, we must not proceed.
        if (parent_proc.state != .Running) {
            return error.ESRCH; // errdefer handles unref
        }

        // Create child thread attached to the SAME process
        const child_thread = thread.createUserThread(
            0, // Entry point set below
            .{
                .name = parent_thread.getName(),
                .cr3 = parent_proc.cr3, // Share CR3/Address Space
                .user_stack_top = if (stack != 0) stack else parent_thread.user_stack_top,
                .process = @ptrCast(parent_proc),
            },
        ) catch {
            return error.ENOMEM;
        };
        errdefer _ = thread.destroyThread(child_thread);

        // Handle CLONE_PARENT_SETTID (store child TID in parent memory)
        // Usually passed in RDX (parent_tid_ptr)
        if ((flags & uapi.sched.CLONE_PARENT_SETTID) != 0) {
            const parent_tid_ptr = frame.rdx;
            if (isValidUserAccess(parent_tid_ptr, @sizeOf(i32), AccessMode.Write)) {
                UserPtr.from(parent_tid_ptr).writeValue(@as(i32, @intCast(child_thread.tid))) catch {
                    // Linux ignores fault here usually or returns EFAULT.
                    // For robustness, we'll return EFAULT.
                    return error.EFAULT;
                };
            } else {
                return error.EFAULT;
            }
        }

        // Handle CLONE_CHILD_CLEARTID (store child TID in child memory and clear on exit)
        // Usually passed in R10 (child_tid_ptr)
        if ((flags & uapi.sched.CLONE_CHILD_CLEARTID) != 0) {
            const child_tid_ptr = frame.r10;
            if (isValidUserAccess(child_tid_ptr, @sizeOf(i32), AccessMode.Write)) {
                // Store TID in child memory (same address space as parent/current)
                UserPtr.from(child_tid_ptr).writeValue(@as(i32, @intCast(child_thread.tid))) catch {
                    return error.EFAULT;
                };
                // Remember address to clear on exit
                child_thread.clear_child_tid = child_tid_ptr;
            } else {
                return error.EFAULT;
            }
        }

        // Handle CLONE_CHILD_SETTID (store child TID in child memory)
        // Usually passed in R10 (child_tid_ptr)
        // Note: SETTID and CLEARTID both use the same pointer register (R10)
        if ((flags & uapi.sched.CLONE_CHILD_SETTID) != 0) {
            const child_tid_ptr = frame.r10;
            if (isValidUserAccess(child_tid_ptr, @sizeOf(i32), AccessMode.Write)) {
                UserPtr.from(child_tid_ptr).writeValue(@as(i32, @intCast(child_thread.tid))) catch {
                    return error.EFAULT;
                };
            } else {
                return error.EFAULT;
            }
        }

        // Copy parent's kernel stack frame (register state) to child
        copyThreadState(frame, parent_thread, child_thread);

        // Set child's return value to 0
        setForkChildReturn(child_thread);

        // If stack was provided, set it in the child's frame
        // (Note: createUserThread sets initial RSP, but copyThreadState overwrites it
        // with parent's RSP. We must enforce the new stack if provided)
        if (stack != 0) {
            const child_frame: *hal.idt.InterruptFrame = @ptrFromInt(child_thread.kernel_rsp);
            child_frame.rsp = stack;
        }

        // Handle TLS setup (CLONE_SETTLS)
        if ((flags & uapi.sched.CLONE_SETTLS) != 0) {
            child_thread.fs_base = tls;
            // Note: We don't write MSR here, child will maintain it on switch
        }

        // Add child thread to process/thread hierarchy
        // SECURITY: Acquire process_tree_lock to prevent TOCTOU with wait4()
        {
            const held = sched.process_tree_lock.acquireWrite();
            defer held.release();
            thread.addChild(parent_thread, child_thread);
        }

        // Add to scheduler
        sched.addThread(child_thread);

        // Return new TID to caller
        return child_thread.tid;
    }

    // Fallback for standard fork-like clone (CLONE_VM not set, etc)
    // If signals matches SIGCHLD and no other flags..
    if (flags == uapi.sched.CSIGNAL) {
        return sys_fork(frame);
    }

    // Other combinations not yet supported
    return error.ENOSYS;
}

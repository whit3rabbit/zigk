// Syscall Base Module
//
// Provides shared state and accessor functions used by all syscall handler modules.
// This module owns the global state for process tracking, file descriptor tables,
// and user virtual memory management.

const std = @import("std");
const uapi = @import("uapi");
const console = @import("console");
const sched = @import("sched");
const fd_mod = @import("fd");
const user_vmm = @import("user_vmm");
const process_mod = @import("process");
const user_mem = @import("user_mem");

// Re-export common types for convenience
pub const UserVmm = user_vmm.UserVmm;
pub const FdTable = fd_mod.FdTable;
pub const FileDescriptor = fd_mod.FileDescriptor;
pub const Process = process_mod.Process;
pub const SyscallError = uapi.errno.SyscallError;
pub const Errno = uapi.errno.Errno;

// Re-export validation functions from user_mem for local use
pub const isValidUserPtr = user_mem.isValidUserPtr;
pub const isValidUserAccess = user_mem.isValidUserAccess;
pub const AccessMode = user_mem.AccessMode;
pub const UserPtr = user_mem.UserPtr;

// =============================================================================
// Current Process Tracking
// =============================================================================
// SECURITY: Uses per-CPU thread state via GS segment for SMP safety.
// The scheduler maintains current_thread in per-CPU data, and each thread
// has a reference to its parent process. This avoids race conditions where
// multiple CPUs could access/modify a shared global.
//
// Fallback to init_process is only used during early boot before scheduler starts.

/// Init process reference for pre-scheduler boot phase
var init_process_cache: ?*Process = null;

/// Get the current process via the scheduler's per-CPU thread state
/// Falls back to init process during early boot (before scheduler starts)
pub fn getCurrentProcess() *Process {
    // SECURITY: Use per-CPU thread state from GS segment (SMP-safe)
    if (sched.getCurrentThread()) |thread| {
        if (thread.process) |proc_ptr| {
            return @ptrCast(@alignCast(proc_ptr));
        }
    }

    // Fallback for early boot before scheduler starts
    if (init_process_cache) |proc| {
        return proc;
    }

    // First access during boot - get or create init process
    init_process_cache = process_mod.getInitProcess() catch {
        console.err("Process: Failed to create init process", .{});
        @panic("Cannot create init process");
    };

    console.info("Process: Using init process (pid={})", .{init_process_cache.?.pid});
    return init_process_cache.?;
}

/// Get the current process if one exists, without creating init
/// Useful for contexts where we need to check if a process exists
/// without side effects (e.g., page fault handling before scheduler runs)
pub fn getCurrentProcessOrNull() ?*Process {
    // SECURITY: Use per-CPU thread state from GS segment (SMP-safe)
    if (sched.getCurrentThread()) |thread| {
        if (thread.process) |proc_ptr| {
            return @ptrCast(@alignCast(proc_ptr));
        }
    }
    // Return cached init process if available (pre-scheduler)
    return init_process_cache;
}

/// Set the init process during early boot (before scheduler starts)
/// After scheduler starts, current process is derived from current thread
pub fn setCurrentProcess(proc: *Process) void {
    // This is only used during init_proc setup before scheduler runs
    init_process_cache = proc;
}

// =============================================================================
// Global FD Table (MVP single-process)
// =============================================================================
// In Phase 4 (Process model), this uses the current process's FD table.
// Falls back to global for backward compatibility.

var global_fd_table: ?*FdTable = null;
var fd_table_initialized: bool = false;

/// Get the FD table for the current process
pub fn getGlobalFdTable() *FdTable {
    // Use current process's FD table via SMP-safe accessor
    if (getCurrentProcessOrNull()) |proc| {
        return proc.fd_table;
    }

    // Fallback to global for backward compatibility
    if (global_fd_table) |table| {
        return table;
    }

    // First access - use init process's FD table
    const init_proc = getCurrentProcess();
    return init_proc.fd_table;
}

// =============================================================================
// Global User VMM (MVP single-process)
// =============================================================================
// In Phase 4 (Process model), this uses the current process's UserVmm.
// Falls back to global for backward compatibility.

var global_user_vmm: ?*UserVmm = null;

/// Get the UserVmm for the current process
pub fn getGlobalUserVmm() *UserVmm {
    // Use current process's UserVmm via SMP-safe accessor
    if (getCurrentProcessOrNull()) |proc| {
        return proc.user_vmm;
    }

    // Fallback to global for backward compatibility
    if (global_user_vmm) |uvmm| {
        return uvmm;
    }

    // First access - use init process's UserVmm
    const init_proc = getCurrentProcess();
    return init_proc.user_vmm;
}

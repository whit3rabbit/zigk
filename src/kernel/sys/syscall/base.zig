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
// For Phase 4, we track the current process. Falls back to init process
// when no explicit current process is set.

var current_process: ?*Process = null;

/// Get the current process (init if none set)
pub fn getCurrentProcess() *Process {
    if (current_process) |proc| {
        return proc;
    }

    // First access - get or create init process
    current_process = process_mod.getInitProcess() catch {
        console.err("Process: Failed to create init process", .{});
        @panic("Cannot create init process");
    };

    console.info("Process: Using init process (pid={})", .{current_process.?.pid});
    return current_process.?;
}

/// Get the current process if one is set, without creating init
/// Useful for contexts where we need to check if a process exists
/// without side effects (e.g., page fault handling before scheduler runs)
pub fn getCurrentProcessOrNull() ?*Process {
    return current_process;
}

/// Set the current process (for context switching)
pub fn setCurrentProcess(proc: *Process) void {
    current_process = proc;
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
    // Use current process's FD table if available
    if (current_process) |proc| {
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
    // Use current process's UserVmm if available
    if (current_process) |proc| {
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

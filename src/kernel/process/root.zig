const std = @import("std");

// Import internal submodules
const types = @import("types.zig");
const lifecycle = @import("lifecycle.zig");
const manager = @import("manager.zig");
const ipc_msg = @import("ipc_msg");
const sched = @import("sched"); // Added for getCurrentProcess

// Export public API

// Types
pub const Process = types.Process;
pub const ProcessState = types.ProcessState;
pub const MailboxLock = Process.MailboxLock; // Nested in Process

// Lifecycle
pub const createProcess = lifecycle.createProcess;
pub const forkProcess = lifecycle.forkProcess;
pub const exit = lifecycle.exit;
pub const destroyProcess = lifecycle.destroyProcess;
pub const refProcess = lifecycle.refProcess; // If needed externally

// Manager
pub const getInitProcess = manager.getInitProcess;
pub const setInitProcess = manager.setInitProcess;
pub const getProcessCount = manager.getProcessCount;
pub const findProcessByPid = manager.findProcessByPid;
pub const allocatePid = manager.allocatePid;

// Auth / Capabilities
// Capability checks are now methods on Process struct
pub const hasInterruptCapability = Process.hasInterruptCapability;
pub const hasIoPortCapability = Process.hasIoPortCapability;
pub const hasMmioCapability = Process.hasMmioCapability;
pub const hasDmaCapability = Process.hasDmaCapability;
pub const hasPciConfigCapability = Process.hasPciConfigCapability;
pub const hasInputInjectionCapability = Process.hasInputInjectionCapability;
pub const hasFileCapability = Process.hasFileCapability;
pub const hasSetUidCapability = Process.hasSetUidCapability;
pub const hasSetGidCapability = Process.hasSetGidCapability;

// Helper to get current process (shim for Scheduler)
pub fn getCurrentProcess() *Process {
    const thread = sched.getCurrentThread() orelse @panic("getCurrentProcess: No current thread");
    if (thread.process) |p| {
        return @ptrCast(@alignCast(p));
    }
    @panic("getCurrentProcess: Thread has no process");
}

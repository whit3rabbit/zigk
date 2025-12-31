const std = @import("std");
const console = @import("console");
const sched = @import("sched"); // For lock
const types = @import("types.zig");
const lifecycle = @import("lifecycle.zig"); // We need access to destroyProcess? Or lifecycle calls us?
// actually manager tracks PIDs.
// manager is needed by lifecycle.
// Lifecycle -> Manager (PID allocation, adding to global list?)
// Manager -> Types.
// Manager -> Lifecycle? (probably not, to avoid cycle).
// `getInitProcess` calls `createProcess` which is in lifecycle.
// So Manager -> Lifecycle.
// Lifecycle -> Manager (PID allocation).
// Circular dependency: Manager <-> Lifecycle.
// `getInitProcess` can be in Lifecycle? Or Manager?
// original `getInitProcess` calls `createProcess`.
// `createProcess` calls `allocatePid`.
// `allocatePid` uses `process_count` and `next_pid`.
// Let's put `allocatePid` and global counters in Manager.
// `getInitProcess` logic:
//   if (init_process) return it;
//   init_process = lifecycle.createProcess(null);
// So Manager needs Lifecycle.
// Lifecycle needs Manager (`allocatePid`, `process_count` increment).
// If we put global vars in Manager:
// Lifecycle imports Manager.
// Manager imports Lifecycle.
// Zig allows this if imports are inside functions or structs, or if logic is separate.
// But `init_process` var is global.
// Let's put `init_process` variable in Manager.
// `createProcess` (in Lifecycle) updates `process_count` (in Manager?).
// Maybe expose `process_count` via functions.
// Let's see.

const Process = types.Process;

// We will use a separate module for global state if needed, but Manager should own it.
// To resolve cycle, `createProcess` can be called from `init_proc` or `main`.
// `getInitProcess` is mainly used by other modules.
// If we move `getInitProcess` to `lifecycle.zig`, then `lifecycle` owns `init_process`.
// But `findProcessByPid` searches from `init_process`.
// So `findProcessByPid` needs `init_process`.
// `findProcessByPid` is clearly Manager logic.
// So Manager needs `init_process`.
// If `getInitProcess` is in Manager, it needs `createProcess`.
// Option: `createProcess` takes a callback? No.
// Option: `init_process` is initialized explicitly during boot?
// `main.zig` calls `init_proc.init()`.
// `init_proc` calls `process.createProcess`.
// So `init_process` reference can be stored in Manager.
// We can have `registerInitProcess(proc: *Process)` in Manager.
// Then `lifecycle.createProcess` creates it, and caller registers it?
// Or `createProcess` handles it?
// Let's keep `init_process` in Manager.
// We will have Lifecycle import Manager for `allocatePid`.
// Manager will NOT import Lifecycle.
// `getInitProcess` will error if init not set?
// Or we move `getInitProcess` creation request out of Manager?
// The original `getInitProcess` lazy-created it.
// We can change that pattern. `init_proc.zig` creates it explicitly.
// `main.zig` doesn't use `getInitProcess` before `init_proc` runs presumably.
// Let's see `init_proc.zig` in the file list... `init_proc.zig` exists.
// Code snippet showed: `pub fn getInitProcess() !*Process`.
// If we make `init_process` public or have setters, we can decouple.

// Let's make Manager depend on Lifecycle is probably fine if Lifecycle just uses types?
// No, Lifecycle uses `allocatePid` (Manager).
// So Manager -> Lifecycle -> Manager.
// We can put `next_pid` and `process_count` in `types.zig`? No, that's state.
// We can put them in a `globals.zig`?
// `kernel/process/globals.zig`.
// Manager imports Globals. Lifecycle imports Globals.
// Globals has no deps (except types).
// `init_process` goes to Globals.
// `process_count` goes to Globals.
// `next_pid` goes to Globals.
// `process_tree_lock` is in `sched`.
// This seems clean.

// Let's wait on creating `globals.zig`. Can we just put them in `manager.zig` and have Lifecycle use `manager.zig` functions?
// And have `manager.zig` NOT import `lifecycle.zig`.
// Then `getInitProcess` cannot lazy-create.
// It must check if likely initialized.
// If not, returns error?
// Original: `if (init_process == null) init_process = createProcess(null)`.
// We can move `createProcess` to `lifecycle.zig`.
// We can make `manager.getInitProcess` NOT create it, but return `?*Process` or error.
// And `init_proc.zig` calls `lifecycle.createProcess(null)` then `manager.setInitProcess(proc)`.
// This breaks the lazy init cycle.
// I'll go with this: `manager` holds state, `lifecycle` creates/modifies.
// `init_proc` coordinates.

pub var init_process: ?*Process = null;
pub var process_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var next_pid: u32 = 1;

/// Register the init process
pub fn setInitProcess(proc: *Process) void {
    init_process = proc;
}

/// Get the init process
pub fn getInitProcess() !*Process {
    if (init_process) |proc| return proc;
    return error.NotInitialized;
}

/// Get current process count
pub fn getProcessCount() u32 {
    return process_count.load(.monotonic);
}

/// Allocate a new PID
/// Uses `sched.process_tree_lock` for synchronization
pub fn allocatePid() u32 {
    const max_attempts = @as(usize, process_count.load(.monotonic)) + 1;
    var attempts: usize = 0;

    const held = sched.process_tree_lock.acquireWrite();
    defer held.release();

    while (attempts <= max_attempts) : (attempts += 1) {
        if (next_pid == 0) {
            next_pid = 1;
        }

        const candidate = next_pid;
        next_pid +%= 1;

        // findProcessByPidLocked required to avoid deadlock (lock already held)
        if (findProcessByPidLocked(candidate) == null) {
            return candidate;
        }
    }

    console.panic("Process: PID space exhausted", .{});
}

/// Find process by PID (public, acquiring lock)
/// WARNING: The returned pointer may become invalid after the lock is released.
/// SECURITY: For safe usage across lock boundaries, use findAndRefProcess() instead.
pub fn findProcessByPid(target_pid: u32) ?*Process {
    const held = sched.process_tree_lock.acquireRead();
    defer held.release();
    return findProcessByPidLocked(target_pid);
}

/// Find process by PID and increment its reference count (SAFE)
/// Returns null if not found
/// The caller MUST call process.unref() when done with the pointer.
/// This is the safe version for use when the pointer will be used after
/// releasing the process tree lock.
pub fn findAndRefProcess(target_pid: u32) ?*Process {
    const held = sched.process_tree_lock.acquireRead();
    defer held.release();

    if (findProcessByPidLocked(target_pid)) |proc| {
        proc.ref(); // Increment refcount before returning
        return proc;
    }
    return null;
}

/// Internal find helper (no lock)
fn findProcessByPidLocked(target_pid: u32) ?*Process {
    if (init_process) |init| {
        if (init.pid == target_pid) {
            return init;
        }
        return findInTree(init, target_pid);
    }
    return null;
}

fn findInTree(proc: *Process, target_pid: u32) ?*Process {
    var child = proc.first_child;
    while (child) |c| {
        if (c.pid == target_pid) {
            return c;
        }
        if (findInTree(c, target_pid)) |found| {
            return found;
        }
        child = c.next_sibling;
    }
    return null;
}

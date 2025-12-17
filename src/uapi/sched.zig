// Zscapek Scheduler API (Linux-compatible)
//
// Defines constants for clone(), sched_setscheduler(), etc.

/// Signal mask to be sent at exit
pub const CSIGNAL: usize = 0x000000ff;

/// Share virtual memory
pub const CLONE_VM: usize = 0x00000100;

/// Share file system info
pub const CLONE_FS: usize = 0x00000200;

/// Share file descriptors
pub const CLONE_FILES: usize = 0x00000400;

/// Share signal handlers
pub const CLONE_SIGHAND: usize = 0x00000800;

/// Ptrace: Parent process is being traced
pub const CLONE_PTRACE: usize = 0x00002000;

/// Suspend parent until child is ready
pub const CLONE_VFORK: usize = 0x00004000;

/// Parent is the same as the cloner's parent
pub const CLONE_PARENT: usize = 0x00008000;

/// Same thread group
pub const CLONE_THREAD: usize = 0x00010000;

/// New namespace for System V IPC
pub const CLONE_NEWNS: usize = 0x00020000;

/// Share System V SYS5 semaphores
pub const CLONE_SYSVSEM: usize = 0x00040000;

/// Set TLS data
pub const CLONE_SETTLS: usize = 0x00080000;

/// Store TID in parent
pub const CLONE_PARENT_SETTID: usize = 0x00100000;

/// Clear TID in child
pub const CLONE_CHILD_CLEARTID: usize = 0x00200000;

/// Detached
pub const CLONE_DETACHED: usize = 0x00400000;

/// Unused
pub const CLONE_UNTRACED: usize = 0x00800000;

/// Store TID in child
pub const CLONE_CHILD_SETTID: usize = 0x01000000;

/// New cgroup namespace
pub const CLONE_NEWCGROUP: usize = 0x02000000;

/// New UTS namespace
pub const CLONE_NEWUTS: usize = 0x04000000;

/// New IPC namespace
pub const CLONE_NEWIPC: usize = 0x08000000;

/// New user namespace
pub const CLONE_NEWUSER: usize = 0x10000000;

/// New PID namespace
pub const CLONE_NEWPID: usize = 0x20000000;

/// New network namespace
pub const CLONE_NEWNET: usize = 0x40000000;

/// New IO namespace
pub const CLONE_IO: usize = 0x80000000;

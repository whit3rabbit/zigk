// Core syscall infrastructure
pub const syscall_base = @import("syscall/core/base.zig");
pub const syscall_table = @import("syscall/core/table.zig");
pub const syscall_error_helpers = @import("syscall/core/error_helpers.zig");
pub const syscall_execution = @import("syscall/core/execution.zig");
pub const syscall_user_mem = @import("syscall/core/user_mem.zig");

// Filesystem syscalls
pub const syscall_fd = @import("syscall/fs/fd.zig");
pub const syscall_fs_handlers = @import("syscall/fs/fs_handlers.zig");

// Memory syscalls
pub const syscall_memory = @import("syscall/memory/memory.zig");
pub const syscall_mmio = @import("syscall/memory/mmio.zig");

// Process syscalls
pub const syscall_process = @import("syscall/process/process.zig");
pub const syscall_scheduling = @import("syscall/process/scheduling.zig");
pub const syscall_signals = @import("syscall/process/signals.zig");

// Network syscalls
pub const syscall_net = @import("syscall/net/net.zig");
pub const syscall_pci = @import("syscall/net/pci_syscall.zig");

// Hardware I/O syscalls
pub const syscall_port_io = @import("syscall/hw/port_io.zig");
pub const syscall_interrupt = @import("syscall/hw/interrupt.zig");
pub const syscall_input = @import("syscall/hw/input.zig");
pub const syscall_ring = @import("syscall/hw/ring.zig");

// Async I/O syscalls
pub const syscall_io = @import("syscall/io/root.zig");
pub const syscall_io_uring = @import("syscall/io_uring/root.zig");

// Misc syscalls
pub const syscall_random = @import("syscall/misc/random.zig");
pub const syscall_ipc = @import("syscall/misc/ipc.zig");
pub const syscall_custom = @import("syscall/misc/custom.zig");
pub const framebuffer = @import("framebuffer.zig");
pub const vdso = @import("vdso.zig");
pub const vdso_blob = @import("vdso_blob.zig");

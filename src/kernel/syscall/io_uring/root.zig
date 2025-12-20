//! IO Uring Subsystem

const setup = @import("setup.zig");
const enter = @import("enter.zig");
const register = @import("register.zig");
const types = @import("types.zig");

// Export syscall handlers
pub const sys_io_uring_setup = setup.sys_io_uring_setup;
pub const sys_io_uring_enter = enter.sys_io_uring_enter;
pub const sys_io_uring_register = register.sys_io_uring_register;

// Export internal types if needed by other kernel modules
pub const IoUringFdData = types.IoUringFdData;

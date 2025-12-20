const read_write = @import("read_write.zig");
const stat = @import("stat.zig");
const dir = @import("dir.zig");
const fcntl = @import("fcntl.zig");

// Export public syscall handlers
pub const sys_read = read_write.sys_read;
pub const sys_write = read_write.sys_write;
pub const sys_writev = read_write.sys_writev;
pub const sys_pread64 = read_write.sys_pread64;

pub const sys_stat = stat.sys_stat;
pub const sys_lstat = stat.sys_lstat;
pub const sys_fstat = stat.sys_fstat;

pub const sys_getdents64 = dir.sys_getdents64;
pub const sys_getcwd = dir.sys_getcwd;
pub const sys_chdir = dir.sys_chdir;
pub const sys_mkdir = dir.sys_mkdir;

pub const sys_fcntl = fcntl.sys_fcntl;
pub const sys_ioctl = fcntl.sys_ioctl;

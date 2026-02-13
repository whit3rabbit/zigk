const read_write = @import("read_write.zig");
const stat = @import("stat.zig");
const dir = @import("dir.zig");
const fcntl = @import("fcntl.zig");
const eventfd = @import("eventfd.zig");
const timerfd = @import("timerfd.zig");
const signalfd = @import("signalfd.zig");
const splice_mod = @import("splice.zig");

// Export public syscall handlers
pub const sys_read = read_write.sys_read;
pub const sys_write = read_write.sys_write;
pub const sys_readv = read_write.sys_readv;
pub const sys_writev = read_write.sys_writev;
pub const sys_pread64 = read_write.sys_pread64;
pub const sys_pwrite64 = read_write.sys_pwrite64;
pub const sys_preadv = read_write.sys_preadv;
pub const sys_pwritev = read_write.sys_pwritev;
pub const sys_preadv2 = read_write.sys_preadv2;
pub const sys_pwritev2 = read_write.sys_pwritev2;
pub const sys_sendfile = read_write.sys_sendfile;

pub const sys_eventfd2 = eventfd.sys_eventfd2;
pub const sys_eventfd = eventfd.sys_eventfd;

pub const sys_timerfd_create = timerfd.sys_timerfd_create;
pub const sys_timerfd_settime = timerfd.sys_timerfd_settime;
pub const sys_timerfd_gettime = timerfd.sys_timerfd_gettime;

pub const sys_signalfd4 = signalfd.sys_signalfd4;
pub const sys_signalfd = signalfd.sys_signalfd;

pub const sys_stat = stat.sys_stat;
pub const sys_lstat = stat.sys_lstat;
pub const sys_fstat = stat.sys_fstat;
pub const sys_newfstatat = stat.sys_fstatat;
pub const sys_statfs = stat.sys_statfs;
pub const sys_fstatfs = stat.sys_fstatfs;

pub const sys_getdents64 = dir.sys_getdents64;
pub const sys_getcwd = dir.sys_getcwd;
pub const sys_chdir = dir.sys_chdir;

pub const sys_fcntl = fcntl.sys_fcntl;
pub const sys_ioctl = fcntl.sys_ioctl;

pub const sys_splice = splice_mod.sys_splice;
pub const sys_tee = splice_mod.sys_tee;
pub const sys_vmsplice = splice_mod.sys_vmsplice;
pub const sys_copy_file_range = splice_mod.sys_copy_file_range;

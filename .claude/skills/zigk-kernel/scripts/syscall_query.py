#!/usr/bin/env python3
"""
Syscall Query Tool for zigk kernel.

Query syscalls by name, number, category, or handler file.
Data is hardcoded for standalone operation without filesystem dependencies.

Usage:
    python syscall_query.py read              # Find syscall by name
    python syscall_query.py 41                # Find syscall by number
    python syscall_query.py --category net    # List category
    python syscall_query.py --handler io.zig  # List syscalls in handler file
    python syscall_query.py --all             # List all syscalls
    python syscall_query.py --zscapek         # List Zscapek extensions (1000+)
    python syscall_query.py --security        # List security-critical syscalls
    python syscall_query.py --arch aarch64    # Use aarch64 syscall numbers
    python syscall_query.py --arch x86_64 41  # Explicitly use x86_64 numbers

Architectures:
    x86_64   - Standard Linux x86_64 syscall numbers (default)
    aarch64  - Standard Linux aarch64 syscall numbers

Categories:
    io       - Core I/O (read, write, ioctl, fcntl)
    fd       - File descriptors (open, close, dup, pipe)
    mem      - Memory (mmap, mprotect, mremap, madvise, mlock)
    proc     - Process (fork, clone, exec, wait, getpid)
    sig      - Signals (rt_sigaction, kill, tgkill)
    net      - Networking (socket, bind, listen, connect)
    sched    - Scheduling (sched_yield, nanosleep, clock_gettime)
    fs       - Filesystem (stat, chmod, mount, sync)
    fsat     - File *at() operations (openat, mkdirat, unlinkat)
    timer    - Timers (timer_create, timerfd, clock_nanosleep)
    event    - Events (epoll, inotify, eventfd, signalfd)
    advio    - Advanced I/O (sendfile, splice, fallocate)
    security - Security (ptrace, prctl, seccomp, capget/capset)
    container- Container/namespace (unshare, setns)
    uring    - io_uring async I/O
    ipc      - Zscapek IPC
    ring     - Zscapek ring buffer IPC
    mmio     - Zscapek MMIO/DMA/PCI
    input    - Zscapek input
    fb       - Zscapek framebuffer
    hypervisor - Zscapek hypervisor access (VMware, KVM, etc.)
    netconfig- Zscapek network interface configuration (SLAAC, ARP)
    virt_pci - Zscapek virtual PCI device emulation (pciem port)
"""

import sys
import re
from pathlib import Path

# Hardcoded syscall data: {number: {"name": "SYS_NAME", "doc": "description", "sig": ""}}
# This makes the script work without filesystem access.
SYSCALLS = {
    # Linux x86_64 ABI
    0: {"name": "SYS_READ", "doc": "Read from a file descriptor", "sig": "read(fd, buf, count) -> bytes_read"},
    1: {"name": "SYS_WRITE", "doc": "Write to a file descriptor", "sig": "write(fd, buf, count) -> bytes_written"},
    2: {"name": "SYS_OPEN", "doc": "Open a file", "sig": "open(path, flags, mode) -> fd"},
    3: {"name": "SYS_CLOSE", "doc": "Close a file descriptor", "sig": "close(fd) -> 0"},
    4: {"name": "SYS_STAT", "doc": "Get file status", "sig": "stat(path, statbuf) -> 0"},
    5: {"name": "SYS_FSTAT", "doc": "Get file status by fd", "sig": "fstat(fd, statbuf) -> 0"},
    6: {"name": "SYS_LSTAT", "doc": "Get file status (do not follow symlinks)", "sig": "lstat(path, statbuf) -> 0"},
    7: {"name": "SYS_POLL", "doc": "Wait for some event on a set of file descriptors", "sig": "poll(fds, nfds, timeout) -> count"},
    8: {"name": "SYS_LSEEK", "doc": "Reposition read/write file offset", "sig": "lseek(fd, offset, whence) -> offset"},
    9: {"name": "SYS_MMAP", "doc": "Map memory pages", "sig": "mmap(addr, len, prot, flags, fd, off) -> addr"},
    10: {"name": "SYS_MPROTECT", "doc": "Set memory protection", "sig": "mprotect(addr, len, prot) -> 0"},
    11: {"name": "SYS_MUNMAP", "doc": "Unmap memory pages", "sig": "munmap(addr, len) -> 0"},
    12: {"name": "SYS_BRK", "doc": "Change data segment size (heap)", "sig": "brk(addr) -> new_brk"},
    13: {"name": "SYS_RT_SIGACTION", "doc": "Examine and change signal actions", "sig": "rt_sigaction(sig, act, oldact, sigsetsize) -> 0"},
    14: {"name": "SYS_RT_SIGPROCMASK", "doc": "Examine and change blocked signals", "sig": "rt_sigprocmask(how, set, oldset, sigsetsize) -> 0"},
    15: {"name": "SYS_RT_SIGRETURN", "doc": "Return from signal handler", "sig": "rt_sigreturn() -> noreturn"},
    16: {"name": "SYS_IOCTL", "doc": "Perform device-specific control operations", "sig": "ioctl(fd, request, arg) -> result"},
    17: {"name": "SYS_PREAD64", "doc": "Read from file at offset", "sig": "pread64(fd, buf, count, offset) -> bytes_read"},
    18: {"name": "SYS_PWRITE64", "doc": "Write to file at offset", "sig": "pwrite64(fd, buf, count, offset) -> bytes_written"},
    19: {"name": "SYS_READV", "doc": "Read data into multiple buffers", "sig": "readv(fd, iov, iovcnt) -> bytes_read"},
    20: {"name": "SYS_WRITEV", "doc": "Write data from multiple buffers", "sig": "writev(fd, iov, iovcnt) -> bytes_written"},
    21: {"name": "SYS_ACCESS", "doc": "Check user's permissions for a file", "sig": "access(path, mode) -> 0"},
    22: {"name": "SYS_PIPE", "doc": "Create a pipe", "sig": "pipe(pipefd[2]) -> 0"},
    23: {"name": "SYS_SELECT", "doc": "Examine multiple file descriptors", "sig": "select(nfds, readfds, writefds, exceptfds, timeout) -> count"},
    24: {"name": "SYS_SCHED_YIELD", "doc": "Yield the processor", "sig": "sched_yield() -> 0"},
    25: {"name": "SYS_MREMAP", "doc": "Remap/resize a virtual memory area", "sig": "mremap(old_addr, old_size, new_size, flags) -> addr"},
    26: {"name": "SYS_MSYNC", "doc": "Synchronize file with memory map", "sig": "msync(addr, len, flags) -> 0"},
    27: {"name": "SYS_MINCORE", "doc": "Determine whether pages are resident in memory", "sig": "mincore(addr, len, vec) -> 0"},
    28: {"name": "SYS_MADVISE", "doc": "Give advice about memory usage patterns", "sig": "madvise(addr, len, advice) -> 0"},
    32: {"name": "SYS_DUP", "doc": "Duplicate a file descriptor", "sig": "dup(oldfd) -> newfd"},
    33: {"name": "SYS_DUP2", "doc": "Duplicate a file descriptor to specific number", "sig": "dup2(oldfd, newfd) -> newfd"},
    35: {"name": "SYS_NANOSLEEP", "doc": "High-resolution sleep", "sig": "nanosleep(req, rem) -> 0"},
    39: {"name": "SYS_GETPID", "doc": "Get process ID", "sig": "getpid() -> pid"},
    40: {"name": "SYS_SENDFILE", "doc": "Transfer data between file descriptors (zero-copy)", "sig": "sendfile(out_fd, in_fd, offset, count) -> bytes_sent"},
    41: {"name": "SYS_SOCKET", "doc": "Create a socket", "sig": "socket(domain, type, protocol) -> fd"},
    42: {"name": "SYS_CONNECT", "doc": "Connect socket to address", "sig": "connect(fd, addr, addrlen) -> 0"},
    43: {"name": "SYS_ACCEPT", "doc": "Accept connection on socket", "sig": "accept(fd, addr, addrlen) -> fd"},
    44: {"name": "SYS_SENDTO", "doc": "Send a message on a socket", "sig": "sendto(fd, buf, len, flags, dest_addr, addrlen) -> bytes_sent"},
    45: {"name": "SYS_RECVFROM", "doc": "Receive a message from a socket", "sig": "recvfrom(fd, buf, len, flags, src_addr, addrlen) -> bytes_recv"},
    46: {"name": "SYS_SENDMSG", "doc": "Send a message on a socket with scatter/gather I/O", "sig": "sendmsg(fd, msg, flags) -> bytes_sent"},
    47: {"name": "SYS_RECVMSG", "doc": "Receive a message from a socket with scatter/gather I/O", "sig": "recvmsg(fd, msg, flags) -> bytes_recv"},
    48: {"name": "SYS_SHUTDOWN", "doc": "Shut down part of a full-duplex connection", "sig": "shutdown(fd, how) -> 0"},
    49: {"name": "SYS_BIND", "doc": "Bind a socket to an address", "sig": "bind(fd, addr, addrlen) -> 0"},
    50: {"name": "SYS_LISTEN", "doc": "Listen for connections on socket", "sig": "listen(fd, backlog) -> 0"},
    51: {"name": "SYS_GETSOCKNAME", "doc": "Get local socket address", "sig": "getsockname(fd, addr, addrlen) -> 0"},
    52: {"name": "SYS_GETPEERNAME", "doc": "Get peer socket address", "sig": "getpeername(fd, addr, addrlen) -> 0"},
    53: {"name": "SYS_SOCKETPAIR", "doc": "Create connected socket pair", "sig": "socketpair(domain, type, protocol, sv[2]) -> 0"},
    54: {"name": "SYS_SETSOCKOPT", "doc": "Set socket options", "sig": "setsockopt(fd, level, optname, optval, optlen) -> 0"},
    55: {"name": "SYS_GETSOCKOPT", "doc": "Get socket options", "sig": "getsockopt(fd, level, optname, optval, optlen) -> 0"},
    56: {"name": "SYS_CLONE", "doc": "Create a child process with specified flags", "sig": "clone(flags, stack, parent_tid, child_tid, tls) -> pid"},
    57: {"name": "SYS_FORK", "doc": "Create a child process", "sig": "fork() -> pid"},
    58: {"name": "SYS_VFORK", "doc": "Create child process sharing VM until exec/exit", "sig": "vfork() -> pid"},
    59: {"name": "SYS_EXECVE", "doc": "Execute a program", "sig": "execve(path, argv, envp) -> noreturn"},
    60: {"name": "SYS_EXIT", "doc": "Exit the current process", "sig": "exit(status) -> noreturn"},
    61: {"name": "SYS_WAIT4", "doc": "Wait for process state change", "sig": "wait4(pid, wstatus, options, rusage) -> pid"},
    62: {"name": "SYS_KILL", "doc": "Send signal to a process", "sig": "kill(pid, sig) -> 0"},
    63: {"name": "SYS_UNAME", "doc": "Get system information", "sig": "uname(buf) -> 0"},
    72: {"name": "SYS_FCNTL", "doc": "Manipulate file descriptor flags (e.g., O_NONBLOCK)", "sig": "fcntl(fd, cmd, arg) -> result"},
    74: {"name": "SYS_FSYNC", "doc": "Synchronize file's in-core state with storage", "sig": "fsync(fd) -> 0"},
    75: {"name": "SYS_FDATASYNC", "doc": "Synchronize file data (not metadata)", "sig": "fdatasync(fd) -> 0"},
    76: {"name": "SYS_TRUNCATE", "doc": "Truncate a file to specified length", "sig": "truncate(path, length) -> 0"},
    77: {"name": "SYS_FTRUNCATE", "doc": "Truncate file by fd to specified length", "sig": "ftruncate(fd, length) -> 0"},
    78: {"name": "SYS_GETDENTS", "doc": "Get directory entries", "sig": "getdents(fd, dirp, count) -> bytes_read"},
    79: {"name": "SYS_GETCWD", "doc": "Get current working directory", "sig": "getcwd(buf, size) -> buf"},
    80: {"name": "SYS_CHDIR", "doc": "Change working directory", "sig": "chdir(path) -> 0"},
    81: {"name": "SYS_FCHDIR", "doc": "Change working directory by fd", "sig": "fchdir(fd) -> 0"},
    82: {"name": "SYS_RENAME", "doc": "Rename a file", "sig": "rename(oldpath, newpath) -> 0"},
    83: {"name": "SYS_MKDIR", "doc": "Create a directory", "sig": "mkdir(path, mode) -> 0"},
    84: {"name": "SYS_RMDIR", "doc": "Remove a directory", "sig": "rmdir(path) -> 0"},
    85: {"name": "SYS_CREAT", "doc": "Create a file (legacy, use open with O_CREAT)", "sig": "creat(path, mode) -> fd"},
    86: {"name": "SYS_LINK", "doc": "Create a hard link", "sig": "link(oldpath, newpath) -> 0"},
    87: {"name": "SYS_UNLINK", "doc": "Delete a file", "sig": "unlink(path) -> 0"},
    88: {"name": "SYS_SYMLINK", "doc": "Create a symbolic link", "sig": "symlink(target, linkpath) -> 0"},
    89: {"name": "SYS_READLINK", "doc": "Read value of symbolic link", "sig": "readlink(path, buf, bufsiz) -> bytes_read"},
    90: {"name": "SYS_CHMOD", "doc": "Change file mode", "sig": "chmod(path, mode) -> 0"},
    91: {"name": "SYS_FCHMOD", "doc": "Change file mode by fd", "sig": "fchmod(fd, mode) -> 0"},
    92: {"name": "SYS_CHOWN", "doc": "Change file owner", "sig": "chown(path, owner, group) -> 0"},
    93: {"name": "SYS_FCHOWN", "doc": "Change file owner by fd", "sig": "fchown(fd, owner, group) -> 0"},
    94: {"name": "SYS_LCHOWN", "doc": "Change symlink owner (don't follow)", "sig": "lchown(path, owner, group) -> 0"},
    95: {"name": "SYS_UMASK", "doc": "Set file creation mask", "sig": "umask(mask) -> old_mask"},
    96: {"name": "SYS_GETTIMEOFDAY", "doc": "Get time of day (legacy)", "sig": "gettimeofday(tv, tz) -> 0"},
    97: {"name": "SYS_GETRLIMIT", "doc": "Get resource limits", "sig": "getrlimit(resource, rlim) -> 0"},
    98: {"name": "SYS_GETRUSAGE", "doc": "Get resource usage statistics", "sig": "getrusage(who, usage) -> 0"},
    101: {"name": "SYS_PTRACE", "doc": "Process tracing and debugging", "sig": "ptrace(request, pid, addr, data) -> result"},
    102: {"name": "SYS_GETUID", "doc": "Get user ID", "sig": "getuid() -> uid"},
    104: {"name": "SYS_GETGID", "doc": "Get group ID", "sig": "getgid() -> gid"},
    105: {"name": "SYS_SETUID", "doc": "Set user ID", "sig": "setuid(uid) -> 0"},
    106: {"name": "SYS_SETGID", "doc": "Set group ID", "sig": "setgid(gid) -> 0"},
    107: {"name": "SYS_GETEUID", "doc": "Get effective user ID", "sig": "geteuid() -> uid"},
    108: {"name": "SYS_GETEGID", "doc": "Get effective group ID", "sig": "getegid() -> gid"},
    110: {"name": "SYS_GETPPID", "doc": "Get parent process ID", "sig": "getppid() -> pid"},
    117: {"name": "SYS_SETRESUID", "doc": "Set real, effective, and saved user IDs", "sig": "setresuid(ruid, euid, suid) -> 0"},
    118: {"name": "SYS_GETRESUID", "doc": "Get real, effective, and saved user IDs", "sig": "getresuid(ruid, euid, suid) -> 0"},
    119: {"name": "SYS_SETRESGID", "doc": "Set real, effective, and saved group IDs", "sig": "setresgid(rgid, egid, sgid) -> 0"},
    120: {"name": "SYS_GETRESGID", "doc": "Get real, effective, and saved group IDs", "sig": "getresgid(rgid, egid, sgid) -> 0"},
    125: {"name": "SYS_CAPGET", "doc": "Get thread capabilities", "sig": "capget(hdr, data) -> 0"},
    126: {"name": "SYS_CAPSET", "doc": "Set thread capabilities", "sig": "capset(hdr, data) -> 0"},
    127: {"name": "SYS_RT_SIGPENDING", "doc": "Examine pending signals", "sig": "rt_sigpending(set, sigsetsize) -> 0"},
    128: {"name": "SYS_RT_SIGTIMEDWAIT", "doc": "Synchronously wait for queued signals", "sig": "rt_sigtimedwait(set, info, timeout, sigsetsize) -> signo"},
    129: {"name": "SYS_RT_SIGQUEUEINFO", "doc": "Queue a signal with info to a process", "sig": "rt_sigqueueinfo(pid, sig, info) -> 0"},
    130: {"name": "SYS_RT_SIGSUSPEND", "doc": "Wait for a signal, replacing signal mask", "sig": "rt_sigsuspend(mask, sigsetsize) -> -EINTR"},
    131: {"name": "SYS_SIGALTSTACK", "doc": "Set/get signal stack context", "sig": "sigaltstack(ss, old_ss) -> 0"},
    137: {"name": "SYS_STATFS", "doc": "Get filesystem statistics", "sig": "statfs(path, buf) -> 0"},
    138: {"name": "SYS_FSTATFS", "doc": "Get filesystem statistics by fd", "sig": "fstatfs(fd, buf) -> 0"},
    149: {"name": "SYS_MLOCK", "doc": "Lock memory pages to prevent swapping", "sig": "mlock(addr, len) -> 0"},
    150: {"name": "SYS_MUNLOCK", "doc": "Unlock memory pages", "sig": "munlock(addr, len) -> 0"},
    151: {"name": "SYS_MLOCKALL", "doc": "Lock all memory pages", "sig": "mlockall(flags) -> 0"},
    152: {"name": "SYS_MUNLOCKALL", "doc": "Unlock all memory pages", "sig": "munlockall() -> 0"},
    157: {"name": "SYS_PRCTL", "doc": "Process control operations", "sig": "prctl(option, arg2, arg3, arg4, arg5) -> result"},
    158: {"name": "SYS_ARCH_PRCTL", "doc": "Set architecture-specific thread state", "sig": "arch_prctl(code, addr) -> 0"},
    160: {"name": "SYS_SETRLIMIT", "doc": "Set resource limits", "sig": "setrlimit(resource, rlim) -> 0"},
    162: {"name": "SYS_SYNC", "doc": "Commit buffer cache to disk", "sig": "sync() -> 0"},
    164: {"name": "SYS_SETTIMEOFDAY", "doc": "Set time of day (requires root)", "sig": "settimeofday(tv, tz) -> 0"},
    165: {"name": "SYS_MOUNT", "doc": "Mount a filesystem", "sig": "mount(source, target, fstype, flags, data) -> 0"},
    166: {"name": "SYS_UMOUNT2", "doc": "Unmount a filesystem", "sig": "umount2(target, flags) -> 0"},
    170: {"name": "SYS_SETHOSTNAME", "doc": "Set host name", "sig": "sethostname(name, len) -> 0"},
    171: {"name": "SYS_SETDOMAINNAME", "doc": "Set domain name", "sig": "setdomainname(name, len) -> 0"},
    186: {"name": "SYS_GETTID", "doc": "Get thread ID", "sig": "gettid() -> tid"},
    200: {"name": "SYS_TKILL", "doc": "Send signal to a specific thread", "sig": "tkill(tid, sig) -> 0"},
    202: {"name": "SYS_FUTEX", "doc": "Fast userspace locking", "sig": "futex(uaddr, op, val, timeout, uaddr2, val3) -> result"},
    217: {"name": "SYS_GETDENTS64", "doc": "Get directory entries (64-bit)", "sig": "getdents64(fd, dirp, count) -> bytes_read"},
    218: {"name": "SYS_SET_TID_ADDRESS", "doc": "Set pointer to thread ID", "sig": "set_tid_address(tidptr) -> tid"},
    222: {"name": "SYS_TIMER_CREATE", "doc": "Create a POSIX per-process timer", "sig": "timer_create(clockid, sevp, timerid) -> 0"},
    223: {"name": "SYS_TIMER_SETTIME", "doc": "Arm/disarm a POSIX per-process timer", "sig": "timer_settime(timerid, flags, new_value, old_value) -> 0"},
    224: {"name": "SYS_TIMER_GETTIME", "doc": "Get POSIX per-process timer state", "sig": "timer_gettime(timerid, curr_value) -> 0"},
    225: {"name": "SYS_TIMER_GETOVERRUN", "doc": "Get overrun count for a POSIX timer", "sig": "timer_getoverrun(timerid) -> overrun"},
    226: {"name": "SYS_TIMER_DELETE", "doc": "Delete a POSIX per-process timer", "sig": "timer_delete(timerid) -> 0"},
    228: {"name": "SYS_CLOCK_GETTIME", "doc": "Get time from a clock", "sig": "clock_gettime(clockid, tp) -> 0"},
    229: {"name": "SYS_CLOCK_GETRES", "doc": "Get clock resolution", "sig": "clock_getres(clockid, res) -> 0"},
    230: {"name": "SYS_CLOCK_NANOSLEEP", "doc": "High-resolution sleep with clock selection", "sig": "clock_nanosleep(clockid, flags, req, rem) -> 0"},
    231: {"name": "SYS_EXIT_GROUP", "doc": "Exit all threads in process", "sig": "exit_group(status) -> noreturn"},
    232: {"name": "SYS_EPOLL_WAIT", "doc": "Wait for I/O events on an epoll instance", "sig": "epoll_wait(epfd, events, maxevents, timeout) -> count"},
    233: {"name": "SYS_EPOLL_CTL", "doc": "Control an epoll instance", "sig": "epoll_ctl(epfd, op, fd, event) -> 0"},
    234: {"name": "SYS_TGKILL", "doc": "Send signal to a thread in a thread group", "sig": "tgkill(tgid, tid, sig) -> 0"},
    253: {"name": "SYS_INOTIFY_INIT", "doc": "Initialize an inotify instance", "sig": "inotify_init() -> fd"},
    254: {"name": "SYS_INOTIFY_ADD_WATCH", "doc": "Add watch to inotify instance", "sig": "inotify_add_watch(fd, path, mask) -> wd"},
    255: {"name": "SYS_INOTIFY_RM_WATCH", "doc": "Remove watch from inotify instance", "sig": "inotify_rm_watch(fd, wd) -> 0"},
    257: {"name": "SYS_OPENAT", "doc": "Open file relative to a directory FD", "sig": "openat(dirfd, path, flags, mode) -> fd"},
    258: {"name": "SYS_MKDIRAT", "doc": "Create directory relative to directory FD", "sig": "mkdirat(dirfd, path, mode) -> 0"},
    259: {"name": "SYS_MKNODAT", "doc": "Create special/device file relative to directory FD", "sig": "mknodat(dirfd, path, mode, dev) -> 0"},
    260: {"name": "SYS_FCHOWNAT", "doc": "Change ownership relative to directory FD", "sig": "fchownat(dirfd, path, owner, group, flags) -> 0"},
    262: {"name": "SYS_NEWFSTATAT", "doc": "Get file status relative to directory FD", "sig": "newfstatat(dirfd, path, statbuf, flags) -> 0"},
    263: {"name": "SYS_UNLINKAT", "doc": "Delete file/directory relative to directory FD", "sig": "unlinkat(dirfd, path, flags) -> 0"},
    264: {"name": "SYS_RENAMEAT", "doc": "Rename file relative to directory FDs", "sig": "renameat(olddirfd, oldpath, newdirfd, newpath) -> 0"},
    265: {"name": "SYS_LINKAT", "doc": "Create hard link relative to directory FDs", "sig": "linkat(olddirfd, oldpath, newdirfd, newpath, flags) -> 0"},
    266: {"name": "SYS_SYMLINKAT", "doc": "Create symlink relative to directory FD", "sig": "symlinkat(target, newdirfd, linkpath) -> 0"},
    267: {"name": "SYS_READLINKAT", "doc": "Read symlink relative to directory FD", "sig": "readlinkat(dirfd, path, buf, bufsiz) -> bytes_read"},
    268: {"name": "SYS_FCHMODAT", "doc": "Change permissions relative to directory FD", "sig": "fchmodat(dirfd, path, mode, flags) -> 0"},
    269: {"name": "SYS_FACCESSAT", "doc": "Check access relative to directory FD", "sig": "faccessat(dirfd, path, mode, flags) -> 0"},
    272: {"name": "SYS_UNSHARE", "doc": "Disassociate parts of execution context", "sig": "unshare(flags) -> 0"},
    275: {"name": "SYS_SPLICE", "doc": "Splice data between file descriptors", "sig": "splice(fd_in, off_in, fd_out, off_out, len, flags) -> bytes"},
    276: {"name": "SYS_TEE", "doc": "Duplicate pipe content", "sig": "tee(fd_in, fd_out, len, flags) -> bytes"},
    277: {"name": "SYS_SYNC_FILE_RANGE", "doc": "Sync file segment with disk", "sig": "sync_file_range(fd, offset, nbytes, flags) -> 0"},
    278: {"name": "SYS_VMSPLICE", "doc": "Splice user pages into pipe", "sig": "vmsplice(fd, iov, nr_segs, flags) -> bytes"},
    281: {"name": "SYS_EPOLL_PWAIT", "doc": "Wait for I/O events with signal mask", "sig": "epoll_pwait(epfd, events, maxevents, timeout, sigmask, sigsetsize) -> count"},
    282: {"name": "SYS_SIGNALFD", "doc": "Create file descriptor for signal handling", "sig": "signalfd(fd, mask, flags) -> fd"},
    283: {"name": "SYS_TIMERFD_CREATE", "doc": "Create timer as file descriptor", "sig": "timerfd_create(clockid, flags) -> fd"},
    284: {"name": "SYS_EVENTFD", "doc": "Create event notification file descriptor", "sig": "eventfd(initval, flags) -> fd"},
    285: {"name": "SYS_FALLOCATE", "doc": "Pre-allocate file space", "sig": "fallocate(fd, mode, offset, len) -> 0"},
    286: {"name": "SYS_TIMERFD_SETTIME", "doc": "Arm/disarm timerfd", "sig": "timerfd_settime(fd, flags, new_value, old_value) -> 0"},
    287: {"name": "SYS_TIMERFD_GETTIME", "doc": "Get timerfd state", "sig": "timerfd_gettime(fd, curr_value) -> 0"},
    289: {"name": "SYS_SIGNALFD4", "doc": "signalfd with flags", "sig": "signalfd4(fd, mask, sizemask, flags) -> fd"},
    290: {"name": "SYS_EVENTFD2", "doc": "eventfd with flags", "sig": "eventfd2(initval, flags) -> fd"},
    291: {"name": "SYS_EPOLL_CREATE1", "doc": "Create an epoll instance", "sig": "epoll_create1(flags) -> fd"},
    292: {"name": "SYS_DUP3", "doc": "Duplicate FD with flags", "sig": "dup3(oldfd, newfd, flags) -> newfd"},
    293: {"name": "SYS_PIPE2", "doc": "Create pipe with flags", "sig": "pipe2(pipefd[2], flags) -> 0"},
    294: {"name": "SYS_INOTIFY_INIT1", "doc": "Initialize inotify instance with flags", "sig": "inotify_init1(flags) -> fd"},
    295: {"name": "SYS_PREADV", "doc": "Read data at offset into multiple buffers", "sig": "preadv(fd, iov, iovcnt, offset) -> bytes_read"},
    296: {"name": "SYS_PWRITEV", "doc": "Write data from multiple buffers at offset", "sig": "pwritev(fd, iov, iovcnt, offset) -> bytes_written"},
    302: {"name": "SYS_PRLIMIT64", "doc": "Get/set resource limits for any process", "sig": "prlimit64(pid, resource, new_rlim, old_rlim) -> 0"},
    306: {"name": "SYS_SYNCFS", "doc": "Sync single filesystem to disk", "sig": "syncfs(fd) -> 0"},
    308: {"name": "SYS_SETNS", "doc": "Reassociate thread with a namespace", "sig": "setns(fd, nstype) -> 0"},
    316: {"name": "SYS_RENAMEAT2", "doc": "Rename file with flags (atomic exchange, noreplace)", "sig": "renameat2(olddirfd, oldpath, newdirfd, newpath, flags) -> 0"},
    317: {"name": "SYS_SECCOMP", "doc": "Secure computing mode (syscall filtering)", "sig": "seccomp(op, flags, args) -> result"},
    318: {"name": "SYS_GETRANDOM", "doc": "Get random bytes", "sig": "getrandom(buf, buflen, flags) -> bytes_read"},
    319: {"name": "SYS_MEMFD_CREATE", "doc": "Create anonymous file for memory sharing", "sig": "memfd_create(name, flags) -> fd"},
    326: {"name": "SYS_COPY_FILE_RANGE", "doc": "Copy data between file descriptors (server-side)", "sig": "copy_file_range(fd_in, off_in, fd_out, off_out, len, flags) -> bytes"},
    425: {"name": "SYS_IO_URING_SETUP", "doc": "Setup io_uring instance", "sig": "io_uring_setup(entries, params) -> fd"},
    426: {"name": "SYS_IO_URING_ENTER", "doc": "Submit and wait for io_uring operations", "sig": "io_uring_enter(fd, to_submit, min_complete, flags, sig) -> count"},
    427: {"name": "SYS_IO_URING_REGISTER", "doc": "Register buffers/files with io_uring", "sig": "io_uring_register(fd, opcode, arg, nr_args) -> 0"},
    435: {"name": "SYS_CLONE3", "doc": "Create child process with clone_args struct", "sig": "clone3(cl_args, size) -> pid"},

    # Zscapek Custom Extensions (1000+)
    1000: {"name": "SYS_DEBUG_LOG", "doc": "Write debug message to kernel log", "sig": "debug_log(msg, len) -> 0"},
    1001: {"name": "SYS_GET_FB_INFO", "doc": "Get framebuffer info", "sig": "get_fb_info(info) -> 0"},
    1002: {"name": "SYS_MAP_FB", "doc": "Map framebuffer into process address space", "sig": "map_fb() -> addr"},
    1003: {"name": "SYS_READ_SCANCODE", "doc": "Read raw keyboard scancode (non-blocking)", "sig": "read_scancode() -> scancode or -EAGAIN"},
    1004: {"name": "SYS_GETCHAR", "doc": "Read ASCII character from input buffer (blocking)", "sig": "getchar() -> char"},
    1005: {"name": "SYS_PUTCHAR", "doc": "Write character to console", "sig": "putchar(c) -> 0"},
    1006: {"name": "SYS_FB_FLUSH", "doc": "Flush framebuffer to display (trigger present)", "sig": "fb_flush() -> 0"},
    1010: {"name": "SYS_READ_INPUT_EVENT", "doc": "Read next input event (non-blocking)", "sig": "read_input_event(event) -> 0 or -EAGAIN"},
    1011: {"name": "SYS_GET_CURSOR_POSITION", "doc": "Get current cursor position", "sig": "get_cursor_position(x, y) -> 0"},
    1012: {"name": "SYS_SET_CURSOR_BOUNDS", "doc": "Set cursor bounds (screen dimensions)", "sig": "set_cursor_bounds(width, height) -> 0"},
    1013: {"name": "SYS_SET_INPUT_MODE", "doc": "Set input mode (relative/absolute/raw)", "sig": "set_input_mode(mode) -> 0"},
    1020: {"name": "SYS_SEND", "doc": "Send an IPC message to a process (blocking)", "sig": "send(pid, msg, len) -> 0"},
    1021: {"name": "SYS_RECV", "doc": "Receive an IPC message (blocking)", "sig": "recv(buf, len, from_pid) -> bytes_recv"},
    1022: {"name": "SYS_WAIT_INTERRUPT", "doc": "Wait for a hardware interrupt (blocking)", "sig": "wait_interrupt(irq) -> 0"},
    1025: {"name": "SYS_REGISTER_IPC_LOGGER", "doc": "Connect kernel logger to IPC backend", "sig": "register_ipc_logger() -> 0"},
    1026: {"name": "SYS_REGISTER_SERVICE", "doc": "Register the current process as a named service", "sig": "register_service(name, len) -> 0"},
    1027: {"name": "SYS_LOOKUP_SERVICE", "doc": "Lookup a service PID by name", "sig": "lookup_service(name, len) -> pid"},
    1030: {"name": "SYS_MMAP_PHYS", "doc": "Map physical MMIO region into userspace", "sig": "mmap_phys(phys, size) -> virt"},
    1031: {"name": "SYS_ALLOC_DMA", "doc": "Allocate DMA-capable memory with known physical address", "sig": "alloc_dma(result, num_pages) -> 0"},
    1032: {"name": "SYS_FREE_DMA", "doc": "Free DMA memory previously allocated with SYS_ALLOC_DMA", "sig": "free_dma(virt, num_pages) -> 0"},
    1033: {"name": "SYS_PCI_ENUMERATE", "doc": "Enumerate PCI devices", "sig": "pci_enumerate(buf, max_devices) -> count"},
    1034: {"name": "SYS_PCI_CONFIG_READ", "doc": "Read PCI configuration space register", "sig": "pci_config_read(bus, dev, func, offset) -> value"},
    1035: {"name": "SYS_PCI_CONFIG_WRITE", "doc": "Write PCI configuration space register", "sig": "pci_config_write(bus, dev, func, offset, value) -> 0"},
    1036: {"name": "SYS_OUTB", "doc": "Write byte to I/O port", "sig": "outb(port, value) -> 0"},
    1037: {"name": "SYS_INB", "doc": "Read byte from I/O port", "sig": "inb(port) -> value"},
    1040: {"name": "SYS_RING_CREATE", "doc": "Create a new ring buffer for zero-copy IPC", "sig": "ring_create(entry_size, count, consumer_pid, name, name_len) -> ring_id"},
    1041: {"name": "SYS_RING_ATTACH", "doc": "Attach to an existing ring as consumer", "sig": "ring_attach(ring_id, result) -> 0"},
    1042: {"name": "SYS_RING_DETACH", "doc": "Detach from a ring (producer or consumer)", "sig": "ring_detach(ring_id) -> 0"},
    1043: {"name": "SYS_RING_WAIT", "doc": "Wait for entries to become available (consumer)", "sig": "ring_wait(ring_id, min_entries, timeout_ns) -> count"},
    1044: {"name": "SYS_RING_NOTIFY", "doc": "Notify consumer that entries are available (producer)", "sig": "ring_notify(ring_id) -> 0"},
    1045: {"name": "SYS_RING_WAIT_ANY", "doc": "Wait for entries on any of multiple rings (MPSC consumer)", "sig": "ring_wait_any(ring_ids, count, min_entries, timeout_ns) -> ring_id"},
    1046: {"name": "SYS_ALLOC_IOMMU_DMA", "doc": "Allocate IOMMU-protected DMA memory for a specific device", "sig": "alloc_iommu_dma(bdf, result, num_pages) -> 0"},
    1047: {"name": "SYS_FREE_IOMMU_DMA", "doc": "Free IOMMU-protected DMA memory", "sig": "free_iommu_dma(bdf, virt, num_pages) -> 0"},
    1050: {"name": "SYS_VMWARE_HYPERCALL", "doc": "Execute VMware hypercall command (requires CAP_HYPERVISOR)", "sig": "vmware_hypercall(regs_ptr) -> 0"},
    1051: {"name": "SYS_GET_HYPERVISOR", "doc": "Get hypervisor type (0=none, 1=vmware, 2=vbox, 3=kvm, 4=hyperv, 5=xen, 6=qemu)", "sig": "get_hypervisor() -> type"},

    # Network Interface Configuration Syscalls (1060-1069)
    1060: {"name": "SYS_NETIF_CONFIG", "doc": "Configure network interface (requires CAP_NET_CONFIG)", "sig": "netif_config(iface_idx, cmd, data_ptr, data_len) -> 0"},
    1061: {"name": "SYS_ARP_PROBE", "doc": "ARP probe for IP conflict detection (RFC 5227)", "sig": "arp_probe(iface_idx, target_ip, timeout_ms) -> 0=safe, 1=conflict, 2=timeout"},
    1062: {"name": "SYS_ARP_ANNOUNCE", "doc": "Gratuitous ARP announcement (RFC 5227)", "sig": "arp_announce(iface_idx, ip_addr) -> 0"},

    # Virtual PCI Device Emulation Syscalls (1080-1090)
    1080: {"name": "SYS_VPCI_CREATE", "doc": "Create virtual PCI device (requires VirtualPciCapability)", "sig": "vpci_create() -> device_id"},
    1081: {"name": "SYS_VPCI_ADD_BAR", "doc": "Add BAR to virtual PCI device", "sig": "vpci_add_bar(dev_id, config_ptr) -> 0"},
    1082: {"name": "SYS_VPCI_ADD_CAP", "doc": "Add PCI capability (MSI, MSI-X, PM)", "sig": "vpci_add_cap(dev_id, cap_ptr) -> offset"},
    1083: {"name": "SYS_VPCI_SET_CONFIG", "doc": "Set PCI config header (vendor/device ID, class)", "sig": "vpci_set_config(dev_id, header_ptr) -> 0"},
    1084: {"name": "SYS_VPCI_REGISTER", "doc": "Make device visible to PCI subsystem, create event ring", "sig": "vpci_register(dev_id) -> ring_id"},
    1085: {"name": "SYS_VPCI_INJECT_IRQ", "doc": "Inject MSI/MSI-X interrupt", "sig": "vpci_inject_irq(dev_id, irq_ptr) -> 0"},
    1086: {"name": "SYS_VPCI_DMA", "doc": "Perform DMA read/write operation", "sig": "vpci_dma(dma_op_ptr) -> bytes"},
    1087: {"name": "SYS_VPCI_GET_BAR_INFO", "doc": "Get BAR physical address after registration", "sig": "vpci_get_bar_info(dev_id, idx, info_ptr) -> 0"},
    1088: {"name": "SYS_VPCI_DESTROY", "doc": "Unregister and destroy virtual device", "sig": "vpci_destroy(dev_id) -> 0"},
    1089: {"name": "SYS_VPCI_WAIT_EVENT", "doc": "Wait for MMIO event on device's event ring", "sig": "vpci_wait_event(dev_id, timeout_ms) -> count"},
    1090: {"name": "SYS_VPCI_RESPOND", "doc": "Submit response to MMIO read event", "sig": "vpci_respond(dev_id, response_ptr) -> 0"},
}

# Linux aarch64 ABI syscall numbers
# Source: https://arm64.syscall.sh/
SYSCALLS_AARCH64 = {
    # I/O Core
    63: {"name": "SYS_READ", "doc": "Read from a file descriptor", "sig": "read(fd, buf, count) -> bytes_read"},
    64: {"name": "SYS_WRITE", "doc": "Write to a file descriptor", "sig": "write(fd, buf, count) -> bytes_written"},
    29: {"name": "SYS_IOCTL", "doc": "Perform device-specific control operations", "sig": "ioctl(fd, request, arg) -> result"},
    25: {"name": "SYS_FCNTL", "doc": "Manipulate file descriptor flags", "sig": "fcntl(fd, cmd, arg) -> result"},
    67: {"name": "SYS_PREAD64", "doc": "Read from file at offset", "sig": "pread64(fd, buf, count, offset) -> bytes_read"},
    68: {"name": "SYS_PWRITE64", "doc": "Write to file at offset", "sig": "pwrite64(fd, buf, count, offset) -> bytes_written"},
    65: {"name": "SYS_READV", "doc": "Read data into multiple buffers", "sig": "readv(fd, iov, iovcnt) -> bytes_read"},
    66: {"name": "SYS_WRITEV", "doc": "Write data from multiple buffers", "sig": "writev(fd, iov, iovcnt) -> bytes_written"},

    # File Descriptors
    56: {"name": "SYS_OPENAT", "doc": "Open file relative to directory FD", "sig": "openat(dirfd, path, flags, mode) -> fd"},
    57: {"name": "SYS_CLOSE", "doc": "Close a file descriptor", "sig": "close(fd) -> 0"},
    62: {"name": "SYS_LSEEK", "doc": "Reposition read/write file offset", "sig": "lseek(fd, offset, whence) -> offset"},
    23: {"name": "SYS_DUP", "doc": "Duplicate a file descriptor", "sig": "dup(oldfd) -> newfd"},
    24: {"name": "SYS_DUP3", "doc": "Duplicate FD with flags", "sig": "dup3(oldfd, newfd, flags) -> newfd"},
    59: {"name": "SYS_PIPE2", "doc": "Create pipe with flags", "sig": "pipe2(pipefd[2], flags) -> 0"},

    # File Status
    79: {"name": "SYS_NEWFSTATAT", "doc": "Get file status relative to directory FD", "sig": "newfstatat(dirfd, path, statbuf, flags) -> 0"},
    80: {"name": "SYS_FSTAT", "doc": "Get file status by fd", "sig": "fstat(fd, statbuf) -> 0"},
    43: {"name": "SYS_STATFS", "doc": "Get filesystem statistics", "sig": "statfs(path, buf) -> 0"},
    44: {"name": "SYS_FSTATFS", "doc": "Get filesystem statistics by fd", "sig": "fstatfs(fd, buf) -> 0"},

    # Directory Operations
    17: {"name": "SYS_GETCWD", "doc": "Get current working directory", "sig": "getcwd(buf, size) -> buf"},
    49: {"name": "SYS_CHDIR", "doc": "Change working directory", "sig": "chdir(path) -> 0"},
    50: {"name": "SYS_FCHDIR", "doc": "Change working directory by fd", "sig": "fchdir(fd) -> 0"},
    34: {"name": "SYS_MKDIRAT", "doc": "Create directory relative to directory FD", "sig": "mkdirat(dirfd, path, mode) -> 0"},
    35: {"name": "SYS_UNLINKAT", "doc": "Delete file/directory relative to directory FD", "sig": "unlinkat(dirfd, path, flags) -> 0"},
    38: {"name": "SYS_RENAMEAT", "doc": "Rename file relative to directory FDs", "sig": "renameat(olddirfd, oldpath, newdirfd, newpath) -> 0"},
    276: {"name": "SYS_RENAMEAT2", "doc": "Rename file with flags", "sig": "renameat2(olddirfd, oldpath, newdirfd, newpath, flags) -> 0"},
    37: {"name": "SYS_LINKAT", "doc": "Create hard link relative to directory FDs", "sig": "linkat(olddirfd, oldpath, newdirfd, newpath, flags) -> 0"},
    36: {"name": "SYS_SYMLINKAT", "doc": "Create symlink relative to directory FD", "sig": "symlinkat(target, newdirfd, linkpath) -> 0"},
    78: {"name": "SYS_READLINKAT", "doc": "Read symlink relative to directory FD", "sig": "readlinkat(dirfd, path, buf, bufsiz) -> bytes_read"},
    33: {"name": "SYS_MKNODAT", "doc": "Create special/device file relative to directory FD", "sig": "mknodat(dirfd, path, mode, dev) -> 0"},

    # Permissions
    52: {"name": "SYS_FCHMOD", "doc": "Change file mode by fd", "sig": "fchmod(fd, mode) -> 0"},
    53: {"name": "SYS_FCHMODAT", "doc": "Change permissions relative to directory FD", "sig": "fchmodat(dirfd, path, mode, flags) -> 0"},
    54: {"name": "SYS_FCHOWNAT", "doc": "Change ownership relative to directory FD", "sig": "fchownat(dirfd, path, owner, group, flags) -> 0"},
    55: {"name": "SYS_FCHOWN", "doc": "Change file owner by fd", "sig": "fchown(fd, owner, group) -> 0"},
    166: {"name": "SYS_UMASK", "doc": "Set file creation mask", "sig": "umask(mask) -> old_mask"},
    48: {"name": "SYS_FACCESSAT", "doc": "Check access relative to directory FD", "sig": "faccessat(dirfd, path, mode, flags) -> 0"},

    # Memory Management
    222: {"name": "SYS_MMAP", "doc": "Map memory pages", "sig": "mmap(addr, len, prot, flags, fd, off) -> addr"},
    226: {"name": "SYS_MPROTECT", "doc": "Set memory protection", "sig": "mprotect(addr, len, prot) -> 0"},
    215: {"name": "SYS_MUNMAP", "doc": "Unmap memory pages", "sig": "munmap(addr, len) -> 0"},
    214: {"name": "SYS_BRK", "doc": "Change data segment size (heap)", "sig": "brk(addr) -> new_brk"},
    216: {"name": "SYS_MREMAP", "doc": "Remap/resize a virtual memory area", "sig": "mremap(old_addr, old_size, new_size, flags) -> addr"},
    227: {"name": "SYS_MSYNC", "doc": "Synchronize file with memory map", "sig": "msync(addr, len, flags) -> 0"},
    232: {"name": "SYS_MINCORE", "doc": "Determine whether pages are resident", "sig": "mincore(addr, len, vec) -> 0"},
    233: {"name": "SYS_MADVISE", "doc": "Give advice about memory usage patterns", "sig": "madvise(addr, len, advice) -> 0"},
    228: {"name": "SYS_MLOCK", "doc": "Lock memory pages", "sig": "mlock(addr, len) -> 0"},
    229: {"name": "SYS_MUNLOCK", "doc": "Unlock memory pages", "sig": "munlock(addr, len) -> 0"},
    230: {"name": "SYS_MLOCKALL", "doc": "Lock all memory pages", "sig": "mlockall(flags) -> 0"},
    231: {"name": "SYS_MUNLOCKALL", "doc": "Unlock all memory pages", "sig": "munlockall() -> 0"},

    # Process Management
    172: {"name": "SYS_GETPID", "doc": "Get process ID", "sig": "getpid() -> pid"},
    173: {"name": "SYS_GETPPID", "doc": "Get parent process ID", "sig": "getppid() -> pid"},
    178: {"name": "SYS_GETTID", "doc": "Get thread ID", "sig": "gettid() -> tid"},
    93: {"name": "SYS_EXIT", "doc": "Exit the current process", "sig": "exit(status) -> noreturn"},
    94: {"name": "SYS_EXIT_GROUP", "doc": "Exit all threads in process", "sig": "exit_group(status) -> noreturn"},
    220: {"name": "SYS_CLONE", "doc": "Create a child process with specified flags", "sig": "clone(flags, stack, parent_tid, child_tid, tls) -> pid"},
    435: {"name": "SYS_CLONE3", "doc": "Create child process with clone_args struct", "sig": "clone3(cl_args, size) -> pid"},
    221: {"name": "SYS_EXECVE", "doc": "Execute a program", "sig": "execve(path, argv, envp) -> noreturn"},
    260: {"name": "SYS_WAIT4", "doc": "Wait for process state change", "sig": "wait4(pid, wstatus, options, rusage) -> pid"},

    # Signals
    134: {"name": "SYS_RT_SIGACTION", "doc": "Examine and change signal actions", "sig": "rt_sigaction(sig, act, oldact, sigsetsize) -> 0"},
    135: {"name": "SYS_RT_SIGPROCMASK", "doc": "Examine and change blocked signals", "sig": "rt_sigprocmask(how, set, oldset, sigsetsize) -> 0"},
    139: {"name": "SYS_RT_SIGRETURN", "doc": "Return from signal handler", "sig": "rt_sigreturn() -> noreturn"},
    136: {"name": "SYS_RT_SIGPENDING", "doc": "Examine pending signals", "sig": "rt_sigpending(set, sigsetsize) -> 0"},
    137: {"name": "SYS_RT_SIGTIMEDWAIT", "doc": "Synchronously wait for queued signals", "sig": "rt_sigtimedwait(set, info, timeout, sigsetsize) -> signo"},
    138: {"name": "SYS_RT_SIGQUEUEINFO", "doc": "Queue a signal with info to a process", "sig": "rt_sigqueueinfo(pid, sig, info) -> 0"},
    133: {"name": "SYS_RT_SIGSUSPEND", "doc": "Wait for a signal, replacing signal mask", "sig": "rt_sigsuspend(mask, sigsetsize) -> -EINTR"},
    132: {"name": "SYS_SIGALTSTACK", "doc": "Set/get signal stack context", "sig": "sigaltstack(ss, old_ss) -> 0"},
    129: {"name": "SYS_KILL", "doc": "Send signal to a process", "sig": "kill(pid, sig) -> 0"},
    130: {"name": "SYS_TKILL", "doc": "Send signal to a specific thread", "sig": "tkill(tid, sig) -> 0"},
    131: {"name": "SYS_TGKILL", "doc": "Send signal to a thread in a thread group", "sig": "tgkill(tgid, tid, sig) -> 0"},

    # User/Group IDs
    174: {"name": "SYS_GETUID", "doc": "Get user ID", "sig": "getuid() -> uid"},
    175: {"name": "SYS_GETEUID", "doc": "Get effective user ID", "sig": "geteuid() -> uid"},
    176: {"name": "SYS_GETGID", "doc": "Get group ID", "sig": "getgid() -> gid"},
    177: {"name": "SYS_GETEGID", "doc": "Get effective group ID", "sig": "getegid() -> gid"},
    146: {"name": "SYS_SETUID", "doc": "Set user ID", "sig": "setuid(uid) -> 0"},
    144: {"name": "SYS_SETGID", "doc": "Set group ID", "sig": "setgid(gid) -> 0"},
    147: {"name": "SYS_SETRESUID", "doc": "Set real, effective, and saved user IDs", "sig": "setresuid(ruid, euid, suid) -> 0"},
    148: {"name": "SYS_GETRESUID", "doc": "Get real, effective, and saved user IDs", "sig": "getresuid(ruid, euid, suid) -> 0"},
    149: {"name": "SYS_SETRESGID", "doc": "Set real, effective, and saved group IDs", "sig": "setresgid(rgid, egid, sgid) -> 0"},
    150: {"name": "SYS_GETRESGID", "doc": "Get real, effective, and saved group IDs", "sig": "getresgid(rgid, egid, sgid) -> 0"},

    # Sockets
    198: {"name": "SYS_SOCKET", "doc": "Create a socket", "sig": "socket(domain, type, protocol) -> fd"},
    199: {"name": "SYS_SOCKETPAIR", "doc": "Create connected socket pair", "sig": "socketpair(domain, type, protocol, sv[2]) -> 0"},
    200: {"name": "SYS_BIND", "doc": "Bind a socket to an address", "sig": "bind(fd, addr, addrlen) -> 0"},
    201: {"name": "SYS_LISTEN", "doc": "Listen for connections on socket", "sig": "listen(fd, backlog) -> 0"},
    202: {"name": "SYS_ACCEPT", "doc": "Accept connection on socket", "sig": "accept(fd, addr, addrlen) -> fd"},
    242: {"name": "SYS_ACCEPT4", "doc": "Accept connection with flags", "sig": "accept4(fd, addr, addrlen, flags) -> fd"},
    203: {"name": "SYS_CONNECT", "doc": "Connect socket to address", "sig": "connect(fd, addr, addrlen) -> 0"},
    204: {"name": "SYS_GETSOCKNAME", "doc": "Get local socket address", "sig": "getsockname(fd, addr, addrlen) -> 0"},
    205: {"name": "SYS_GETPEERNAME", "doc": "Get peer socket address", "sig": "getpeername(fd, addr, addrlen) -> 0"},
    206: {"name": "SYS_SENDTO", "doc": "Send a message on a socket", "sig": "sendto(fd, buf, len, flags, dest_addr, addrlen) -> bytes_sent"},
    207: {"name": "SYS_RECVFROM", "doc": "Receive a message from a socket", "sig": "recvfrom(fd, buf, len, flags, src_addr, addrlen) -> bytes_recv"},
    211: {"name": "SYS_SENDMSG", "doc": "Send a message with scatter/gather I/O", "sig": "sendmsg(fd, msg, flags) -> bytes_sent"},
    212: {"name": "SYS_RECVMSG", "doc": "Receive a message with scatter/gather I/O", "sig": "recvmsg(fd, msg, flags) -> bytes_recv"},
    208: {"name": "SYS_SETSOCKOPT", "doc": "Set socket options", "sig": "setsockopt(fd, level, optname, optval, optlen) -> 0"},
    209: {"name": "SYS_GETSOCKOPT", "doc": "Get socket options", "sig": "getsockopt(fd, level, optname, optval, optlen) -> 0"},
    210: {"name": "SYS_SHUTDOWN", "doc": "Shut down part of a connection", "sig": "shutdown(fd, how) -> 0"},

    # Time
    169: {"name": "SYS_GETTIMEOFDAY", "doc": "Get time of day", "sig": "gettimeofday(tv, tz) -> 0"},
    170: {"name": "SYS_SETTIMEOFDAY", "doc": "Set time of day", "sig": "settimeofday(tv, tz) -> 0"},
    113: {"name": "SYS_CLOCK_GETTIME", "doc": "Get time from a clock", "sig": "clock_gettime(clockid, tp) -> 0"},
    114: {"name": "SYS_CLOCK_GETRES", "doc": "Get clock resolution", "sig": "clock_getres(clockid, res) -> 0"},
    115: {"name": "SYS_CLOCK_NANOSLEEP", "doc": "High-resolution sleep with clock selection", "sig": "clock_nanosleep(clockid, flags, req, rem) -> 0"},
    101: {"name": "SYS_NANOSLEEP", "doc": "High-resolution sleep", "sig": "nanosleep(req, rem) -> 0"},
    107: {"name": "SYS_TIMER_CREATE", "doc": "Create a POSIX per-process timer", "sig": "timer_create(clockid, sevp, timerid) -> 0"},
    108: {"name": "SYS_TIMER_GETTIME", "doc": "Get POSIX per-process timer state", "sig": "timer_gettime(timerid, curr_value) -> 0"},
    109: {"name": "SYS_TIMER_GETOVERRUN", "doc": "Get overrun count for a POSIX timer", "sig": "timer_getoverrun(timerid) -> overrun"},
    110: {"name": "SYS_TIMER_SETTIME", "doc": "Arm/disarm a POSIX per-process timer", "sig": "timer_settime(timerid, flags, new_value, old_value) -> 0"},
    111: {"name": "SYS_TIMER_DELETE", "doc": "Delete a POSIX per-process timer", "sig": "timer_delete(timerid) -> 0"},

    # Epoll/Events
    20: {"name": "SYS_EPOLL_CREATE1", "doc": "Create an epoll instance", "sig": "epoll_create1(flags) -> fd"},
    21: {"name": "SYS_EPOLL_CTL", "doc": "Control an epoll instance", "sig": "epoll_ctl(epfd, op, fd, event) -> 0"},
    22: {"name": "SYS_EPOLL_PWAIT", "doc": "Wait for I/O events with signal mask", "sig": "epoll_pwait(epfd, events, maxevents, timeout, sigmask, sigsetsize) -> count"},
    19: {"name": "SYS_EVENTFD2", "doc": "eventfd with flags", "sig": "eventfd2(initval, flags) -> fd"},
    74: {"name": "SYS_SIGNALFD4", "doc": "signalfd with flags", "sig": "signalfd4(fd, mask, sizemask, flags) -> fd"},
    85: {"name": "SYS_TIMERFD_CREATE", "doc": "Create timer as file descriptor", "sig": "timerfd_create(clockid, flags) -> fd"},
    86: {"name": "SYS_TIMERFD_SETTIME", "doc": "Arm/disarm timerfd", "sig": "timerfd_settime(fd, flags, new_value, old_value) -> 0"},
    87: {"name": "SYS_TIMERFD_GETTIME", "doc": "Get timerfd state", "sig": "timerfd_gettime(fd, curr_value) -> 0"},

    # Scheduling
    124: {"name": "SYS_SCHED_YIELD", "doc": "Yield the processor", "sig": "sched_yield() -> 0"},
    98: {"name": "SYS_FUTEX", "doc": "Fast userspace locking", "sig": "futex(uaddr, op, val, timeout, uaddr2, val3) -> result"},
    96: {"name": "SYS_SET_TID_ADDRESS", "doc": "Set pointer to thread ID", "sig": "set_tid_address(tidptr) -> tid"},

    # Filesystem Operations
    81: {"name": "SYS_SYNC", "doc": "Commit buffer cache to disk", "sig": "sync() -> 0"},
    82: {"name": "SYS_FSYNC", "doc": "Synchronize file's in-core state with storage", "sig": "fsync(fd) -> 0"},
    83: {"name": "SYS_FDATASYNC", "doc": "Synchronize file data (not metadata)", "sig": "fdatasync(fd) -> 0"},
    267: {"name": "SYS_SYNCFS", "doc": "Sync single filesystem to disk", "sig": "syncfs(fd) -> 0"},
    45: {"name": "SYS_TRUNCATE", "doc": "Truncate a file to specified length", "sig": "truncate(path, length) -> 0"},
    46: {"name": "SYS_FTRUNCATE", "doc": "Truncate file by fd to specified length", "sig": "ftruncate(fd, length) -> 0"},
    47: {"name": "SYS_FALLOCATE", "doc": "Pre-allocate file space", "sig": "fallocate(fd, mode, offset, len) -> 0"},
    40: {"name": "SYS_MOUNT", "doc": "Mount a filesystem", "sig": "mount(source, target, fstype, flags, data) -> 0"},
    39: {"name": "SYS_UMOUNT2", "doc": "Unmount a filesystem", "sig": "umount2(target, flags) -> 0"},

    # Advanced I/O
    71: {"name": "SYS_SENDFILE", "doc": "Transfer data between file descriptors (zero-copy)", "sig": "sendfile(out_fd, in_fd, offset, count) -> bytes_sent"},
    76: {"name": "SYS_SPLICE", "doc": "Splice data between file descriptors", "sig": "splice(fd_in, off_in, fd_out, off_out, len, flags) -> bytes"},
    77: {"name": "SYS_TEE", "doc": "Duplicate pipe content", "sig": "tee(fd_in, fd_out, len, flags) -> bytes"},
    75: {"name": "SYS_VMSPLICE", "doc": "Splice user pages into pipe", "sig": "vmsplice(fd, iov, nr_segs, flags) -> bytes"},
    285: {"name": "SYS_COPY_FILE_RANGE", "doc": "Copy data between file descriptors", "sig": "copy_file_range(fd_in, off_in, fd_out, off_out, len, flags) -> bytes"},
    61: {"name": "SYS_GETDENTS64", "doc": "Get directory entries (64-bit)", "sig": "getdents64(fd, dirp, count) -> bytes_read"},
    69: {"name": "SYS_PREADV", "doc": "Read data at offset into multiple buffers", "sig": "preadv(fd, iov, iovcnt, offset) -> bytes_read"},
    70: {"name": "SYS_PWRITEV", "doc": "Write data from multiple buffers at offset", "sig": "pwritev(fd, iov, iovcnt, offset) -> bytes_written"},

    # Misc
    160: {"name": "SYS_UNAME", "doc": "Get system information", "sig": "uname(buf) -> 0"},
    161: {"name": "SYS_SETHOSTNAME", "doc": "Set host name", "sig": "sethostname(name, len) -> 0"},
    162: {"name": "SYS_SETDOMAINNAME", "doc": "Set domain name", "sig": "setdomainname(name, len) -> 0"},
    163: {"name": "SYS_GETRLIMIT", "doc": "Get resource limits", "sig": "getrlimit(resource, rlim) -> 0"},
    164: {"name": "SYS_SETRLIMIT", "doc": "Set resource limits", "sig": "setrlimit(resource, rlim) -> 0"},
    261: {"name": "SYS_PRLIMIT64", "doc": "Get/set resource limits for any process", "sig": "prlimit64(pid, resource, new_rlim, old_rlim) -> 0"},
    165: {"name": "SYS_GETRUSAGE", "doc": "Get resource usage statistics", "sig": "getrusage(who, usage) -> 0"},
    167: {"name": "SYS_PRCTL", "doc": "Process control operations", "sig": "prctl(option, arg2, arg3, arg4, arg5) -> result"},
    278: {"name": "SYS_GETRANDOM", "doc": "Get random bytes", "sig": "getrandom(buf, buflen, flags) -> bytes_read"},
    279: {"name": "SYS_MEMFD_CREATE", "doc": "Create anonymous file for memory sharing", "sig": "memfd_create(name, flags) -> fd"},
    277: {"name": "SYS_SECCOMP", "doc": "Secure computing mode (syscall filtering)", "sig": "seccomp(op, flags, args) -> result"},

    # inotify
    26: {"name": "SYS_INOTIFY_INIT1", "doc": "Initialize inotify instance with flags", "sig": "inotify_init1(flags) -> fd"},
    27: {"name": "SYS_INOTIFY_ADD_WATCH", "doc": "Add watch to inotify instance", "sig": "inotify_add_watch(fd, path, mask) -> wd"},
    28: {"name": "SYS_INOTIFY_RM_WATCH", "doc": "Remove watch from inotify instance", "sig": "inotify_rm_watch(fd, wd) -> 0"},

    # Capabilities & Debugging
    90: {"name": "SYS_CAPGET", "doc": "Get thread capabilities", "sig": "capget(hdr, data) -> 0"},
    91: {"name": "SYS_CAPSET", "doc": "Set thread capabilities", "sig": "capset(hdr, data) -> 0"},
    117: {"name": "SYS_PTRACE", "doc": "Process tracing and debugging", "sig": "ptrace(request, pid, addr, data) -> result"},

    # Container/Namespace
    97: {"name": "SYS_UNSHARE", "doc": "Disassociate parts of execution context", "sig": "unshare(flags) -> 0"},
    268: {"name": "SYS_SETNS", "doc": "Reassociate thread with a namespace", "sig": "setns(fd, nstype) -> 0"},

    # io_uring
    425: {"name": "SYS_IO_URING_SETUP", "doc": "Setup io_uring instance", "sig": "io_uring_setup(entries, params) -> fd"},
    426: {"name": "SYS_IO_URING_ENTER", "doc": "Submit and wait for io_uring operations", "sig": "io_uring_enter(fd, to_submit, min_complete, flags, sig) -> count"},
    427: {"name": "SYS_IO_URING_REGISTER", "doc": "Register buffers/files with io_uring", "sig": "io_uring_register(fd, opcode, arg, nr_args) -> 0"},

    # Legacy compatibility stubs (zigk-specific, 500-599 range)
    500: {"name": "SYS_OPEN", "doc": "[zigk compat] Open a file (redirects to openat)", "sig": "open(path, flags, mode) -> fd"},
    502: {"name": "SYS_PIPE", "doc": "[zigk compat] Create a pipe (redirects to pipe2)", "sig": "pipe(pipefd[2]) -> 0"},
    503: {"name": "SYS_STAT", "doc": "[zigk compat] Get file status (redirects to newfstatat)", "sig": "stat(path, statbuf) -> 0"},
    504: {"name": "SYS_LSTAT", "doc": "[zigk compat] Get file status no follow (redirects to newfstatat)", "sig": "lstat(path, statbuf) -> 0"},
    505: {"name": "SYS_ACCESS", "doc": "[zigk compat] Check permissions (redirects to faccessat)", "sig": "access(path, mode) -> 0"},
    506: {"name": "SYS_DUP2", "doc": "[zigk compat] Duplicate FD (redirects to dup3)", "sig": "dup2(oldfd, newfd) -> newfd"},
    507: {"name": "SYS_FORK", "doc": "[zigk compat] Create child process (redirects to clone)", "sig": "fork() -> pid"},
    508: {"name": "SYS_SELECT", "doc": "[zigk compat] Examine FDs (redirects to pselect6)", "sig": "select(nfds, r, w, e, timeout) -> count"},
    509: {"name": "SYS_EPOLL_WAIT", "doc": "[zigk compat] Wait for epoll (redirects to epoll_pwait)", "sig": "epoll_wait(epfd, events, maxevents, timeout) -> count"},
    510: {"name": "SYS_POLL", "doc": "[zigk compat] Wait for events (redirects to ppoll)", "sig": "poll(fds, nfds, timeout) -> count"},

    # Zscapek Custom Extensions (1000+) - same as x86_64
    1000: {"name": "SYS_DEBUG_LOG", "doc": "Write debug message to kernel log", "sig": "debug_log(msg, len) -> 0"},
    1001: {"name": "SYS_GET_FB_INFO", "doc": "Get framebuffer info", "sig": "get_fb_info(info) -> 0"},
    1002: {"name": "SYS_MAP_FB", "doc": "Map framebuffer into process address space", "sig": "map_fb() -> addr"},
    1003: {"name": "SYS_READ_SCANCODE", "doc": "Read raw keyboard scancode (non-blocking)", "sig": "read_scancode() -> scancode or -EAGAIN"},
    1004: {"name": "SYS_GETCHAR", "doc": "Read ASCII character from input buffer (blocking)", "sig": "getchar() -> char"},
    1005: {"name": "SYS_PUTCHAR", "doc": "Write character to console", "sig": "putchar(c) -> 0"},
    1006: {"name": "SYS_FB_FLUSH", "doc": "Flush framebuffer to display (trigger present)", "sig": "fb_flush() -> 0"},
    1010: {"name": "SYS_READ_INPUT_EVENT", "doc": "Read next input event (non-blocking)", "sig": "read_input_event(event) -> 0 or -EAGAIN"},
    1020: {"name": "SYS_SEND", "doc": "Send an IPC message to a process (blocking)", "sig": "send(pid, msg, len) -> 0"},
    1021: {"name": "SYS_RECV", "doc": "Receive an IPC message (blocking)", "sig": "recv(buf, len, from_pid) -> bytes_recv"},
    1022: {"name": "SYS_WAIT_INTERRUPT", "doc": "Wait for a hardware interrupt (blocking)", "sig": "wait_interrupt(irq) -> 0"},
    1026: {"name": "SYS_REGISTER_SERVICE", "doc": "Register the current process as a named service", "sig": "register_service(name, len) -> 0"},
    1027: {"name": "SYS_LOOKUP_SERVICE", "doc": "Lookup a service PID by name", "sig": "lookup_service(name, len) -> pid"},
    1030: {"name": "SYS_MMAP_PHYS", "doc": "Map physical MMIO region into userspace", "sig": "mmap_phys(phys, size) -> virt"},
    1031: {"name": "SYS_ALLOC_DMA", "doc": "Allocate DMA-capable memory", "sig": "alloc_dma(result, num_pages) -> 0"},
    1032: {"name": "SYS_FREE_DMA", "doc": "Free DMA memory", "sig": "free_dma(virt, num_pages) -> 0"},
    1033: {"name": "SYS_PCI_ENUMERATE", "doc": "Enumerate PCI devices", "sig": "pci_enumerate(buf, max_devices) -> count"},
    1040: {"name": "SYS_RING_CREATE", "doc": "Create a new ring buffer for zero-copy IPC", "sig": "ring_create(entry_size, count, consumer_pid, name, name_len) -> ring_id"},
    1041: {"name": "SYS_RING_ATTACH", "doc": "Attach to an existing ring as consumer", "sig": "ring_attach(ring_id, result) -> 0"},
    1042: {"name": "SYS_RING_DETACH", "doc": "Detach from a ring", "sig": "ring_detach(ring_id) -> 0"},
    1043: {"name": "SYS_RING_WAIT", "doc": "Wait for entries to become available", "sig": "ring_wait(ring_id, min_entries, timeout_ns) -> count"},
    1044: {"name": "SYS_RING_NOTIFY", "doc": "Notify consumer that entries are available", "sig": "ring_notify(ring_id) -> 0"},
    1050: {"name": "SYS_VMWARE_HYPERCALL", "doc": "Execute VMware hypercall command", "sig": "vmware_hypercall(regs_ptr) -> 0"},
    1051: {"name": "SYS_GET_HYPERVISOR", "doc": "Get hypervisor type", "sig": "get_hypervisor() -> type"},
    1060: {"name": "SYS_NETIF_CONFIG", "doc": "Configure network interface", "sig": "netif_config(iface_idx, cmd, data_ptr, data_len) -> 0"},

    # Virtual PCI Device Emulation Syscalls (1080-1090) - same as x86_64
    1080: {"name": "SYS_VPCI_CREATE", "doc": "Create virtual PCI device (requires VirtualPciCapability)", "sig": "vpci_create() -> device_id"},
    1081: {"name": "SYS_VPCI_ADD_BAR", "doc": "Add BAR to virtual PCI device", "sig": "vpci_add_bar(dev_id, config_ptr) -> 0"},
    1082: {"name": "SYS_VPCI_ADD_CAP", "doc": "Add PCI capability (MSI, MSI-X, PM)", "sig": "vpci_add_cap(dev_id, cap_ptr) -> offset"},
    1083: {"name": "SYS_VPCI_SET_CONFIG", "doc": "Set PCI config header (vendor/device ID, class)", "sig": "vpci_set_config(dev_id, header_ptr) -> 0"},
    1084: {"name": "SYS_VPCI_REGISTER", "doc": "Make device visible to PCI subsystem, create event ring", "sig": "vpci_register(dev_id) -> ring_id"},
    1085: {"name": "SYS_VPCI_INJECT_IRQ", "doc": "Inject MSI/MSI-X interrupt", "sig": "vpci_inject_irq(dev_id, irq_ptr) -> 0"},
    1086: {"name": "SYS_VPCI_DMA", "doc": "Perform DMA read/write operation", "sig": "vpci_dma(dma_op_ptr) -> bytes"},
    1087: {"name": "SYS_VPCI_GET_BAR_INFO", "doc": "Get BAR physical address after registration", "sig": "vpci_get_bar_info(dev_id, idx, info_ptr) -> 0"},
    1088: {"name": "SYS_VPCI_DESTROY", "doc": "Unregister and destroy virtual device", "sig": "vpci_destroy(dev_id) -> 0"},
    1089: {"name": "SYS_VPCI_WAIT_EVENT", "doc": "Wait for MMIO event on device's event ring", "sig": "vpci_wait_event(dev_id, timeout_ms) -> count"},
    1090: {"name": "SYS_VPCI_RESPOND", "doc": "Submit response to MMIO read event", "sig": "vpci_respond(dev_id, response_ptr) -> 0"},
}

# Categories for aarch64 (using aarch64 syscall numbers)
CATEGORIES_AARCH64 = {
    "io": [63, 64, 29, 25, 67, 68, 65, 66, 82, 83, 45, 46, 17, 49, 50],
    "fd": [56, 57, 62, 23, 24, 59, 500],
    "mem": [222, 226, 215, 214, 216, 227, 232, 233, 228, 229, 230, 231],
    "proc": [172, 173, 178, 93, 94, 220, 435, 221, 260, 174, 175, 176, 177, 146, 144, 147, 148, 149, 150, 261, 507],
    "sig": [134, 135, 139, 136, 137, 138, 133, 132, 129, 130, 131],
    "net": [198, 199, 200, 201, 202, 242, 203, 204, 205, 206, 207, 211, 212, 208, 209, 210],
    "sched": [124, 98, 96, 101, 169, 170, 113, 114, 115],
    "fs": [79, 80, 43, 44, 81, 267, 47, 40, 39, 61, 166, 503, 504],
    "fsat": [56, 34, 35, 38, 276, 37, 36, 78, 33, 53, 54, 48],
    "timer": [107, 108, 109, 110, 111, 85, 86, 87, 115],
    "event": [20, 21, 22, 19, 74, 26, 27, 28, 509],
    "advio": [71, 76, 77, 75, 285, 69, 70],
    "security": [117, 90, 91, 167, 277],
    "container": [97, 268],
    "misc": [160, 161, 162, 163, 164, 165, 278, 279],
    "uring": [425, 426, 427],
    "ipc": [1020, 1021, 1022, 1026, 1027],
    "ring": [1040, 1041, 1042, 1043, 1044],
    "mmio": [1030, 1031, 1032, 1033],
    "input": [1003, 1004, 1005, 1010],
    "fb": [1000, 1001, 1002, 1006],
    "hypervisor": [1050, 1051],
    "netconfig": [1060],
    "virt_pci": [1080, 1081, 1082, 1083, 1084, 1085, 1086, 1087, 1088, 1089, 1090],
}

# Categories for grouping (x86_64)
CATEGORIES = {
    "io": [0, 1, 6, 16, 17, 18, 19, 20, 72, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 86, 88, 89, 93, 94],
    "fd": [2, 3, 8, 22, 32, 33, 85, 257, 292, 293],
    "mem": [9, 10, 11, 12, 25, 26, 27, 28, 149, 150, 151, 152],
    "proc": [39, 56, 57, 58, 59, 60, 61, 62, 98, 102, 104, 105, 106, 107, 108, 110, 117, 118, 119, 120, 186, 231, 302, 435],
    "sig": [13, 14, 15, 127, 128, 129, 130, 131, 200, 218, 234],
    "net": [7, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55],
    "sched": [23, 24, 35, 164, 228, 229, 230],
    "fs": [4, 5, 21, 87, 90, 91, 92, 95, 96, 97, 137, 138, 160, 162, 165, 166, 217, 306],
    "fsat": [257, 258, 259, 260, 262, 263, 264, 265, 266, 267, 268, 269, 316],
    "timer": [222, 223, 224, 225, 226, 230, 283, 286, 287],
    "event": [232, 233, 253, 254, 255, 281, 282, 284, 289, 290, 291, 294],
    "advio": [40, 275, 276, 277, 278, 285, 295, 296, 326],
    "security": [101, 125, 126, 157, 317],
    "container": [272, 308],
    "misc": [162, 306, 318, 319],
    "uring": [425, 426, 427],
    "ipc": [1020, 1021, 1022, 1025, 1026, 1027],
    "ring": [1040, 1041, 1042, 1043, 1044, 1045],
    "mmio": [1030, 1031, 1032, 1033, 1034, 1035, 1036, 1037, 1046, 1047],
    "input": [1003, 1004, 1005, 1010, 1011, 1012, 1013],
    "fb": [1000, 1001, 1002, 1006],
    "hypervisor": [1050, 1051],
    "netconfig": [1060, 1061, 1062],
    "virt_pci": [1080, 1081, 1082, 1083, 1084, 1085, 1086, 1087, 1088, 1089, 1090],
}

# Optional: Try to parse live from source if available (for updates)
def find_project_root():
    path = Path(__file__).resolve()
    for parent in path.parents:
        if (parent / "build.zig").exists():
            return parent
    return None

def parse_syscalls_from_source():
    """Optionally parse syscalls from source for live updates."""
    root = find_project_root()
    if not root:
        return None

    syscalls = {}

    # Check both possible locations
    for subpath in ["src/uapi/syscalls/linux.zig", "src/uapi/syscalls/zscapek.zig", "src/uapi/syscalls/root.zig", "src/uapi/syscalls.zig"]:
        zig_file = root / subpath
        if not zig_file.exists():
            continue

        content = zig_file.read_text()
        # Match: pub const SYS_NAME: usize = N; or pub const SYS_NAME = N;
        # Fixed regex: type annotation is now optional
        pattern = r'pub const (SYS_\w+)(?::\s*usize)?\s*=\s*(?:[a-zA-Z0-9_.]+\.)?(\d+);'

        for match in re.finditer(pattern, content):
            name = match.group(1)
            num = int(match.group(2))
            # Extract doc comment above if present
            start = match.start()
            lines_before = content[:start].split('\n')
            doc = ""
            sig = ""
            for line in reversed(lines_before[-5:]):
                line = line.strip()
                if line.startswith("///"):
                    doc_line = line[3:].strip()
                    if "(" in doc_line and ")" in doc_line:
                        sig = doc_line
                    else:
                        doc = doc_line
                        break
            syscalls[num] = {"name": name, "doc": doc, "sig": sig}

    return syscalls if syscalls else None

def find_handler(syscall_name):
    """Find which handler file implements a syscall"""
    root = find_project_root()
    if not root:
        return None

    syscall_dir = root / "src" / "kernel" / "sys" / "syscall"
    if not syscall_dir.exists():
        return None

    # Convert SYS_READ to sys_read
    fn_name = "sys_" + syscall_name[4:].lower()

    for zig_file in syscall_dir.glob("**/*.zig"):
        if zig_file.name in ["table.zig", "base.zig", "user_mem.zig"]:
            continue
        try:
            content = zig_file.read_text()
            if f"pub fn {fn_name}" in content:
                return zig_file.name
        except:
            pass
    return None

def format_syscall(num, info, show_handler=True):
    """Format a single syscall for display"""
    name = info["name"][4:]  # Remove SYS_ prefix
    handler = find_handler(info["name"]) if show_handler else None
    handler_str = f" [{handler}]" if handler else ""
    sig = info.get("sig", "")
    doc = info.get("doc", "")

    result = f"{num:4d} | {name:20s}{handler_str}"
    if sig:
        result += f"\n      {sig}"
    if doc and doc != sig:
        result += f"\n      {doc}"
    return result

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    # Parse --arch argument if present
    args = sys.argv[1:]
    arch = "x86_64"  # Default architecture

    if "--arch" in args:
        arch_idx = args.index("--arch")
        if arch_idx + 1 < len(args):
            arch = args[arch_idx + 1].lower()
            # Remove --arch and its value from args
            args = args[:arch_idx] + args[arch_idx + 2:]
        else:
            print("Error: --arch requires a value (x86_64 or aarch64)")
            sys.exit(1)

    # Validate architecture
    if arch not in ("x86_64", "aarch64"):
        print(f"Error: Unknown architecture '{arch}'. Use 'x86_64' or 'aarch64'.")
        sys.exit(1)

    # Select architecture-specific data
    if arch == "aarch64":
        syscalls = SYSCALLS_AARCH64.copy()
        categories = CATEGORIES_AARCH64
    else:
        syscalls = SYSCALLS.copy()
        categories = CATEGORIES

    # Optionally override with live source (x86_64 only for now)
    if arch == "x86_64":
        live = parse_syscalls_from_source()
        if live:
            syscalls.update(live)  # Merge live data

    if not args:
        print(__doc__)
        sys.exit(1)

    arg = args[0]

    # --all: list all syscalls
    if arg == "--all":
        print(f"All syscalls ({arch}):")
        for num in sorted(syscalls.keys()):
            print(format_syscall(num, syscalls[num]))
        return

    # --zscapek: list Zscapek extensions (1000+)
    if arg == "--zscapek":
        print(f"Zscapek Extensions (1000+) ({arch}):")
        for num in sorted(syscalls.keys()):
            if num >= 1000:
                print(format_syscall(num, syscalls[num]))
        return

    # --security: shorthand for --category security
    if arg == "--security":
        print(f"Security-Critical Syscalls ({arch}):")
        for num in categories["security"]:
            if num in syscalls:
                print(format_syscall(num, syscalls[num]))
        return

    # --category: list by category
    if arg == "--category" and len(args) > 1:
        cat = args[1].lower()
        if cat not in categories:
            print(f"Categories: {', '.join(categories.keys())}")
            sys.exit(1)
        print(f"Category: {cat} ({arch})")
        for num in categories[cat]:
            if num in syscalls:
                print(format_syscall(num, syscalls[num]))
        return

    # --handler: list by handler file
    if arg == "--handler" and len(args) > 1:
        handler = args[1]
        if not handler.endswith(".zig"):
            handler += ".zig"
        print(f"Handler: {handler}")
        for num in sorted(syscalls.keys()):
            info = syscalls[num]
            h = find_handler(info["name"])
            if h == handler:
                print(format_syscall(num, info, show_handler=False))
        return

    # Search by name (partial match)
    if not arg.isdigit():
        query = arg.upper()
        if not query.startswith("SYS_"):
            query = "SYS_" + query
        found = False
        for num, info in sorted(syscalls.items()):
            if query in info["name"]:
                print(format_syscall(num, info))
                found = True
        if not found:
            print(f"No syscall matching '{arg}'")
        return

    # Search by number
    num = int(arg)
    if num in syscalls:
        print(format_syscall(num, syscalls[num]))
    else:
        print(f"No syscall with number {num}")

if __name__ == "__main__":
    main()

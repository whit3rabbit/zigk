#!/usr/bin/env python3
"""
Syscall Query Tool for zigk kernel.

Query syscalls by name, number, category, or handler file.
Parses actual source files for always up-to-date information.

Usage:
    python syscall_query.py read              # Find syscall by name
    python syscall_query.py 41                # Find syscall by number
    python syscall_query.py --category net    # List category
    python syscall_query.py --handler io.zig  # List syscalls in handler file
    python syscall_query.py --all             # List all syscalls
    python syscall_query.py --zscapek         # List Zscapek extensions (1000+)
    python syscall_query.py --security        # List security-critical syscalls

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
"""

import sys
import re
import os
from pathlib import Path

# Find project root (look for build.zig)
def find_project_root():
    path = Path(__file__).resolve()
    for parent in path.parents:
        if (parent / "build.zig").exists():
            return parent
    return Path.cwd()

PROJECT_ROOT = find_project_root()
SYSCALLS_FILE = PROJECT_ROOT / "src" / "uapi" / "syscalls.zig"
SYSCALL_DIR = PROJECT_ROOT / "src" / "kernel" / "syscall"

# Categories for grouping
# Updated with all Linux ABI syscalls added in security audit
CATEGORIES = {
    # Core I/O operations
    "io": [0, 1, 6, 16, 17, 18, 19, 20, 72, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 86, 88, 89, 93, 94],
    # File descriptors: open, close, dup, pipe, creat
    "fd": [2, 3, 8, 22, 32, 33, 85, 257, 292, 293],
    # Memory management: mmap, mprotect, mremap, madvise, mlock
    "mem": [9, 10, 11, 12, 25, 26, 27, 28, 149, 150, 151, 152],
    # Process management: fork, clone, exec, exit, wait, getpid, getrusage
    "proc": [39, 56, 57, 58, 59, 60, 61, 62, 98, 102, 104, 105, 106, 107, 108, 110, 117, 118, 119, 120, 186, 231, 302, 435],
    # Signals: rt_sig*, sigaltstack, kill, tgkill
    "sig": [13, 14, 15, 127, 128, 129, 130, 131, 200, 218, 234],
    # Networking: socket, bind, listen, connect, accept, send, recv
    "net": [7, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55],
    # Scheduling and time: sched_yield, nanosleep, clock_gettime
    "sched": [23, 24, 35, 228, 229, 230],
    # Filesystem: stat, access, chmod, mount, getdents
    "fs": [4, 5, 21, 87, 90, 91, 92, 95, 96, 97, 160, 162, 165, 166, 217, 306],
    # File *at() operations: mkdirat, unlinkat, renameat, fstatat, etc.
    "fsat": [257, 258, 259, 260, 262, 263, 264, 265, 266, 267, 268, 269, 316],
    # Timers: timer_create, timerfd_create, clock_nanosleep
    "timer": [222, 223, 224, 225, 226, 230, 283, 286, 287],
    # Events: epoll, inotify, eventfd, signalfd
    "event": [232, 233, 253, 254, 255, 281, 282, 284, 289, 290, 291, 294],
    # Advanced I/O: sendfile, splice, fallocate, copy_file_range
    "advio": [40, 275, 276, 277, 278, 285, 295, 296, 326],
    # Security: ptrace, prctl, seccomp, capget/capset
    "security": [101, 125, 126, 157, 317],
    # Container/namespace: unshare, setns
    "container": [272, 308],
    # Misc: sync, memfd_create, getrandom
    "misc": [162, 306, 318, 319],
    # io_uring async I/O
    "uring": [425, 426, 427],
    # Zscapek IPC
    "ipc": [1020, 1021, 1022, 1025, 1026, 1027],
    # Zscapek ring buffer IPC
    "ring": [1040, 1041, 1042, 1043, 1044, 1045],
    # Zscapek MMIO/DMA/PCI
    "mmio": [1030, 1031, 1032, 1033, 1034, 1035, 1036, 1037, 1046, 1047],
    # Zscapek input
    "input": [1003, 1004, 1005, 1010, 1011, 1012, 1013],
    # Zscapek framebuffer
    "fb": [1000, 1001, 1002],
}

def parse_syscalls():
    """Parse syscalls from src/uapi/syscalls.zig"""
    syscalls = {}
    if not SYSCALLS_FILE.exists():
        return syscalls

    content = SYSCALLS_FILE.read_text()
    # Match: pub const SYS_NAME: usize = N;
    pattern = r'pub const (SYS_\w+):\s*usize\s*=\s*(\d+);'

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

    return syscalls

def find_handler(syscall_name):
    """Find which handler file implements a syscall"""
    # Convert SYS_READ to sys_read
    fn_name = "sys_" + syscall_name[4:].lower()

    if not SYSCALL_DIR.exists():
        return None

    for zig_file in SYSCALL_DIR.glob("*.zig"):
        if zig_file.name in ["table.zig", "base.zig", "user_mem.zig"]:
            continue
        content = zig_file.read_text()
        if f"pub fn {fn_name}" in content:
            return zig_file.name
    return None

def format_syscall(num, info, show_handler=True):
    """Format a single syscall for display"""
    name = info["name"][4:]  # Remove SYS_ prefix
    handler = find_handler(info["name"]) if show_handler else None
    handler_str = f" [{handler}]" if handler else ""
    sig = info["sig"] if info["sig"] else ""
    doc = info["doc"] if info["doc"] else ""

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

    syscalls = parse_syscalls()
    if not syscalls:
        print("Error: Could not parse syscalls.zig")
        sys.exit(1)

    arg = sys.argv[1]

    # --all: list all syscalls
    if arg == "--all":
        for num in sorted(syscalls.keys()):
            print(format_syscall(num, syscalls[num]))
        return

    # --zscapek: list Zscapek extensions (1000+)
    if arg == "--zscapek":
        print("Zscapek Extensions (1000+):")
        for num in sorted(syscalls.keys()):
            if num >= 1000:
                print(format_syscall(num, syscalls[num]))
        return

    # --security: shorthand for --category security
    if arg == "--security":
        print("Security-Critical Syscalls:")
        for num in CATEGORIES["security"]:
            if num in syscalls:
                print(format_syscall(num, syscalls[num]))
        return

    # --category: list by category
    if arg == "--category" and len(sys.argv) > 2:
        cat = sys.argv[2].lower()
        if cat not in CATEGORIES:
            print(f"Categories: {', '.join(CATEGORIES.keys())}")
            sys.exit(1)
        print(f"Category: {cat}")
        for num in CATEGORIES[cat]:
            if num in syscalls:
                print(format_syscall(num, syscalls[num]))
        return

    # --handler: list by handler file
    if arg == "--handler" and len(sys.argv) > 2:
        handler = sys.argv[2]
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

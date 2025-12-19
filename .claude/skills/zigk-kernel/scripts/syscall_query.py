#!/usr/bin/env python3
"""
Syscall Query Tool for zigk kernel.

Query syscalls by name, number, category, or handler file.
Parses actual source files for always up-to-date information.

Usage:
    python syscall_query.py read              # Find syscall by name
    python syscall_query.py 41                # Find syscall by number
    python syscall_query.py --category net    # List category (net, io, mem, proc, fs, ipc, ring)
    python syscall_query.py --handler io.zig  # List syscalls in handler file
    python syscall_query.py --all             # List all syscalls
    python syscall_query.py --zscapek         # List Zscapek extensions (1000+)
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
CATEGORIES = {
    "io": [0, 1, 4, 5, 6, 16, 17, 18, 19, 20, 72, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 86, 88, 89, 90, 91, 92, 93, 94],
    "fd": [2, 3, 8, 22, 32, 33, 85, 257, 292, 293],  # Added creat, openat, dup3, pipe2
    "mem": [9, 10, 11, 12],
    "proc": [39, 56, 57, 59, 60, 61, 62, 102, 104, 105, 106, 107, 108, 110, 117, 118, 119, 120, 231],  # Added setuid/setgid/seteuid/setegid/setresuid/getresuid/setresgid/getresgid
    "sig": [13, 14, 15, 131, 200, 218, 234],
    "net": [7, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 54, 55],
    "sched": [23, 24, 35, 228, 229],
    "fs": [21, 87, 95, 96, 97, 160, 165, 166, 217],  # Removed 85 (creat) and 257 (openat) - moved to fd
    "ipc": [1020, 1021, 1022, 1025, 1026, 1027],
    "ring": [1040, 1041, 1042, 1043, 1044, 1045],
    "mmio": [1030, 1031, 1032, 1033, 1034, 1035, 1036, 1037],
    "input": [1003, 1004, 1005, 1010, 1011, 1012, 1013],
    "fb": [1000, 1001, 1002],
    "uring": [425, 426, 427],
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

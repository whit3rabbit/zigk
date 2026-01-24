#!/usr/bin/env python3
"""
Libc/Userspace Query Tool for zk kernel.

Query libc implementation details and userspace patterns.

Usage:
    python libc_query.py errno           # Error code mappings
    python libc_query.py syscall         # Userspace syscall wrapper
    python libc_query.py printf          # printf implementation
    python libc_query.py string          # String functions
    python libc_query.py memory          # Memory functions (malloc, etc)
    python libc_query.py file            # File I/O wrappers
    python libc_query.py net             # Network socket wrappers
    python libc_query.py crt0            # C runtime startup
    python libc_query.py structure       # User folder structure
"""

import sys
import re
from pathlib import Path

def find_project_root():
    path = Path(__file__).resolve()
    for parent in path.parents:
        if (parent / "build.zig").exists():
            return parent
    return Path.cwd()

PROJECT_ROOT = find_project_root()
ERRNO_FILE = PROJECT_ROOT / "src" / "uapi" / "errno.zig"
USER_SYSCALL = PROJECT_ROOT / "src" / "user" / "lib" / "syscall.zig"

def get_errno_codes():
    """Parse errno codes from uapi/errno.zig"""
    if not ERRNO_FILE.exists():
        return None

    content = ERRNO_FILE.read_text()
    # Find SyscallError enum
    pattern = r'pub const SyscallError = error\{([^}]+)\}'
    match = re.search(pattern, content, re.DOTALL)
    if match:
        errors = [e.strip().rstrip(',') for e in match.group(1).split('\n') if e.strip()]
        return errors
    return None

PATTERNS = {
    "syscall": """
## Userspace Syscall Wrapper

Location: src/user/lib/syscall.zig

### Basic Pattern
```zig
pub fn read(fd: i32, buf: [*]u8, count: usize) isize {
    return @bitCast(asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (@as(usize, 0)),  // SYS_READ
          [arg1] "{rdi}" (@as(usize, @bitCast(fd))),
          [arg2] "{rsi}" (@intFromPtr(buf)),
          [arg3] "{rdx}" (count),
        : "rcx", "r11", "memory"
    ));
}
```

### Register Convention
- RAX: syscall number (in) / return value (out)
- RDI: arg1
- RSI: arg2
- RDX: arg3
- R10: arg4 (NOT RCX!)
- R8: arg5
- R9: arg6
- Clobbers: RCX, R11

### Checking Errors
```zig
const ret = syscall.read(fd, buf, len);
if (ret < 0) {
    const errno: u32 = @intCast(-ret);
    // Handle error
}
```
""",

    "printf": """
## Printf Implementation

Location: src/user/lib/libc/stdio/printf.zig

### Format Specifiers
- %d, %i: signed decimal
- %u: unsigned decimal
- %x, %X: hexadecimal
- %s: string
- %c: character
- %p: pointer
- %%: literal %

### Width and Precision
- %10d: minimum width 10
- %.5s: max 5 chars from string
- %08x: zero-padded to 8 chars
- %-10s: left-aligned

### Implementation Notes
- Uses syscall.write(1, ...) for stdout
- Buffered output (flushes on newline or buffer full)
- No floating point support

### Usage
```zig
const printf = @import("libc").printf;
_ = printf("Value: %d, Hex: 0x%08x\\n", .{val, addr});
```
""",

    "string": """
## String Functions

Location: src/user/lib/libc/string/

### Available Functions
| Function | Purpose |
|----------|---------|
| strlen | String length |
| strcmp | Compare strings |
| strncmp | Compare n chars |
| strcpy | Copy string |
| strncpy | Copy n chars |
| strcat | Concatenate |
| strchr | Find char |
| strrchr | Find char (reverse) |
| memcpy | Copy memory |
| memmove | Copy (overlap safe) |
| memset | Fill memory |
| memcmp | Compare memory |

### Notes
- memcpy uses architecture-optimized version via HAL
- memmove handles overlapping regions
- Null terminators handled per C standard
""",

    "memory": """
## Memory Functions

Location: src/user/lib/libc/stdlib/

### Heap Allocation
```zig
const stdlib = @import("libc").stdlib;

const ptr = stdlib.malloc(size);
if (ptr == null) {
    // Handle OOM
}
defer stdlib.free(ptr);

// Reallocate
const new_ptr = stdlib.realloc(ptr, new_size);

// Zeroed allocation
const ptr = stdlib.calloc(count, size);
```

### Implementation
- Uses brk/sbrk syscalls for heap management
- Simple bump allocator (no coalescing yet)
- Thread-unsafe in current implementation

### mmap Usage
```zig
const addr = syscall.mmap(
    null,           // addr hint
    size,           // length
    PROT_READ | PROT_WRITE,
    MAP_PRIVATE | MAP_ANONYMOUS,
    -1,             // fd (not used for anon)
    0               // offset
);
```
""",

    "crt0": """
## C Runtime Startup (crt0)

Location: src/user/crt0.zig

### Entry Point
```zig
export fn _start() callconv(.c) noreturn {
    // Get argc, argv from stack (set by kernel)
    const argc: usize = @as(*usize, @ptrFromInt(stack_ptr)).*;
    const argv: [*][*:0]u8 = @ptrFromInt(stack_ptr + 8);

    // Call main
    const ret = main(argc, argv);

    // Exit
    syscall.exit(ret);
    unreachable;
}
```

### Stack Layout at Entry
```
+----------------+ <- RSP from kernel
| argc           | 8 bytes
+----------------+
| argv[0]        | pointer to first arg
| argv[1]        | ...
| NULL           | terminator
+----------------+
| envp[0]        | environment (future)
| ...            |
+----------------+
```

### Linking
- Compiled with -fPIE for ASLR support
- Entry point: _start (not main)
- main() called with (argc, argv)
""",

    "structure": """
## User Folder Structure

```
src/user/
├── crt0.zig              # C runtime startup
├── lib/
│   ├── syscall.zig       # Syscall wrappers + IoUring
│   └── libc/
│       ├── root.zig      # Libc exports
│       ├── errno.zig     # Error codes
│       ├── stdio/
│       │   ├── printf.zig
│       │   └── fprintf.zig
│       ├── stdlib/
│       │   ├── malloc.zig
│       │   └── atoi.zig
│       ├── string/
│       │   ├── strlen.zig
│       │   └── memcpy.zig
│       └── stubs.zig     # Unimplemented functions
├── programs/
│   ├── shell.zig         # Interactive shell
│   ├── httpd.zig         # HTTP server
│   ├── init.zig          # First userspace process
│   └── ...
└── drivers/
    ├── virtio_net/       # Userspace network driver
    ├── ps2/              # Userspace input driver
    └── uart/             # Userspace serial driver
```

### Build Integration
- User programs built by build.zig
- Linked with crt0.zig
- Embedded in initrd.tar
""",

    "file": """
## File I/O Wrappers

Location: src/user/lib/syscall.zig

### open
```zig
pub fn open(path: [*:0]const u8, flags: i32, mode: u32) i32 {
    return @bitCast(@as(u32, @truncate(syscall3(
        SYS.open,
        @intFromPtr(path),
        @bitCast(@as(u32, @intCast(flags))),
        mode,
    ))));
}
```

### read
```zig
pub fn read(fd: i32, buf: [*]u8, count: usize) isize {
    return @bitCast(syscall3(
        SYS.read,
        @bitCast(@as(u32, @intCast(fd))),
        @intFromPtr(buf),
        count,
    ));
}
```

### write
```zig
pub fn write(fd: i32, buf: [*]const u8, count: usize) isize {
    return @bitCast(syscall3(
        SYS.write,
        @bitCast(@as(u32, @intCast(fd))),
        @intFromPtr(buf),
        count,
    ));
}
```

### close
```zig
pub fn close(fd: i32) i32 {
    return @bitCast(@as(u32, @truncate(syscall1(
        SYS.close,
        @bitCast(@as(u32, @intCast(fd))),
    ))));
}
```

### lseek
```zig
pub fn lseek(fd: i32, offset: i64, whence: i32) i64 {
    return @bitCast(syscall3(
        SYS.lseek,
        @bitCast(@as(u32, @intCast(fd))),
        @bitCast(@as(u64, @intCast(offset))),
        @bitCast(@as(u32, @intCast(whence))),
    ));
}
```

### File Flags
```zig
pub const O_RDONLY = 0;
pub const O_WRONLY = 1;
pub const O_RDWR = 2;
pub const O_CREAT = 0o100;
pub const O_TRUNC = 0o1000;
pub const O_APPEND = 0o2000;
```
""",

    "net": """
## Network Socket Wrappers

Location: src/user/lib/syscall.zig

### socket
```zig
pub fn socket(domain: i32, sock_type: i32, protocol: i32) i32 {
    return @bitCast(@as(u32, @truncate(syscall3(
        SYS.socket,
        @bitCast(@as(u32, @intCast(domain))),
        @bitCast(@as(u32, @intCast(sock_type))),
        @bitCast(@as(u32, @intCast(protocol))),
    ))));
}
```

### bind
```zig
pub fn bind(fd: i32, addr: *const sockaddr, len: u32) i32 {
    return @bitCast(@as(u32, @truncate(syscall3(
        SYS.bind,
        @bitCast(@as(u32, @intCast(fd))),
        @intFromPtr(addr),
        len,
    ))));
}
```

### listen
```zig
pub fn listen(fd: i32, backlog: i32) i32 {
    return @bitCast(@as(u32, @truncate(syscall2(
        SYS.listen,
        @bitCast(@as(u32, @intCast(fd))),
        @bitCast(@as(u32, @intCast(backlog))),
    ))));
}
```

### accept
```zig
pub fn accept(fd: i32, addr: ?*sockaddr, len: ?*u32) i32 {
    return @bitCast(@as(u32, @truncate(syscall3(
        SYS.accept,
        @bitCast(@as(u32, @intCast(fd))),
        if (addr) |a| @intFromPtr(a) else 0,
        if (len) |l| @intFromPtr(l) else 0,
    ))));
}
```

### connect
```zig
pub fn connect(fd: i32, addr: *const sockaddr, len: u32) i32 {
    return @bitCast(@as(u32, @truncate(syscall3(
        SYS.connect,
        @bitCast(@as(u32, @intCast(fd))),
        @intFromPtr(addr),
        len,
    ))));
}
```

### sendto / recvfrom
```zig
pub fn sendto(fd: i32, buf: [*]const u8, len: usize, flags: i32,
              dest: ?*const sockaddr, addrlen: u32) isize;

pub fn recvfrom(fd: i32, buf: [*]u8, len: usize, flags: i32,
                src: ?*sockaddr, addrlen: ?*u32) isize;
```

### Socket Constants
```zig
pub const AF_INET = 2;
pub const AF_INET6 = 10;
pub const SOCK_STREAM = 1;  // TCP
pub const SOCK_DGRAM = 2;   // UDP
pub const SOCK_RAW = 3;     // Raw

pub const IPPROTO_TCP = 6;
pub const IPPROTO_UDP = 17;
pub const IPPROTO_ICMP = 1;
```

### sockaddr_in
```zig
pub const sockaddr_in = extern struct {
    family: u16 = AF_INET,
    port: u16,      // Network byte order (big-endian)
    addr: u32,      // Network byte order
    zero: [8]u8 = .{0} ** 8,
};
```
""",
}

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    query = sys.argv[1].lower()

    # Special handling for errno - parse from source
    if query == "errno":
        print("## Error Codes (SyscallError)\n")
        print("Location: src/uapi/errno.zig\n")
        codes = get_errno_codes()
        if codes:
            print("| Error | Description |")
            print("|-------|-------------|")
            descriptions = {
                "EPERM": "Operation not permitted",
                "ENOENT": "No such file or directory",
                "ESRCH": "No such process",
                "EINTR": "Interrupted system call",
                "EIO": "I/O error",
                "ENXIO": "No such device or address",
                "EBADF": "Bad file descriptor",
                "ECHILD": "No child processes",
                "EAGAIN": "Try again / Would block",
                "ENOMEM": "Out of memory",
                "EACCES": "Permission denied",
                "EFAULT": "Bad address",
                "EBUSY": "Device or resource busy",
                "EEXIST": "File exists",
                "ENODEV": "No such device",
                "ENOTDIR": "Not a directory",
                "EISDIR": "Is a directory",
                "EINVAL": "Invalid argument",
                "ENFILE": "File table overflow",
                "EMFILE": "Too many open files",
                "ENOTTY": "Not a typewriter",
                "EFBIG": "File too large",
                "ENOSPC": "No space left on device",
                "ESPIPE": "Illegal seek",
                "EROFS": "Read-only file system",
                "EPIPE": "Broken pipe",
                "ENOSYS": "Function not implemented",
                "ENOTSOCK": "Not a socket",
                "EADDRINUSE": "Address already in use",
                "EADDRNOTAVAIL": "Address not available",
                "ENETUNREACH": "Network unreachable",
                "ECONNRESET": "Connection reset",
                "ECONNREFUSED": "Connection refused",
                "ETIMEDOUT": "Connection timed out",
                "ENOTCONN": "Not connected",
                "EALREADY": "Already in progress",
                "EINPROGRESS": "Operation in progress",
            }
            for code in codes:
                desc = descriptions.get(code, "")
                print(f"| {code} | {desc} |")
        else:
            print("Could not parse errno.zig")
        return

    if query in PATTERNS:
        print(PATTERNS[query])
    else:
        matches = [k for k in PATTERNS.keys() if query in k]
        if matches:
            for m in matches:
                print(PATTERNS[m])
        else:
            print(f"Unknown topic: {query}")
            print(f"Available: errno, {', '.join(PATTERNS.keys())}")
            sys.exit(1)

if __name__ == "__main__":
    main()

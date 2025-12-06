# Syscall Interface Contract

**Feature Branch**: `003-microkernel-userland-networking`
**Created**: 2025-12-04

## Overview

This document defines the syscall interface between userland and kernel. All syscalls use the SYSCALL/SYSRET mechanism with the x86_64 System V ABI register conventions.

---

## Syscall Convention

### Register Usage

| Register | Purpose | Direction |
|----------|---------|-----------|
| RAX | Syscall number | In |
| RDI | Argument 0 | In |
| RSI | Argument 1 | In |
| RDX | Argument 2 | In |
| R10 | Argument 3 | In |
| R8 | Argument 4 | In |
| R9 | Argument 5 | In |
| RAX | Return value | Out |
| RCX | Clobbered (return address) | - |
| R11 | Clobbered (saved RFLAGS) | - |

### Return Values

- Success: Non-negative value (syscall-specific meaning)
- Error: Negative value (negated error code)

### Error Codes

| Code | Name | Description |
|------|------|-------------|
| -1 | EPERM | Operation not permitted |
| -2 | ENOENT | No such file or directory |
| -9 | EBADF | Bad file descriptor |
| -11 | EAGAIN | Try again |
| -12 | ENOMEM | Out of memory |
| -14 | EFAULT | Bad address |
| -17 | EEXIST | Already exists |
| -19 | ENODEV | No such device |
| -22 | EINVAL | Invalid argument |
| -24 | EMFILE | Too many open files |
| -38 | ENOSYS | Function not implemented |

---

## Syscall Definitions

### SYS_EXIT (0)

Terminate the calling thread.

**Signature**:
```zig
fn sys_exit(status: i32) noreturn
```

**Arguments**:
- `rdi`: Exit status code

**Returns**: Does not return

**Errors**: None

---

### SYS_WRITE (1)

Write to a file descriptor.

**Signature**:
```zig
fn sys_write(fd: u32, buf: [*]const u8, count: usize) isize
```

**Arguments**:
- `rdi`: File descriptor (0=stdin, 1=stdout, 2=stderr)
- `rsi`: Pointer to buffer
- `rdx`: Number of bytes to write

**Returns**: Number of bytes written, or negative error

**Errors**:
- EBADF: Invalid file descriptor
- EFAULT: Buffer address invalid
- EINVAL: Count is negative

**Validation**:
- Buffer must be in user address space
- Buffer + count must not overflow
- FD must be valid (0, 1, or 2 for MVP)

---

### SYS_READ (2)

Read from a file descriptor.

**Signature**:
```zig
fn sys_read(fd: u32, buf: [*]u8, count: usize) isize
```

**Arguments**:
- `rdi`: File descriptor (0=stdin for keyboard)
- `rsi`: Pointer to buffer
- `rdx`: Maximum bytes to read

**Returns**: Number of bytes read, or negative error

**Errors**:
- EBADF: Invalid file descriptor
- EFAULT: Buffer address invalid
- EAGAIN: No data available (non-blocking)

**Behavior**:
- FD 0 (stdin): Reads from keyboard buffer
- Blocks until at least one character available

---

### SYS_GETCHAR (3)

Read a single character from keyboard.

**Signature**:
```zig
fn sys_getchar() i32
```

**Arguments**: None

**Returns**: ASCII code of character, or negative error

**Errors**:
- EAGAIN: No character available

**Behavior**:
- Non-blocking
- Returns -EAGAIN if buffer empty

---

### SYS_PUTCHAR (4)

Write a single character to display.

**Signature**:
```zig
fn sys_putchar(c: u8) i32
```

**Arguments**:
- `rdi`: Character to output

**Returns**: 0 on success, or negative error

**Errors**: None (always succeeds for MVP)

**Behavior**:
- Writes to framebuffer console
- Handles special characters (newline, backspace)

---

### SYS_YIELD (5)

Voluntarily yield the CPU to another thread.

**Signature**:
```zig
fn sys_yield() i32
```

**Arguments**: None

**Returns**: 0 on success

**Errors**: None

**Behavior**:
- Current thread moves to end of ready queue
- Scheduler runs next ready thread

---

### SYS_SLEEP (6)

Sleep for specified milliseconds.

**Signature**:
```zig
fn sys_sleep(ms: u32) i32
```

**Arguments**:
- `rdi`: Milliseconds to sleep

**Returns**: 0 on success

**Errors**: None

**Behavior**:
- Thread moves to blocked state
- Timer interrupt wakes thread after delay

---

### SYS_GETPID (7)

Get current thread ID.

**Signature**:
```zig
fn sys_getpid() u32
```

**Arguments**: None

**Returns**: Thread ID (always positive)

**Errors**: None

---

### SYS_SEND_UDP (10)

Send a UDP packet.

**Signature**:
```zig
fn sys_send_udp(dest_ip: u32, dest_port: u16, src_port: u16, data: [*]const u8, len: usize) isize
```

**Arguments**:
- `rdi`: Destination IP (network byte order)
- `rsi`: Destination port (network byte order)
- `rdx`: Source port (network byte order)
- `r10`: Pointer to data buffer
- `r8`: Data length

**Returns**: Number of bytes sent, or negative error

**Errors**:
- EFAULT: Data buffer invalid
- EINVAL: Invalid port or length
- ENOMEM: No TX descriptors available
- EAGAIN: ARP resolution pending

**Behavior**:
- Triggers ARP if MAC unknown
- Returns -EAGAIN if waiting for ARP reply

---

### SYS_RECV_UDP (11)

Receive a UDP packet (non-blocking).

**Signature**:
```zig
fn sys_recv_udp(port: u16, buf: [*]u8, max_len: usize, src_ip: *u32, src_port: *u16) isize
```

**Arguments**:
- `rdi`: Local port to receive on
- `rsi`: Pointer to receive buffer
- `rdx`: Maximum bytes to receive
- `r10`: Pointer to store source IP
- `r8`: Pointer to store source port

**Returns**: Number of bytes received, or negative error

**Errors**:
- EFAULT: Buffer address invalid
- EINVAL: Invalid port
- EAGAIN: No packet available

---

### SYS_OPEN (20)

Open a file from InitRD.

**Signature**:
```zig
fn sys_open(path: [*:0]const u8, flags: u32) i32
```

**Arguments**:
- `rdi`: Pointer to null-terminated path string
- `rsi`: Open flags (O_RDONLY = 0)

**Returns**: File descriptor (3-15), or negative error

**Errors**:
- ENOENT: File not found in InitRD
- EFAULT: Path pointer invalid
- EINVAL: Invalid flags (only O_RDONLY supported)
- EMFILE: Too many open files (max 16)

**Behavior**:
- Searches InitRD file table for matching name
- Allocates FD from thread's FD table
- Sets initial read position to 0

---

### SYS_CLOSE (21)

Close a file descriptor.

**Signature**:
```zig
fn sys_close(fd: u32) i32
```

**Arguments**:
- `rdi`: File descriptor to close

**Returns**: 0 on success, or negative error

**Errors**:
- EBADF: Invalid file descriptor

**Behavior**:
- Marks FD slot as available
- FD 0, 1, 2 cannot be closed (returns EBADF)

---

### SYS_FILE_READ (22)

Read from an open file descriptor.

**Signature**:
```zig
fn sys_file_read(fd: u32, buf: [*]u8, count: usize) isize
```

**Arguments**:
- `rdi`: File descriptor
- `rsi`: Buffer to read into
- `rdx`: Maximum bytes to read

**Returns**: Bytes read (may be less than count at EOF), or negative error

**Errors**:
- EBADF: Invalid file descriptor
- EFAULT: Buffer address invalid

**Behavior**:
- Reads from current position
- Advances position by bytes read
- Returns 0 at EOF

---

### SYS_SEEK (23)

Seek to position in file.

**Signature**:
```zig
fn sys_seek(fd: u32, offset: i64, whence: u32) i64
```

**Arguments**:
- `rdi`: File descriptor
- `rsi`: Offset (signed)
- `rdx`: Whence (0=SEEK_SET, 1=SEEK_CUR, 2=SEEK_END)

**Returns**: New position, or negative error

**Errors**:
- EBADF: Invalid file descriptor
- EINVAL: Invalid whence or resulting position < 0

**Behavior**:
- SEEK_SET: position = offset
- SEEK_CUR: position += offset
- SEEK_END: position = file_size + offset

---

### SYS_SBRK (30)

Extend the userland heap.

**Signature**:
```zig
fn sys_sbrk(increment: isize) isize
```

**Arguments**:
- `rdi`: Number of bytes to extend (or 0 to query)

**Returns**: Previous program break address, or -ENOMEM

**Errors**:
- ENOMEM: Cannot allocate more memory
- EINVAL: Negative increment would reduce break below base

**Behavior**:
- If increment == 0: returns current break without modification
- If increment > 0: extends heap, maps new pages if needed
- New pages are zeroed and have user+write permissions
- Break is rounded up to page boundary

---

### SYS_GET_FB_INFO (40)

Get framebuffer information.

**Signature**:
```zig
fn sys_get_fb_info(info: *FramebufferInfo) i32
```

**Arguments**:
- `rdi`: Pointer to FramebufferInfo struct to fill

**Returns**: 0 on success, or negative error

**Errors**:
- EFAULT: Info pointer invalid
- ENODEV: No framebuffer available

**FramebufferInfo struct**:
```zig
const FramebufferInfo = extern struct {
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u16,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
};
```

---

### SYS_MMAP_FB (41)

Map framebuffer into userland address space.

**Signature**:
```zig
fn sys_mmap_fb() isize
```

**Arguments**: None

**Returns**: Virtual address of mapped framebuffer, or negative error

**Errors**:
- ENOMEM: Cannot allocate virtual address range
- ENODEV: No framebuffer available
- EEXIST: Framebuffer already mapped for this thread

**Behavior**:
- Maps framebuffer physical pages into user address space
- Pages have user+write+write-through flags
- Address is stable for lifetime of thread
- Only framebuffer region can be mapped (security)

---

### SYS_READ_SCANCODE (50)

Read raw keyboard scancode.

**Signature**:
```zig
fn sys_read_scancode() i32
```

**Arguments**: None

**Returns**: Scancode (0x00-0xFF), or negative error

**Errors**:
- EAGAIN: No scancode available (non-blocking)

**Behavior**:
- Non-blocking: returns immediately
- Returns make codes (key down) and break codes (key up)
- Break codes are typically scancode | 0x80
- Separate from ASCII character buffer

---

## Syscall Number Summary

| Number | Name | Description |
|--------|------|-------------|
| 0 | SYS_EXIT | Terminate thread |
| 1 | SYS_WRITE | Write to FD |
| 2 | SYS_READ_CHAR | Read ASCII character (blocking) |
| 3 | SYS_YIELD | Yield CPU |
| 4 | SYS_GETPID | Get thread ID |
| 5 | SYS_SLEEP | Sleep for ms |
| 6 | SYS_SEND_UDP | Send UDP packet |
| 7 | SYS_RECV_UDP | Receive UDP packet |
| 8 | SYS_GET_TIME | Get system ticks |
| 9 | SYS_READ_SCANCODE | Read raw scancode |
| 10 | SYS_GET_FB_INFO | Get framebuffer info |
| 11 | SYS_MAP_FB | Map framebuffer |
| 12 | SYS_MMAP | Map memory (anonymous/framebuffer) |
| 13 | SYS_OPEN | Open InitRD file |
| 14 | SYS_CLOSE | Close file descriptor |
| 15 | SYS_READ | Read from file |
| 16 | SYS_SEEK | Seek in file |
| 17 | SYS_SBRK | Extend heap |

**Byte Order Note**: All multi-byte syscall parameters use host byte order (Little Endian). The kernel converts to network byte order (Big Endian) internally for network operations (SYS_SEND_UDP, SYS_RECV_UDP).

---

## Security Considerations

### Big Kernel Lock (MVP TOCTOU Prevention)

**CRITICAL**: All syscalls run with interrupts disabled to prevent TOCTOU race conditions.

```zig
export fn syscall_entry() callconv(.Naked) noreturn {
    asm volatile (
        \\ cli                    # Disable interrupts FIRST
        \\ swapgs
        \\ mov rsp, [gs:0]        # Load kernel stack
        \\ ...
    );
}

fn syscall_exit() void {
    asm volatile (
        \\ swapgs
        \\ sti                    # Re-enable interrupts LAST
        \\ sysretq
    );
}
```

**Rationale**: With 2 threads (network + shell), checking a user pointer and then accessing it creates a race if another thread modifies page tables. The Big Kernel Lock (CLI/STI) is acceptable for MVP; fine-grained locking deferred.

### Pointer Validation (Principle VIII)

All pointer arguments MUST be validated before use, **with interrupts already disabled**:

```zig
fn validate_user_ptr(addr: u64, len: u64) bool {
    // Interrupts must be disabled (Big Kernel Lock)
    assert(!interrupts_enabled());

    // Must be in user space (below kernel base)
    if (addr >= KERNEL_BASE) return false;
    // Must not overflow
    if (addr + len < addr) return false;
    if (addr + len > KERNEL_BASE) return false;
    // Must be mapped in user page tables
    return is_mapped_user(addr, len);
}
```

### Capability Checks

- File descriptors validated against thread's FD table
- Network operations check for network capability
- All syscalls log to audit trail (optional for MVP)

---

## Userland Library

Minimal syscall wrapper for user programs:

```zig
// lib/syscall.zig
pub fn syscall0(num: u64) isize {
    return @bitCast(asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (num),
        : "rcx", "r11", "memory"
    ));
}

pub fn syscall1(num: u64, a0: u64) isize {
    return @bitCast(asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (num),
          [a0] "{rdi}" (a0),
        : "rcx", "r11", "memory"
    ));
}

// ... syscall2 through syscall6

pub fn exit(status: i32) noreturn {
    _ = syscall1(0, @bitCast(@as(i64, status)));
    unreachable;
}

pub fn write(fd: u32, buf: []const u8) isize {
    return syscall3(1, fd, @intFromPtr(buf.ptr), buf.len);
}

pub fn read(fd: u32, buf: []u8) isize {
    return syscall3(2, fd, @intFromPtr(buf.ptr), buf.len);
}

pub fn getchar() i32 {
    return @truncate(syscall0(3));
}

pub fn putchar(c: u8) void {
    _ = syscall1(4, c);
}

pub fn yield() void {
    _ = syscall0(5);
}

// File operations (InitRD)
pub fn open(path: [*:0]const u8, flags: u32) i32 {
    return @truncate(syscall2(20, @intFromPtr(path), flags));
}

pub fn close(fd: u32) i32 {
    return @truncate(syscall1(21, fd));
}

pub fn file_read(fd: u32, buf: []u8) isize {
    return syscall3(22, fd, @intFromPtr(buf.ptr), buf.len);
}

pub fn seek(fd: u32, offset: i64, whence: u32) i64 {
    return @bitCast(syscall3(23, fd, @bitCast(offset), whence));
}

// Dynamic heap
pub fn sbrk(increment: isize) isize {
    return syscall1(30, @bitCast(increment));
}

// Framebuffer
pub fn get_fb_info(info: *FramebufferInfo) i32 {
    return @truncate(syscall1(40, @intFromPtr(info)));
}

pub fn mmap_fb() isize {
    return syscall0(41);
}

// Raw keyboard
pub fn read_scancode() i32 {
    return @truncate(syscall0(50));
}
```

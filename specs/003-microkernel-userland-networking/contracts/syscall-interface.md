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

### sys_exit (60)

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

### sys_write (1)

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

### sys_read (0)

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

### sys_getchar (1004)

Read a single character from keyboard. (ZigK convenience extension)

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

### sys_putchar (1005)

Write a single character to display. (ZigK convenience extension)

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

### sys_sched_yield (24)

Voluntarily yield the CPU to another thread.

**Signature**:
```zig
fn sys_sched_yield() i32
```

**Arguments**: None

**Returns**: 0 on success

**Errors**: None

**Behavior**:
- Current thread moves to end of ready queue
- Scheduler runs next ready thread

---

### sys_nanosleep (35)

Sleep for specified duration.

**Signature**:
```zig
fn sys_nanosleep(req: *const Timespec, rem: ?*Timespec) i32
```

**Arguments**:
- `rdi`: Pointer to Timespec struct with requested sleep duration
- `rsi`: Optional pointer to Timespec for remaining time (if interrupted)

**Returns**: 0 on success, -EINTR if interrupted

**Errors**:
- EFAULT: Invalid pointer
- EINTR: Sleep interrupted by signal

**Behavior**:
- Thread moves to blocked state
- Timer interrupt wakes thread after delay
- If interrupted, remaining time written to rem (if non-null)

---

### sys_getpid (39)

Get current process/thread ID.

**Signature**:
```zig
fn sys_getpid() u32
```

**Arguments**: None

**Returns**: Thread ID (always positive)

**Errors**: None

---

### sys_sendto (44)

Send a message on a socket (UDP).

**Signature**:
```zig
fn sys_sendto(fd: i32, buf: [*]const u8, len: usize, flags: i32, dest_addr: *const sockaddr, addrlen: u32) isize
```

**Arguments**:
- `rdi`: Socket file descriptor
- `rsi`: Pointer to data buffer
- `rdx`: Data length
- `r10`: Flags (0 for default)
- `r8`: Pointer to sockaddr_in with destination IP/port
- `r9`: Size of sockaddr structure

**Returns**: Number of bytes sent, or negative error

**Errors**:
- EBADF: Invalid socket file descriptor
- EFAULT: Data buffer or address invalid
- EINVAL: Invalid flags or address length
- ENOMEM: No TX descriptors available
- EAGAIN: ARP resolution pending

**Behavior**:
- Triggers ARP if destination MAC unknown
- Returns -EAGAIN if waiting for ARP reply
- Uses sockaddr_in for IPv4 addresses

---

### sys_recvfrom (45)

Receive a message from a socket (UDP).

**Signature**:
```zig
fn sys_recvfrom(fd: i32, buf: [*]u8, len: usize, flags: i32, src_addr: ?*sockaddr, addrlen: ?*u32) isize
```

**Arguments**:
- `rdi`: Socket file descriptor
- `rsi`: Pointer to receive buffer
- `rdx`: Maximum bytes to receive
- `r10`: Flags (0 for default, MSG_DONTWAIT for non-blocking)
- `r8`: Optional pointer to store source address
- `r9`: Optional pointer to address length (in/out)

**Returns**: Number of bytes received, or negative error

**Errors**:
- EBADF: Invalid socket file descriptor
- EFAULT: Buffer or address invalid
- EINVAL: Invalid flags
- EAGAIN: No packet available (non-blocking mode)

---

### sys_open (2)

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

### sys_close (3)

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

### sys_read for files (0)

Read from an open file descriptor. (Uses sys_read - same syscall number as stdin read)

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

### sys_lseek (8)

Seek to position in file.

**Signature**:
```zig
fn sys_lseek(fd: u32, offset: i64, whence: u32) i64
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

### sys_brk (12)

Change the program break (heap end).

**Signature**:
```zig
fn sys_brk(brk: usize) isize
```

**Arguments**:
- `rdi`: New program break address (or 0 to query current break)

**Returns**: Current program break address on success, or unchanged break on error

**Errors**:
- ENOMEM: Cannot allocate more memory (returns current break, not -ENOMEM)

**Behavior**:
- If brk == 0: returns current break without modification
- If brk > current: extends heap, maps new pages if needed
- If brk < current: shrinks heap (unimplemented in MVP, returns current break)
- New pages are zeroed and have user+write permissions
- Break is rounded up to page boundary

---

### sys_get_fb_info (1001)

Get framebuffer information. (ZigK custom extension)

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

### sys_map_fb (1002)

Map framebuffer into userland address space. (ZigK custom extension)

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

### sys_read_scancode (1003)

Read raw keyboard scancode. (ZigK custom extension)

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

### Linux x86_64 ABI Syscalls

| Number | Name | Description |
|--------|------|-------------|
| 0 | sys_read | Read from file descriptor |
| 1 | sys_write | Write to file descriptor |
| 2 | sys_open | Open file from InitRD |
| 3 | sys_close | Close file descriptor |
| 8 | sys_lseek | Seek in file |
| 12 | sys_brk | Change program break (heap) |
| 24 | sys_sched_yield | Yield CPU timeslice |
| 35 | sys_nanosleep | Sleep for duration |
| 39 | sys_getpid | Get process/thread ID |
| 44 | sys_sendto | Send UDP message |
| 45 | sys_recvfrom | Receive UDP message |
| 60 | sys_exit | Terminate thread |

### ZigK Custom Extensions (1000+)

| Number | Name | Description |
|--------|------|-------------|
| 1001 | sys_get_fb_info | Get framebuffer info |
| 1002 | sys_map_fb | Map framebuffer to userspace |
| 1003 | sys_read_scancode | Read raw keyboard scancode |
| 1004 | sys_getchar | Read single ASCII char (convenience) |
| 1005 | sys_putchar | Write single char (convenience) |

**Byte Order Note**: All multi-byte syscall parameters use host byte order (Little Endian). The kernel converts to network byte order (Big Endian) internally for network operations (sys_sendto, sys_recvfrom).

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

// Linux ABI syscalls
pub fn exit(status: i32) noreturn {
    _ = syscall1(60, @bitCast(@as(i64, status)));
    unreachable;
}

pub fn write(fd: u32, buf: []const u8) isize {
    return syscall3(1, fd, @intFromPtr(buf.ptr), buf.len);
}

pub fn read(fd: u32, buf: []u8) isize {
    return syscall3(0, fd, @intFromPtr(buf.ptr), buf.len);
}

pub fn sched_yield() void {
    _ = syscall0(24);
}

pub fn getpid() u32 {
    return @truncate(syscall0(39));
}

// File operations (InitRD)
pub fn open(path: [*:0]const u8, flags: u32) i32 {
    return @truncate(syscall2(2, @intFromPtr(path), flags));
}

pub fn close(fd: u32) i32 {
    return @truncate(syscall1(3, fd));
}

pub fn lseek(fd: u32, offset: i64, whence: u32) i64 {
    return @bitCast(syscall3(8, fd, @bitCast(offset), whence));
}

// Dynamic heap
pub fn brk(addr: usize) usize {
    return @bitCast(syscall1(12, addr));
}

// ZigK custom extensions (1000+)
pub fn get_fb_info(info: *FramebufferInfo) i32 {
    return @truncate(syscall1(1001, @intFromPtr(info)));
}

pub fn map_fb() isize {
    return syscall0(1002);
}

pub fn read_scancode() i32 {
    return @truncate(syscall0(1003));
}

pub fn getchar() i32 {
    return @truncate(syscall0(1004));
}

pub fn putchar(c: u8) void {
    _ = syscall1(1005, c);
}
```

#!/usr/bin/env python3
"""
Kernel Rules Query Tool for zk kernel.

Query kernel development rules and required patterns.

Usage:
    python rules_query.py hal           # HAL barrier rules
    python rules_query.py handler       # Syscall handler pattern
    python rules_query.py memory        # Memory safety rules
    python rules_query.py user_ptr      # User pointer validation
    python rules_query.py error         # Error handling pattern
    python rules_query.py asm           # Inline assembly (Zig 0.16.x)
    python rules_query.py thread        # Threading ABI pattern
    python rules_query.py lock          # Lock ordering
    python rules_query.py all           # All rules summary
"""

import sys

RULES = {
    "hal": """
## HAL Barrier Rule (STRICT)

**Forbidden outside src/arch/:**
- asm volatile (inline assembly)
- Direct port I/O: outb, inb, outw, inw
- CPU register access: CR0-4, MSRs
- Direct MMIO reads/writes

**Required pattern:**
```zig
const hal = @import("hal");

hal.io.outB(port, data);         // Port I/O
const val = hal.io.inB(port);

hal.cpu.writeCr3(pml4);          // CR access

const regs = hal.mmio_device.MmioDevice(Regs).init(addr, size);
regs.write(.CTRL, val);          // Type-safe MMIO
```

**Assembly goes in:** src/arch/x86_64/asm_helpers.S

**HAL modules:** io, cpu, serial, mem, paging, gdt, idt, pic, apic,
                 interrupts, fpu, entropy, syscall_arch, mmio, mmio_device,
                 pit, timing, smp
""",

    "handler": """
## Syscall Handler Pattern

**Correct (use this):**
```zig
const SyscallError = uapi.errno.SyscallError;

pub fn sys_read(fd: usize, buf_ptr: usize, count: usize) SyscallError!usize {
    // 1. Validate user pointers FIRST
    if (!user_mem.isValidUserPtr(buf_ptr, count)) {
        return error.EFAULT;
    }

    // 2. Get resources
    const file = base.getGlobalFdTable().get(fd) orelse return error.EBADF;

    // 3. Perform operation (propagate with try)
    const result = try file.read(buf);

    // 4. Return success value
    return result;
}
```

**Forbidden (legacy):**
```zig
pub fn sys_read(...) isize {           // Don't use isize
    return Errno.EFAULT.toReturn();     // Don't manually convert
}
```

**Exception:** Non-returning handlers (sys_exit) may use isize.

**Handler file locations:** src/kernel/sys/syscall/
- core/: base.zig, table.zig, execution.zig, error_helpers.zig, user_mem.zig
- fs/: fd.zig, fs_handlers.zig
- memory/: memory.zig
- process/: process.zig, signals.zig, scheduling.zig
- net/: net.zig, pci_syscall.zig
- hw/: interrupt.zig, mmio.zig, port_io.zig
- io/: input.zig, ipc.zig, ring.zig
- io_uring/: io_uring.zig
- misc/: random.zig, custom.zig
""",

    "memory": """
## Memory Safety Rules

**Zig 0.16.x specifics:**
- No `undefined` without immediate initialization
- Use wrapping operators (+%, -%, *%) for intentional overflow
- Prefer stack arrays with slices over heap allocation
- Use `try` for error propagation, avoid `catch unreachable`

**Stack vs Heap:**
```zig
// Stack (preferred for small, known-size)
var buf: [4096]u8 = undefined;

// Heap (for large or dynamic)
const buf = try allocator.alloc(u8, size);
defer allocator.free(buf);
```

**Integer overflow gotchas:**
```zig
// WRONG - BAR sizing with 64-bit contamination
const size = ~bar_read + 1;

// CORRECT - mask to expected width
const size = (~bar_read +% 1) & 0xFFFFFFFF;

// WRONG - u3 loop counter overflows at 8
for (func: u3 = 0; func < 8; func += 1) {}

// CORRECT - use u4
for (func: u4 = 0; func < 8; func += 1) {}
```

**Boot-time stack limit:** ~4-16KB. Allocate large structs on heap.
""",

    "user_ptr": """
## User Pointer Validation

**Always validate before use:**
```zig
const user_mem = @import("user_mem");

// Basic check
if (!user_mem.isValidUserPtr(ptr, size)) {
    return error.EFAULT;
}

// With access mode
if (!user_mem.isValidUserAccess(ptr, size, .Write)) {
    return error.EFAULT;
}
```

**Safe copy operations:**
```zig
// From user to kernel
user_mem.copyFromUser(kernel_buf, user_ptr, len) catch return error.EFAULT;

// From kernel to user
user_mem.copyToUser(user_ptr, kernel_buf, len) catch return error.EFAULT;
```

**User space boundaries:**
- Valid: 0x0000_0000_0040_0000 to 0x0000_7FFF_FFFF_FFFF
- MAX_PATH_LEN: 4096

**AccessMode enum:** .Read, .Write, .Execute
""",

    "error": """
## Error Handling Pattern

**Common SyscallError values:**
| Error | When to use |
|-------|-------------|
| error.EBADF | Bad file descriptor |
| error.EFAULT | Invalid user pointer |
| error.EINVAL | Invalid argument |
| error.ENOSYS | Not implemented |
| error.ENOMEM | Out of memory |
| error.EAGAIN | Try again (non-blocking) |
| error.EADDRINUSE | Address in use (net) |
| error.ECONNREFUSED | Connection refused |

**Subsystem error conversion:**
```zig
fn socketErrorToSyscallError(err: socket.SocketError) SyscallError {
    return switch (err) {
        .AddrInUse => error.EADDRINUSE,
        .WouldBlock => error.EAGAIN,
        .ConnectionRefused => error.ECONNREFUSED,
        else => error.EIO,
    };
}
```

**Dispatch layer:** Automatically converts SyscallError!usize to -errno.
""",

    "asm": """
## Inline Assembly (Zig 0.16.x)

**Clobber syntax:**
```zig
// Memory barrier
asm volatile ("cli"
    :
    :
    : .{ .memory = true }
);

// Register constraints
asm volatile ("out %[data], %[port]"
    :
    : [port] "{dx}" (port),
      [data] "{al}" (data),
);

// Output with input
asm volatile ("in %[port], %[result]"
    : [result] "={al}" (-> u8)
    : [port] "{dx}" (port),
);
```

**Common constraints:**
- "{rax}", "{rdi}", "{dx}" - specific registers
- "=m" - memory output
- "r" - any general register
- .{ .memory = true } - memory barrier

**When to use assembly file (asm_helpers.S):**
- lgdt/lidt (indirect memory operands)
- Far jumps (CS reload)
- 16/32/64-bit mode transitions (trampoline)
- Complex sequences with labels
""",

    "thread": """
## Threading ABI Pattern

**Safe kernel thread entry:**
```zig
const Self = @This();

pub fn startThread(self: *Self) void {
    scheduler.createKernelThread(threadEntry, @ptrCast(self));
}

// Must be callconv(.c) for ABI compatibility
fn threadEntry(ctx: ?*anyopaque) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.runLoop();
}
```

**Why this pattern:**
- System V AMD64 ABI passes 1st arg in RDI
- createKernelThread sets up RDI with context
- Using Zig methods directly causes NULL self crashes

**DO NOT:**
```zig
// WRONG - Zig method as entry point
scheduler.createKernelThread(self.runLoop, null);

// WRONG - relying on closure capture
scheduler.createKernelThread(struct { fn run() void { self.x; } }.run, null);
```
""",

    "lock": """
## Lock Ordering

**Full lock ordering (lower number = acquired first):**
1.  `process_tree_lock`
2.  `SFS.alloc_lock` (Filesystem Allocation)
3.  `FileDescriptor.lock`
4.  `Scheduler/Runqueue Lock`
5.  `tcp_state.lock` (Global TCP state)
6.  `socket/state.lock` (Socket table)
7.  Per-socket `sock.lock` / Per-TCB `tcb.mutex`
8.  `UserVmm.lock` (must NOT hold during sleep)
8.5. `devices_lock` (USB global device array RwLock)
8.6. `UsbDevice.device_lock` (per-device Spinlock, IRQ-safe)
9.  `FutexBucket.lock` (per-bucket spinlock)
10. `pmm.lock` (internal PMM spinlock, not held across calls)

**Pattern:**
```zig
{
    const held = process_tree_lock.acquire();
    defer held.release();

    const fd_held = fd_table.lock.acquire();
    defer fd_held.release();

    // ... operate on resources
}
```

**UserVmm.lock special rule:**
- Read mode: address translation
- Write mode: munmap
- **NEVER** hold during sleep/block operations

**Spinlock usage:**
```zig
var lock = hal.SpinLock{};

lock.acquire();
defer lock.release();
// Critical section
```

**DO NOT hold locks across:**
- sched.block() calls
- Potentially blocking I/O
- User memory access (could page fault)
""",

    "all": """
## Kernel Development Rules Summary

1. **HAL Barrier:** No asm/port I/O outside src/arch/. Use hal module.

2. **Handler Pattern:** Return SyscallError!usize, validate user ptrs first.

3. **Memory Safety:** No undefined, use wrapping ops, mind stack limits.

4. **User Pointers:** Always validate with isValidUserPtr before use.

5. **Errors:** Use SyscallError enum, dispatch converts to -errno.

6. **Assembly:** Use .S file for lgdt/lidt/far jumps. Zig 0.16.x clobber syntax.

7. **Threading:** Use callconv(.c) entry with opaque context pointer.

8. **Locking:** process_tree_lock > process.lock > fd_table.lock

Run individual queries for detailed patterns:
  python rules_query.py hal
  python rules_query.py handler
  python rules_query.py memory
  python rules_query.py user_ptr
  python rules_query.py error
  python rules_query.py asm
  python rules_query.py thread
  python rules_query.py lock
""",
}

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    query = sys.argv[1].lower()

    if query in RULES:
        print(RULES[query])
    else:
        matches = [k for k in RULES.keys() if query in k]
        if matches:
            for m in matches:
                print(RULES[m])
        else:
            print(f"Unknown rule: {query}")
            print(f"Available: {', '.join(RULES.keys())}")
            sys.exit(1)

if __name__ == "__main__":
    main()

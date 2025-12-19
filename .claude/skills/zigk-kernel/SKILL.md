---
name: zigk-kernel
description: Provides queryable reference for zigk/zscapek kernel development. Run scripts to lookup syscalls, patterns, rules, drivers, async I/O, security, and libc. Use when implementing syscalls, drivers, or kernel features. Token-efficient - scripts return only needed info.
---

# Zigk Kernel Development

Queryable reference for the zscapek Zig kernel. Run scripts instead of loading docs.

## Query Scripts

Run these scripts to get targeted information without loading full docs:

| Script | Purpose | Example |
|--------|---------|---------|
| `scripts/syscall_query.py` | Syscall lookup | `python scripts/syscall_query.py read` |
| `scripts/rules_query.py` | Kernel rules | `python scripts/rules_query.py handler` |
| `scripts/driver_query.py` | Driver patterns | `python scripts/driver_query.py mmio` |
| `scripts/async_query.py` | Async I/O | `python scripts/async_query.py reactor` |
| `scripts/security_query.py` | Security | `python scripts/security_query.py spinlock` |
| `scripts/memory_query.py` | Memory layout | `python scripts/memory_query.py pte` |
| `scripts/libc_query.py` | Userspace/libc | `python scripts/libc_query.py errno` |

## Quick Reference (Always Available)

### Syscall Handler Template
```zig
pub fn sys_example(fd: usize, ptr: usize, len: usize) SyscallError!usize {
    if (!user_mem.isValidUserPtr(ptr, len)) return error.EFAULT;
    const file = base.getGlobalFdTable().get(fd) orelse return error.EBADF;
    return try file.read(buf);
}
```

### HAL Barrier
- **Forbidden outside src/arch/:** asm volatile, port I/O, direct register access
- **Required:** Use `hal.io`, `hal.cpu`, `hal.mmio_device.MmioDevice`

### Common Errors
EBADF (bad fd), EFAULT (bad ptr), EINVAL (bad arg), ENOSYS (unimplemented), ENOMEM, EAGAIN

## Query Examples

### Syscall Lookup
```bash
python scripts/syscall_query.py socket        # Find by name
python scripts/syscall_query.py 41            # Find by number
python scripts/syscall_query.py --category net    # List network syscalls
python scripts/syscall_query.py --handler io.zig  # List handler's syscalls
python scripts/syscall_query.py --zscapek         # Zscapek extensions (1000+)
```

### Rules Lookup
```bash
python scripts/rules_query.py hal       # HAL barrier rules
python scripts/rules_query.py handler   # Syscall handler pattern
python scripts/rules_query.py user_ptr  # User pointer validation
python scripts/rules_query.py asm       # Zig 0.16.x inline asm
python scripts/rules_query.py thread    # Threading ABI pattern
python scripts/rules_query.py lock      # Lock ordering
```

### Driver Lookup
```bash
python scripts/driver_query.py mmio         # MmioDevice pattern
python scripts/driver_query.py ring         # Ring IPC pattern
python scripts/driver_query.py capabilities # Userspace driver caps
python scripts/driver_query.py split        # Split-process pattern
python scripts/driver_query.py pci          # PCI enumeration
```

### Async Lookup
```bash
python scripts/async_query.py reactor   # Kernel reactor pattern
python scripts/async_query.py io_uring  # Userspace io_uring
python scripts/async_query.py ring      # Ring buffer details
python scripts/async_query.py timer     # Timer wheel
python scripts/async_query.py ahci      # AHCI async block I/O
```

### Security Lookup
```bash
python scripts/security_query.py spinlock   # Spinlock usage
python scripts/security_query.py canary     # Stack canary
python scripts/security_query.py aslr       # ASLR config
python scripts/security_query.py capability # Capability system
```

### Memory Layout Lookup
```bash
python scripts/memory_query.py virt      # Virtual memory map
python scripts/memory_query.py hhdm      # HHDM translation
python scripts/memory_query.py pte       # Page table entry format
python scripts/memory_query.py gdt       # GDT entry format (8 bytes)
python scripts/memory_query.py idt       # IDT entry format (16 bytes)
python scripts/memory_query.py fault     # Page fault error codes
python scripts/memory_query.py limine    # Boot mappings
```

### Libc/User Lookup
```bash
python scripts/libc_query.py errno     # Error codes
python scripts/libc_query.py syscall   # Userspace syscall wrapper
python scripts/libc_query.py file      # File I/O wrappers
python scripts/libc_query.py net       # Network socket wrappers
python scripts/libc_query.py structure # User folder layout
```

## Workflow: Adding a Feature

### New Syscall
1. Query existing: `python scripts/syscall_query.py --category <relevant>`
2. Query pattern: `python scripts/rules_query.py handler`
3. Add to `src/uapi/syscalls.zig`
4. Add handler to appropriate file in `src/kernel/syscall/`

### New Driver (Kernel)
1. Query pattern: `python scripts/driver_query.py mmio`
2. Query PCI: `python scripts/driver_query.py pci`
3. Create in `src/drivers/`
4. Use MmioDevice for register access

### New Driver (Userspace)
1. Query caps: `python scripts/driver_query.py capabilities`
2. Query split: `python scripts/driver_query.py split`
3. Query ring: `python scripts/driver_query.py ring`
4. Create in `src/user/drivers/`

### Network Feature
1. Query syscalls: `python scripts/syscall_query.py --category net`
2. Query async: `python scripts/async_query.py reactor`
3. Query ring: `python scripts/async_query.py ring`

## File Locations

| Component | Location |
|-----------|----------|
| Syscall numbers | src/uapi/syscalls.zig |
| Syscall handlers | src/kernel/syscall/*.zig |
| HAL | src/arch/x86_64/ (via hal import) |
| Kernel drivers | src/drivers/ |
| User drivers | src/user/drivers/ |
| Libc | src/user/lib/libc/ |
| Async I/O | src/kernel/io/ |


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
| `scripts/build_query.py` | Build system | `python scripts/build_query.py modules` |
| `scripts/debug_query.py` | Debugging | `python scripts/debug_query.py panic` |
| `scripts/uefi_query.py` | UEFI bootloader | `python scripts/uefi_query.py event` |
| `scripts/network_query.py` | Network stack | `python scripts/network_query.py tcp` |
| `scripts/boot_query.py` | Boot process | `python scripts/boot_query.py flow` |

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

### IRQ Routing (Common Bug!)
```zig
// WRONG: enableIrq only unmasks - interrupts silently lost!
hal.apic.enableIrq(12);

// CORRECT: Route first, then enable
hal.apic.routeIrq(12, hal.apic.Vectors.MOUSE, 0);
hal.apic.enableIrq(12);
```
Query: `python scripts/driver_query.py irq`

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
python scripts/driver_query.py irq          # Legacy ISA IRQ routing (CRITICAL!)
python scripts/driver_query.py msix         # MSI-X interrupt pattern
python scripts/driver_query.py input        # Input subsystem flow (HID/mouse/keyboard)
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
python scripts/security_query.py entropy    # Entropy and PRNG selection
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
python scripts/memory_query.py vector    # Interrupt vector map
```

### Libc/User Lookup
```bash
python scripts/libc_query.py errno     # Error codes
python scripts/libc_query.py syscall   # Userspace syscall wrapper
python scripts/libc_query.py file      # File I/O wrappers
python scripts/libc_query.py net       # Network socket wrappers
python scripts/libc_query.py structure # User folder layout
```

### Build System Lookup
```bash
python scripts/build_query.py modules    # Module dependency graph
python scripts/build_query.py targets    # Build targets (x86_64-freestanding)
python scripts/build_query.py options    # Build options (-D flags)
python scripts/build_query.py artifacts  # Output paths (kernel.elf, ISO, disk.img)
python scripts/build_query.py disk_image # GPT disk image tool (tools/disk_image.zig)
python scripts/build_query.py qemu       # QEMU run options
python scripts/build_query.py commands   # Common build commands
```

### Debug/Troubleshooting Lookup
```bash
python scripts/debug_query.py panic      # Panic handler and stack traces
python scripts/debug_query.py log        # Kernel logging (console.printf)
python scripts/debug_query.py qemu       # QEMU debugging tips
python scripts/debug_query.py gdb        # GDB debugging setup
python scripts/debug_query.py crash      # Common crash causes and fixes
python scripts/debug_query.py serial     # Serial output debugging
```

### UEFI Bootloader Lookup
```bash
python scripts/uefi_query.py system      # System table structure
python scripts/uefi_query.py boot        # Boot services overview
python scripts/uefi_query.py event       # Event/Timer APIs
python scripts/uefi_query.py text        # SimpleTextInput/Output protocols
python scripts/uefi_query.py gop         # Graphics Output Protocol
python scripts/uefi_query.py memmap      # Memory map and types
python scripts/uefi_query.py file        # File protocol and loading
python scripts/uefi_query.py exit        # ExitBootServices pattern
python scripts/uefi_query.py paging      # Page table setup in UEFI (x86_64)
python scripts/uefi_query.py aarch64     # AArch64 paging (TTBR/MAIR/TCR)
python scripts/uefi_query.py errors      # Common errors and fixes
```

### Network Stack Lookup
```bash
python scripts/network_query.py tcp           # TCP protocol overview
python scripts/network_query.py tcp_states    # TCP state machine and timeouts
python scripts/network_query.py socket        # Socket API and syscalls
python scripts/network_query.py socket_options # setsockopt/getsockopt options
python scripts/network_query.py udp           # UDP protocol
python scripts/network_query.py arp           # ARP cache and resolution
python scripts/network_query.py dns           # DNS resolver with anti-spoofing
python scripts/network_query.py icmp          # ICMP handling and PMTU
python scripts/network_query.py reassembly    # IP fragment reassembly (DoS protected)
python scripts/network_query.py security      # All network security features
python scripts/network_query.py constants     # Protocol constants and limits
python scripts/network_query.py blocking      # Blocking I/O scheduler integration
python scripts/network_query.py async         # Async socket API pattern
python scripts/network_query.py template protocol    # New protocol handler template
python scripts/network_query.py template socket_op   # Socket operation template
python scripts/network_query.py template packet_parse # Safe packet parsing template
python scripts/network_query.py template state_machine # Protocol state machine
```

### Boot Process Lookup
```bash
python scripts/boot_query.py flow          # Boot flow stages (UEFI -> kernel)
python scripts/boot_query.py bootinfo      # BootInfo structure (144 bytes)
python scripts/boot_query.py memory        # Memory layout (HHDM, kernel, user)
python scripts/boot_query.py paging        # Page table setup (PML4/TTBR)
python scripts/boot_query.py abi           # Calling convention (MS x64 vs SysV)
python scripts/boot_query.py entry         # Kernel entry points
python scripts/boot_query.py init          # Initialization sequence (14 steps)
python scripts/boot_query.py troubleshoot  # Common boot failures and fixes
python scripts/boot_query.py aarch64       # AArch64 differences (TTBR/MAIR/TCR)
```

### Driver Template Generation
```bash
python scripts/driver_query.py template mmio  # MMIO kernel driver boilerplate
python scripts/driver_query.py template ring  # Ring IPC userspace driver
```

## Workflow: Adding a Feature

### New Syscall
1. Query existing: `python scripts/syscall_query.py --category <relevant>`
2. Query pattern: `python scripts/rules_query.py handler`
3. Add to `src/uapi/syscalls.zig`
4. Add handler to appropriate subdirectory in `src/kernel/sys/syscall/` (core/, fs/, memory/, process/, net/, hw/, io/, io_uring/, misc/)

### New Driver (Kernel)
1. Generate template: `python scripts/driver_query.py template mmio`
2. Query PCI: `python scripts/driver_query.py pci`
3. Query interrupt pattern: `python scripts/driver_query.py msix` (PCI) or `irq` (ISA)
4. Create in `src/drivers/`
5. Customize template with device-specific registers
6. For ISA IRQs: Call `routeIrq()` BEFORE `enableIrq()` (see `irq` pattern)

### New Driver (Userspace)
1. Generate template: `python scripts/driver_query.py template ring`
2. Query caps: `python scripts/driver_query.py capabilities`
3. Query split: `python scripts/driver_query.py split`
4. Create in `src/user/drivers/`

### Network Feature
1. Query protocol: `python scripts/network_query.py tcp` or `udp`
2. Query constants: `python scripts/network_query.py constants`
3. Query security: `python scripts/network_query.py security`
4. Generate template: `python scripts/network_query.py template protocol`
5. Query syscalls: `python scripts/syscall_query.py --category net`

### Debug Input Device (Keyboard/Mouse)
1. Query input flow: `python scripts/driver_query.py input`
2. Verify IRQ routing: `python scripts/driver_query.py irq`
3. Check: Is IRQ routed? (boot log: "routed to vector N")
4. Check: Does handler push to unified input subsystem?
5. Keyboard uses `sys_read_scancode()`, Mouse uses `sys_read_input_event()`

## File Locations

| Component | Location |
|-----------|----------|
| Syscall numbers | src/uapi/syscalls/root.zig |
| Syscall handlers | src/kernel/sys/syscall/{core,fs,memory,process,net,hw,io,io_uring,misc}/*.zig |
| HAL (x86_64) | src/arch/x86_64/ (via hal import) |
| HAL (aarch64) | src/arch/aarch64/ (via hal import) |
| APIC/IRQ routing | src/arch/x86_64/kernel/apic/root.zig |
| Kernel drivers | src/drivers/ |
| Input drivers | src/drivers/input/{keyboard,mouse,input}.zig |
| USB HID driver | src/drivers/usb/class/hid/ |
| User drivers | src/user/drivers/ |
| Libc | src/user/lib/libc/ |
| Async I/O | src/kernel/io/ |
| Network stack | src/net/ |
| UEFI bootloader | src/boot/uefi/ (dual-arch: x86_64/aarch64) |
| Boot info | src/boot/common/boot_info.zig |
| Build tools | tools/ (disk_image.zig, docker-build.sh) |


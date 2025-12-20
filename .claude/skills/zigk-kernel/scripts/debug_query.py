#!/usr/bin/env python3
"""
Debug Query Tool for zigk kernel.

Query debugging techniques, panic handling, logging, and QEMU tips.

Usage:
    python debug_query.py panic          # Panic handler and stack traces
    python debug_query.py log            # Kernel logging (console.printf)
    python debug_query.py qemu           # QEMU debugging tips
    python debug_query.py gdb            # GDB debugging setup
    python debug_query.py crash          # Common crash causes and fixes
    python debug_query.py serial         # Serial output debugging
"""

import sys

PATTERNS = {
    "panic": """
## Panic Handler

Location: src/kernel/panic.zig

### How Panics Work
1. `@panic("message")` or `panic.panic("message")` called
2. Interrupts disabled
3. Stack trace printed (if available)
4. CPU halted in loop

### Panic Output Format
```
KERNEL PANIC: <message>
  at <file>:<line>:<column>
Stack trace:
  0x<addr1> -> <symbol1>
  0x<addr2> -> <symbol2>
  ...
```

### Stack Trace Availability
- **Debug builds**: Full stack traces with symbols
- **ReleaseSafe**: Limited traces (frame pointers preserved)
- **ReleaseFast**: No stack traces (frame pointers omitted)

### Triggering Panics
```zig
// Zig builtin
@panic("Something went wrong");

// With formatting (use this pattern)
console.printf("PANIC: error={} at 0x{x}\\n", .{err, addr});
@panic("See above for details");

// Unreachable code
unreachable;  // Becomes @panic("reached unreachable code")
```

### Panic Handler Customization
```zig
// In src/kernel/panic.zig
pub fn panic(msg: []const u8, ret_addr: ?usize) noreturn {
    hal.cpu.disableInterrupts();

    console.printf("\\n*** KERNEL PANIC ***\\n", .{});
    console.printf("Message: {s}\\n", .{msg});

    if (ret_addr) |addr| {
        console.printf("Return address: 0x{x}\\n", .{addr});
    }

    // Print stack trace if available
    printStackTrace();

    // Halt
    while (true) {
        hal.cpu.halt();
    }
}
```

### Post-Panic Analysis
1. Check serial output for panic message
2. Note the return address (RIP)
3. Use `addr2line` or `llvm-objdump` to find source location
""",

    "log": """
## Kernel Logging

Location: src/kernel/debug/console.zig

### console.printf
```zig
const console = @import("console");

// Basic output
console.printf("Hello kernel\\n", .{});

// With formatting
console.printf("PID={} addr=0x{x} name={s}\\n", .{pid, addr, name});

// Conditional debug output
if (config.debug_enabled) {
    console.printf("[DEBUG] value={}\\n", .{val});
}
```

### Format Specifiers
| Specifier | Type | Example |
|-----------|------|---------|
| {} | Any (auto) | `console.printf("{}", .{value})` |
| {d} | Decimal int | `123` |
| {x} | Hex int | `0x7b` |
| {X} | Hex (upper) | `0x7B` |
| {s} | String | `"hello"` |
| {c} | Char | `'a'` |
| {b} | Binary | `0b1111011` |
| {e} | Error | `.EINVAL` |

### Debug Levels (Build Options)
```bash
zig build -Ddebug=true              # General debug output
zig build -Ddebug-memory=true       # Memory allocator traces
zig build -Ddebug-scheduler=true    # Scheduler decisions
zig build -Ddebug-network=true      # Network packet traces
```

### Accessing Debug Flags in Code
```zig
const config = @import("config");

if (config.debug_memory) {
    console.printf("[PMM] Allocated page at 0x{x}\\n", .{phys});
}
```

### Serial Output
All console.printf output goes to COM1 (0x3F8) at 115200 baud.
View with: `zig build run` (serial output to terminal)
""",

    "qemu": """
## QEMU Debugging Tips

### Basic Run
```bash
zig build run -Ddisplay=none    # Headless, serial to terminal
```

### QEMU Monitor
```bash
# Add -monitor stdio to get QEMU monitor
# Or press Ctrl+A, C in serial console

# Useful commands:
info registers       # Show CPU registers
info mem             # Show page table mappings
info tlb             # Show TLB entries
x/10i $rip           # Disassemble 10 instructions at RIP
xp /10x 0x1000       # Examine physical memory
gpa2hva 0x1000       # Guest physical to host virtual
```

### Debug Interrupts
```bash
qemu-system-x86_64 ... -d int -D /tmp/qemu.log
# Then: tail -f /tmp/qemu.log
```

### Debug CPU Resets
```bash
qemu-system-x86_64 ... -d cpu_reset -D /tmp/qemu.log
```

### Debug I/O
```bash
qemu-system-x86_64 ... -d in_asm,out_asm -D /tmp/qemu.log
```

### Memory Dump on Crash
```bash
# Add -no-reboot to stop on triple fault instead of reboot
qemu-system-x86_64 ... -no-reboot

# Then in monitor: dump-guest-memory /tmp/crash.bin
```

### Network Debugging
```bash
# Capture packets
qemu-system-x86_64 ... -object filter-dump,id=f1,netdev=net0,file=/tmp/net.pcap

# View with Wireshark
wireshark /tmp/net.pcap
```

### USB Debugging
```bash
qemu-system-x86_64 ... -trace 'usb*'
```
""",

    "gdb": """
## GDB Debugging Setup

### Start QEMU with GDB Stub
```bash
qemu-system-x86_64 ... -s -S
# -s: Start GDB stub on port 1234
# -S: Freeze CPU at startup
```

### Connect GDB
```bash
gdb zig-out/bin/kernel.elf
(gdb) target remote :1234
(gdb) continue
```

### Useful GDB Commands
```
# Breakpoints
break kmain                    # Break at function
break *0xffffffff80100000      # Break at address
delete 1                       # Delete breakpoint 1

# Execution
continue                       # Continue execution
step                           # Step into
next                           # Step over
finish                         # Run until function returns

# Inspection
info registers                 # Show all registers
print $rax                     # Show RAX
print/x $cr3                   # Show CR3 in hex
x/10i $rip                     # Disassemble 10 instructions
x/10gx $rsp                    # Examine stack (10 64-bit words)

# Memory
x/s 0xffffffff80200000         # Examine string
x/10x 0x1000                   # Examine 10 hex words

# Stack
backtrace                      # Show call stack
frame 3                        # Select frame 3
info frame                     # Show frame details
```

### GDB Script for Kernel
```gdb
# ~/.gdbinit or kernel.gdb
set architecture i386:x86-64
set disassembly-flavor intel
target remote :1234

# Break on panic
break panic
commands
  info registers
  backtrace
end
```

### LLDB Alternative (macOS)
```bash
lldb zig-out/bin/kernel.elf
(lldb) gdb-remote 1234
(lldb) continue
```
""",

    "crash": """
## Common Crash Causes and Fixes

### Triple Fault (Immediate Reboot)
**Causes:**
- Invalid IDT entry (handler address wrong)
- Stack overflow (RSP goes below guard page)
- Double fault handler itself faults

**Debug:**
```bash
qemu-system-x86_64 ... -no-reboot -d int
# Look for #DF (Double Fault, vector 8)
```

### Page Fault (#PF, Vector 14)
**Check:**
```zig
fn handlePageFault(cr2: u64, error_code: u64) void {
    const present = (error_code & 1) != 0;
    const write = (error_code & 2) != 0;
    const user = (error_code & 4) != 0;

    console.printf("Page fault at 0x{x}: present={} write={} user={}\\n",
        .{cr2, present, write, user});
}
```

**Common causes:**
- NULL pointer dereference (cr2 near 0)
- Stack overflow (cr2 in guard page)
- Invalid user pointer not validated

### General Protection Fault (#GP, Vector 13)
**Common causes:**
- Loading invalid selector into segment register
- I/O port access without permission
- Unaligned SSE access
- Privilege violation

**Debug:**
```
Error code = selector index (or 0 if not segment-related)
```

### Stack Overflow
**Symptoms:**
- Crash in deeply nested function
- CR2 in stack guard page region

**Fix:**
```zig
// Increase stack size in build.zig
zig build -Dstack-size=32768
```

### Interrupt Handler Crash
**Debug pattern:**
```zig
fn handler() void {
    console.printf("Handler entered\\n", .{});

    // ... do work ...

    console.printf("Handler complete\\n", .{});
}
```

### Memory Corruption
**Symptoms:**
- Random crashes
- Corrupted data structures

**Debug:**
- Enable `-Ddebug-memory=true`
- Add canary checks around allocations
- Use ASAN/MSAN when available
""",

    "serial": """
## Serial Output Debugging

### Serial Port Configuration
- **Port**: COM1 (0x3F8)
- **Baud**: 115200 (configurable via `-Dserial-baud=`)
- **Format**: 8N1 (8 bits, no parity, 1 stop bit)

### QEMU Serial Output
```bash
# Output to terminal (default)
zig build run

# Output to file
qemu-system-x86_64 ... -serial file:/tmp/serial.log

# Output to PTY (for minicom)
qemu-system-x86_64 ... -serial pty
# QEMU will print: char device redirected to /dev/pts/X
```

### Early Boot Debugging
Serial is initialized very early. For pre-serial debugging:
```zig
// Direct port I/O (emergency only)
hal.io.outB(0x3F8, 'X');  // Write 'X' to COM1
```

### Serial Console Colors
```zig
// ANSI escape codes work in most terminals
console.printf("\\x1b[31mRED TEXT\\x1b[0m\\n", .{});
console.printf("\\x1b[32mGREEN TEXT\\x1b[0m\\n", .{});
```

### Reading Serial Input
```zig
// In kernel
const c = hal.serial.readByte();

// In userspace (via syscall)
const c = syscall.read(0, &buf, 1);  // fd 0 = stdin
```

### Common Issues
1. **No output**: Check `-Ddebug=true` is set
2. **Garbled output**: Baud rate mismatch
3. **Missing output**: Buffer not flushed (add `\\n`)
""",
}

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    query = sys.argv[1].lower()

    if query in PATTERNS:
        print(PATTERNS[query])
    else:
        matches = [k for k in PATTERNS.keys() if query in k]
        if matches:
            for m in matches:
                print(PATTERNS[m])
        else:
            print(f"Unknown topic: {query}")
            print(f"Available: {', '.join(PATTERNS.keys())}")
            sys.exit(1)

if __name__ == "__main__":
    main()

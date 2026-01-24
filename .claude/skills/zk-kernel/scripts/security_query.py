#!/usr/bin/env python3
"""
Security Pattern Query Tool for zk kernel.

Query security features: spinlocks, stack canary, ASLR, capabilities, entropy.

Usage:
    python security_query.py spinlock      # Spinlock usage
    python security_query.py canary        # Stack canary/SSP
    python security_query.py aslr          # Address space randomization
    python security_query.py capability    # Capability system
    python security_query.py privilege     # Ring 0/3 separation
    python security_query.py validation    # Input validation patterns
    python security_query.py entropy       # Entropy and PRNG selection
"""

import sys

PATTERNS = {
    "spinlock": """
## Spinlock Usage

Location: src/arch/x86_64/spinlock.zig (via hal)

### Basic Pattern
```zig
const hal = @import("hal");

var lock = hal.SpinLock{};

// Acquire (spins until available)
lock.acquire();
defer lock.release();

// Critical section
doWork();
```

### With Interrupt Disable
```zig
// Disables interrupts while held
const state = lock.acquireDisableIrq();
defer lock.releaseRestoreIrq(state);

// Critical section (no interrupts)
```

### Rules
1. **Never hold across blocking operations** (sched.block, I/O)
2. **Never hold across user memory access** (page fault possible)
3. **Keep critical sections short** (spinlock = busy wait)
4. **Respect lock ordering** to prevent deadlock

### Lock Ordering (lower number = acquired first)
1.  process_tree_lock
2.  SFS.alloc_lock (Filesystem)
3.  FileDescriptor.lock
4.  Scheduler/Runqueue Lock
5.  tcp_state.lock (Global TCP)
6.  socket/state.lock (Socket table)
7.  Per-socket sock.lock / Per-TCB tcb.mutex
8.  UserVmm.lock (NO sleep while held!)
8.5 devices_lock (USB global)
8.6 UsbDevice.device_lock (per-device, IRQ-safe)
9.  FutexBucket.lock
10. pmm.lock (internal)

### When to Use
- Short critical sections in interrupt context
- Protecting simple data structures
- When blocking is not acceptable

### When NOT to Use
- Long operations (use mutex instead)
- Across syscall boundaries
- When holding other locks that might block
""",

    "canary": """
## Stack Canary (SSP)

Location: src/kernel/stack_guard.zig

### How It Works
```
+------------------+
| Return Address   |
+------------------+
| Stack Canary     |  <- Random value, checked on return
+------------------+
| Local Variables  |
+------------------+
| ...              |
+------------------+ <- RSP
```

### Symbols
- __stack_chk_guard: The canary value (exported)
- __stack_chk_fail: Called on corruption (panics)

### Canary Format
```
[random 7 bytes][0x00]
```
Low byte is 0x00 for null-terminator overflow detection.

### Initialization Sequence
```
hal.entropy.init()     →  Detect RDRAND
prng.init()            →  Seed RNG
stack_guard.init()     →  Generate canary
initApic()             →  Add timing jitter
stack_guard.reseed()   →  Reseed before threads
scheduler.init()       →  Protected threads start
```

### Entropy Sources
1. RDRAND (preferred): Hardware RNG via CPUID
2. RDTSC (fallback): Time Stamp Counter

### Compiler Integration
- Zig automatically inserts canary checks with -fstack-protector
- Enabled in ReleaseSafe and Debug builds
""",

    "aslr": """
## Address Space Layout Randomization

Location: src/kernel/mm/aslr.zig

### Randomized Regions
| Component | Base Address | Entropy | Granularity | Range |
|-----------|--------------|---------|-------------|-------|
| Stack | 0x7FFF_FFFF_F000 | 22 bits | 4KB (page) | 16GB |
| PIE | 0x5555_5000_0000 | 16 bits | 64KB | 4GB |
| mmap | 0x1000_0000_0000 | 20 bits | 4KB (page) | 4TB |
| Heap gap | After ELF | 16 bits | 4KB (page) | 256MB |
| TLS | 0xB000_0000 | 16 bits | 4KB (page) | 256MB |
| VDSO | 0x7FFF_E000_0000 | 16 bits | 4KB (page) | 256MB |

### AslrOffsets Structure
```zig
pub const AslrOffsets = struct {
    stack_offset: u32,    // Subtracted from stack base (u32 for 22 bits)
    pie_offset: u16,      // Added to PIE base (64KB units)
    mmap_offset: u32,     // Added to mmap base (pages)
    heap_gap: u16,        // Gap after ELF (16 bits entropy)
    tls_offset: u16,      // TLS offset (16 bits entropy)
    stack_top: u64,       // Computed stack top
    mmap_start: u64,      // Computed mmap start
    tls_base: u64,        // Computed TLS base

    // Comptime validation ensures storage types match entropy bits
    comptime { /* validates all offset types >= entropy bits */ }
};
```

### When Generated
| Event | Action |
|-------|--------|
| createProcess() | New random offsets |
| forkProcess() | Copy parent's offsets |
| sys_execve() | New random offsets |

### Entropy Source
Uses kernel CSPRNG (ChaCha20, RFC 8439) seeded from RDRAND/RDSEED at boot.
All MAX_OFFSET values are powers of 2, so modulo produces uniform distribution.

### Security Notes
- **Fail-secure**: If entropy is weak, `generateOffsets()` returns `error.WeakEntropy`
- 22-bit stack entropy provides strong protection vs heap spraying
- 16-bit heap gap entropy prevents brute-force heap layout prediction
- Comptime validation prevents entropy truncation bugs (storage type >= entropy bits)

### Architecture Compatibility
All base addresses are valid for both x86_64 (47-bit) and AArch64 (48-bit) canonical ranges.

### Debug Output (Debug builds only)
```
ASLR[pid=1]: stack_top=7fffff8bf000 pie_base=5555c3470000 mmap=10002a590000 heap_gap=49 tls_base=b0001000
```
""",

    "capability": """
## Capability System

Location: src/kernel/capability.zig

### Process Capabilities
Each process has a capability bitmask controlling privileged operations.

| Capability | Bit | Allows |
|------------|-----|--------|
| INTERRUPT | 0 | SYS_WAIT_INTERRUPT |
| PORT_IO | 1 | SYS_OUTB/INB |
| MMIO | 2 | SYS_MMAP_PHYS |
| DMA | 3 | SYS_ALLOC_DMA |
| PCI | 4 | PCI config access |
| RAW_SOCKET | 5 | Raw network access |

### Granting Capabilities
Only init_proc can grant capabilities:
```zig
// In init_proc spawn logic
child.capabilities |= CAP_INTERRUPT | CAP_MMIO;
```

### Checking Capabilities
```zig
pub fn sys_wait_interrupt(irq: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();
    if (!proc.hasCapability(.INTERRUPT)) {
        return error.EPERM;
    }
    // ... proceed
}
```

### IRQ Ownership
Specific IRQs can be assigned to processes:
```zig
proc.owned_irqs |= (1 << irq);
```

### Capability Inheritance
- fork(): Child inherits parent's capabilities
- execve(): Capabilities preserved (unless setuid, future)
""",

    "privilege": """
## Privilege Separation (Ring 0/3)

### Ring Levels
- Ring 0: Kernel (full hardware access)
- Ring 3: User (restricted, must use syscalls)

### Protection Mechanisms
1. **Page Tables**: U bit controls user access
2. **Segment Selectors**: DPL in GDT/LDT
3. **SYSCALL/SYSRET**: Ring transition

### Page Table Protection
```zig
// Kernel page (Ring 0 only)
entry = phys | PRESENT | WRITABLE;

// User page (Ring 3 accessible)
entry = phys | PRESENT | WRITABLE | USER;
```

### GDT Segments
| Selector | Ring | Type |
|----------|------|------|
| 0x08 | 0 | Kernel Code |
| 0x10 | 0 | Kernel Data |
| 0x18 | 3 | User Code |
| 0x20 | 3 | User Data |

### Syscall Entry
1. User executes `syscall` instruction
2. CPU loads kernel CS/SS from MSRs
3. Kernel validates user pointers
4. Kernel performs operation
5. `sysret` returns to user mode

### Future: SMAP/SMEP
- SMAP: Prevent kernel from accessing user pages accidentally
- SMEP: Prevent kernel from executing user pages
""",

    "validation": """
## Input Validation Patterns

### User Pointer Validation
```zig
// Always validate before dereferencing
if (!user_mem.isValidUserPtr(ptr, size)) {
    return error.EFAULT;
}

// Check access mode
if (!user_mem.isValidUserAccess(ptr, size, .Write)) {
    return error.EFAULT;
}
```

### Bounds Checking
```zig
// Validate array index
if (index >= array.len) {
    return error.EINVAL;
}

// Validate fd
if (fd >= MAX_FDS) {
    return error.EBADF;
}
```

### Integer Overflow Prevention
```zig
// Use checked arithmetic
const sum = std.math.add(usize, a, b) catch return error.EOVERFLOW;

// Or wrapping when intentional
const wrapped = a +% b;
```

### Path Validation
```zig
// Check path length
if (path_len > user_mem.MAX_PATH_LEN) {
    return error.ENAMETOOLONG;
}

// Validate path doesn't escape (for sandboxing)
if (std.mem.indexOf(u8, path, "..")) |_| {
    return error.EACCES;
}
```

### File Descriptor Validation
```zig
const fd_table = base.getGlobalFdTable();
const file = fd_table.get(fd) orelse return error.EBADF;
```
""",

    "entropy": """
## Entropy & Random Number Generation

### Use Case Selection Table
| Use Case | Kernel | Userspace |
|----------|--------|-----------|
| XID, nonces, tokens | `random.getU64()` | `syscall.getSecureRandomU32/U64()` |
| Crypto keys, buffers | `random.fillRandom(buf)` | `syscall.getSecureRandom(buf)` |
| Non-security (jitter) | `prng.fill(buf)` | `libc rand()` |
| Custom error handling | `hal.entropy.*` | Raw `syscall.getrandom()` |

### Key Files
| File | Purpose |
|------|---------|
| `src/kernel/core/random.zig` | ChaCha20 CSPRNG (crypto-quality) |
| `src/lib/prng.zig` | xoroshiro128+ (fast, non-crypto) |
| `src/arch/*/kernel/entropy.zig` | Hardware entropy (RDRAND/RDSEED/RNDR) |
| `src/user/lib/syscall/resource.zig` | Userspace secure wrappers |
| `src/net/transport/tcp/state.zig` | TCP ISN generation (RFC 6528) |

### Kernel CSPRNG Usage
```zig
const random = @import("random");

// Single u64
const val = random.getU64();

// Fill buffer
var key: [32]u8 = undefined;
random.fillRandom(&key);
```

### Userspace Secure Random
```zig
const syscall = @import("syscall");

// PREFERRED: Handles partial reads, EINTR, panics on failure
const xid = syscall.getSecureRandomU32();

// Buffer fill
var nonce: [12]u8 = undefined;
syscall.getSecureRandom(&nonce);
```

### WRONG Patterns
```zig
// WRONG: Partial reads not handled!
_ = syscall.getrandom(buf.ptr, buf.len, 0);

// WRONG: Tick-based fallback is predictable!
const xid = if (getrandom fails) getTickMs() ^ 0xDEADBEEF;

// WRONG: rand() for security!
const session_id = rand();
```

### Hardware Entropy Hierarchy
1. RDSEED (x86_64) / RNDR (AArch64) - True hardware entropy
2. RDRAND (x86_64) - CPU entropy (cryptographic)
3. ChaCha20 CSPRNG - Seeded from hardware
4. xoroshiro128+ - Fast non-crypto PRNG
5. TSC/timing - Weak fallback (avoid for security)

### TCP ISN Security (RFC 6528)
Location: `src/net/transport/tcp/state.zig`
```
ISN = M + F(secret_key, src_ip, src_port, dst_ip, dst_port)
M = milliseconds * 250 (4us per increment)
F = SipHash-2-4
```
- Fresh hardware entropy mixed per connection
- Key re-seeded every 10,000 ISNs
- Prevents TCP sequence number prediction attacks

### Fail-Secure Policy
- `getSecureRandom()` panics on entropy failure
- Never fall back to weak PRNG silently
- VirtIO-RNG feeds entropy to kernel pool
- Build flag `require_hardware_entropy` for production
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

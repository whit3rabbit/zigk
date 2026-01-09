# zscapek Development Guidelines

A Zig-based microkernel for x86_64 and AArch64 with a custom UEFI bootloader.

## Environment & Build
- **Zig Version**: 0.16.x (Nightly)
- **Target**: `x86_64-freestanding` or `aarch64-freestanding`
- **Bootloader**: Custom UEFI (src/boot/uefi/)
- **Host**: macOS (Apple Silicon) -> Requires QEMU TCG for x86_64

### Commands
```bash
zig build -Darch=x86_64   # Build for x86_64 (default)
zig build -Darch=aarch64  # Build for AArch64
zig build iso -Darch=x86_64   # Create x86_64 UEFI ISO
zig build run -Darch=x86_64   # Run x86_64 in QEMU
zig build run -Darch=aarch64  # Run AArch64 in QEMU
zig build test            # Run unit tests
```

**Note:** Kernel binaries are architecture-named (`kernel-x86_64.elf`, `kernel-aarch64.elf`) and coexist in `zig-out/bin/`.

**QEMU on macOS (Apple Silicon):**
Use `-Dbios=/path/to/OVMF.fd` to specify UEFI firmware.
Use `-Dqemu-args="-accel tcg,thread=multi -cpu max"` to prevent stability issues.
To prevent hangs on CI/Testing, ensure test runner implements timeouts (e.g., 30s).

## Zig 0.16.x Compatibility Notes

### Breaking API Changes from 0.15.x

**build.zig changes:**
- `std.fs.accessAbsolute(path, flags)` removed - use `std.c.access(path.ptr, std.c.F_OK)` with `[:0]const u8` paths
- `compile.addAssemblyFile(...)` deprecated - use `compile.root_module.addAssemblyFile(...)`
- `compile.addCSourceFile(...)` deprecated - use `compile.root_module.addCSourceFile(...)`
- `compile.addCSourceFiles(...)` deprecated - use `compile.root_module.addCSourceFiles(...)`
- `compile.addIncludePath(...)` deprecated - use `compile.root_module.addIncludePath(...)`
- `compile.linkLibC()` deprecated - use `compile.root_module.link_libc = true`
- `setLinkerScript` remains on Step.Compile (not deprecated)

**Standard library changes:**
- `std.atomic.compilerFence(.seq_cst)` removed - use `asm volatile ("" ::: "memory")`
- `std.mem.trimRight(T, slice, chars)` removed - implement manually or use helper function
- `std.meta.intToEnum(Enum, int)` removed - use `std.enums.fromInt(Enum, int)` which returns `?Enum`
- `std.fs.cwd()` removed - filesystem APIs moved to `std.Io.Dir` with required `Io` context parameter

**Pattern for file existence check in build.zig:**
```zig
fn fileExists(path: [:0]const u8) bool {
    return std.c.access(path.ptr, std.c.F_OK) == 0;
}
```

**Pattern for compiler fence:**
```zig
// Instead of: std.atomic.compilerFence(.seq_cst)
asm volatile ("" ::: "memory");
```

## Reference Skills

### Linux Kernel Reference (`.claude/skills/linux-kernel-ref/`)
**Query this skill** when implementing:
- **Drivers**: PCI enumeration, MMIO access, MSI-X interrupts, DMA buffers
- **Network stack**: Socket layer, TCP/UDP protocols, sk_buff handling
- **Filesystems**: VFS, inode/dentry operations, superblock, block I/O

```bash
# Driver patterns
python .claude/skills/linux-kernel-ref/scripts/driver_query.py ahci interrupt
python .claude/skills/linux-kernel-ref/scripts/driver_query.py e1000e mmio

# Network stack
python .claude/skills/linux-kernel-ref/scripts/driver_query.py tcp socket
python .claude/skills/linux-kernel-ref/scripts/subsystem_query.py net

# Filesystem
python .claude/skills/linux-kernel-ref/scripts/driver_query.py ext4 inode
python .claude/skills/linux-kernel-ref/scripts/subsystem_query.py vfs
```

First-time setup: `bash .claude/skills/linux-kernel-ref/scripts/setup_kernel.sh`

## Security Standards (Strict)

### 1. Memory Access (`UserPtr`)
**NEVER** dereference user pointers directly. Use `UserPtr` to ensure bounds checks, page mapping verification, and SMAP compliance.

```zig
// ✅ CORRECT: Type-safe copy
pub fn sys_read(fd: usize, buf_ptr: usize, len: usize) SyscallError!usize {
    if (!user_mem.isValidUserAccess(buf_ptr, len, .Write)) return error.EFAULT;
    const uptr = user_mem.UserPtr.from(buf_ptr);
    // ... copy logic ...
}
```

### 2. Concurrency & State Management (TOCTOU Prevention)
*   **Refresh State Under Lock**: Never rely on cached metadata (size, permissions, active flags) acquired *before* a lock. Always re-read or verify the state from the source (disk/inode) immediately **after** acquiring the lock.
*   **Bounds Checks Inside Lock**: If accessing a shared array using an index validated outside the lock, **re-validate** the index against `.len` *inside* the lock. Arrays may have shrunk or reallocated.
*   **Post-Open Verification**: For filesystem operations, verify permissions/file status *after* obtaining the file descriptor to catch symlink swaps or race conditions.
*   **Lock Ordering** (lower number = acquired first, higher number = acquired later):
    1. `process_tree_lock`
    2. `SFS.alloc_lock` (Filesystem Allocation)
    3. `FileDescriptor.lock`
    4. `Scheduler/Runqueue Lock`
    5. `tcp_state.lock` (Global TCP state - `src/net/transport/tcp/state.zig`)
    6. `socket/state.lock` (Socket table - `src/net/transport/socket/state.zig`)
    7. Per-socket `sock.lock` / Per-TCB `tcb.mutex`
    8. `UserVmm.lock` (read mode for address translation, write mode for munmap - must NOT be held during sleep)
    8.5. `devices_lock` (USB global device array RwLock - `src/drivers/usb/xhci/device.zig`)
    8.6. `UsbDevice.device_lock` (per-device Spinlock for transfer operations, IRQ-safe)
    9. `FutexBucket.lock` (per-bucket spinlock for futex wait queues)
    10. `pmm.lock` (internal PMM spinlock, not held across calls)

### 3. I/O Robustness & Information Leaks
*   **DMA Hygiene**: Zero-initialize (`@memset(buf, 0)`) destination buffers **before** initiating DMA or hardware reads. This prevents kernel stack leaks if the device writes less data than expected or fails silently.
*   **Partial I/O & EINTR**: System calls and internal I/O (like `getrandom` or `read`) must assume **partial returns** or interruptions. Always wrap in a loop handling `EINTR` (retry) and updating offsets until the full request is satisfied or a hard error occurs.
*   **Secure Initialization**: Prefer `var buf = [_]u8{0} ** N;` over `undefined` for security-sensitive buffers (keys, RNG, network packets). `undefined` in `ReleaseFast` leaks stack data.
*   **Fail Secure**: If a security-critical dependency (like entropy source) fails, **panic** or return a fatal error. Do not fall back to insecure defaults silently.

### 4. Entropy & Random Number Generation
Use the correct entropy source for each use case. **Never use weak fallbacks for security-critical operations.**

| Use Case | Kernel | Userspace |
|----------|--------|-----------|
| XID, nonces, session tokens | `random.getU64()` | `syscall.getSecureRandomU32/U64()` |
| Crypto keys, arbitrary buffers | `random.fillRandom(buf)` | `syscall.getSecureRandom(buf)` |
| Non-security (shuffling, jitter) | `prng.fill(buf)` | `libc rand()` (after seeding) |
| Low-level with custom handling | `hal.entropy.*` | Raw `syscall.getrandom()` |

**Key Files:**
*   Kernel CSPRNG (ChaCha20): `src/kernel/core/random.zig`
*   Kernel fast PRNG (xoroshiro128+): `src/lib/prng.zig`
*   Hardware entropy (RDRAND/RDSEED): `src/arch/*/kernel/entropy.zig`
*   Userspace secure wrappers: `src/user/lib/syscall/resource.zig`

**Rules:**
*   `getSecureRandom()` handles partial reads, EINTR, and panics on failure (fail-secure).
*   Raw `syscall.getrandom()` does NOT handle partial reads - use only if you implement the loop yourself.
*   TCP ISN uses SipHash-2-4 with hardware entropy mixing (RFC 6528) - see `src/net/transport/tcp/state.zig`.
*   Never use tick-based or time-based values as entropy fallbacks for security operations.

### 5. Integer Safety
*   **Checked Arithmetic**: Use `std.math.add`, `sub`, `mul` for **all** calculations involving:
    *   File offsets/positions.
    *   Buffer lengths derived from user input.
    *   Sector counts.
    *   Allocation sizes.
    *   Display dimensions (width, height, pitch, rows, cols).
    *   Memory region calculations (phys_start + num_pages * PAGE_SIZE).
    *   Any `count * size` pattern (e.g., `height * pitch`, `rows * font_height`).
*   **Underflow Prevention**: Before subtracting, verify the value is >= the amount being subtracted, or use `std.math.sub`:
    ```zig
    // WRONG: Underflows to u32::MAX if rows == 0
    const y = (self.rows - 1) * font_h;

    // CORRECT: Early return or use @max
    if (self.rows == 0) return;
    const y = std.math.mul(u32, self.rows - 1, font_h) catch return;

    // ALSO CORRECT: Guarantee minimum value at initialization
    .rows = @max(1, mode.height / font_height),
    ```
*   **Panic on Overflow**: In kernel space, unexpected overflow is a security violation. Fail the syscall (return error) rather than wrapping.
*   **Common Patterns Requiring Checked Arithmetic**:
    ```zig
    // Pitch/stride calculations
    .pitch = std.math.mul(u32, pixels_per_line, bytes_per_pixel) catch return error.InvalidMode,

    // Buffer size calculations
    const size = std.math.mul(usize, height, pitch) catch return null;

    // Heap/memory size additions
    const total = std.math.add(usize, base_size, offset) catch { panic.halt(); };

    // Physical region bounds
    const region_size = std.math.mul(u64, num_pages, PAGE_SIZE) catch continue;
    const region_end = std.math.add(u64, phys_start, region_size) catch continue;
    ```

### 6. Capabilities over Root
Do not check `uid == 0` for hardware access. Use the Capability system (`src/capabilities/`).

```zig
// ✅ CORRECT
if (!proc.hasMmioCapability(phys_addr, size)) return error.EPERM;
```

### 7. Network Stack Security (Zero-Trust)
Treat all incoming packets as malicious.

*   **Packet Parsing**: NEVER rely on length fields inside the packet headers (IP Total Len, TCP Data Offset) without verifying them against the actual buffer slice length first.
    *   Use `packed struct` for headers to avoid compiler padding leaks or misalignments.
    *   Use `@bitCast` only after size verification.
    ```zig
    // ✅ CORRECT
    if (buffer.len < @sizeOf(IpHeader)) return error.PacketTooShort;
    const ip_hdr: *const IpHeader = @ptrCast(buffer.ptr);
    if (ip_hdr.total_len > buffer.len) return error.PacketTruncated;
    ```
*   **Sequence Number Randomization**: TCP Initial Sequence Numbers (ISNs) MUST be generated using a CSPRNG (ChaCha20), never a simple counter or time-based value, to prevent connection hijacking.
*   **Padding Hygiene**: When constructing packets to send, strictly zero-initialize any padding bytes in headers. Uninitialized padding leaks kernel stack memory to the network.
*   **State Exhaustion (DoS)**:
    *   Limit the number of "embryonic" (SYN_RCVD) connections per listener.
    *   Use a fixed-size memory pool for packet buffers (`mbufs`). Do not allocate heap memory per incoming packet; drop packets if the pool is empty.
*   **Checksum Arithmetic**: Use `u32` accumulators for 16-bit checksum calculations to safely catch overflows before folding bits.

## Async I/O & IPC Architecture

### 1. Kernel Async (`src/kernel/io/`)
Use the Reactor pattern for kernel-side async operations.
*   **Allocate**: `io.allocRequest(.disk_read)`
*   **Submit**: `io.submit(req)`
*   **Wait**: `future.wait()` (Blocks thread via scheduler, does not spin)

### 2. Userspace I/O (`io_uring`)
General file/net operations use Linux-compatible `io_uring`.
*   **Syscalls**: `sys_io_uring_setup`, `_enter`, `_register`.
*   **Pattern**: Submission Queue (SQ) -> Kernel Reactor -> Completion Queue (CQ).

### 3. Zero-Copy Driver IPC (`sys_ring_*`)
High-throughput drivers (VirtIO, Netstack) use shared memory rings, **not** io_uring.
*   **Create**: `sys_ring_create` (Producer)
*   **Attach**: `sys_ring_attach` (Consumer)
*   **Notify**: `sys_ring_notify` / `sys_ring_wait` (Futex-based signaling)

## Syscall Implementation

*   **Location**: `src/kernel/sys/syscall/` (organized into subdirectories: core/, fs/, memory/, process/, net/, hw/, io/, io_uring/, misc/)
*   **Return Type**: Must be `SyscallError!usize`.
*   **Dispatch**: Auto-registered in `core/table.zig`.

```zig
pub fn sys_example(arg1: usize) SyscallError!usize {
    // Return standard Zig errors; dispatcher converts to -errno
    if (arg1 == 0) return error.EINVAL; 
    return 0;
}
```

## Hardware Abstraction Layer (HAL)
*   **Directory**: `src/arch/`
*   **Rule**: Inline assembly (`asm volatile`) is **FORBIDDEN** outside of `src/arch/`.
*   **Usage**: Kernel code calls `hal.cpu.disableInterrupts()`, never `cli`.

## Coding Style
*   **Allocators**: Explicitly use `heap.allocator()` or `dma_allocator`. No global allocator fallback.
*   **Error Handling**: Use `errdefer` to ensure complex multi-step operations (like file creation) fully roll back resources (free blocks, remove entries) on failure.
*   **Slices**: Prefer `[]u8` over `[*]u8`.
*   **Naming**: `sys_snake_case` for syscalls, `camelCase` for internal functions.

## InitRD
*   **Format**: USTAR Tarball.
*   **Mount**: Loaded by UEFI bootloader, passed to kernel via BootInfo, mounted at `/` by `init_proc.zig`.
*   **Security**: Read-only. Paths must be canonicalized to prevent `../../` traversal.

## File Descriptors
*   **Location**: `src/kernel/fd.zig`
*   **Purpose**: Manage file descriptors (FDs) which abstract access to files, devices, sockets, and pipes.
*   **Design**: Fixed-size FD table (`MAX_FDS` entries) per process. Shared FDs via reference counting (for `fork` and `dup`). Standard I/O (stdin, stdout, stderr) pre-populated at slots 0, 1, 2.

## Drivers

### 1. Driver Registration & Lifecycle
*   **Location**: Drivers live in `src/drivers/<subsystem>/<driver_name>/`.
*   **Entry Point**: Drivers must expose a public `init` function taking `*const pci.PciDevice` and `pci.PciAccess`.
*   **Hook**: New drivers are initialized in `src/kernel/init_hw.zig` inside the `init<Subsystem>` functions (e.g., `initNetwork`, `initStorage`).
*   **State**: Driver instances are typically allocated on the heap, but global singleton pointers (e.g., `g_controller`) are often kept in the driver's `root.zig` for ISR access.

### 2. Register Access Pattern (`MmioDevice`)
Do not use raw pointer casting for register access. Use the `hal.mmio_device.MmioDevice` wrapper for type safety.

```zig
// 1. Define offsets enum
pub const Reg = enum(usize) { ctrl = 0x00, status = 0x08 };

// 2. Init wrapper
const MmioDevice = hal.mmio_device.MmioDevice;
var regs = MmioDevice(Reg).init(base_addr, size);

// 3. Use typed access (with packed structs)
const ctrl = regs.readTyped(.ctrl, ControlReg);
regs.writeTyped(.ctrl, .{ .enable = true });
```

### 3. DMA Memory Allocation
Drivers must **never** use `heap.allocator()` for DMA buffers.
*   **Allocation**: Use `pmm.allocZeroedPages(count)` to get physical addresses.
*   **Virtual Access**: Use `hal.paging.physToVirt(phys)` to get the kernel HHDM virtual address for software access.
*   **Hardware Access**: Pass the *physical* address to the device registers/descriptors.
*   **64-bit BARs**: If a BAR is > 4GB, use `vmm.mapMmioExplicit` instead of HHDM logic.

### 4. Interrupt Handling (MSI-X Preference)
Drivers should prefer MSI-X over Legacy INTx.
1.  Check capability: `pci.findMsix(ecam, dev)`.
2.  Allocate vector: `hal.interrupts.allocateMsixVector()`.
3.  Register handler: `hal.interrupts.registerMsixHandler(vector, handler)`.
4.  Enable on device: `pci.enableMsix(...)`.
5.  **ISR Rule**: Interrupt handlers must be fast. For complex processing (like network packets), use a worker thread pattern (`thread.createKernelThread`) and wake it from the ISR using `sched.unblock`.

### 5. Hardware Structures
*   Use `extern struct` for descriptors that require specific memory layouts.
*   Use `packed struct(u32)` for registers where bit manipulation is required.
*   **Alignment**: Ensure structs have `align(16)` or similar if the hardware requires specific alignment (like xHCI TRBs).
*   **Volatile**: Descriptors shared with hardware must be accessed via `*volatile` pointers.

### 6. Async I/O Integration
Drivers implementing `read/write` ops must support the kernel `IoRequest` pattern:
*   **Sync**: Return `isize` directly (legacy) or block using `io.Future`.
*   **Async**: If `req.compareAndSwapState(.pending, .in_progress)` succeeds, queue the request in a driver-local list.
*   **Completion**: The ISR or Worker thread calls `req.complete(...)` when hardware finishes.

### 7. Module Imports
*   Avoid relative imports like `@import("../../hal.zig")`.
*   Use the package names defined in `build.zig`: `@import("hal")`, `@import("pci")`, `@import("pmm")`.
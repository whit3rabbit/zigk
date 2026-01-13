# Memory Management

This document covers the kernel's memory management subsystems.

## Kernel Stack Allocator

**Location:** `src/kernel/mm/kernel_stack.zig`

The kernel stack allocator manages per-thread kernel stacks with guard page protection. Unlike HHDM-based stacks, it allocates from a dedicated virtual address range where guard pages are truly unmapped.

### Architecture-Specific Stack Sizes

| Architecture | Stack Pages | Stack Size | Total Slot | Rationale |
|--------------|-------------|------------|------------|-----------|
| x86_64 | 8 | 32 KB | 36 KB | 128-byte SyscallFrame |
| AArch64 | 16 | 64 KB | 68 KB | 288-byte SyscallFrame (2.25x larger) |

AArch64 requires larger stacks because its SyscallFrame saves 31 GPRs (x0-x30) plus system registers (ELR, SPSR, SP_EL0), totaling 288 bytes per exception entry. x86_64 only saves 16 GPRs for 128 bytes.

### Memory Layout

```
Stack Slot (per thread):
+-------------------+ <- slot_base
|   Guard Page      |    4 KB (unmapped - triggers #PF on overflow)
+-------------------+ <- stack_base
|                   |
|   Stack Space     |    32 KB (x86_64) or 64 KB (AArch64)
|                   |
+-------------------+ <- stack_top (initial RSP/SP)
```

Stack grows downward from `stack_top` toward `stack_base`. Overflow writes into the guard page, triggering a page fault.

### Virtual Address Region

- Base: `0xFFFF_A000_0000_0000` (with KASLR offset)
- Size: `MAX_STACKS * STACK_SLOT_SIZE` (256 slots)
- Isolated from HHDM to ensure guard pages are truly unmapped

### Security Features

1. **Integer Overflow Protection**: All address calculations use `std.math.add/mul` with explicit overflow handling
2. **Guard Page Enforcement**: Failed guard page unmap (except NotMapped) returns error instead of silently continuing
3. **Region Validation**: `stack_region_base` validated to be in kernel space and not overflow address space
4. **Double-Free Detection**: Bitmap check before freeing; panics in Debug mode
5. **Descriptor Validation**: `free()` verifies `stack_base` matches expected address for slot
6. **Initialization Race Prevention**: `initialized` check moved inside lock
7. **Bitmap Bounds Assertions**: Debug assertions on slot bounds before bitmap access
8. **Comptime Validation**: Constants verified at compile time for overflow safety

### API

```zig
// Initialize (call once during boot)
pub fn init() StackError!void

// Allocate a stack for a new thread
pub fn alloc() StackError!KernelStack

// Free a thread's stack
pub fn free(stack: KernelStack) void

// Check if address is in a guard page (for page fault handler)
pub fn isGuardPage(addr: u64) bool

// Get stack info for guard page fault diagnostics
pub fn getStackInfoForGuardFault(addr: u64) ?struct { slot: usize, stack_base: u64, stack_top: u64 }
```

### Error Types

- `NotInitialized`: Allocator not initialized yet
- `OutOfSlots`: All 256 stack slots in use
- `OutOfMemory`: PMM cannot allocate physical pages
- `MappingFailed`: VMM mapping or address calculation error
- `InvalidSlot`: Invalid slot index in free()
- `InvalidRegion`: stack_region_base validation failed

### Thread Integration

When creating a kernel thread (`src/kernel/proc/thread.zig`):

1. Call `kernel_stack.alloc()` to get a `KernelStack`
2. Use `stack_top` as the initial stack pointer
3. On thread exit, call `kernel_stack.free(stack)`

The page fault handler checks `isGuardPage(fault_addr)` to detect stack overflows and provide helpful diagnostics.

---

## Physical Memory Manager (PMM)

**Location:** `src/kernel/mm/pmm.zig`

Bitmap-based allocator with 16-bit reference counts per page.

### Features

- Page allocation/deallocation with zeroing
- Reference counting for future CoW support
- Contiguous multi-page allocation
- Memory statistics tracking

---

## Virtual Memory Manager (VMM)

**Location:** `src/kernel/mm/vmm.zig`

4-level page table management (PML4 on x86_64, TTBR on AArch64).

### Features

- Kernel and user address space management
- VMA (Virtual Memory Area) tracking
- Demand paging with zero-fill on fault
- ASLR for stack, heap, PIE, mmap regions
- TLB shootdown for SMP coherency

---

## IOMMU / DMA

**Location:** `src/kernel/mm/iommu/`, `src/kernel/mm/dma.zig`

DMA isolation using Intel VT-d.

### Features

- Per-device IOVA spaces
- Bitmap-based IOVA allocator (64KB granularity)
- RMRR (Reserved Memory Region Reporting) support
- IOTLB invalidation on map/unmap
- Transparent driver API (`dma.allocBuffer()`)

---

## Slab Allocator

**Location:** `src/kernel/mm/slab.zig`

O(1) small object allocator using bitmapped slabs.

### Features

- Size classes: 16B to 2KB
- Cache-line aligned allocations
- Zero-fragmentation for fixed-size objects
- Per-slab bitmap for allocation tracking

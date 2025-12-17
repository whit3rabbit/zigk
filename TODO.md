# Zscapek Kernel Roadmap & TODO

This document tracks the development progress of the Zscapek microkernel.

## 🎯 Current Focus: Phase 4 (SMP & Concurrency)

Transitioning from a basic multi-core bring-up to a fully preemptive, scalable SMP scheduler.

---

## ✅ Completed Phases

### Phase 1: Zero-Cost HAL (Hardware Abstraction Layer)
- [x] **MmioDevice Wrapper**: Comptime-generated register offsets and type-safe accessors (`arch/x86_64/mmio_device.zig`).
- [x] **Driver Refactoring**: E1000e, AHCI, and XHCI/EHCI drivers updated to use `MmioDevice`.
- [x] **Logging**: Serial (UART) and Framebuffer consoles integrated via `std.log` interface.

### Phase 2: Async I/O (The Reactor)
- [x] **Core Infrastructure**: `IoRequest` state machine, `IoRequestPool`, and `Reactor` singleton.
- [x] **Timer Wheel**: Hierarchical O(1) timer handling.
- [x] **io_uring**: Linux-compatible syscalls implemented (`setup`, `enter`, `register`).
- [x] **Socket Integration**: TCP/UDP stacks hooks into the reactor for non-blocking operations.

### Phase 3: Microkernel Transition
- [x] **Capabilities**: Capability-based access control for IRQs, MMIO, and I/O ports.
- [x] **Userspace Drivers**:
    - `uart_driver`: Forked process model (RX interrupt handler + TX IPC handler).
    - `ps2_driver`: Keyboard/Mouse input handling via IPC.
    - `virtio_net` & `virtio_blk`: Pure userspace drivers using capabilities.
- [x] **IPC Syscalls**: `sys_send` / `sys_recv` for blocking message passing.
- [x] **Hardware Syscalls**: `sys_mmap_phys`, `sys_alloc_dma`, `sys_wait_interrupt`.

---

## 🗺️ Roadmap

### Phase 4: SMP & Synchronization (Completed)
Current status: Scheduler decentralized, Per-CPU queues, TLB shootdown, and fine-grained locking implemented.

- [x] **Per-CPU Scheduler Queues**: Move `ready_queue` from global `Scheduler` to per-CPU structs to reduce lock contention.
- [x] **TLB Shootdown**: Implement Inter-Processor Interrupts (IPI) to invalidate TLB entries on other cores when modifying page tables.
- [x] **Cross-Core Wakeups**: Allow one core to wake a thread sleeping on another core (required for I/O completion).
- [x] **Fine-Grained Locking**: Break `process_tree_lock` and `fd_table` locks into more granular rw-locks.
- [x] **SMP Stability**: Fixed critical AP bootstrapping bugs (GS_BASE, IDT, FPU) and resolved boot-time race conditions.

### Phase 5: Advanced Userspace & Threading
- [X] **Multi-threading**: Implement `sys_clone` with `CLONE_THREAD` support (currently `ENOSYS`).
- [x] **Futexes**: FUTEX_WAIT/FUTEX_WAKE with timeout support implemented.
    - Basic wait/wake operations work
    - Timeout support with proper sleep list integration
    - Remaining: FUTEX_REQUEUE, robust futexes, priority inheritance
- [ ] **Signals**: Finish signal delivery logic. `checkSignals` exists but `sys_rt_sigreturn` context restoration needs validation against `sys_clone`.
- [ ] **VDSO**: Map a page into userspace for fast time/getcpu calls without syscall overhead.

### Phase 5.5: Memory mapping

Here is the step-by-step migration plan to implement Lazy (Demand) Paging in the Zscapek kernel.

### Step 1: Update `kernel/user_vmm.zig`
We need to modify the `Vma` structure to track the mapping type, remove eager allocation from `mmap`, and add the page fault handling logic.

```zig:kernel/user_vmm.zig
// [ADD] At the top with other imports
const process = @import("process");

// [ADD] VmaType enum definition
pub const VmaType = enum {
    Anonymous,
    File,
    Device,
};

// [MODIFY] Vma struct to include type
pub const Vma = struct {
    start: u64,
    end: u64,
    prot: u32,
    flags: u32,
    type: VmaType, // New field
    // ... existing fields ...
    
    // ... existing methods ...
};

// [MODIFY] createVma to initialize type
pub fn createVma(self: *UserVmm, start: u64, end: u64, prot: u32, flags: u32) !*Vma {
    const alloc = heap.allocator();
    const vma = try alloc.create(Vma);
    vma.* = Vma{
        .start = start,
        .end = end,
        .prot = prot,
        .flags = flags,
        .type = .Anonymous, // Default to Anonymous
        .next = null,
        .prev = null,
    };
    return vma;
}

// [MODIFY] mmap function to be Lazy
pub fn mmap(self: *UserVmm, addr: u64, len: usize, prot: u32, flags: u32) isize {
    // ... [Keep validation logic] ...

    // ... [Keep address finding logic (findFreeRange / MAP_FIXED checks)] ...
    // map_addr is determined here

    // [DELETE] The entire block allocating physical pages (pmm.allocZeroedPages)
    // [DELETE] The vmm.mapRange call

    // Create VMA to track this mapping
    const vma = self.createVma(map_addr, map_addr + aligned_len, prot, flags) catch {
        return Errno.ENOMEM.toReturn();
    };
    vma.type = .Anonymous;

    // Insert VMA into list
    self.insertVma(vma);
    self.total_mapped += aligned_len;

    console.debug("UserVmm: Lazy mmap {x}-{x} prot={x}", .{
        map_addr,
        map_addr + aligned_len,
        prot,
    });

    return @bitCast(map_addr);
}

// [ADD] Page Fault Handler
pub fn handlePageFault(self: *UserVmm, addr: u64, err_code: u64) bool {
    // 1. Find VMA covering the fault address
    var vma_iter = self.vma_head;
    var target_vma: ?*Vma = null;
    while (vma_iter) |v| {
        if (v.contains(addr)) {
            target_vma = v;
            break;
        }
        vma_iter = v.next;
    }
    
    const vma = target_vma orelse return false; // Segfault (Address not mapped)

    // 2. Check Permissions
    const is_write = (err_code & 2) != 0;
    if (is_write and (vma.prot & PROT_WRITE) == 0) {
        console.warn("PageFault: Write to Read-Only VMA at {x}", .{addr});
        return false; // Access violation
    }
    
    // 3. Allocate Physical Page
    const phys = pmm.allocZeroedPage() orelse {
        console.err("PageFault: OOM allocating page for {x}", .{addr});
        return false; // OOM
    };
    
    // 4. Map the page
    const page_base = addr & ~@as(u64, 0xFFF);
    const flags = vma.toPageFlags();
    
    vmm.mapPage(self.pml4_phys, page_base, phys, flags) catch {
        pmm.freePage(phys);
        return false;
    };
    
    return true; // Successfully handled
}
```

### Step 2: Update `kernel/syscall/mmio.zig`
Since we modified `Vma` and `createVma`, we need to ensure MMIO mappings (which *must* be eager) are marked correctly.

```zig:kernel/syscall/mmio.zig
// [MODIFY] sys_mmap_phys function
// ... after vmm.mapRange ...

// Create VMA
const vma = proc.user_vmm.createVma(
    virt_addr,
    virt_addr + aligned_size,
    user_vmm.PROT_READ | user_vmm.PROT_WRITE,
    user_vmm.MAP_SHARED | user_vmm.MAP_DEVICE,
) catch {
    // ... rollback logic ...
};
vma.type = .Device; // [ADD] Explicitly mark as Device

// ...
```

### Step 3: Update `arch/x86_64/interrupts.zig`
Hook up the page fault handler mechanism. We allow the kernel to register a handler callback to avoid circular dependencies between `hal` and `kernel`.

```zig:arch/x86_64/interrupts.zig
// [ADD] Global callback pointer
var page_fault_handler: ?*const fn (u64, u64) bool = null;

// [ADD] Setter for the handler
pub fn setPageFaultHandler(handler: *const fn (u64, u64) bool) void {
    page_fault_handler = handler;
}

// [MODIFY] exceptionHandler, case 14
14 => {
    const cr2 = cpu.readCr2();
    const err_code = frame.error_code;
    
    // Try to handle user page fault
    if ((frame.cs & 3) == 3 && page_fault_handler != null) {
        if (page_fault_handler.?(cr2, err_code)) {
             return; // Handled, retry instruction
        }
    }

    // Original dump logic...
    debug.dumpPageFaultInfo(frame);
    // ...
},
```

### Step 4: Register Handler in `kernel/main.zig`
Connect the kernel's logic to the HAL's interrupt handler.

```zig:kernel/main.zig
// [ADD] Import syscall_base to get access to current process
const base = @import("syscall_base");

// [ADD] Wrapper function that matches the HAL callback signature
fn pageFaultHandler(addr: u64, err_code: u64) bool {
    const proc = base.getCurrentProcess();
    const handled = proc.user_vmm.handlePageFault(addr, err_code);
    
    if (handled) {
        // Update RSS accounting (we allocated 1 page = 4KB)
        proc.rss_current += 4096;
    }
    
    return handled;
}

// [MODIFY] _start function (initialization)
export fn _start() noreturn {
    hal.init();
    
    // ... [after hal.init] ...
    
    // Register Page Fault Handler
    hal.interrupts.setPageFaultHandler(pageFaultHandler);
    
    // ... rest of init ...
}
```

### Checklist

1.  [x] **`kernel/user_vmm.zig`**: Add `VmaType` enum and field to `Vma`.
2.  [x] **`kernel/user_vmm.zig`**: In `mmap`, remove `allocZeroedPages` and `mapRange`. Only create VMA.
3.  [x] **`kernel/user_vmm.zig`**: Implement `handlePageFault(addr, err)` logic.
4.  [x] **`kernel/syscall/mmio.zig`**: Set `vma.type = .Device` in `sys_mmap_phys` and `sys_alloc_dma`.
5.  [x] **`arch/x86_64/interrupts.zig`**: Add `setPageFaultHandler` and call it in vector 14.
6.  [x] **`kernel/main.zig`**: Define handler wrapper and call `setPageFaultHandler`.

### Phase 6: Networking & Storage Optimization
Current status: Networking stack is in-kernel (hybrid) or userspace (VirtIO). Storage is synchronous SFS.

- [ ] **Netstack Process**: Move TCP/IP stack (`net/`) out of kernel into a dedicated `netstack` userspace process.
- [ ] **Zero-Copy Ring IPC**: Replace `sys_send`/`sys_recv` (memcpy) with shared memory rings (like io_uring) for high-bandwidth driver<->stack communication.
- [ ] **Async Disk I/O**:
    - Update `AHCI` driver to use `IoRequest` / Reactor pattern.
    - Update `SFS` to use async reads/writes via io_uring interface.

### Phase 7: Security & Robustness
- [ ] **IOMMU (VT-d)**: Implement DMAR parsing and page tables to restrict userspace drivers to their own DMA buffers.
- [ ] **ASLR**: Randomize heap, stack, and mmap base addresses.
- [ ] **User/Group Permissions**: Implement actual checks in VFS (currently stubs return 0 or EACCES statically).

### Phase 8: Bootloader (Optional "Flex")
- [ ] **UEFI Loader**: Replace Limine with custom Zig UEFI application (`src/boot/uefi`).
    - Parse ELF kernel.
    - Map kernel higher-half.
    - ExitBootServices and jump.

---

## 🐛 Known Issues / Technical Debt

1.  **Legacy PCI**: `pci_syscall.zig` assumes ECAM is available. Needs fallback for Legacy Port I/O PCI access for userspace drivers on older hardware.
2.  **Memory Reclamation**: `UserVmm` frees pages on process exit, but there is no swap or page eviction for memory pressure.
3.  **Double-Fault Handling**: Stack overflow in kernel mode currently relies on a small guard page. Double Fault (IDT 8) handler needs a dedicated IST stack (partially implemented in `gdt.zig` but needs verification).
4.  **Floppy Drive**: Just kidding.

## 🛠️ Refactoring Candidates

-   **`kernel/syscall/io.zig`**: `sys_read`/`sys_write` perform synchronous copies. Refactor to use `Reactor` internally for file types that support it (pipes, sockets).
-   **`drivers/video/console.zig`**: Console output holds a global spinlock. For high-volume logging, switch to a lock-free ring buffer consumed by a dedicated low-priority kernel thread.
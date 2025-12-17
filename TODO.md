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
- [ ] **Multi-threading**: Implement `sys_clone` with `CLONE_THREAD` support (currently `ENOSYS`).
- [ ] **Futexes**: Implement `sys_futex` for efficient userspace synchronization (required for `std.Thread` in userspace).
- [ ] **Signals**: Finish signal delivery logic. `checkSignals` exists but `sys_rt_sigreturn` context restoration needs validation against `sys_clone`.
- [ ] **VDSO**: Map a page into userspace for fast time/getcpu calls without syscall overhead.

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
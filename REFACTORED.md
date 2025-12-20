# Refactoring Plan (REFACTORED.md)

This document contains a detailed checklist for refactoring files larger than 400 lines in the `zigk` codebase.
The goal is to improve maintainability, verifyability, and logical separation of concerns.

## Strategy
1.  **Prioritize Core Kernel and Drivers**: Focus on `src/kernel`, `src/drivers`, and `src/arch`.
2.  **Split by Responsibility**: Create directory-level submodules.
3.  **Keep HAL Boundaries**: Split by hardware role, keep inline asm isolated.
4.  **UAPI/Net Layering**: Split by protocol/area.
5.  **Vendored Code**: Keep third-party code intact unless modifying.

## Refactor Checklist

### Kernel Core
#### [REFACTOR] src/kernel/sched.zig [DONE]
- [x] Create `src/kernel/sched/` directory
- [x] Move `Thread` struct and lifecycle to `src/kernel/sched/thread.zig`
- [x] Move `WaitQueue` and `ReadyQueue` logic to `src/kernel/sched/queue.zig`
- [x] Move `runScheduler` and core loop to `src/kernel/sched/scheduler.zig`
- [x] Move per-CPU data and logic to `src/kernel/sched/cpu.zig`
- [x] Create `src/kernel/sched/root.zig` explicitly exporting public API
- [x] Update call sites

#### [REFACTOR] src/kernel/process.zig [DONE]
- [x] Create `src/kernel/process/` directory
- [x] Move `Process` struct and types to `src/kernel/process/types.zig`
- [x] Move lifecycle logic (fork, exec, exit) to `src/kernel/process/lifecycle.zig`
- [x] Move IPC/Mailbox logic to `src/kernel/process/ipc.zig`
- [x] Move global manager/locking to `src/kernel/process/manager.zig`
- [x] Move capability/credential checks to `src/kernel/process/auth.zig`
- [x] Create `src/kernel/process/root.zig`

#### [REFACTOR] src/kernel/elf.zig [DONE]
- [x] Create `src/kernel/elf/` directory
- [x] Move ELF structs/types to `src/kernel/elf/types.zig`
- [x] Move `load()` and segment handling to `src/kernel/elf/loader.zig`
- [x] Move header validation to `src/kernel/elf/validation.zig`
- [x] Create `src/kernel/elf/root.zig`

#### [REFACTOR] src/kernel/syscall/io.zig [DONE]
- [x] Create `src/kernel/syscall/io/` directory
- [x] Move read/write/writev implementation to `src/kernel/syscall/io/read_write.zig`
- [x] Move ioctl implementation to `src/kernel/syscall/io/ioctl.zig`
- [x] Move stat/fstat to `src/kernel/syscall/io/stat.zig`
- [x] Move generic helpers to `src/kernel/syscall/io/utils.zig`
- [x] Create `src/kernel/syscall/io/root.zig`

#### [REFACTOR] src/kernel/syscall/io_uring.zig [DONE]
- [x] Create `src/kernel/syscall/io_uring/` directory
- [x] Move ring types/headers to `src/kernel/syscall/io_uring/types.zig`
- [x] Move SQ/CQ queue logic to `src/kernel/syscall/io_uring/queue.zig`
- [x] Move request processing to `src/kernel/syscall/io_uring/process.zig`
- [x] Move memory/setup logic to `src/kernel/syscall/io_uring/memory.zig`
- [x] Create `src/kernel/syscall/io_uring/root.zig`

### Drivers
#### [REFACTOR] src/drivers/net/e1000e/root.zig [DONE]
- [x] Create `src/drivers/net/e1000e/` directory (if not exists as package) or split root
- [x] Move Descriptors and Register definitions to `src/drivers/net/e1000e/types.zig`
- [x] Move Receive logic to `src/drivers/net/e1000e/rx.zig`
- [x] Move Transmit logic to `src/drivers/net/e1000e/tx.zig`
- [x] Move Init/Reset logic to `src/drivers/net/e1000e/init.zig`
- [x] Move Worker thread logic to `src/drivers/net/e1000e/worker.zig`
- [x] Cleanup `src/drivers/net/e1000e/root.zig` to only contain exports and struct definition

#### [REFACTOR] src/drivers/usb/xhci/ (root.zig, transfer.zig) [DONE]
- [x] Ensure `src/drivers/usb/xhci/` submodule structure is cleaner
- [x] Splits for `root.zig`:
    - [x] `src/drivers/usb/xhci/controller.zig`: Controller struct, init, reset
    - [x] `src/drivers/usb/xhci/events.zig`: Event ring and interrupt logic
    - [x] `src/drivers/usb/xhci/memory.zig`: Memory allocation and setup
- [x] Splits for `transfer.zig`:
    - [x] `src/drivers/usb/xhci/transfer/control.zig`: Control pipe logic
    - [x] `src/drivers/usb/xhci/transfer/bulk.zig`: Bulk pipe logic
    - [x] `src/drivers/usb/xhci/transfer/common.zig`: Wait/Completion helpers
- [x] Update `src/drivers/usb/xhci/root.zig` to export clean API

#### [REFACTOR] src/drivers/usb/class/hid.zig [DONE]
- [x] Create `src/drivers/usb/class/hid/` directory
- [x] Move Report Parser logic and types to `src/drivers/usb/class/hid/descriptor.zig`
- [x] Move Input event mapping to `src/drivers/usb/class/hid/input.zig`
- [x] Move Driver lifecycle to `src/drivers/usb/class/hid/driver.zig`
- [x] Create `src/drivers/usb/class/hid/root.zig`

#### [REFACTOR] src/drivers/audio/ac97.zig [DONE]
- [x] Create `src/drivers/audio/ac97/` directory
- [x] Move Register constants (`NABM_*`, `NAM_*`) to `src/drivers/audio/ac97/regs.zig`
- [x] Move Init/Reset logic to `src/drivers/audio/ac97/init.zig`
- [x] Move Mixer/Volume logic to `src/drivers/audio/ac97/mixer.zig`
- [x] Move Buffer/BDL management to `src/drivers/audio/ac97/buffer.zig` (integrated into types/init)
- [x] Move DSP/Processing logic to `src/drivers/audio/ac97/dsp.zig`
- [x] Create `src/drivers/audio/ac97/root.zig`

### Network Stack
#### [REFACTOR] src/net/ipv4/arp.zig [DONE]
- [x] Create `src/net/ipv4/arp/` directory
- [x] Move Cache management to `src/net/ipv4/arp/cache.zig`
- [x] Move Packet processing to `src/net/ipv4/arp/packet.zig`
- [x] Move Monitoring/Aging to `src/net/ipv4/arp/monitor.zig`
- [x] Create `src/net/ipv4/arp/root.zig`

#### [REFACTOR] src/net/ipv4/ipv4.zig
- [ ] Create `src/net/ipv4/` directory (if not exists as package)
- [ ] Move Option validation to `src/net/ipv4/validation.zig`
- [ ] Move Packet processing dispatch to `src/net/ipv4/process.zig`
- [ ] Ensure `src/net/ipv4/reassembly.zig` is used effectively (already exists)
- [ ] Create `src/net/ipv4/root.zig`

#### [REFACTOR] src/net/transport/tcp/ (rx.zig, tx.zig)
- [ ] Split `rx.zig` into:
    - [ ] `src/net/transport/tcp/rx/listen.zig` (processListenPacket)
    - [ ] `src/net/transport/tcp/rx/established.zig` (processEstablishedPacket)
    - [ ] `src/net/transport/tcp/rx/syn.zig` (processSynSent, processSynReceived)
    - [ ] `src/net/transport/tcp/rx/root.zig` (processPacket entry)
- [ ] Split `tx.zig` into:
    - [ ] `src/net/transport/tcp/tx/segment.zig` (sendSegment)
    - [ ] `src/net/transport/tcp/tx/control.zig` (sendSyn, sendSynAck, sendRst)

### UAPI
#### [REFACTOR] src/uapi/syscalls.zig
- [ ] Create `src/uapi/syscalls/` directory
- [ ] Move standard syscall numbers to `src/uapi/syscalls/linux.zig`
- [ ] Move custom/extension numbers to `src/uapi/syscalls/zscapek.zig`
- [ ] Move helper tables/maps (if any) to `src/uapi/syscalls/tables.zig`
- [ ] Create `src/uapi/syscalls/root.zig`

### Architecture (x86_64)
#### [REFACTOR] src/arch/x86_64/interrupts.zig
- [ ] Create `src/arch/x86_64/interrupts/` directory
- [ ] Move Exception Handler dispatch logic to `src/arch/x86_64/interrupts/handlers.zig`
- [ ] Move IRQ handling logic to `src/arch/x86_64/interrupts/irq.zig`
- [ ] Move Initialization and registration to `src/arch/x86_64/interrupts/init.zig`
- [ ] Create `src/arch/x86_64/interrupts/root.zig`

### Filesystem
#### [REFACTOR] src/fs/sfs.zig
- [ ] Create `src/fs/sfs/` directory
- [ ] Move Superblock and definitions to `src/fs/sfs/types.zig`
- [ ] Move Allocation (bitmap) logic to `src/fs/sfs/alloc.zig`
- [ ] Move Sector I/O logic to `src/fs/sfs/io.zig`
- [ ] Move File/Dir operations to `src/fs/sfs/ops.zig` (or split `file.zig`/`dir.zig` if complex)
- [ ] Create `src/fs/sfs/root.zig`

### Userland & Libraries
#### [REFACTOR] src/user/lib/syscall.zig
- [ ] Create `src/user/lib/syscall/` directory
- [ ] Move File I/O wrappers to `src/user/lib/syscall/io.zig`
- [ ] Move Process management wrappers to `src/user/lib/syscall/process.zig`
- [ ] Move Signal wrappers to `src/user/lib/syscall/signal.zig`
- [ ] Move Network wrappers to `src/user/lib/syscall/net.zig`
- [ ] Move Time/Sched wrappers to `src/user/lib/syscall/time.zig`
- [ ] Move Primitives (`syscall0`, etc) to `src/user/lib/syscall/primitive.zig`
- [ ] Create `src/user/lib/syscall/root.zig`

## Kernel Directory Organization Plan (Linux-inspired)
Goal: make `src/kernel/` look more like `linux/kernel`, `mm`, `ipc`, `fs`, `lib`, while preserving existing subsystems and HAL boundaries.

### Proposed Top-Level Buckets
- [ ] `src/kernel/core/`: kernel entry and boot lifecycle
    - [ ] Move `main.zig`, `boot.zig`, `init_hw.zig`, `init_mem.zig`, `init_fs.zig`, `init_proc.zig`
    - [ ] Keep `panic.zig` and `stack_guard.zig` in `core/` or `debug/` based on usage
- [ ] `src/kernel/mm/`: memory management (Linux `mm/`)
    - [ ] Move `pmm.zig`, `vmm.zig`, `user_vmm.zig`, `heap.zig`, `slab.zig`, `dma_allocator.zig`, `aslr.zig`, `tlb.zig`
    - [ ] Keep `kernel_stack.zig` here if it is allocator-backed
- [ ] `src/kernel/proc/`: processes, threads, signals, permissions (Linux `kernel/` + `ipc/`)
    - [ ] Move `process/`, `thread.zig`, `signal.zig`, `futex.zig`, `ipc/`, `capabilities/`, `perms.zig`
    - [ ] Keep scheduler under `sched/` and link via a `proc/root.zig` or `sched/root.zig` API
- [ ] `src/kernel/fs/`: kernel-facing filesystem glue
    - [ ] Move `devfs.zig`, `pipe.zig`, `fd.zig` and any VFS layer that currently lives in `src/kernel/`
    - [ ] Coordinate with `src/fs/` to avoid duplication (kernel VFS vs on-disk FS)
- [ ] `src/kernel/io/`: async I/O core and ring infrastructure
    - [ ] Keep existing `io/` and `ring.zig`
    - [ ] Move `futex.zig` here only if it is tied to io wait queues
- [ ] `src/kernel/sys/`: syscall dispatch, vdso, user ABI glue
    - [ ] Keep `syscall/`, move `vdso.zig`, `vdso_blob.zig`, `framebuffer.zig` if syscall related
- [ ] `src/kernel/debug/`: debug-only helpers (existing `debug/`)

### Staged Refactor Plan
- [ ] Stage 1: create `core/`, `mm/`, `proc/`, `fs/`, `io/`, `sys/` directories
    - [ ] Add `root.zig` shims that re-export current files to keep imports stable
    - [ ] Define import conventions: new code uses `kernel/<bucket>/root.zig`, old paths stay temporarily
    - [ ] Add `docs/FILESYSTEM.md` note that these are shims until moves complete
- [ ] Stage 2: move files into buckets in small batches
    - [ ] Batch A (core): `main.zig`, `boot.zig`, `init_*` files, `panic.zig`, `stack_guard.zig`
    - [ ] Batch B (mm): `pmm.zig`, `vmm.zig`, `user_vmm.zig`, `heap.zig`, `slab.zig`, `dma_allocator.zig`, `aslr.zig`, `tlb.zig`, `kernel_stack.zig`
    - [ ] Batch C (proc): `thread.zig`, `signal.zig`, `futex.zig`, `ipc/*`, `capabilities/*`, `perms.zig`, `sched/*`, `process/*`
    - [ ] Batch D (sys): `syscall/*`, `vdso*`, `framebuffer.zig`
    - [ ] Batch E (fs): `devfs.zig`, `pipe.zig`, `fd.zig`
    - [ ] After each batch: update imports, update `docs/FILESYSTEM.md`, run a build
- [ ] Stage 3: reduce cycles and stabilize APIs
    - [ ] Introduce `core/types.zig` or `proc/types.zig` for shared enums/structs
    - [ ] Replace deep relative imports with bucket `root.zig` exports
    - [ ] Delete old import paths only after all call sites move
- [ ] Stage 4: remove shims and finalize docs
    - [ ] Remove old file stubs and update any build scripts/module maps
    - [ ] Update `docs/FILESYSTEM.md` and `README.md` to reflect final layout

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
#### [REFACTOR] src/kernel/sched.zig
- [ ] Create `src/kernel/sched/` directory
- [ ] Move `Thread` struct and lifecycle to `src/kernel/sched/thread.zig`
- [ ] Move `WaitQueue` and `ReadyQueue` logic to `src/kernel/sched/queue.zig`
- [ ] Move `runScheduler` and core loop to `src/kernel/sched/scheduler.zig`
- [ ] Move per-CPU data and logic to `src/kernel/sched/cpu.zig`
- [ ] Create `src/kernel/sched/root.zig` explicitly exporting public API
- [ ] Update call sites

#### [REFACTOR] src/kernel/process.zig
- [ ] Create `src/kernel/process/` directory
- [ ] Move `Process` struct and types to `src/kernel/process/types.zig`
- [ ] Move lifecycle logic (fork, exec, exit) to `src/kernel/process/lifecycle.zig`
- [ ] Move IPC/Mailbox logic to `src/kernel/process/ipc.zig`
- [ ] Move global manager/locking to `src/kernel/process/manager.zig`
- [ ] Move capability/credential checks to `src/kernel/process/auth.zig`
- [ ] Create `src/kernel/process/root.zig`

#### [REFACTOR] src/kernel/elf.zig
- [ ] Create `src/kernel/elf/` directory
- [ ] Move ELF structs/types to `src/kernel/elf/types.zig`
- [ ] Move `load()` and segment handling to `src/kernel/elf/loader.zig`
- [ ] Move header validation to `src/kernel/elf/validation.zig`
- [ ] Create `src/kernel/elf/root.zig`

#### [REFACTOR] src/kernel/syscall/io.zig
- [ ] Create `src/kernel/syscall/io/` directory
- [ ] Move read/write/writev implementation to `src/kernel/syscall/io/read_write.zig`
- [ ] Move ioctl implementation to `src/kernel/syscall/io/ioctl.zig`
- [ ] Move stat/fstat to `src/kernel/syscall/io/stat.zig`
- [ ] Move generic helpers to `src/kernel/syscall/io/utils.zig`
- [ ] Create `src/kernel/syscall/io/root.zig`

#### [REFACTOR] src/kernel/syscall/io_uring.zig
- [ ] Create `src/kernel/syscall/io_uring/` directory
- [ ] Move ring types/headers to `src/kernel/syscall/io_uring/types.zig`
- [ ] Move SQ/CQ queue logic to `src/kernel/syscall/io_uring/queue.zig`
- [ ] Move request processing to `src/kernel/syscall/io_uring/process.zig`
- [ ] Move memory/setup logic to `src/kernel/syscall/io_uring/memory.zig`
- [ ] Create `src/kernel/syscall/io_uring/root.zig`

### Drivers
#### [REFACTOR] src/drivers/net/e1000e/root.zig
- [ ] Create `src/drivers/net/e1000e/` directory (if not exists as package) or split root
- [ ] Move Descriptors and Register definitions to `src/drivers/net/e1000e/types.zig`
- [ ] Move Receive logic to `src/drivers/net/e1000e/rx.zig`
- [ ] Move Transmit logic to `src/drivers/net/e1000e/tx.zig`
- [ ] Move Init/Reset logic to `src/drivers/net/e1000e/init.zig`
- [ ] Move Worker thread logic to `src/drivers/net/e1000e/worker.zig`
- [ ] Cleanup `src/drivers/net/e1000e/root.zig` to only contain exports and struct definition

#### [REFACTOR] src/drivers/usb/xhci/ (root.zig, transfer.zig)
- [ ] Ensure `src/drivers/usb/xhci/` submodule structure is cleaner
- [ ] Splits for `root.zig`:
    - [ ] `src/drivers/usb/xhci/controller.zig`: Controller struct, init, reset
    - [ ] `src/drivers/usb/xhci/events.zig`: Event ring and interrupt logic
    - [ ] `src/drivers/usb/xhci/memory.zig`: Memory allocation and setup
- [ ] Splits for `transfer.zig` (900+ lines):
    - [ ] `src/drivers/usb/xhci/transfer/control.zig`: Control pipe logic
    - [ ] `src/drivers/usb/xhci/transfer/bulk.zig`: Bulk pipe logic (if explicit)
    - [ ] `src/drivers/usb/xhci/transfer/common.zig`: Wait/Completion helpers
- [ ] Update `src/drivers/usb/xhci/root.zig` to export clean API

#### [REFACTOR] src/drivers/usb/class/hid.zig
- [ ] Create `src/drivers/usb/class/hid/` directory
- [ ] Move Report Parser logic and types to `src/drivers/usb/class/hid/descriptor.zig`
- [ ] Move Input event mapping to `src/drivers/usb/class/hid/input.zig`
- [ ] Move Driver lifecycle to `src/drivers/usb/class/hid/driver.zig`
- [ ] Create `src/drivers/usb/class/hid/root.zig`

#### [REFACTOR] src/drivers/audio/ac97.zig
- [ ] Create `src/drivers/audio/ac97/` directory
- [ ] Move Register constants (`NABM_*`, `NAM_*`) to `src/drivers/audio/ac97/regs.zig`
- [ ] Move Init/Reset logic to `src/drivers/audio/ac97/init.zig`
- [ ] Move Mixer/Volume logic to `src/drivers/audio/ac97/mixer.zig`
- [ ] Move Buffer/BDL management to `src/drivers/audio/ac97/buffer.zig`
- [ ] Move DSP/Processing logic to `src/drivers/audio/ac97/dsp.zig`
- [ ] Create `src/drivers/audio/ac97/root.zig`

### Network Stack
#### [REFACTOR] src/net/ipv4/arp.zig
- [ ] Create `src/net/ipv4/arp/` directory
- [ ] Move Cache and Entry logic to `src/net/ipv4/arp/cache.zig`
- [ ] Move Packet processing to `src/net/ipv4/arp/packet.zig`
- [ ] Move Conflict/Timeout monitoring to `src/net/ipv4/arp/monitor.zig`
- [ ] Create `src/net/ipv4/arp/root.zig`

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

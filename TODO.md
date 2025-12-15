# Architecture Pivot: Monolithic to Microkernel

| Goal | Status |
|------|--------|
| Zero-Cost HAL (comptime) | **Done** - MmioDevice wrapper with comptime offsets |
| Capabilities-Based Microkernel | Not implemented - drivers in kernel space |
| Asynchronous I/O | **Done** - io_uring syscalls, reactor pattern, timer wheel |
| Safe Unsafe Code | Well implemented - UserPtr, error handling, copyStructFromUser |

---

## Immediate Improvements (Low-Hanging Fruit)

### 1. Syscall Dispatch Optimization
**File:** `src/kernel/syscall/table.zig`

~~Current linear search is O(n). Use comptime to generate O(1) dispatch.~~

**Status: VERIFIED - No changes needed**

Disassembly confirmed LLVM already optimizes the `inline for` to jump tables:
```asm
jmpq *-0x7ff8dd18(,%rax,8)  ; Jump table dispatch
```

- [x] ~~Refactor syscall dispatch to use comptime-generated switch~~ (LLVM already optimizes)

### 2. Generic User Memory Copy
**File:** `src/kernel/syscall/user_mem.zig`

- [x] Add `copyStructFromUser(T, ptr)` generic wrapper
- [x] Add `copyStructToUser(T, ptr, value)` generic wrapper
- [x] Audit existing `copyFromUser` calls for migration

**Implementation:**
```zig
pub fn copyStructFromUser(comptime T: type, ptr: UserPtr) UserPtrError!T {
    comptime {
        if (@typeInfo(T) != .@"struct") {
            @compileError("copyStructFromUser requires a struct type");
        }
    }
    return ptr.readValue(T);
}
```

---

## Phase 1: Zero-Cost Hardware Interface - COMPLETE

Refactored MMIO and driver definitions to use comptime generation.

### Completed Tasks

- [x] **Created `MmioDevice` wrapper** in `src/arch/x86_64/mmio_device.zig`
  - Register offsets computed at comptime (zero runtime math)
  - Bounds checking only in Debug mode (zero-cost in release)
  - Type-safe `readTyped`/`writeTyped` with packed structs
  - Register names enforced by enum (typos caught at compile time)

- [x] **Refactored E1000e driver** (`src/drivers/net/e1000e/`)
  - Converted `Reg` struct to `enum(u64)` for comptime validation
  - Replaced `readReg(self, Reg.TCTL)` with `self.regs.read(.tctl)`
  - Updated `root.zig`, `rx.zig`, `tx.zig` to use MmioDevice

- [x] **Refactored USB drivers** (`src/drivers/usb/`)
  - Updated XHCI and EHCI to use `MmioDevice`
- [x] **Refactored AHCI driver** (`src/drivers/storage/ahci/`)
  - Updated port and root controllers to use `MmioDevice`

**New API:**
```zig
const Reg = enum(u64) { ctrl = 0x0000, status = 0x0008, ... };
const DeviceRegs = MmioDevice(Reg);

// Usage:
const status = self.regs.read(.status);
self.regs.write(.ctrl, value);
const ctrl = self.regs.readTyped(.ctrl, DeviceCtl);
```

---

## Phase 2: Async System Calls (The Reactor) - COMPLETE

Implemented io_uring-style async I/O with internal KernelIo interface.

See [docs/ASYNC.md](docs/ASYNC.md) for detailed documentation.

### Completed Tasks

- [x] **Core Infrastructure** (`src/kernel/io/`)
  - `types.zig` - IoRequest state machine, Future handle, IoResult union
  - `pool.zig` - Fixed-size request pool (256 concurrent operations)
  - `reactor.zig` - Global reactor singleton with timer management
  - `timer.zig` - Hierarchical 3-level timer wheel (1ms/256ms/65536ms)

- [x] **UAPI Structures** (`src/uapi/io_ring.zig`)
  - Linux-compatible SQE (64 bytes) and CQE (16 bytes)
  - IoUringParams for setup syscall
  - Operation codes: NOP, READ, WRITE, ACCEPT, CONNECT, RECV, SEND, TIMEOUT

- [x] **io_uring Syscalls** (`src/kernel/syscall/io_uring.zig`)
  - `sys_io_uring_setup` (425) - Create io_uring instance
  - `sys_io_uring_enter` (426) - Submit SQEs, wait for CQEs
  - `sys_io_uring_register` (427) - Resource registration (stub)

- [x] **Socket Async API** (`src/net/transport/socket/tcp_api.zig`)
  - `acceptAsync`, `connectAsync`, `recvAsync`, `sendAsync`
  - Completion hooks in `tcp/rx.zig` for TCP handshake and data receive

- [x] **Pipe Async Support** (`src/kernel/pipe.zig`)
  - `readAsync`, `writeAsync` functions
  - Completion on data transfer

- [x] **Keyboard Async Support** (`src/drivers/keyboard.zig`)
  - `getCharAsync` function
  - IRQ handler completes pending requests

- [x] **Integration**
  - Reactor initialized in `src/kernel/main.zig`
  - Timer tick registered via `net.tick()` -> `io.timerTick()`

---

## Phase 3: Microkernel Transition (create a new branch in git for this)

Move one driver to userspace to prove the concept. Start with UART (easiest).

### Tasks

- [ ] **Implement IPC syscalls**
  - `sys_send(target_pid, msg)` in `src/kernel/syscall/ipc.zig`
  - `sys_recv()` for receiving messages

- [ ] **Create Capability objects**
  - `InterruptCapability` kernel object
  - `sys_wait_interrupt(irq_cap)` syscall

- [ ] **Create userspace UART driver**
  - Move `src/drivers/serial/uart.zig` logic to `src/user/drivers/uart/main.zig`
  - Kernel `sys_write` to stdout sends IPC to UART driver process
  - UART driver waits for IPC, writes to I/O port, waits for interrupt

---

## Phase 2.5: Async Expansion (Post-Phase 2 Refinements)

Expand async I/O beyond networking to other subsystems.

- [ ] **Generic File I/O**
  - Update `IORING_OP_READ`/`WRITE` to dispatch based on FD type
  - Implement `fs.readAsync` and `fs.writeAsync`

- [ ] **Storage Async**
  - Implement async read/write for AHCI driver
  - Expose via `fs` layer for true async disk I/O

- [ ] **Mouse Async**
  - Implement `getEventAsync` in `src/drivers/mouse.zig`
  - Add `IORING_OP_READ` support for mouse fd


---

## Phase 4: UEFI Loader (Optional)

Replace Limine with custom Zig UEFI app to fully showcase Zig capabilities.

### Tasks

- [ ] **Create UEFI bootloader** at `src/boot/uefi/main.zig`
  - Use `std.os.uefi`
  - Entry point: `pub fn main() uefi.Status`

- [ ] **Implement ELF loading**
  - Parse `kernel.elf` with `std.elf`
  - Allocate memory via `boot_services.allocatePages`
  - Read kernel, map it, exit boot services, jump

- [ ] **Update build system**
  - Build UEFI executable as `BOOTX64.EFI`
  - Remove Limine dependency

---

## Priority Order

1. ~~**Immediate:** Syscall dispatch + user_mem generics~~ **DONE**
2. ~~**Phase 1:** Zero-cost HAL~~ **DONE**
3. ~~**Phase 2:** Async I/O (major architectural shift, high impact)~~ **DONE**
4. **Phase 3:** Microkernel transition (proves the architecture)
5. **Phase 4:** UEFI loader (optional, "flex" feature)

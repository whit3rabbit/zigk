# Architecture Pivot: Monolithic to Microkernel

## Current State Assessment

You have built a feature-rich **Monolithic Kernel** with:
- TCP/IP stack
- AHCI driver
- E1000e NIC driver
- Virtual File System
- Doom running in userland

**Gap Analysis:** The stated goals (Microkernel, Async I/O, Zero-cost abstractions) diverge from the current implementation.

| Goal | Status |
|------|--------|
| Zero-Cost HAL (comptime) | **Done** - MmioDevice wrapper with comptime offsets |
| Capabilities-Based Microkernel | Not implemented - drivers in kernel space |
| Asynchronous I/O | Not implemented - blocking syscalls |
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
- [ ] Audit existing `copyFromUser` calls for migration

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

## Phase 2: Async System Calls (The Reactor)

Move away from `sched.block()` inside syscalls to io_uring-style async.

### Tasks

- [ ] **Define ring buffer structures** in `src/uapi/io_ring.zig`
  - User -> Kernel submission queue
  - Kernel -> User completion queue

- [ ] **Implement `sys_submit_io` syscall**
  - Takes ring index, returns immediately
  - Add to `src/kernel/syscall/io.zig`

- [ ] **Refactor socket read path** (`src/net/transport/socket.zig`)
  - Return `error.WouldBlock` instead of blocking
  - Store continuation (request ID) in socket structure
  - On interrupt (`rx.zig`): push completion event instead of `sched.unblock()`

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
3. **Phase 2:** Async I/O (major architectural shift, high impact)
4. **Phase 3:** Microkernel transition (proves the architecture)
5. **Phase 4:** UEFI loader (optional, "flex" feature)

---

## Future Improvements (from Phase 1)

Other drivers that could benefit from MmioDevice refactoring:
- XHCI/EHCI USB controllers (currently duplicate readReg/writeReg patterns)
- AHCI storage controller
- Any new MMIO-based drivers

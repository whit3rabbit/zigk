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
| Zero-Cost HAL (comptime) | Partial - using packed structs but runtime MMIO |
| Capabilities-Based Microkernel | Not implemented - drivers in kernel space |
| Asynchronous I/O | Not implemented - blocking syscalls |
| Safe Unsafe Code | Well implemented - UserPtr, error handling |

---

## Immediate Improvements (Low-Hanging Fruit)

### 1. Syscall Dispatch Optimization
**File:** `src/kernel/syscall/table.zig`

Current linear search is O(n). Use comptime to generate O(1) dispatch.

```zig
// Current (slow):
inline for (handler_entries) |entry| { if (entry.value == syscall_num) ... }

// Better (O(1) switch):
switch (syscall_num) {
    inline for (handler_entries) |entry| {
        entry.value => return callHandler(...),
    }
    else => return error.ENOSYS,
}
```

- [ ] Refactor syscall dispatch to use comptime-generated switch

### 2. Generic User Memory Copy
**File:** `src/kernel/syscall/user_mem.zig`

Add type-safe wrapper to prevent buffer size mismatches at compile time.

```zig
pub fn copyStructFromUser(comptime T: type, ptr: UserPtr) !T {
    // Validates sizeof(T) automatically
}
```

- [ ] Add `copyStructFromUser(T, ptr)` generic wrapper
- [ ] Audit existing `copyFromUser` calls for migration

---

## Phase 1: Zero-Cost Hardware Interface

Refactor MMIO and driver definitions to use comptime generation.

### Tasks

- [ ] **Create `MmioStruct` wrapper** in `src/arch/x86_64/mmio.zig`
  ```zig
  pub fn MmioDevice(comptime T: type) type {
      return struct {
          base: usize,
          pub inline fn read(self: @This(), comptime field: []const u8) FieldType(T, field) {
              // Compile-time calculation of offset based on struct layout
          }
      };
  }
  ```

- [ ] **Refactor E1000e driver** (`src/drivers/net/e1000e/`)
  - Replace `readReg(self, Reg.TCTL)` with `self.regs.read("tctl")`
  - Proves Zig optimizes away offset math while enforcing types

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

1. **Immediate:** Syscall dispatch + user_mem generics (quick wins, improve existing code)
2. **Phase 1:** Zero-cost HAL (foundation for type-safe hardware access)
3. **Phase 2:** Async I/O (major architectural shift, high impact)
4. **Phase 3:** Microkernel transition (proves the architecture)
5. **Phase 4:** UEFI loader (optional, "flex" feature)

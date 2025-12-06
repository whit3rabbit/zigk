# Feature Specification: ARM AArch64 Hardware Abstraction Layer Portability

**Feature Branch**: `008-arm-hal-portability`
**Created**: 2025-12-05
**Status**: Draft
**Input**: Architecture the kernel for ARM/AArch64 portability by enforcing strict HAL boundaries, abstract I/O interfaces, and architecture-aware syscall constants

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Strict HAL Boundary Enforcement (Priority: P1)

As a kernel developer, I need all hardware-specific code (assembly, port I/O, register access) confined to the HAL directory so that adding ARM support later requires only implementing the HAL interface, not modifying kernel logic.

**Why this priority**: This is the foundational architectural constraint. If hardware code leaks into generic kernel code now, ARM support becomes a complete rewrite rather than a targeted implementation effort.

**Independent Test**: Run a static analysis or code review that verifies no assembly or volatile pointer access exists outside the HAL directory.

**Acceptance Scenarios**:

1. **Given** the kernel codebase, **When** searching for inline assembly outside HAL, **Then** zero matches are found.
2. **Given** a driver or kernel module, **When** it needs hardware access, **Then** it calls HAL interface functions, not direct port/register operations.
3. **Given** the scheduler or VMM, **When** they need architecture-specific operations, **Then** they use HAL abstractions like `hal.enableInterrupts()`.

---

### User Story 2 - Abstract Console/Serial Interface (Priority: P1)

As a kernel developer, I need debug output to go through a hardware-agnostic console interface so that debug logging works on both x86 (port 0x3F8) and ARM (MMIO at 0x09000000) without code changes.

**Why this priority**: Debug output is used everywhere in kernel development. If it's hardcoded to x86 ports, every debug statement becomes a porting blocker.

**Independent Test**: Write a message via `hal.console.write()` and verify it appears on both x86 QEMU (serial port) and ARM QEMU (PL011 UART) with identical kernel code.

**Acceptance Scenarios**:

1. **Given** generic kernel code calling console write, **When** running on x86, **Then** output goes to COM1 (port 0x3F8).
2. **Given** generic kernel code calling console write, **When** running on ARM (future), **Then** output goes to PL011 UART (MMIO 0x09000000).
3. **Given** the debug library, **When** it logs messages, **Then** it uses only HAL console functions, never direct port I/O.

---

### User Story 3 - Architecture-Aware Syscall Numbers (Priority: P1)

As a kernel developer, I need syscall numbers defined in a central location that varies by architecture so that Linux ABI compatibility works correctly on both x86_64 and AArch64.

**Why this priority**: x86_64 and AArch64 use completely different syscall numbers (e.g., write is 1 on x86, 64 on ARM). Hardcoding numbers makes ARM support impossible without major refactoring.

**Independent Test**: Compile the syscall dispatch for both architectures and verify the correct numbers are used (write=1 for x86, write=64 for ARM).

**Acceptance Scenarios**:

1. **Given** the syscall dispatch table, **When** compiled for x86_64, **Then** SYS_write is 1, SYS_exit is 60.
2. **Given** the syscall dispatch table, **When** compiled for AArch64, **Then** SYS_write is 64, SYS_exit is 93.
3. **Given** a new syscall addition, **When** a developer adds it, **Then** they add entries for all supported architectures in one place.

---

### User Story 4 - Abstract Interrupt Controller Interface (Priority: P2)

As a kernel developer, I need the scheduler to receive timer ticks through a generic interface so that it works with both x86 PIC/APIC and ARM GIC without modification.

**Why this priority**: The scheduler is core kernel logic that should be architecture-independent. If it knows about PIC vectors or GIC interrupt IDs, it becomes architecture-specific.

**Independent Test**: Trigger a timer interrupt on both architectures and verify `scheduler.tick()` is called identically on both.

**Acceptance Scenarios**:

1. **Given** the scheduler module, **When** inspected, **Then** it has no knowledge of PIC, APIC, or GIC.
2. **Given** the HAL timer implementation, **When** a timer interrupt fires, **Then** it calls `scheduler.tick()` as a callback.
3. **Given** a new interrupt source, **When** adding it, **Then** only HAL code changes, not scheduler or kernel code.

---

### User Story 5 - Abstract PCI Configuration Access (Priority: P2)

As a kernel developer, I need PCI configuration read/write to go through HAL so that PCI device drivers (like E1000) work on both x86 (port I/O 0xCF8/0xCFC) and ARM (MMIO ECAM).

**Why this priority**: The E1000 driver uses PCI to discover the network card. If PCI access is hardcoded to x86 ports, the network stack becomes architecture-specific.

**Independent Test**: Read a PCI device's vendor ID through `hal.pci.readConfig32()` on both architectures and get the same value.

**Acceptance Scenarios**:

1. **Given** the E1000 driver, **When** it reads PCI config, **Then** it calls `hal.pci.readConfig32()`, not direct port operations.
2. **Given** x86 HAL PCI implementation, **When** reading config, **Then** it uses ports 0xCF8/0xCFC.
3. **Given** ARM HAL PCI implementation (future), **When** reading config, **Then** it uses ECAM MMIO region.

---

### User Story 6 - Architecture-Specific Page Table Entry Format (Priority: P2)

As a kernel developer, I need page table entry bit manipulation in the HAL so that VMM logic stays generic while PTE formats differ between x86 and ARM.

**Why this priority**: Both architectures use 4-level page tables, but bit positions (Present, Writable, NX) differ. Generic VMM code should manage the tree structure while HAL handles the bits.

**Independent Test**: Map a page as read-only on both architectures and verify write attempts fault on both.

**Acceptance Scenarios**:

1. **Given** the VMM code, **When** it creates a mapping, **Then** it calls `hal.paging.mapPage()` with generic flags.
2. **Given** x86 HAL paging, **When** setting a page read-only, **Then** it clears the R/W bit (bit 1).
3. **Given** ARM HAL paging (future), **When** setting a page read-only, **Then** it sets the AP[2] bit appropriately.

---

### User Story 7 - Build System Architecture Selection (Priority: P3)

As a kernel developer, I need the build system to automatically select the correct HAL implementation based on target architecture so that cross-compilation "just works."

**Why this priority**: This enables the practical workflow of building for ARM without manual configuration changes.

**Independent Test**: Run `zig build -Dtarget=aarch64-freestanding` and verify it selects the ARM HAL module.

**Acceptance Scenarios**:

1. **Given** a build for x86_64, **When** HAL is resolved, **Then** it uses `src/hal/x86_64/mod.zig`.
2. **Given** a build for aarch64, **When** HAL is resolved, **Then** it uses `src/hal/aarch64/mod.zig`.
3. **Given** an unsupported architecture, **When** built, **Then** a clear compile error is produced.

---

### Edge Cases

- What happens when a driver accidentally uses direct port I/O? (Should fail to compile or be caught in review)
- How does the system handle architectures with different endianness?
- What happens when an architecture doesn't have PCI? (HAL returns "no devices found")
- How does the system handle different page sizes (4KB vs 16KB on some ARM)?
- What happens when syscall number tables are incomplete for an architecture?
- How does the system handle ARM hardware without a GIC (bare-metal timer interrupts)?

## Requirements *(mandatory)*

### Functional Requirements

**HAL Boundary Enforcement**

- **FR-001**: All inline assembly MUST be confined to files within `src/hal/` directory.
- **FR-002**: All volatile pointer access for MMIO MUST be confined to `src/hal/` directory.
- **FR-003**: Files in `src/kernel/` MUST NOT import architecture-specific modules directly.
- **FR-004**: HAL MUST expose a generic interface in `src/hal/generic.zig` that all architectures implement.

**Console Abstraction**

- **FR-005**: Debug output MUST go through `hal.console.write()` function.
- **FR-006**: Console interface MUST NOT expose port numbers or MMIO addresses to callers.
- **FR-007**: Serial/UART initialization MUST be handled by HAL, not generic kernel code.

**Syscall Number Management**

- **FR-008**: Syscall numbers MUST be defined in a single location that switches on target architecture.
- **FR-009**: Syscall dispatch MUST use these architecture-aware constants, not hardcoded numbers.
- **FR-010**: Adding a syscall MUST require adding entries for all supported architectures.

**Interrupt Abstraction**

- **FR-011**: Scheduler MUST receive timer events via a generic callback, not by knowing interrupt vector numbers.
- **FR-012**: HAL MUST provide `hal.interrupts.registerTimerCallback()` for scheduler integration.
- **FR-013**: Interrupt controller initialization (PIC/GIC) MUST be in HAL, not kernel code.

**PCI Abstraction**

- **FR-014**: Drivers MUST access PCI configuration via `hal.pci.readConfig*()` and `hal.pci.writeConfig*()`.
- **FR-015**: PCI functions MUST hide the underlying mechanism (ports vs MMIO) from callers.

**Paging Abstraction**

- **FR-016**: Page table entry manipulation MUST be in HAL (`hal.paging.mapPage()`, `hal.paging.unmapPage()`).
- **FR-017**: VMM logic (page table walking, free page tracking) MUST be in generic kernel code.
- **FR-018**: HAL paging MUST accept generic flags (read, write, execute) and translate to architecture bits.

**Build System**

- **FR-019**: Build system MUST select HAL implementation based on `builtin.cpu.arch`.
- **FR-020**: Build MUST fail with a clear error for unsupported architectures.
- **FR-021**: Cross-compilation to supported architectures MUST work without manual configuration.

### Key Entities

- **HAL (Hardware Abstraction Layer)**: Interface isolating hardware-specific code from generic kernel logic.
- **Console Interface**: Generic interface for text output regardless of underlying hardware (serial port, UART).
- **Syscall Number Table**: Architecture-indexed mapping of syscall names to numbers.
- **Interrupt Controller**: Abstract representation of PIC (x86) or GIC (ARM) for managing hardware interrupts.
- **PCI Configuration Space**: Hardware interface for discovering and configuring PCI devices.
- **Page Table Entry (PTE)**: Architecture-specific memory mapping descriptor with permission bits.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Zero inline assembly statements exist outside `src/hal/` directory.
- **SC-002**: Zero direct port I/O calls (outb/inb) exist outside `src/hal/` directory.
- **SC-003**: Kernel builds successfully for both x86_64 and aarch64 targets (aarch64 HAL may be stubbed).
- **SC-004**: All syscall numbers are defined in architecture-switched constants, not hardcoded.
- **SC-005**: Debug output works identically on x86 and ARM (when ARM HAL is implemented).
- **SC-006**: Adding ARM support requires only implementing HAL interface functions, no kernel logic changes.
- **SC-007**: PCI device discovery works through HAL interface on x86, ready for ARM ECAM.

## Assumptions

- Primary development target is x86_64; AArch64 is a future target.
- ARM support will use QEMU `-machine virt` which includes PCI support.
- Both architectures use 4-level paging with 4KB pages (ARM can also use 16KB/64KB but we target 4KB).
- Limine bootloader supports both architectures (it does).
- The HAL interface will be designed for the intersection of x86_64 and AArch64 capabilities.
- Platform-specific features (x86 TSC, ARM performance counters) are optional extensions, not core requirements.
- This specification establishes architectural constraints; actual ARM implementation is a separate future feature.

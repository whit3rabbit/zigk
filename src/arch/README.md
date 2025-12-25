# Hardware Abstraction Layer (HAL)

This repository contains a high-performance Hardware Abstraction Layer (HAL) written in Zig. It provides a unified, type-safe interface for kernel-level operations across x86_64 and AArch64 architectures.

## Architecture and Design

The HAL follows a **Provider Pattern**. The top-level `root.zig` detects the target architecture at compile time using `builtin.cpu.arch` and re-exports the appropriate implementation. This ensures that the core kernel remains architecture-agnostic while the HAL handles the specific hardware details.

### Core Differences
- **I/O Access**: x86_64 utilizes both Port I/O (`in`/`out`) and MMIO. AArch64 is strictly MMIO-based. Parity is maintained via stubs in the AArch64 implementation.
- **Interrupts**: x86_64 relies on the IDT (Interrupt Descriptor Table) and APIC. AArch64 uses VBAR (Vector Base Address Register) and the GIC (Generic Interrupt Controller).
- **Privilege Levels**: x86_64 manages transitions between Ring 3 (User) and Ring 0 (Kernel). AArch64 manages transitions between EL0 (User) and EL1 (Kernel).

## Project Structure

```text
.
├── root.zig                # Entry point; selects arch-specific implementation
├── aarch64/                # ARMv8-A implementation
│   ├── boot/               # entry.S, linker.ld
│   ├── kernel/             # GIC, Syscalls, Timing, CPU control
│   ├── mm/                 # Paging, MMIO, MMIO Device wrapper
│   └── root.zig            # Arch-specific exports
└── x86_64/                 # AMD64 implementation
    ├── boot/               # SMP Trampoline, linker.ld
    ├── kernel/             # APIC, GDT, IDT, PIC, PIT, Syscalls
    ├── lib/                # ISR stubs, safe copy helpers, optimized memcpy
    ├── mm/                 # Paging, IOMMU (VT-d), MMIO
    └── root.zig            # Arch-specific exports
```

## Security Invariants and Safety Instructions

To maintain kernel integrity and prevent privilege escalation, all developers and LLMs must adhere to these safety instructions:

### 1. Memory and Privilege Protection
- **SMAP Bracketing (x86_64)**: All assembly routines accessing user-space memory (e.g., `_asm_copy_from_user`) MUST bracket the access with `stac` (Set Alignment Check) and `clac` (Clear Alignment Check). Failure to do so will cause immediate faults when SMAP is enabled.
- **Canonical Address Validation**: The syscall entry point MUST validate that the return `RIP` in `RCX` (x86_64) or equivalent is canonical. Non-canonical addresses must be handled via a slow `iret` path to prevent hardware-level privilege escalation.
- **User Stack Validation**: When entering EL0/Ring 3, the kernel MUST verify the provided `stack_top` resides within the valid user-virtual range before performing any writes to the user stack.

### 2. Context Isolation
- **Thread-Local Storage (TLS)**: Context switches MUST save and restore TLS base registers (e.g., `TPIDR_EL0/1` for ARM, `FS/GS_BASE` for x86). Failure to do so leads to cross-thread data leakage.
- **SIMD/FPU State**: Use Lazy FPU switching (via `CR0.TS` on x86) or eager save/restore during `switchContext`. General-purpose registers alone are insufficient to isolate thread state.
- **Information Leakage**: All structures crossing protection boundaries (Kernel-to-User) or context boundaries (Thread-to-Thread) MUST be initialized with `std.mem.zeroes`. Avoid `undefined` for any field that could be exposed to a lower privilege level.

### 3. Hardware State Invariants
- **APIC ID Validation**: Never clamp or alias out-of-bounds CPU IDs to index `0`. If `lapic_id >= MAX_CPUS`, the HAL MUST `panic` immediately. Aliasing leads to critical race conditions and stack corruption.
- **Atomic Handler Registration**: All interrupt/exception callbacks stored as function pointers MUST be updated using `@atomicStore` with `.release` ordering and read with `.acquire`.
- **Dynamic MMIO Discovery**: Discourage hardcoded MMIO physical addresses. Prefer dynamic discovery via ACPI or Device Tree (FDT) to prevent memory collisions on different hardware revisions.

## Zig Best Practices (Zig-isms)

### Comptime and Type Safety
- **MMIO Device Wrapper**: Utilize `MmioDevice(comptime RegisterMap: type)`. This enforces that only valid enum-defined offsets are used, catching typos and invalid accesses at compile time.
- **Safe Integer Arithmetic**: Use `std.math.add` or `std.math.sub` for bounds checks in `MmioDevice`. Do not use wrapping arithmetic (`+%`) for address validation as it masks overflow vulnerabilities.
- **Packed Structs**: Hardware registers and table entries (PTEs, GDT entries) MUST be defined as `packed struct(uN)`. This guarantees exact bit-level layout matching hardware specifications.

### Resource Management
- **Freestanding Initialization**: Multi-stage hardware initialization (like SMP booting or IOMMU setup) MUST use `errdefer` to clean up previously allocated physical pages if a subsequent step fails.
- **Alignment**: Enforce hardware alignment requirements strictly using Zig’s `align(N)` attribute (e.g., 4096 for page tables, 16 for FPU state).

## Features and Roadmap

### Current Features
- **Multi-Core (SMP)**: Full AP bring-up for x86_64 via trampoline and SIPI sequences.
- **IOMMU**: Initial support for Intel VT-d (Root/Context tables and fault handling).
- **Safe User Copy**: Assembly helpers (`copy_from_user`) with integrated Page Fault fixup logic.
- **Hardware Entropy**: Support for `RDRAND`/`RDSEED` and AArch64 `FEAT_RNG`.

### Roadmap / Missing Features
- **GICv3/v4 Support**: AArch64 is currently limited to GICv2.
- **AArch64 IOMMU**: SMMU support is not yet implemented.
- **PCID Support**: Process Context Identifiers for x86_64 TLB optimization.
- **Entropy Hardening**: Removal of linear TSC-based fallbacks for critical security parameters.

## Developer and LLM Guidelines

### For Developers
1. **Logic Isolation**: The HAL provides the *mechanism* (how to switch context), never the *policy* (which thread to run). Keep the HAL stateless.
2. **Assembly Usage**: Reserve `.S` files for entry points and instructions Zig cannot generate. All control logic and data manipulation must reside in Zig.
3. **Hardware Parity**: Ensure new functionality in one architecture has at least a stub/interface parity in the other to maintain cross-platform builds.

### For LLMs (AI Analysis)
1. **Instruction Set Sensitivity**: Note that x86_64 uses `SWAPGS` for per-CPU data, while AArch64 utilizes system registers like `TPIDR_EL1`.
2. **Volatile Semantics**: When generating RMW (Read-Modify-Write) helpers, ensure the entire sequence is treated as volatile to prevent compiler reordering between the read and the final write.
3. **Register Bitfields**: Always represent hardware registers as `packed struct` with explicit bit-widths to ensure accuracy during synthesis.
# Hardware Abstraction Layer (HAL)

A high-performance, security-hardened Hardware Abstraction Layer (HAL) written in Zig. This library provides a unified, type-safe interface for kernel-level operations across **x86_64** (AMD64) and **AArch64** (ARMv8-A) architectures.

## Architectural Design

The HAL utilizes a **Provider Pattern**. The top-level `root.zig` selects the target architecture at compile time, ensuring the core kernel remains architecture-agnostic while the HAL manages low-level hardware orchestration.

### Implementation Principles
*   **Mechanism vs. Policy**: The HAL provides the hardware mechanisms (context switching, page table manipulation, interrupt routing) but does not define kernel policy (scheduling algorithms, memory allocation strategy).
*   **Zero-Cost Abstractions**: Leveraging Zig's `comptime` and `inline` capabilities, hardware access carries no runtime overhead compared to manual assembly.
*   **Hardware Parity**: Where possible, subsystems are standardized. For example, AArch64 utilizes the same `SyscallFrame` field names as x86_64 to allow shared syscall dispatch logic.

## Feature Matrix

| Subsystem | x86_64 Support | AArch64 Support |
| :--- | :--- | :--- |
| **Interrupts** | APIC (Local/IO), IDT, PIC | GICv2, Exception Vectors (VBAR) |
| **Symmetric Multi-Processing** | Full (Trampoline + SIPI) | Initialized (Single Core Focus) |
| **Paging** | 4-Level (PML4) | 4-Level (L0-L3), 4KB Granule |
| **IOMMU** | Intel VT-d (DRHD/Faults) | Planned (SMMU) |
| **Hardware Entropy** | `RDRAND`, `RDSEED` | `FEAT_RNG` (RNDR) |
| **Security Features** | SMEP, SMAP, Paranoid ISR | PAN (Privileged Access Never) |
| **FPU Management** | FXSAVE/FXRSTOR (SSE) | NEON (Q0-Q31) |

## Security Invariants

The following invariants are strictly enforced to maintain kernel integrity and prevent privilege escalation:

### 1. User/Kernel Isolation
*   **Privileged Access Prevention**: On AArch64, **PAN** is enabled globally; kernel code is prohibited from accessing user memory via standard load/store instructions. Developers must use the provided `LDTR`/`STTR` assembly helpers. On x86_64, **SMAP** requires explicit `stac`/`clac` bracketing.
*   **Return Validation**: The x86_64 syscall entry point validates that the return `RIP` is canonical to prevent Intel-specific privilege escalation vulnerabilities. AArch64 validates that the `ELR` (Exception Link Register) does not point into kernel space when returning to EL0.
*   **Register Sanitization**: All general-purpose registers are cleared before transitioning to userspace to prevent information leakage and speculative execution gadgets.

### 2. Memory Protection
*   **HHDM Guarding**: Higher-Half Direct Map (HHDM) conversions (`physToVirt`) include mandatory overflow checks. If a physical address calculation wraps into user-virtual space, the HAL will trigger an immediate panic.
*   **MMIO Bounds Enforcement**: The `MmioDevice` wrapper enforces bounds checking on register offsets in both `Debug` and `ReleaseSafe` modes to prevent accidental corruption of adjacent hardware registers.

### 3. Entropy Quality Standards
*   The entropy subsystem distinguishes between `.high` quality (Hardware RNG) and `.low` quality (Timing-based jitter).
*   **Strict Mode**: Security-critical operations (e.g., generating cryptographic keys) should use `fillWithHardwareEntropyStrict()`, which panics if high-quality hardware entropy is unavailable, rather than falling back to weak timing sources.

## Developer Technical Reference

### Cross-Architecture Syscall Compatibility
To facilitate code sharing, the `SyscallFrame` utilizes x86_64 naming conventions even on AArch64. Developers working on architecture-independent code must use these aliases:
*   `rax` → `x0` (Return Value / Argument 0)
*   `rdi` → `x1` (Argument 1)
*   `rsi` → `x2` (Argument 2)
*   `rdx` → `x3` (Argument 3)
*   `rbp` → `x29` (Frame Pointer)
*   `r15` → `x30` (Link Register)

### Type-Safe MMIO
Direct memory manipulation is discouraged. Hardware drivers should define a register map enum and use the `MmioDevice` wrapper:
```zig
const DeviceRegs = enum(u32) {
    Control = 0x00,
    Status = 0x04,
    Data = 0x08,
};

const dev = mmio_device.MmioDevice(DeviceRegs).init(base_addr, size);
dev.write(.Control, 0x1); // Comptime validated and bounds checked
```

### Atomic Interrupt Registration
Interrupt and exception handler registration is atomic. Developers must use the provided `setHandler` functions (e.g., `setTimerHandler`, `setKeyboardHandler`). This prevents torn pointer reads on SMP systems and ensures proper memory ordering (`acquire`/`release` semantics).

### Context Switching Requirements
The `switchContext` mechanism is designed to be minimal. SIMD/FPU registers are **not** saved automatically during a standard switch. The scheduler must manage `FpuState` explicitly using `fxsave`/`fxrstor` (x86) or the NEON save/restore helpers (ARM).

## Project Structure

The HAL is organized by architecture, with shared patterns implemented within each:

*   `root.zig`: Central entry point and architecture selector (Unified HAL API).
*   `x86_64/`: Implementation for AMD64 systems.
    *   `boot/`: Bootloader-specific entry points and handoff.
    *   `kernel/`: Interrupt controllers (APIC), syscall entry points, and GDT/IDT.
    *   `mm/`: Paging, MMIO wrappers, and IOMMU (VT-d).
    *   `lib/`: Optimized assembly helpers.
*   `aarch64/`: Implementation for ARMv8-A systems.
    *   `boot/`: Low-level exception vector setup and boot handoff.
    *   `kernel/`: GICv2 implementation, exception routing, and syscalls.
    *   `mm/`: AArch64 paging (4KB granules) and MMIO.
    *   `lib/`: ARM-specific assembly utilities.

## Unified HAL API

The HAL exposes a consistent interface via `src/arch/root.zig`. Kernel-level code should consume features through this unified layer rather than importing architecture-specific files directly.

```zig
const arch = @import("arch");

// Example: Writing to the early serial console
arch.earlyPrint("HAL Initialized\n");

// Example: Accessing CPU features
const cpu_id = arch.cpu.getCoreId();
```

## Roadmap

*   Implementation of GICv3 and GICv4 support for AArch64.
*   Expansion of ARM SMMU support for IOMMU parity.
*   Integration of PCID (Process Context ID) for x86_64 TLB optimization.
*   Implementation of 5-level paging support for modern x86_64 processors.
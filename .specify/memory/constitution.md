<!--
=============================================================================
SYNC IMPACT REPORT
=============================================================================
Version change: 1.0.0 → 1.1.0 (MINOR - new principles added)

Modified principles: None (existing principles unchanged)

Added sections:
  - Principle VI: Strict Layering (Kernel/HAL separation)
  - Principle VII: Zero-Copy Networking (pointer-based packet handling)
  - Principle VIII: Capability-Based Security (syscall enforcement)
  - Principle IX: Heap Hygiene (allocation tracking, leak prevention)

Removed sections: None

Templates requiring updates:
  - .specify/templates/plan-template.md: ✅ compatible (Constitution Check section
    will dynamically read principles from this file)
  - .specify/templates/spec-template.md: ✅ compatible (no principle-specific content)
  - .specify/templates/tasks-template.md: ✅ compatible (no principle-specific content)

Follow-up TODOs: None
=============================================================================
-->

# ZigK Constitution

## Core Principles

### I. Bare-Metal Zig

All kernel code MUST be written in Zig targeting freestanding x86_64. No standard library
runtime, no libc, no external dependencies beyond the Limine bootloader protocol. Inline
assembly is permitted ONLY for hardware operations that cannot be expressed in safe Zig
(e.g., HLT instruction, port I/O, control register access).

**Rationale**: A kernel operates without an OS underneath—dependencies on hosted runtimes
are impossible. Zig's comptime and freestanding target provide the necessary control.

### II. Limine Protocol Compliance

The kernel MUST boot exclusively via the Limine bootloader protocol. All boot-time
resources (framebuffer, memory map, RSDP, kernel address) MUST be obtained through
Limine request structures. The kernel MUST NOT assume specific memory layouts beyond
what Limine guarantees.

**Rationale**: Limine provides a modern, well-documented boot protocol that handles
mode switching and hardware initialization, allowing the kernel to focus on OS logic.

### III. Minimal Viable Kernel

Each milestone MUST produce a bootable, testable artifact. Features MUST be added
incrementally: first boot → framebuffer → halt loop → memory → interrupts. No feature
may be merged that breaks the boot-to-halt cycle. YAGNI applies strictly—implement
only what the current milestone requires.

**Rationale**: Kernel development is unforgiving; a broken boot path blocks all progress.
Incremental, verifiable milestones ensure continuous forward motion.

### IV. QEMU-First Verification

All kernel functionality MUST be verifiable in QEMU x86_64 before any bare-metal testing.
The build system MUST produce a bootable ISO image. A `make run` or equivalent MUST
launch QEMU with the kernel. Visual output (framebuffer color) serves as the initial
verification mechanism.

**Rationale**: QEMU provides rapid iteration, debugging (via `-d` flags), and deterministic
testing without hardware dependencies.

### V. Explicit Memory and Hardware

Memory operations MUST be explicit: no hidden allocations, no implicit copies. Hardware
access MUST use volatile pointers or inline assembly. All memory regions obtained from
Limine MUST be validated before use. Undefined behavior is unacceptable—use Zig's
safety features where possible, disable only with explicit justification.

**Rationale**: Kernel code has no safety net. Implicit operations hide bugs that manifest
as silent corruption or triple faults.

### VI. Strict Layering

The Kernel MUST be architecturally distinct from the Hardware Abstraction Layer (HAL).
Higher-level subsystems (networking, filesystem, scheduling) MUST NOT directly access
CPU registers, port I/O, or memory-mapped hardware. All hardware interaction MUST flow
through the HAL's defined interfaces. Networking code specifically MUST NOT touch CPU
registers directly; it MUST use HAL-provided abstractions.

**Rationale**: Strict layering enables portability across architectures, simplifies testing
(HAL can be mocked), and prevents subtle bugs from scattered hardware access patterns.
A networking stack that manipulates CR3 directly is unmaintainable and unportable.

### VII. Zero-Copy Networking

Network packet handling MUST prefer passing pointers over copying data buffers. When a
packet arrives, its buffer MUST be passed by reference through the network stack layers
rather than being copied at each layer. Copies are permitted ONLY when crossing trust
boundaries (userspace ↔ kernel) or when buffer lifetime cannot be guaranteed.

**Rationale**: Memory bandwidth is precious in kernel context. Copying a 1500-byte packet
multiple times per layer wastes cycles and cache. Zero-copy maintains performance and
minimizes memory footprint, critical for high-throughput networking.

### VIII. Capability-Based Security

Userland processes MUST have zero direct hardware access. All hardware interaction from
userspace MUST occur through defined syscall interfaces. The kernel MUST validate every
syscall, checking capabilities before granting access to resources. No userland code may
execute privileged instructions, access I/O ports, or map physical memory directly.

**Rationale**: Direct hardware access from userspace enables trivial privilege escalation.
Capability-based security ensures the kernel mediates all sensitive operations, enabling
fine-grained access control and audit logging.

### IX. Heap Hygiene

All dynamic memory allocations within the kernel MUST be tracked. Every allocation MUST
have a corresponding deallocation path. Memory leaks in the kernel are considered fatal
defects—the kernel MUST NOT leak memory under any code path. Allocation failures MUST
be handled explicitly; silent allocation failure leading to null pointer use is
unacceptable.

**Rationale**: Unlike userspace processes, the kernel cannot be restarted to reclaim
leaked memory. A leaking kernel will eventually exhaust available memory, causing system
failure. Tracked allocations enable leak detection tooling and enforce discipline.

## Technical Constraints

**Target Architecture**: x86_64 (long mode, 64-bit)
**Bootloader**: Limine (v5+ protocol)
**Language**: Zig (latest stable, freestanding target)
**Build Output**: ELF kernel binary + bootable ISO
**Emulation**: QEMU x86_64 with `-cdrom` or `-hda` boot
**Initial Verification**: Framebuffer fill (solid color proves video memory control)

**Prohibited**:
- Standard library beyond `@import("builtin")` and comptime utilities
- Dynamic memory allocation before a heap is explicitly implemented
- Floating-point operations in kernel context (FPU state not preserved)
- External C libraries or FFI
- Direct hardware access from layers above the HAL (per Principle VI)
- Userspace direct hardware access (per Principle VIII)

## Development Workflow

1. **Specification First**: Each feature begins with a spec defining boot behavior,
   hardware interaction, and verification method.

2. **Build-Test Cycle**: Every commit MUST produce a bootable ISO. CI (if present)
   MUST run `qemu-system-x86_64 -cdrom kernel.iso -display none -serial stdio` and
   verify expected output or lack of triple fault.

3. **Incremental Complexity**: Memory management before interrupts. Interrupts before
   scheduling. Scheduling before userspace. No skipping layers.

4. **Documentation as Code**: Limine protocol usage, memory map interpretation, and
   hardware register manipulation MUST be documented inline or in companion docs.

5. **Layer Verification**: Code reviews MUST verify that subsystem code respects layer
   boundaries. Networking, filesystem, and scheduler code MUST NOT contain inline
   assembly or direct port I/O—only HAL calls.

6. **Allocation Auditing**: All code paths introducing dynamic allocation MUST document
   the deallocation strategy. PR descriptions MUST note new allocations and their
   lifecycle management.

## Governance

This constitution supersedes all other development practices for the ZigK project.
Amendments require:

1. Written proposal with rationale
2. Verification that the change does not break existing boot functionality
3. Version increment following semantic versioning:
   - MAJOR: Principle removal or redefinition
   - MINOR: New principle or section added
   - PATCH: Clarification or wording refinement

Compliance review: All code contributions MUST demonstrate adherence to the nine
core principles. Complexity beyond minimal viable implementation requires explicit
justification in the PR description.

**Version**: 1.1.0 | **Ratified**: 2025-12-04 | **Last Amended**: 2025-12-04

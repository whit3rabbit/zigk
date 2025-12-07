# Boot Process Documentation

## Overview
ZigK uses the **Multiboot2** protocol for booting. This allows it to be loaded by compliant bootloaders like GRUB2.
The kernel is compiled as a 64-bit ELF binary but is linked and loaded as a **Flat Binary** at a fixed physical address to ensure compatibility with linker section layouts.

## Boot Flow
1.  **BIOS/UEFI** hands control to the Bootloader (GRUB2).
2.  **GRUB2** reads the ISO/Disk and locates the Multiboot2 Header.
3.  **GRUB2** loads the kernel binary into memory at physical address `0x01000000` (16MB).
4.  **GRUB2** transitions to 32-bit Protected Mode and jumps to the kernel entry point (`_start32`).
5.  **Kernel Bootstrap (`boot32.S`)**:
    - Disables interrupts.
    - Sets up provisional page tables (Identity + Higher-Half + HHDM).
    - Enables PAE, Long Mode (EFER.LME), and Paging (CR0.PG).
    - Jumps to 64-bit Long Mode code (`_start64`).
6.  **Kernel Main**:
    - `_start64` sets up the stack and jumps to Zig `kmain`.

## Multiboot2 Header Layout
The kernel includes a Multiboot2 header within the first 32KB of the binary. This header specifies how the bootloader should load the kernel.

**Magic Value:** `0xE85250D6`
**Architecture:** `0` (i386/Protected Mode)
**Load Address:** `0x01000000` (16MB)

### Header Structure (ASCII Chart)

```text
+-------------------+----------------+-----------------------------------------+
| Field             | Value (Hex)    | Description                             |
+-------------------+----------------+-----------------------------------------+
| Magic             | 0xE85250D6     | Multiboot2 Magic Number                 |
| Architecture      | 0x00000000     | i386 (Protected Mode)                   |
| Header Length     | [Calculated]   | Total size of header + tags             |
| Checksum          | [Calculated]   | -(Magic + Arch + Length)                |
+-------------------+----------------+-----------------------------------------+
| Tag: Address (Type 2)                                                        |
+-------------------+----------------+-----------------------------------------+
| Type              | 0x0002         | Address Tag                             |
| Flags             | 0x0001         | Required (Bootloader must process)      |
| Size              | 24 bytes       |                                         |
| Header Addr       | 0x01000000     | Physical address of this header         |
| Load Addr         | 0x01000000     | Physical address to load segment at     |
| Load End Addr     | 0x00000000     | 0 = Load entire file                    |
| BSS End Addr      | 0x01500000     | Physical address end of BSS (Reserved)  |
+-------------------+----------------+-----------------------------------------+
| Tag: End (Type 0)                                                            |
+-------------------+----------------+-----------------------------------------+
| Type              | 0x0000         | End Tag                                 |
| Flags             | 0x0000         |                                         |
| Size              | 8 bytes        |                                         |
+-------------------+----------------+-----------------------------------------+
```

## Why Flat Binary?
We use a valid ELF64 binary during compilation but strip it to a Flat Binary (`kernel.bin`) for the final ISO.
This is done because standard linkers (like LLD) may introduce alignment gaps between ELF sections (e.g., jumping from 1MB to 2MB).
The Multiboot2 **Address Tag** forces the bootloader to load the file as a contiguous block at `0x01000000`, bypassing ELF parsing logic that might fail due to these gaps.

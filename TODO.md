## Phase 9: Bootloader (Optional)

### 10. Custom UEFI Loader

**Current State:** Limine provides complete boot services. Replacement is significant effort.

**Key Findings:**
- Limine provides: memory map, HHDM (0xFFFF800000000000), framebuffer, modules, RSDP
- Kernel entry at `_start()` expects 64-bit long mode, paging enabled, interrupts disabled
- Higher-half kernel linked to 0xFFFFFFFF80000000 (fixed in linker.ld)
- CS reload mandatory after GDT switch (documented critical bug in BOOT.md)
- ELF loading code exists in `src/kernel/elf.zig` (reusable for bootloader)
- Module loading documented in init_proc.zig

**Key Files:**
- `src/lib/limine.zig` - Limine protocol structures
- `src/kernel/boot.zig` - Boot request definitions
- `src/kernel/main.zig:165-249` - Boot protocol validation
- `src/arch/x86_64/boot/linker.ld` - Kernel link address
- `docs/BOOT_ARCHITECTURE.md`, `docs/BOOT.md` - Boot documentation

**Sub-Tasks:**
- [ ] **UEFI Application:** Create `src/boot/uefi/main.zig` target
- [ ] **ELF Parsing:** Implement ELF64 loader (reuse from kernel/elf.zig)
- [ ] **Memory Map:** UEFI GetMemoryMap -> Limine-compatible format
- [ ] **GOP Setup:** Initialize Graphics Output Protocol
- [ ] **ExitBootServices:** Handover to kernel entry point

**Effort:** Very High (~2000+ lines, PE32+ target, UEFI protocol complexity)

Migrating from Limine to a custom UEFI bootloader is a significant undertaking. It shifts the responsibility of hardware initialization, memory map parsing, ELF loading, and page table construction from a mature external tool to your own code.

However, it gives you complete control over the machine state at `_start` and removes external dependencies.

Here is the architectural plan to migrate Zscapek to a custom UEFI loader.

### 1. The Strategy: "The Boot Info Contract"

Currently, your kernel relies on **Requests** (kernel asks, bootloader fills).
We will switch to a **Handover** model (bootloader prepares specific struct, passes pointer to kernel).

We need to define a `BootInfo` struct that contains everything the kernel currently gets from Limine.

#### New File: `common/boot_info.zig`
This file will be shared between the Bootloader and the Kernel.

```zig
pub const BootInfo = extern struct {
    // Memory
    memory_map: [*]MemoryDescriptor,
    memory_map_count: usize,
    descriptor_size: usize,
    
    // Video (Framebuffer)
    fb_addr: u64,
    fb_size: usize,
    fb_width: u32,
    fb_height: u32,
    fb_pitch: u32,
    // (Add RGB mask shifts here matching Limine's format)

    // ACPI
    rsdp_addr: u64,

    // Modules (InitRD)
    initrd_addr: u64,
    initrd_size: u64,

    // Addressing
    hhdm_offset: u64, // Usually 0xFFFF800000000000
    kernel_phys_base: u64,
    kernel_virt_base: u64,
};

pub const MemoryDescriptor = extern struct {
    type: u32, // EfiMemoryType
    phys_start: u64,
    virt_start: u64,
    num_pages: u64,
    attribute: u64,
};
```

---

### 2. The Migration Roadmap

#### Step 1: Create the UEFI Bootloader Application
We need a separate Zig executable target that compiles to `BOOTX64.EFI`.

**`build.zig` addition:**
```zig
const bootloader = b.addExecutable("bootx64", "src/boot/uefi/main.zig");
bootloader.setTarget(.{
    .cpu_arch = .x86_64,
    .os_tag = .uefi,
    .abi = .msvc, 
});
bootloader.install();
```

#### Step 2: Implement UEFI Logic
The bootloader must perform these specific tasks in order:

1.  **Initialize UEFI Services:** Get handles for `SimpleFileSystem` (disk access) and `GraphicsOutput` (GOP).
2.  **Load Files:** Load `kernel.elf` and `initrd.tar` from the EFI partition into memory.
3.  **Parse ELF:** The UEFI loader must read the ELF headers of the kernel to find `PT_LOAD` segments.
4.  **Allocate Kernel Memory:** Use UEFI `AllocatePages` to reserve physical memory where the kernel wants to be loaded.
5.  **Get Hardware Info:**
    *   Find RSDP (scan System Table ConfigurationTables).
    *   Get Framebuffer info from GOP.
6.  **ExitBootServices:** This is the point of no return. The firmware shuts down.
7.  **Setup Paging (The Hard Part):**
    *   Limine currently creates your Page Tables (PML4). You must now do this.
    *   Map the Kernel to High Memory (e.g., `0xFFFFFFFF80000000`).
    *   Map Physical Memory to HHDM (e.g., `0xFFFF800000000000`).
    *   Identity map the lower 4GB (temporarily) so the CPU doesn't crash immediately after enabling paging.
8.  **Jump:** Load the new CR3 (page table) and jump to the kernel entry point, passing the `&BootInfo` pointer in `RDI` (System V ABI).

#### Step 3: Refactor Kernel Entry (`kernel/main.zig`)

Currently, your kernel looks for Limine requests in `.bss` or `.data`. We need to abstract this.

**Create `kernel/boot_interface.zig`:**
This file will detect if we were booted via Limine or Custom UEFI (or simply define a unified interface).

**Update `kernel/main.zig`:**

```zig
// Old way:
// framebuffer.initFromLimine(&boot.framebuffer_request);

// New way (Conceptual):
export fn _start(boot_info: *const BootInfo) noreturn {
    // 1. Initialize HAL using the passed struct, not global Limine vars
    hal.paging.init(boot_info.hhdm_offset);
    
    // 2. Initialize PMM
    pmm.initFromInfo(boot_info.memory_map, boot_info.memory_map_count);
    
    // ...
}
```

---

### 3. Detailed Task List for Migration

Here is the concrete set of tasks to add to your roadmap.

#### A. Build System & Skeleton
- [ ] **Configure Build:** Add a `bootx64` target to `build.zig` targeting `x86_64-uefi-msvc`.
- [ ] **Basic UEFI App:** Create `src/boot/uefi/main.zig` that prints "Hello Zscapek" using `uefi.system_table.con_out` and waits for a keypress.

#### B. File Loading & Parsing
- [ ] **Protocol Access:** Implement helper to open the EFI Volume and File Protocol.
- [ ] **ELF Parser:** Write a standalone ELF64 parser in the bootloader.
    *   Must validate magic.
    *   Must iterate Program Headers (`Phdr`).
    *   Must identify `PT_LOAD` segments.
- [ ] **Loader:** Read `kernel.elf` into a temporary buffer, parse it, allocate specific physical pages for segments, and copy data.

#### C. Memory & Graphics Setup
- [ ] **GOP Setup:** Query UEFI Graphics Output Protocol. Select the best mode. Populate `BootInfo.fb_*`.
- [ ] **RSDP Lookup:** Iterate `SystemTable.ConfigurationTable` to find the ACPI 2.0 GUID.
- [ ] **Memory Map:** Call `GetMemoryMap`. **Crucial:** This must be done *immediately* before `ExitBootServices` because allocating memory changes the map.

#### D. Paging & Handover (The Critical Path)
- [ ] **Page Table Builder:** Implement a lightweight VMM in the bootloader.
    *   Allocate pages for PML4, PDPT, PD, PT.
    *   Map Kernel Virtual -> Kernel Physical.
    *   Map HHDM Virtual -> Physical 0.
    *   Map 0 -> 0 (Identity) for the transition.
- [ ] **ExitBootServices:** Call `bs.exitBootServices()`.
- [ ] **State Switch:**
    *   Disable Interrupts (`cli`).
    *   Load CR3 with new PML4.
    *   Jump to Kernel Entry (`elf_header.entry`), passing `boot_info` pointer.

#### E. Kernel Adaptation
- [ ] **Abstract Boot Source:** Refactor `kernel/init_mem.zig`, `kernel/framebuffer.zig`, etc., to take generic arguments (e.g., `(phys_base, size)`) rather than `limine.Response` objects.
- [ ] **Unified Entry:** Rewrite `_start` in `kernel/main.zig` to accept the `BootInfo` pointer argument.

### 4. Code Example: The Bootloader Entry

Here is what `src/boot/uefi/main.zig` will look like roughly:

```zig
const std = @import("std");
const uefi = std.os.uefi;
const BootInfo = @import("../../common/boot_info.zig").BootInfo;

pub fn main() usize {
    const boot_services = uefi.system_table.boot_services.?;
    const con_out = uefi.system_table.con_out.?;

    _ = con_out.outputString(utf16("Loading Zscapek Kernel...\r\n"));

    // 1. Load Kernel File
    // ... implementation ...

    // 2. Build Page Tables
    // ... implementation ...

    // 3. Get Memory Map & Exit Boot Services
    // This part is tricky; you often have to retry if map key changes
    var map_key: usize = 0;
    // ... get map ...
    
    const status = boot_services.exitBootServices(uefi.handle, map_key);
    if (status != .Success) {
        // Handle failure
    }

    // 4. Switch Page Table
    asm volatile ("mov %[pml4], %%cr3" : : [pml4] "r" (pml4_phys));

    // 5. Jump to Kernel
    // System V ABI: First arg in RDI
    const kernel_entry: fn(*const BootInfo) noreturn = @ptrFromInt(kernel_entry_addr);
    kernel_entry(&boot_info);
}

fn utf16(s: []const u8) *const [*:0]u16 {
    // Helper to convert string literals for UEFI
    // ...
}
```

### 5. Why do this? (Pros/Cons)

**Pros:**
1.  **Total Control:** You aren't at the mercy of Limine's memory layout decisions.
2.  **Education:** Writing a UEFI loader demystifies how the CPU gets into Long Mode.
3.  **Features:** You can implement things Limine might not support, like secure boot signatures specific to your OS, or fancy graphical splash screens before the kernel loads.

**Cons:**
1.  **Complexity:** You have to reimplement Paging logic in the bootloader.
2.  **Maintenance:** You now maintain two complex pieces of software (Loader + Kernel).
3.  **Fragility:** UEFI implementations vary wildly between hardware vendors. Limine abstracts this pain away.

**Recommendation:**
Keep Limine for now while developing Phase 6 and 7 of your kernel. Start the `src/boot/uefi` project as a side task ("Phase 9") and only switch when the loader can successfully boot a "Hello World" kernel that prints to the framebuffer.

---

## Priority Ranking (Recommended Order)

| Priority | Task | Effort | Impact | Status |
|----------|------|--------|--------|--------|
| 1 | Optimized Memcpy/Memset | Low | High (8x faster) | PARTIAL (copy_from_user done) |
| 2 | MSI-X Refinement (GPU) | Low-Med | Medium (GPU perf) | DONE |
| 3 | Slab Allocator | Medium | High (O(1) alloc) | DONE |
| 4 | VFS Mount + Permissions | Medium | Medium (userland) | DONE |
| 5 | Scheduler Lock Breaking | High | High (SMP scaling) | DONE |
| 6 | Async Filesystem (SFS) | High | Medium (I/O perf) | DONE |
| 7 | Zero-Copy IPC | High | High (network perf) | DONE |
| 8 | User/Group Permissions | Medium | Low (security) | PARTIAL (setresuid/CAP_SETUID done) |
| 9 | IOMMU | Very High | High (security) | |
| 10 | Custom UEFI | Very High | Low (optional) | |

**Completed:**
1. ~~Memcpy optimization~~ - copy_from_user optimized with rep movsq
2. ~~VirtIO-GPU MSI-X~~ - Implemented following XHCI pattern
3. ~~MSI-X u6/u8 boundary fix~~ - Changed offset to u8
4. ~~Slab allocator~~ - O(1) allocation for objects <= 2KB
5. ~~Scheduler lock breaking~~ - timerTick lock hold reduced 97%, sleep_lock added, atomic tick_count
6. ~~Zero-Copy Ring IPC~~ - RingMPSC pattern with decomposed SPSC rings, VirtIO-Net and netstack migrated
7. ~~VFS Permission Enforcement~~ - statPath, perms module, sys_open/sys_access checks
8. ~~User/Group Privileges~~ - setresuid/setresgid (117-120), CAP_SETUID/CAP_SETGID capabilities, saved UID/GID
9. ~~VFS Mount API~~ - sys_mount/sys_umount2, multi-filesystem support (sfs, devfs, initrd, tmpfs)
10. ~~SFS Permissions~~ - DirEntry v3 with mode/uid/gid/mtime, stat/fstat/chmod/chown syscalls
11. ~~Async SFS~~ - Batched bitmap loading (3-5x I/O reduction), async allocateBlock/freeBlock

**Next Priority:**
- Optimized Memcpy/Memset - remaining userland integration (Low effort, High impact)
- IOMMU (Very High effort, High impact)

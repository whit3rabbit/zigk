This plan outlines how to implement comprehensive Address Space Layout Randomization (ASLR), extending beyond the current user-space implementation to include the Kernel (KASLR) and critical kernel memory regions.

### Phase 1: Enable Kernel-Image KASLR (Bootloader Support)

The most effective KASLR is performed by the bootloader before the kernel starts. This prevents static analysis of the kernel binary on disk from mapping 1:1 to memory addresses.

**1. Update Build Configuration (`build.zig`)**
The kernel must be compiled as a Position Independent Executable (PIE) to allow it to run at any address.
*   **Action:** Ensure the kernel compile step includes `-fPIE` (or `-fPIC`) and the linker produces a PIE binary (not a static executable with fixed base).
*   **Action:** Verify specific Zig flags: `code_model = .kernel` (usually handles high-half, but PIE requires careful handling of the Global Offset Table if used).

**2. Update Limine Configuration (`limine.cfg`)**
*   **Action:** Add `KASLR: yes` to the protocol configuration. This instructs Limine to slide the kernel to a random virtual address in the higher half.

**3. Handle Dynamic Base Address in `core/boot.zig`**
Currently, the kernel likely assumes fixed addresses. We must read the actual load address from Limine.

```zig
// core/boot.zig

// Request the kernel address from Limine
pub export var kernel_address_request linksection(".limine_requests") = limine.KernelAddressRequest{};

// Helper to get the actual runtime kernel base
pub fn getKernelBase() u64 {
    if (kernel_address_request.response) |resp| {
        return resp.virtual_base;
    }
    // Fallback or panic if bootloader didn't provide it
    return 0xFFFF_8000_0000_0000;
}
```

### Phase 2: Dynamic Kernel Virtual Memory Management

Hardcoded constants in `mm/vmm.zig` must be replaced with runtime variables initialized at boot.

**1. Refactor `mm/vmm.zig` Constants**
Change `const` definitions to `var` and initialize them in `vmm.init()`.

```zig
// mm/vmm.zig

// Old: public const KERNEL_BASE: u64 = 0xFFFF_8000_0000_0000;
// New:
pub var KERNEL_BASE: u64 = undefined;
pub var HHDM_BASE: u64 = undefined; // Higher Half Direct Map

// Regions relative to KERNEL_BASE need random gaps
pub var KERNEL_HEAP_BASE: u64 = undefined;
pub var KERNEL_STACK_BASE: u64 = undefined;

pub fn init() VmmError!void {
    // 1. Get KASLR base from boot protocol
    KERNEL_BASE = @import("core").boot.getKernelBase();
    
    // 2. Initialize PRNG early (using RDRAND/TSC) to generate offsets
    const rng = @import("prng"); 
    
    // 3. Randomize HHDM base (if not fixed by Limine)
    // Note: Limine usually fixes HHDM relative to kernel, but we can 
    // technically remap it if we want extreme security, though expensive.
    
    // 4. Randomize Heap Base (e.g., 256GB window)
    const heap_entropy = rng.range(0x4000); // 16384 pages entropy
    KERNEL_HEAP_BASE = KERNEL_BASE + 0x4000_0000 + (heap_entropy * PAGE_SIZE);

    // ... continue initialization
}
```

### Phase 3: Kernel Heap & Stack Randomization

Protect dynamic kernel allocations (stacks and heap) from deterministic placement.

**1. Randomize Kernel Stacks (`mm/kernel_stack.zig`)**
The `STACK_REGION_BASE` is currently fixed. Each thread's stack should be allocated from a randomized region, or the region base itself should be randomized at boot.

```zig
// mm/kernel_stack.zig

// Replace fixed constant
var region_base: u64 = 0;

pub fn init() StackError!void {
    // Get base from VMM (which randomized it in Phase 2)
    // Or add entropy here:
    const entropy = @import("prng").range(1024 * 1024); // Random offset in pages
    region_base = 0xFFFF_A000_0000_0000 + (entropy * PAGE_SIZE);
    
    // ... rest of init
}
```

**2. Randomize Kernel Heap (`mm/heap.zig`)**
The heap currently initializes based on a physical region mapped 1:1.
*   **Action:** Instead of mapping the heap contiguously after the kernel image, map it to a disjoint, randomized virtual address region (calculated in Phase 2).

### Phase 4: Hardening the Entropy Source (`prng.zig`)

The current PRNG (`xoroshiro128+`) is fast but not cryptographically secure, making ASLR bypass easier if the state leaks.

**1. Implement ChaCha20**
Replace the core generator with ChaCha20. It provides a much larger state space and is resistant to analysis even if outputs are observed.

**2. Early Boot Entropy**
KASLR requires entropy *before* the kernel is fully running.
*   **Action:** Rely on the `RDRAND` instruction immediately in `_start` or `kmain` to seed the initial layout variables.
*   **Action:** If available, use the **Limine Seed Request** (`limine.KernelFileRequest`) to get entropy provided by the UEFI firmware/bootloader.

### Phase 5: Advanced Userspace ASLR

The current user ASLR (`mm/aslr.zig`) uses offsets. We can improve this.

**1. Update `sys_mmap` (`sys/syscall/memory.zig`)**
Currently, `sys_mmap` uses a first-fit allocator starting at `mmap_base`.
*   **Improvement:** Implement "randomized allocation". Instead of `findFreeRange` strictly looking for the first gap, pick a random start address within the valid user range and search from there.

```zig
// mm/user_vmm.zig

pub fn findFreeRange(self: *UserVmm, size: usize) ?u64 {
    // Start search at a random offset into the mmap region
    const entropy = @import("prng").range(self.mmap_range_size / 4096);
    var search_start = self.mmap_base + (entropy * 4096);
    
    // Wrap around logic if search hits end of address space
    // ...
}
```

**2. Brute-Force Detection**
*   **Action:** In `sys/syscall/execution.zig`, implement a crash counter for `fork` children. If a child crashes (segfaults) repeatedly and rapidly (indicating a brute-force attempt on ASLR offsets), throttle the parent process or kill it.

### Phase 6: Verification

**1. System Map Check**
*   Boot the kernel multiple times.
*   Dump the symbol table or `printk` the address of `kmain`, `heap_start`, and a newly allocated kernel stack.
*   **Success Criteria:** These addresses must differ significantly on every boot.

**2. Panic Handler Hardening**
*   The `panic.zig` handler prints stack traces.
*   **Action:** Ensure that printing raw kernel pointers (instruction pointers) in panic logs is disabled in production builds (or hashed), as this leaks the KASLR slide to a local attacker viewing logs.
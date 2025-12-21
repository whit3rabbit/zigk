const std = @import("std");
const hal = @import("hal");
const vmm = @import("vmm");
const pmm = @import("pmm");
const console = @import("console");
const types = @import("types.zig");
const utils = @import("utils.zig");

const ElfError = types.ElfError;
const AuxEntry = types.AuxEntry;
const Elf64_Phdr = types.Elf64_Phdr;
const PageFlags = hal.paging.PageFlags;

const checkStackBounds = utils.checkStackBounds;
const copyToUserspace = utils.copyToUserspace;
const writeToUserspace = utils.writeToUserspace;
const writeU64ToUserspace = utils.writeU64ToUserspace;

/// Set up the initial user stack with argc, argv, envp, auxv
///
/// Stack layout (growing downward):
///   [envp strings]
///   [argv strings]
///   [padding to 16 bytes]
///   auxv NULL terminator (0, 0)
///   auxv entries...
///   NULL (envp terminator)
///   envp[n-1]..envp[0] pointers
///   NULL (argv terminator)
///   argv[n-1]..argv[0] pointers
///   argc
///   <- RSP points here
///
/// Args:
///   pml4_phys: Page table physical address
///   stack_top: Top of stack virtual address
///   stack_size: Stack size in bytes
///   argv: Argument strings (can be empty)
///   envp: Environment strings (can be empty)
///   auxv: Auxiliary vector entries (for AT_PHDR, etc.)
///
/// Returns: Initial RSP value
pub fn setupStack(
    pml4_phys: u64,
    stack_top: u64,
    stack_size: usize,
    argv: []const []const u8,
    envp: []const []const u8,
    auxv: []const AuxEntry,
) !u64 {
    const page_size = pmm.PAGE_SIZE;
    const stack_base = stack_top - stack_size;

    // SECURITY: Pre-calculate total stack space required before any writes.
    // Without this check, we'd begin writing strings and pointers to the stack,
    // only to discover overflow mid-operation via checkStackBounds(). This leaves
    // the stack in an inconsistent state. By calculating upfront, we fail fast
    // with a clean error before any partial writes occur.
    //
    // Stack layout (bytes needed):
    //   - argv strings + null terminators: sum(len+1 for each arg)
    //   - envp strings + null terminators: sum(len+1 for each env)
    //   - alignment padding: up to 15 bytes
    //   - auxv entries: (auxv.len + 1) * 16  (+1 for AT_NULL terminator)
    //   - envp pointers + NULL: (envc + 1) * 8
    //   - argv pointers + NULL: (argc + 1) * 8
    //   - argc: 8 bytes
    var total_stack_needed: usize = 0;
    const precheck_argc = @min(argv.len, 64);
    const precheck_envc = @min(envp.len, 64);

    for (argv[0..precheck_argc]) |arg| {
        total_stack_needed += arg.len + 1; // string + null terminator
    }
    for (envp[0..precheck_envc]) |env| {
        total_stack_needed += env.len + 1;
    }
    total_stack_needed += 15; // worst case alignment padding
    total_stack_needed += (auxv.len + 1) * 16; // auxv entries + AT_NULL
    total_stack_needed += (precheck_envc + 1) * 8; // envp pointers + NULL
    total_stack_needed += (precheck_argc + 1) * 8; // argv pointers + NULL
    total_stack_needed += 8; // argc value

    if (total_stack_needed > stack_size) {
        console.err("ELF: Stack setup requires {} bytes but only {} available", .{
            total_stack_needed,
            stack_size,
        });
        return error.StackOverflow;
    }

    // Allocate and map stack pages
    const page_count = stack_size / page_size;
    var pages_mapped: usize = 0;
    var current_vaddr = stack_base;

    const stack_flags = PageFlags{
        .writable = true,
        .user = true,
        .no_execute = true,
    };

    while (pages_mapped < page_count) : (pages_mapped += 1) {
        const phys_page = pmm.allocPage() orelse {
            return error.OutOfMemory;
        };

        vmm.mapPage(pml4_phys, current_vaddr, phys_page, stack_flags) catch {
            pmm.freePage(phys_page);
            return error.MappingFailed;
        };

        // Zero the stack page
        const page_ptr: [*]u8 = hal.paging.physToVirt(phys_page);
        hal.mem.fill(page_ptr, 0, page_size);

        current_vaddr += page_size;
    }

    // Build stack contents from the top down
    var sp = stack_top;

    // First, push the actual strings (argv and envp)
    // We need to track where each string ends up
    var argv_ptrs: [64]u64 = undefined; // Max 64 args for simplicity
    var envp_ptrs: [64]u64 = undefined;

    const argc = @min(argv.len, 64);
    const envc = @min(envp.len, 64);

    // Push envp strings (in reverse order)
    var i: usize = envc;
    while (i > 0) {
        i -= 1;
        sp -= envp[i].len + 1; // +1 for null terminator
        try checkStackBounds(sp, stack_base);
        envp_ptrs[i] = sp;
        try copyToUserspace(pml4_phys, sp, envp[i]);
        // Write null terminator
        try writeToUserspace(pml4_phys, sp + envp[i].len, &[_]u8{0});
    }

    // Push argv strings (in reverse order)
    i = argc;
    while (i > 0) {
        i -= 1;
        sp -= argv[i].len + 1;
        try checkStackBounds(sp, stack_base);
        argv_ptrs[i] = sp;
        try copyToUserspace(pml4_phys, sp, argv[i]);
        try writeToUserspace(pml4_phys, sp + argv[i].len, &[_]u8{0});
    }

    // Align to 16 bytes
    sp = sp & ~@as(u64, 15);
    try checkStackBounds(sp, stack_base);

    // Push auxv NULL terminator (AT_NULL = 0, 0)
    sp -= 16;
    try checkStackBounds(sp, stack_base);
    try writeU64ToUserspace(pml4_phys, sp, 0); // id = AT_NULL
    try writeU64ToUserspace(pml4_phys, sp + 8, 0); // value = 0

    // Push auxv entries (in reverse order)
    var j: usize = auxv.len;
    while (j > 0) {
        j -= 1;
        sp -= 16;
        try checkStackBounds(sp, stack_base);
        try writeU64ToUserspace(pml4_phys, sp, auxv[j].id);
        try writeU64ToUserspace(pml4_phys, sp + 8, auxv[j].value);
    }

    // Push NULL terminator for envp
    sp -= 8;
    try checkStackBounds(sp, stack_base);
    try writeU64ToUserspace(pml4_phys, sp, 0);

    // Push envp pointers
    i = envc;
    while (i > 0) {
        i -= 1;
        sp -= 8;
        try checkStackBounds(sp, stack_base);
        try writeU64ToUserspace(pml4_phys, sp, envp_ptrs[i]);
    }

    // Push NULL terminator for argv
    sp -= 8;
    try checkStackBounds(sp, stack_base);
    try writeU64ToUserspace(pml4_phys, sp, 0);

    // Push argv pointers
    i = argc;
    while (i > 0) {
        i -= 1;
        sp -= 8;
        try checkStackBounds(sp, stack_base);
        try writeU64ToUserspace(pml4_phys, sp, argv_ptrs[i]);
    }

    // Push argc
    sp -= 8;
    try checkStackBounds(sp, stack_base);
    try writeU64ToUserspace(pml4_phys, sp, argc);

    console.debug("ELF: Stack setup complete, sp={x}", .{sp});

    return sp;
}

const StackBounds = types.StackBounds;

/// Set up TLS/TCB for a new thread
///
/// Allocates memory for the TLS block (tdata + tbss) and TCB.
/// Copies the initial TLS image from the ELF file.
/// Sets up the self-pointer in the TCB.
///
/// Args:
///   pml4_phys: Page table physical address
///   phdr: PT_TLS program header
///   file_data: Raw ELF file data
///   preferred_tp: Preferred thread pointer address
///   stack_bounds: Actual stack bounds (ASLR) for overlap validation
///
/// Returns: The FS base address (pointer to TCB)
pub fn setupTls(
    pml4_phys: u64,
    phdr: Elf64_Phdr,
    file_data: []const u8,
    preferred_tp: u64,
    stack_bounds: ?StackBounds,
) !u64 {
    const bounds = stack_bounds orelse StackBounds.default;
    // SECURITY: Validate p_align before use.
    // A malicious ELF could set p_align=0, causing underflow in (p_align - 1).
    // This would result in align_mask = 0xFFFFFFFFFFFFFFFF, corrupting all
    // subsequent address calculations and potentially mapping memory into
    // kernel space or causing integer wraparound in allocation sizes.
    //
    // Valid alignment must be:
    // - Non-zero (prevent underflow)
    // - Power of 2 (required for proper alignment math)
    // - Reasonable size (prevent DoS via huge alignment padding)
    const alignment = phdr.p_align;
    if (alignment == 0) {
        console.err("ELF: TLS segment has invalid p_align=0", .{});
        return ElfError.InvalidAddressRange;
    }
    // Check power of 2: (n & (n-1)) == 0 for powers of 2
    if ((alignment & (alignment - 1)) != 0) {
        console.err("ELF: TLS segment p_align={} is not a power of 2", .{alignment});
        return ElfError.InvalidAddressRange;
    }
    // Sanity check: alignment shouldn't be absurdly large (max 2MB for TLS)
    const MAX_TLS_ALIGN: u64 = 2 * 1024 * 1024;
    if (alignment > MAX_TLS_ALIGN) {
        console.err("ELF: TLS segment p_align={} exceeds maximum {}", .{ alignment, MAX_TLS_ALIGN });
        return ElfError.InvalidAddressRange;
    }

    // SECURITY: Apply the same segment size limits to TLS as PT_LOAD segments.
    // Without this check, a malicious ELF could specify p_memsz = 1GB for TLS,
    // causing memory exhaustion during page allocation. PT_LOAD segments are
    // protected by MAX_SEGMENT_SIZE (128MB), but TLS was previously unbounded.
    if (phdr.p_memsz > types.MAX_SEGMENT_SIZE) {
        console.err("ELF: TLS segment too large: {} bytes (max {} MB)", .{
            phdr.p_memsz,
            types.MAX_SEGMENT_SIZE / (1024 * 1024),
        });
        return ElfError.SegmentTooLarge;
    }

    // SECURITY: Validate p_filesz <= p_memsz for TLS segment.
    // Same vulnerability as PT_LOAD: we allocate based on p_memsz but copy
    // based on p_filesz. If p_filesz > p_memsz, we'd overflow the allocation.
    if (phdr.p_filesz > phdr.p_memsz) {
        console.err("ELF: TLS segment invalid: p_filesz ({}) > p_memsz ({})", .{ phdr.p_filesz, phdr.p_memsz });
        return ElfError.InvalidAddressRange;
    }

    // TCB pointer (TP) must be aligned to p_align
    // We use the preferred_tp as a starting point and align it up
    const align_mask = alignment - 1;
    const tp = (preferred_tp + align_mask) & ~align_mask;

    // TLS data is located at tp - aligned_size
    // According to x86_64 ABI Variant II
    const tls_size = std.mem.alignForward(u64, phdr.p_memsz, alignment);

    // SECURITY: Check for underflow before subtraction.
    // A malicious ELF with large p_memsz (up to MAX_SEGMENT_SIZE = 128MB) could cause
    // tp - tls_size to wrap around if preferred_tp is low. This would result in
    // tls_start being a very high address (near 0xFFFFFFFF_XXXXXXXX), potentially
    // landing in kernel space or overlapping with other mapped regions.
    if (tp < tls_size) {
        console.err("ELF: TLS size ({x}) exceeds thread pointer ({x})", .{ tls_size, tp });
        return ElfError.InvalidAddressRange;
    }
    const tls_start = tp - tls_size;

    // We need to map memory covering [tls_start, tp + tcb_size]
    // Allocate at least 1 page for TCB (Musl uses struct pthread)
    const tcb_size = 4096;

    // Align allocation to page boundaries
    const page_size = pmm.PAGE_SIZE;
    // Ensure we start allocating at a page boundary below or at tls_start
    const alloc_start = tls_start & ~(page_size - 1);
    // Ensure we end allocating at a page boundary above or at tp + tcb_size
    const alloc_end = std.mem.alignForward(u64, tp + tcb_size, page_size);
    const total_size = alloc_end - alloc_start;
    const page_count = total_size / page_size;

    // SECURITY: Validate TLS region does not overlap kernel space or user stack.
    // Unlike PT_LOAD segments (which have these checks in loadSegment), TLS setup
    // was missing boundary validation. A malicious ELF could craft preferred_tp
    // or large p_memsz to place TLS pages in kernel space or over the stack.
    // Pages mapped with .user=true in kernel space = privilege escalation.
    if (alloc_end >= vmm.KERNEL_BASE or alloc_start >= vmm.KERNEL_BASE) {
        console.err("ELF: TLS overlaps kernel space: {x}-{x}", .{ alloc_start, alloc_end });
        return ElfError.InvalidAddressRange;
    }
    // SECURITY: Check against actual ASLR stack bounds, not hardcoded defaults
    const stack_base_addr = bounds.base();
    if (alloc_start < bounds.stack_top and alloc_end > stack_base_addr) {
        console.err("ELF: TLS overlaps user stack reservation: {x}-{x} (stack={x}-{x})", .{
            alloc_start,
            alloc_end,
            stack_base_addr,
            bounds.stack_top,
        });
        return ElfError.InvalidAddressRange;
    }

    console.debug("ELF: Setting up TLS at {x} (tp={x}, size={d})", .{ alloc_start, tp, tls_size });

    // Allocate and map pages
    const page_flags = PageFlags{
        .writable = true,
        .user = true,
        .no_execute = true, // TLS/TCB should not be executable
    };

    // SECURITY: Track mapped pages for proper cleanup on failure.
    // The previous code only freed the current page on mapping failure,
    // leaking all previously allocated pages in the loop. This could be
    // exploited for memory exhaustion (DoS) by repeatedly triggering
    // TLS setup failures.
    const MAX_TLS_PAGES = 64; // 256KB max TLS (64 * 4KB pages)
    if (page_count > MAX_TLS_PAGES) {
        console.err("ELF: TLS requires too many pages: {} (max {})", .{ page_count, MAX_TLS_PAGES });
        return ElfError.SegmentTooLarge;
    }
    var mapped_pages: [MAX_TLS_PAGES]u64 = undefined;
    var pages_mapped: usize = 0;

    // Helper to clean up on failure
    const cleanup = struct {
        fn run(pml4: u64, start: u64, psize: u64, pages: []const u64) void {
            for (pages, 0..) |phys, idx| {
                const virt = start + idx * psize;
                vmm.unmapPage(pml4, virt) catch {};
                pmm.freePage(phys);
            }
        }
    };

    var current_vaddr = alloc_start;
    var i: usize = 0;
    while (i < page_count) : (i += 1) {
        const phys_page = pmm.allocPage() orelse {
            cleanup.run(pml4_phys, alloc_start, page_size, mapped_pages[0..pages_mapped]);
            return ElfError.OutOfMemory;
        };

        vmm.mapPage(pml4_phys, current_vaddr, phys_page, page_flags) catch {
            pmm.freePage(phys_page);
            cleanup.run(pml4_phys, alloc_start, page_size, mapped_pages[0..pages_mapped]);
            return ElfError.MappingFailed;
        };

        // Track this page for cleanup
        mapped_pages[pages_mapped] = phys_page;
        pages_mapped += 1;

        // Zero the page (handles tbss and TCB init)
        const page_ptr: [*]u8 = hal.paging.physToVirt(phys_page);
        hal.mem.fill(page_ptr, 0, page_size);

        current_vaddr += page_size;
    }

    // Copy TLS template data (tdata)
    if (phdr.p_filesz > 0) {
        // SECURITY: Use checked arithmetic for bounds validation.
        // A malicious ELF with p_offset = 0xFFFFFFFF_FFFFF000 and p_filesz = 0x1000
        // would cause p_offset + p_filesz to wrap to 0x0, bypassing the bounds check.
        // The subsequent slice operation would then access out-of-bounds memory.
        const file_end = std.math.add(u64, phdr.p_offset, phdr.p_filesz) catch {
            console.err("ELF: TLS p_offset + p_filesz overflow", .{});
            return ElfError.BufferTooSmall;
        };
        if (file_end > file_data.len) {
            console.err("ELF: TLS segment out of file bounds", .{});
            return ElfError.BufferTooSmall;
        }

        // We need to copy to tls_start. We can use copyToUserspace.
        const src = file_data[phdr.p_offset..][0..phdr.p_filesz];
        try copyToUserspace(pml4_phys, tls_start, src);
    }

    // Set up TCB self-pointer at TP (first 8 bytes)
    // This is required for %fs:0 to work
    try writeU64ToUserspace(pml4_phys, tp, tp);

    return tp;
}

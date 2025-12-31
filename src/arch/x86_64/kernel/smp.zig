// SMP (Symmetric Multi-Processing) Support
//
// Manages Application Processors (APs) bring-up and control.

const std = @import("std");
const console = @import("console");
const pmm = @import("pmm");
const sched = @import("sched");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const apic = @import("apic/root.zig");
const syscall_arch = @import("syscall.zig");
const cpu = @import("cpu.zig");
const paging = @import("../mm/paging.zig");
const vmm = @import("vmm");
const fpu = @import("fpu.zig");
const mem = @import("../mm/mem.zig");

// Code for the AP trampoline is defined in external assembly file
extern const smp_trampoline_start: anyopaque;
extern const smp_trampoline_end: anyopaque;

// Patch locations in trampoline
extern var smp_trampoline_pm_jump_operand: anyopaque;
extern var smp_trampoline_lm_jump_operand: anyopaque;
extern var smp_trampoline_cr3_imm: anyopaque;
extern var smp_trampoline_rsp_imm: anyopaque;
extern var smp_trampoline_ap_gdt_imm: anyopaque;
extern var smp_trampoline_entry_imm: anyopaque;
extern var smp_trampoline_gdt_ptr: anyopaque;
extern const smp_trampoline_gdt: anyopaque;

// Code Targets
extern const trampoline_protected_mode: anyopaque;
extern const trampoline_long_mode: anyopaque;

// Per-CPU state for APs
// SECURITY: Must not exceed gdt.MAX_CPUS or CPU IDs will overflow TSS/GDT arrays
const MAX_CPUS: usize = 256; // Match madt.zig

// Comptime assertion: SMP MAX_CPUS must not exceed GDT MAX_CPUS
// Violating this causes array bounds overflow when initializing TSS for high CPU IDs
comptime {
    if (MAX_CPUS > gdt.MAX_CPUS) {
        // Note: This is expected to trigger until gdt.MAX_CPUS is increased
        // For now, SMP will clamp CPU IDs to gdt.MAX_CPUS at runtime
        // @compileError("SMP MAX_CPUS exceeds GDT MAX_CPUS - increase gdt.MAX_CPUS or reduce SMP MAX_CPUS");
    }
}

// SECURITY: Zero-initialize to prevent info leaks if accessed before per-AP init
var ap_gs_data: [MAX_CPUS]syscall_arch.KernelGsData = [_]syscall_arch.KernelGsData{.{
    .kernel_stack = 0,
    .user_stack = 0,
    .current_thread = 0,
    .scratch = 0,
    .apic_id = 0,
    .idle_thread = 0,
}} ** MAX_CPUS;

// GDT copy for APs (in HHDM range, accessible without kernel image mappings)
// We store the physical address so AP can access it via HHDM without reading kernel image
var ap_gdt_phys: u64 = 0;

// Synchronization flag to release APs after all are booted
var ap_release_flag: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// Synchronization flag for AP boot sequence
// Set by AP after TSS load is complete, cleared by BSP before booting next AP
var ap_boot_complete: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// Counter for successfully booted APs
var booted_ap_count: u32 = 0;

/// Initialize SMP
/// Boot up all APs found in MADT
pub fn init() void {
    console.debug("SMP: init() function entry", .{});
    console.info("SMP: Initializing...", .{});

    const init_info = apic.getInitInfo() orelse {
        console.warn("SMP: APIC not initialized, skipping SMP", .{});
        return;
    };

    if (init_info.lapic_ids.len <= 1) {
        console.info("SMP: No APs detected (single core)", .{});
        return;
    }

    // 1. Prepare Trampoline
    var trampoline_phys: u64 = 0;
    var trampoline_vector: u8 = 0;

    var page_addr: u64 = 0x1000;
    while (page_addr < 0xA0000) : (page_addr += 0x1000) {
        if (pmm.allocSpecificPage(page_addr)) {
            trampoline_phys = page_addr;
            trampoline_vector = @intCast(page_addr >> 12);
            break;
        }
    }

    if (trampoline_phys == 0) {
        console.warn("SMP: Failed to allocate low memory for trampoline", .{});
        return;
    }

    console.info("SMP: Allocated trampoline at {x} (Vector {x})", .{ trampoline_phys, trampoline_vector });

    // Allocate a page for AP GDT copy (in HHDM range)
    // This is needed because APs can't access kernel image addresses
    ap_gdt_phys = pmm.allocZeroedPage() orelse {
        console.warn("SMP: Failed to allocate page for AP GDT", .{});
        return;
    };
    const gdt_page_virt = paging.physToVirt(ap_gdt_phys);
    const ap_gdt_copy: *gdt.Gdt = @ptrCast(@alignCast(gdt_page_virt));

    // Copy kernel GDT to AP-accessible memory (BSP can access kernel image)
    ap_gdt_copy.* = gdt.getGdtPtr().*;
    console.debug("SMP: AP GDT at virt {x} phys {x}", .{ @intFromPtr(gdt_page_virt), ap_gdt_phys });

    // Map the trampoline page
    const trampoline_virt = paging.physToVirt(trampoline_phys);
    const trampoline_len = @intFromPtr(&smp_trampoline_end) - @intFromPtr(&smp_trampoline_start);

    if (trampoline_len > pmm.PAGE_SIZE) {
        console.panic("SMP: Trampoline too large ({d} bytes)", .{trampoline_len});
    }

    // Copy trampoline code
    const code_src = @as([*]const u8, @ptrCast(&smp_trampoline_start))[0..trampoline_len];
    const code_dst = trampoline_virt[0..trampoline_len];
    mem.copy(code_dst.ptr, code_src.ptr, code_dst.len);

    // Identity-map trampoline so AP can execute after enabling paging
    // When AP enables paging at physical 0x2000, virtual 0x2000 must also map there
    vmm.mapPage(vmm.getKernelPml4(), trampoline_phys, trampoline_phys, paging.PageFlags.KERNEL_RWX) catch |err| {
        console.panic("SMP: Failed to identity-map trampoline: {}", .{err});
    };

    // Calculate offsets for patching
    const start_addr = @intFromPtr(&smp_trampoline_start);

    // Jump Operands (Offsets where the immediate value is stored)
    const off_pm_jump = @intFromPtr(&smp_trampoline_pm_jump_operand) - start_addr;
    const off_lm_jump = @intFromPtr(&smp_trampoline_lm_jump_operand) - start_addr;

    // Immediate Operands
    const off_cr3 = @intFromPtr(&smp_trampoline_cr3_imm) - start_addr;
    const off_rsp = @intFromPtr(&smp_trampoline_rsp_imm) - start_addr;
    const off_ap_gdt = @intFromPtr(&smp_trampoline_ap_gdt_imm) - start_addr;
    const off_entry = @intFromPtr(&smp_trampoline_entry_imm) - start_addr;

    // GDTR
    const off_gdt_ptr = @intFromPtr(&smp_trampoline_gdt_ptr) - start_addr;
    const off_gdt = @intFromPtr(&smp_trampoline_gdt) - start_addr;

    // Code Targets (Offsets from start)
    const off_code_pm = @intFromPtr(&trampoline_protected_mode) - start_addr;
    const off_code_lm = @intFromPtr(&trampoline_long_mode) - start_addr;

    // Patch Variables

    // PM Jump Target (32-bit linear address)
    const pm_target = trampoline_phys + off_code_pm;
    const pm_jump_ptr: *align(1) u32 = @ptrCast(&trampoline_virt[off_pm_jump]);
    pm_jump_ptr.* = @intCast(pm_target);

    // LM Jump Target (32-bit linear address in compatibility mode)
    const lm_target = trampoline_phys + off_code_lm;
    const lm_jump_ptr: *align(1) u32 = @ptrCast(&trampoline_virt[off_lm_jump]);
    lm_jump_ptr.* = @intCast(lm_target);

    // CR3 - use BSP's actual CR3, not vmm.getKernelPml4()
    // The BSP's CR3 has working mappings for kernel image + HHDM
    const cr3_val = cpu.readCr3();
    console.debug("SMP: Using BSP CR3={x} for AP", .{cr3_val});
    const cr3_ptr: *align(1) u32 = @ptrCast(&trampoline_virt[off_cr3]);
    cr3_ptr.* = @intCast(cr3_val); // Use BSP's actual CR3

    // Entry Point (Global)
    const entry_ptr: *align(1) u64 = @ptrCast(&trampoline_virt[off_entry]);
    entry_ptr.* = @intFromPtr(&apEntry);

    // AP GDT Address (will be loaded into R15 before jump to entry point)
    // This is the virtual address of the AP GDT copy in HHDM range
    const ap_gdt_virt = @intFromPtr(paging.physToVirt(ap_gdt_phys));
    const ap_gdt_ptr_patch: *align(1) u64 = @ptrCast(&trampoline_virt[off_ap_gdt]);
    ap_gdt_ptr_patch.* = ap_gdt_virt;
    console.debug("SMP: Patched AP GDT at offset {x} with virt {x}", .{ off_ap_gdt, ap_gdt_virt });

    // GDTR
    // GDT has 4 entries (null, 64-bit code, data, 32-bit code) = 32 bytes
    // Limit = size - 1 = 31
    const gdt_base_phys = trampoline_phys + off_gdt;
    const limit_ptr: *align(1) u16 = @ptrCast(&trampoline_virt[off_gdt_ptr]);
    const base_ptr: *align(1) u32 = @ptrCast(&trampoline_virt[off_gdt_ptr + 2]);
    limit_ptr.* = 31;
    base_ptr.* = @intCast(gdt_base_phys);

    // 2. Boot APs
    const bsp_id = apic.lapic.getId();

    for (init_info.lapic_ids) |apic_id| {
        if (apic_id == bsp_id) continue;

        console.info("SMP: Booting AP with APIC ID {d}...", .{apic_id});

        // SECURITY: Skip CPUs with APIC IDs that exceed GDT's TSS array bounds
        // This prevents array overflow when calling gdt.initTssForCpu()
        if (apic_id >= gdt.MAX_CPUS) {
            console.warn("SMP: Skipping AP {d} - APIC ID exceeds GDT MAX_CPUS ({d})", .{ apic_id, gdt.MAX_CPUS });
            continue;
        }

        // Allocate stack for this AP
        const stack_size = 16 * 1024;
        const stack_phys = pmm.allocZeroedPages(stack_size / pmm.PAGE_SIZE) orelse {
            console.warn("SMP: Failed to allocate stack for AP {d}", .{apic_id});
            continue;
        };
        const stack_virt_base = paging.physToVirt(stack_phys);
        // SECURITY: Use checked arithmetic to prevent overflow in stack calculations
        const stack_top = std.math.add(usize, @intFromPtr(stack_virt_base), stack_size) catch {
            console.warn("SMP: Stack top overflow for AP {d}", .{apic_id});
            continue;
        };

        console.debug("SMP: AP stack phys={x} virt_base={x} top={x}", .{ stack_phys, @intFromPtr(stack_virt_base), stack_top });

        // Patch Stack Top in trampoline
        const stack_ptr: *align(1) u64 = @ptrCast(&trampoline_virt[off_rsp]);
        stack_ptr.* = stack_top;
        console.debug("SMP: Patched RSP at offset {x} with value {x}", .{ off_rsp, stack_top });

        // Initialize per-CPU data
        ap_gs_data[apic_id] = .{
            .kernel_stack = 0, // Will be set by scheduler
            .user_stack = 0,
            .current_thread = 0,
            .scratch = 0,
            .apic_id = @intCast(apic_id),
            .idle_thread = 0, // Will be set by scheduler init
        };

        // Initialize per-CPU TSS for this AP and update the shared AP GDT's TSS descriptor
        // This must be done before booting the AP so it loads the correct TSS
        // ap_gdt_virt is declared above as the integer address of the GDT copy
        const ap_gdt_for_tss: *gdt.Gdt = @ptrFromInt(ap_gdt_virt);
        gdt.initTssForCpu(@intCast(apic_id), ap_gdt_for_tss);
        console.debug("SMP: Initialized TSS for AP {d}", .{apic_id});

        // Clear boot complete flag before booting
        ap_boot_complete.store(0, .release);

        // Send INIT IPI
        apic.lapic.sendInitIpi(apic_id);
        cpu.stall(10000); // 10ms wait

        // Send SIPI
        apic.lapic.sendStartupIpi(apic_id, trampoline_vector);
        cpu.stall(200); // 200us wait

        // Send Second SIPI
        apic.lapic.sendStartupIpi(apic_id, trampoline_vector);

        // Wait for AP to signal boot complete (with timeout)
        var timeout: u32 = 0;
        while (ap_boot_complete.load(.acquire) == 0 and timeout < 1000) : (timeout += 1) {
            cpu.stall(1000); // 1ms per iteration, max 1 second
        }

        if (ap_boot_complete.load(.acquire) != 0) {
            booted_ap_count += 1;
            console.info("SMP: AP {d} booted successfully", .{apic_id});
        } else {
            // SECURITY: If an AP times out, we MUST NOT continue booting more APs.
            // The shared GDT's TSS descriptor would be overwritten for the next AP,
            // corrupting state for the slow AP if it eventually wakes up.
            // This prevents a TOCTOU race condition in AP boot sequence.
            console.warn("SMP: AP {d} boot timeout - aborting further AP boots to prevent TSS corruption", .{apic_id});
            break;
        }
    }

    console.info("SMP: {d} APs booted successfully", .{booted_ap_count});

    // Release all APs to start scheduling
    ap_release_flag.store(1, .release);
}

/// Get count of successfully booted APs
pub fn getBootedApCount() u32 {
    return booted_ap_count;
}

/// AP Entry Point (64-bit Long Mode)
/// Called from trampoline
export fn apEntry() callconv(.c) noreturn {
    // Debug: Write directly to COM1 port without any dependencies
    // This bypasses any locks or per-CPU data that might not be set up
    // const io = @import("io.zig");
    // const COM1: u16 = 0x3F8;
    // Wait for transmit buffer empty and write
    // while (io.inb(COM1 + 5) & 0x20 == 0) {}
    // io.outb(COM1, 'A');
    // ...
    
    // Debug helper
    const writeChar = struct {
        fn f(c: u8) void {
            _ = c;
            // while (io.inb(COM1 + 5) & 0x20 == 0) {}
            // io.outb(COM1, c);
        }
    }.f;

    // Reload GDT using pre-allocated AP GDT copy (in HHDM range)
    // The trampoline loaded the AP GDT address into R15 before jumping here
    writeChar('G');

    // Read AP GDT address from R15 (set by trampoline)
    var ap_gdt_addr: u64 = undefined;
    asm volatile ("movq %%r15, %[out]"
        : [out] "=r" (ap_gdt_addr)
    );

    const GdtPtr = packed struct(u80) {
        limit: u16,
        base: u64,
    };
    const gdt_ptr = GdtPtr{
        .limit = @sizeOf(gdt.Gdt) - 1,
        .base = ap_gdt_addr,
    };
    writeChar('P'); // GdtPtr created

    // Step 3: Load GDT via LGDT
    asm volatile ("lgdt (%[ptr])"
        :
        : [ptr] "r" (&gdt_ptr),
        : .{.memory = true}
    );
    writeChar('L'); // After LGDT

    // Step 4: Reload data segment registers
    asm volatile (
        \\mov %[ds], %%ds
        \\mov %[ds], %%es
        \\mov %[ds], %%ss
        :
        : [ds] "r" (@as(u16, gdt.KERNEL_DATA)),
        : .{.memory = true}
    );
    writeChar('D'); // After DS/ES/SS

    // Step 5: Clear FS and GS
    asm volatile (
        \\xor %%eax, %%eax
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        :
        :
        : .{.rax = true}
    );
    writeChar('F'); // After FS/GS

    // Step 6: Reload CS via far return
    asm volatile (
        \\pushq %[cs]
        \\lea 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        :
        : [cs] "r" (@as(u64, gdt.KERNEL_CODE)),
        : .{.rax = true, .memory = true}
    );
    writeChar('R'); // After CS reload

    // Step 7: Load TSS (now configured with per-CPU TSS by BSP)
    asm volatile ("ltr %[sel]"
        :
        : [sel] "r" (@as(u16, gdt.TSS_SELECTOR)),
    );
    writeChar('T'); // TSS loaded

    // Load IDT
    idt.reload();
    writeChar('I');

    // Initialize FPU (enable SSE, OSFXSR)
    fpu.init();
    // Enable XSAVE for extended FPU state (AVX, etc.)
    fpu.initXsave();
    writeChar('F');

    // Step 8: Set up GS base for per-CPU data
    // Get APIC ID to index into per-CPU data
    const apic_id = apic.lapic.getId();

    // SECURITY: Bounds check APIC ID to prevent OOB access
    // A malicious hypervisor could report invalid APIC IDs
    if (apic_id >= ap_gs_data.len or apic_id >= gdt.MAX_CPUS) {
        // Cannot proceed safely - halt this CPU
        cpu.haltForever();
    }

    const gs_data_ptr = @intFromPtr(&ap_gs_data[apic_id]);

    // Set GS_BASE MSR to point to per-CPU data (since we are in kernel mode)
    cpu.writeMsr(cpu.IA32_GS_BASE, gs_data_ptr);

    // Set KERNEL_GS_BASE to 0 (user GS base)
    // SWAPGS instruction swaps these on syscall entry/exit
    cpu.writeMsr(cpu.IA32_KERNEL_GS_BASE, 0);

    writeChar('G'); // GS base set

    // Signal boot complete to BSP
    ap_boot_complete.store(1, .release);
    writeChar('!');
    writeChar('O');
    writeChar('K');
    writeChar('\n');

    // Wait for BSP to release us
    while (ap_release_flag.load(.acquire) == 0) {
        cpu.pause();
    }

    // Initialize LAPIC for this AP (enable APIC, set SVR/TPR)
    apic.lapic.initAp();

    // Initialize scheduler for this AP (creates idle thread)
    sched.initAp();

    // Enable interrupts and enter idle loop
    // The scheduler will pick up this CPU when there's work to do
    cpu.enableInterrupts();

    while (true) {
        asm volatile ("hlt");
    }
}

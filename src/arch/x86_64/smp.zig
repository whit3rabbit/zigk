// SMP (Symmetric Multi-Processing) Support
//
// Manages Application Processors (APs) bring-up and control.

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const pmm = @import("pmm");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const apic = @import("apic/root.zig");
const syscall = @import("syscall.zig");
const sched = @import("../../kernel/sched.zig");

// Code for the AP trampoline is defined in external assembly file
extern const smp_trampoline_start: anyopaque;
extern const smp_trampoline_end: anyopaque;

// Patch locations in trampoline
extern var smp_trampoline_pm_jump_operand: anyopaque;
extern var smp_trampoline_lm_jump_operand: anyopaque;
extern var smp_trampoline_cr3_imm: anyopaque;
extern var smp_trampoline_rsp_imm: anyopaque;
extern var smp_trampoline_entry_imm: anyopaque;
extern var smp_trampoline_gdt_ptr: anyopaque;
extern const smp_trampoline_gdt: anyopaque;

// Code Targets
extern const trampoline_protected_mode: anyopaque;
extern const trampoline_long_mode: anyopaque;

// Per-CPU state for APs
var ap_gs_data: [apic.lapic.MAX_CPUS]hal.syscall.KernelGsData = undefined;

/// Initialize SMP
/// Boot up all APs found in MADT
pub fn init() void {
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

    // Map the trampoline page
    const trampoline_virt = hal.paging.physToVirt(trampoline_phys);
    const trampoline_len = @intFromPtr(&smp_trampoline_end) - @intFromPtr(&smp_trampoline_start);

    if (trampoline_len > pmm.PAGE_SIZE) {
        console.panic("SMP: Trampoline too large ({d} bytes)", .{trampoline_len});
    }

    // Copy trampoline code
    const code_src = @as([*]const u8, @ptrCast(&smp_trampoline_start))[0..trampoline_len];
    const code_dst = trampoline_virt[0..trampoline_len];
    @memcpy(code_dst, code_src);

    // Calculate offsets for patching
    const start_addr = @intFromPtr(&smp_trampoline_start);

    // Jump Operands (Offsets where the immediate value is stored)
    const off_pm_jump = @intFromPtr(&smp_trampoline_pm_jump_operand) - start_addr;
    const off_lm_jump = @intFromPtr(&smp_trampoline_lm_jump_operand) - start_addr;

    // Immediate Operands
    const off_cr3 = @intFromPtr(&smp_trampoline_cr3_imm) - start_addr;
    const off_rsp = @intFromPtr(&smp_trampoline_rsp_imm) - start_addr;
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

    // CR3
    const cr3_val = hal.cpu.readCr3();
    const cr3_ptr: *align(1) u32 = @ptrCast(&trampoline_virt[off_cr3]);
    cr3_ptr.* = @intCast(cr3_val);

    // Entry Point (Global)
    const entry_ptr: *align(1) u64 = @ptrCast(&trampoline_virt[off_entry]);
    entry_ptr.* = @intFromPtr(&apEntry);

    // GDTR
    const gdt_base_phys = trampoline_phys + off_gdt;
    const limit_ptr: *align(1) u16 = @ptrCast(&trampoline_virt[off_gdt_ptr]);
    const base_ptr: *align(1) u32 = @ptrCast(&trampoline_virt[off_gdt_ptr + 2]);
    limit_ptr.* = 23;
    base_ptr.* = @intCast(gdt_base_phys);

    // 2. Boot APs
    const bsp_id = apic.lapic.getId();

    for (init_info.lapic_ids) |apic_id| {
        if (apic_id == bsp_id) continue;

        console.info("SMP: Booting AP with APIC ID {d}...", .{apic_id});

        // Allocate stack for this AP
        const stack_size = 16 * 1024;
        const stack_phys = pmm.allocZeroedPages(stack_size / pmm.PAGE_SIZE) orelse {
            console.warn("SMP: Failed to allocate stack for AP {d}", .{apic_id});
            continue;
        };
        const stack_virt_base = hal.paging.physToVirt(stack_phys);
        const stack_top = @intFromPtr(stack_virt_base) + stack_size;

        // Patch Stack Top in trampoline
        const stack_ptr: *align(1) u64 = @ptrCast(&trampoline_virt[off_rsp]);
        stack_ptr.* = stack_top;

        // Initialize per-CPU data
        ap_gs_data[apic_id] = .{
            .kernel_stack = 0, // Will be set by scheduler
            .user_stack = 0,
            .current_thread = 0,
            .scratch = 0,
            .apic_id = @intCast(apic_id),
            .idle_thread = 0, // Will be set by scheduler init
        };

        // Send INIT IPI
        apic.lapic.sendInitIpi(apic_id);
        hal.cpu.stall(10000); // 10ms wait

        // Send SIPI
        apic.lapic.sendStartupIpi(apic_id, trampoline_vector);
        hal.cpu.stall(200); // 200us wait

        // Send Second SIPI
        apic.lapic.sendStartupIpi(apic_id, trampoline_vector);
    }
}

/// AP Entry Point (64-bit Long Mode)
/// Called from trampoline
export fn apEntry() callconv(.C) noreturn {
    // Reload Kernel GDT and IDT
    gdt.reload();
    idt.reload();

    // Identify who we are
    const id = apic.lapic.getId();

    // Set up GS Base to point to our per-CPU data
    const gs_ptr = @intFromPtr(&ap_gs_data[id]);

    // Set IA32_GS_BASE (Active GS) to point to Kernel Data
    hal.cpu.writeMsr(hal.cpu.IA32_GS_BASE, gs_ptr);

    // Set IA32_KERNEL_GS_BASE (Shadow GS) to 0 (User GS default)
    hal.cpu.writeMsr(hal.cpu.IA32_KERNEL_GS_BASE, 0);

    // Initialize LAPIC
    apic.lapic.initAp();

    // Initialize Scheduler for this AP (creates idle thread)
    sched.initAp();

    // Start Scheduler (loop forever)
    sched.startAp();
}

// AArch64 Architecture HAL Root Module

const std = @import("std");

pub const io = @import("lib/io.zig");
pub const cpu = @import("kernel/cpu.zig");
pub const pl011 = @import("serial");
pub const serial = pl011;

pub fn earlyWrite(c: u8) void { pl011.writeByte(c); }
pub fn earlyPrint(msg: []const u8) void { pl011.writeString(msg); }

pub const mem = @import("mm/mem.zig");
pub const paging = @import("mm/paging.zig");
pub const interrupts = @import("kernel/interrupts/root.zig");
pub const fpu = @import("kernel/fpu.zig");
pub const debug = @import("kernel/debug.zig");
pub const entropy = @import("kernel/entropy.zig");
pub const syscall = @import("kernel/syscall.zig");
pub const mmio = @import("mm/mmio.zig");
pub const mmio_device = @import("mm/mmio_device.zig");
pub const timing = @import("kernel/timing.zig");
pub const smp = @import("kernel/smp.zig");
pub const userspace = @import("kernel/userspace.zig");

pub const gdt = struct {
    pub const MAX_CPUS = 8;
    pub const USER_DATA = 0x23; 
    pub const USER_CODE = 0x1b;
    pub fn init() void {}
    pub fn setKernelStack(_: u64) void {}
};

pub const idt = struct {
    pub const InterruptFrame = syscall.SyscallFrame;
    pub fn init() void {}
    pub fn setSignalChecker(_: anytype) void {}
};


pub const apic = struct {
    pub fn routeIrq(_: u32, _: u32, _: u32) void {}
    pub fn enableIrq(_: u32) void {}
    pub fn disableIrq(_: u32) void {}
    pub fn setLegacyPicMode() void {}
    pub const Vectors = struct {
        pub const MOUSE: u32 = 44;
        pub const COM1: u32 = 36;
    };
    pub const lapic = struct {
        pub fn getId() u32 { return 0; }
        pub fn sendEoi() void {}
    };
    pub const ipi = struct {
        pub fn sendTo(_: u32, _: anytype) void {}
        pub fn registerHandler(_: anytype, _: anytype) void {}
        pub fn broadcast(_: anytype) void {}
    };
    pub fn init(_: anytype) void {}
    pub const ioapic = struct {
        pub const MAX_IOAPICS = 1;
        pub fn init(_: anytype) void {}
    };
    pub const IoApicInfo = struct {
        id: u8,
        addr: u64,
        base: u64 = 0,
        gsi_base: u32,
    };
    pub const InterruptOverride = struct {
        source_irq: u8,
        gsi: u32,
        polarity: u2 = 0,
        trigger_mode: u2 = 0,
    };
    pub const ApicInitInfo = struct {
        local_apic_addr: u64,
        io_apics: []const IoApicInfo,
        overrides: []const ?InterruptOverride,
        pcat_compat: bool,
        lapic_ids: []const u8 = &[_]u8{},
        lapic_count: u16 = 0,
    };
};


pub const iommu = struct {
    pub const page_table = @import("mm/paging.zig");
};

// x86 compatibility stubs (these don't exist on ARM but kernel code may reference them)
pub const pic = struct {
    pub fn init() void {}
    pub fn enableIrq(_: u32) void {}
    pub fn disableIrq(_: u32) void {}
    pub fn sendEoi(_: u8) void {}
    pub fn disableAll() void {}
};

pub const pit = struct {
    pub fn init(_: u32) void {
        // ARM uses GIC timer (PPI 30) instead of PIT
    }
    pub fn disable() void {}
    pub fn readCount() u16 {
        return 0;
    }
};

pub fn init(hhdm_offset: u64) void {
    paging.init(hhdm_offset);
    serial.initDefault();
}

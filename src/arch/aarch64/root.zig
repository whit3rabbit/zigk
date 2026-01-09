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

// Hypervisor support
pub const vmware = @import("hypervisor/vmware.zig");
pub const hypervisor = @import("hypervisor/root.zig");

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
    pub fn sendEoi() void {}
    pub const Vectors = struct {
        pub const MOUSE: u32 = 44;
        pub const COM1: u32 = 36;
        pub const RTC: u32 = 40;
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
    pub fn isActive() bool { return false; }
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

    // VT-d stub for aarch64 (VT-d is Intel x86 specific)
    pub const vtd = struct {
        pub const VtdUnit = struct {
            pub fn init(_: anytype) !VtdUnit {
                return error.NotSupported;
            }
            pub fn logInfo(_: *const VtdUnit) void {}
            pub fn setRootTable(_: *VtdUnit, _: u64) void {}
            pub fn invalidateContextGlobal(_: *VtdUnit) !void {}
            pub fn invalidateIotlbDomain(_: *VtdUnit, _: u16) !void {}
            pub fn invalidateIotlbGlobal(_: *VtdUnit) !void {}
            pub fn enableTranslation(_: *VtdUnit) !void {}
            pub fn enableFaultInterrupt(_: *VtdUnit) void {}
        };
        pub fn registerUnit(_: VtdUnit) void {}
        pub fn getUnitCount() usize {
            return 0;
        }
        pub fn getUnit(_: usize) ?*VtdUnit {
            return null;
        }
    };

    // Stub for kernel IOMMU domain code
    pub fn getUnitCount() usize {
        return 0;
    }
    pub fn getUnit(_: usize) ?*vtd.VtdUnit {
        return null;
    }

    // Fault handling stub
    pub const fault = struct {
        pub fn init() void {}
    };
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
    pub fn init(freq_hz: u32) void {
        // ARM uses the Generic Timer (virtual timer) instead of PIT
        timing.startPeriodicTimer(freq_hz);
    }
    pub fn disable() void {}
    pub fn readCount(_: anytype) u16 {
        return 0;
    }

    pub const Command = struct {
        pub const Channel = enum(u2) { ch0 = 0, ch1 = 1, ch2 = 2, readback = 3 };
        pub const Mode = enum(u3) {
            interrupt_on_terminal_count = 0,
            hw_retriggerable_one_shot = 1,
            rate_generator = 2,
            square_wave = 3,
            sw_triggered_strobe = 4,
            hw_triggered_strobe = 5,
        };
    };
    pub const BASE_FREQUENCY: u32 = 1193182;
    pub fn configureOneShot(_: Command.Channel, _: u16) void {}
    pub fn configure(_: Command.Channel, _: Command.Mode, _: u16) void {}
    pub fn setSpeakerGate(_: bool, _: bool) void {}
    pub fn readChannel2Out() bool { return false; }
    pub fn beep(_: u32, _: u32) void {}
    pub fn calculateDivisor(_: u32) u16 { return 0; }
};

/// RTC stub for aarch64 (ARM typically uses PL031 or similar)
/// Returns epoch time (1970-01-01 00:00:00) as placeholder
pub const rtc = struct {
    pub const DateTime = struct {
        year: u16 = 1970,
        month: u8 = 1,
        day: u8 = 1,
        hour: u8 = 0,
        minute: u8 = 0,
        second: u8 = 0,
        day_of_week: u8 = 4, // Thursday (Jan 1, 1970 was Thursday)

        pub fn toUnixTimestamp(_: *const @This()) i64 {
            return 0; // Epoch
        }

        pub fn fromUnixTimestamp(_: i64) @This() {
            return .{}; // Return epoch
        }
    };

    pub const StatusA = packed struct(u8) {
        rate_select: u4 = 0,
        divider: u3 = 0,
        update_in_progress: u1 = 0,
    };

    pub const StatusB = packed struct(u8) {
        daylight_savings: u1 = 0,
        hour_format: u1 = 1,
        binary_mode: u1 = 1,
        square_wave: u1 = 0,
        update_ended_int: u1 = 0,
        alarm_int: u1 = 0,
        periodic_int: u1 = 0,
        update_inhibit: u1 = 0,
    };

    pub const AlarmCallback = *const fn () void;
    pub const PeriodicCallback = *const fn () void;

    pub const PeriodicRate = enum(u4) {
        off = 0,
        rate_122us = 3,
        rate_244us = 4,
        rate_488us = 5,
        rate_976us = 6,
        rate_1953us = 7,
        rate_3906us = 8,
        rate_7812us = 9,
        rate_15625us = 10,
        rate_31250us = 11,
        rate_62500us = 12,
        rate_125ms = 13,
        rate_250ms = 14,
        rate_500ms = 15,
    };

    pub fn init() void {
        // ARM uses different RTC hardware (e.g., PL031)
        // This is a stub - implement PL031 driver for full support
    }

    pub fn isInitialized() bool {
        return false;
    }

    pub fn readDateTime() DateTime {
        return .{};
    }

    pub fn writeDateTime(_: *const DateTime) void {}

    pub fn getUnixTimestamp() i64 {
        return 0;
    }

    pub fn setAlarm(_: u8, _: u8, _: u8, _: AlarmCallback) void {}
    pub fn disableAlarm() void {}
    pub fn enablePeriodicInterrupt(_: PeriodicRate, _: PeriodicCallback) void {}
    pub fn disablePeriodicInterrupt() void {}
    pub fn readCmosRam(_: u8) u8 { return 0; }
    pub fn writeCmosRam(_: u8, _: u8) void {}
};

pub fn init(hhdm_offset: u64) void {
    paging.init(hhdm_offset);
    serial.initDefault();

    // Clear TTBR0 - no user page tables yet
    // We set TTBR0 to 0 (invalid) since we don't have user processes yet.
    // NOTE: TLBI is skipped here because it causes hangs in QEMU TCG.
    // We use ASID switching in writeTtbr0 to avoid stale TLB entries.
    asm volatile (
        // Set TTBR0 to 0 with ASID 0 in upper bits
        \\msr ttbr0_el1, xzr
        \\isb
    );

    // Enable PAN (Privileged Access Never) for security
    // This prevents the kernel from accidentally accessing user memory
    // via normal load/store; must use LDTR/STTR instead
    cpu.enablePAN();

    // Initialize GIC and exception vectors
    // Must be done before any code calls setSerialHandler or other IRQ functions
    interrupts.init();

    // Initialize timing subsystem with best available clock source
    // Uses Generic Timer, with pvtime stolen time tracking under KVM
    timing.initBest();

    // Initialize periodic timer at 100Hz for scheduler
    pit.init(100);
}

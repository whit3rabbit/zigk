//! VMware Tools Service
//!
//! Provides VMware/VirtualBox guest integration features:
//! - Time synchronization with host
//! - Screen resolution change handling
//! - Graceful shutdown handling
//!
//! Uses the VMware backdoor interface via sys_vmware_backdoor syscall.

const std = @import("std");
const builtin = @import("builtin");
const syscall = @import("syscall");

// VMware backdoor constants
const BACKDOOR_PORT: u16 = 0x5658;
const BACKDOOR_MAGIC: u32 = 0x564D5868;

// VMware backdoor command IDs
const CMD_GET_VERSION: u32 = 10;
const CMD_GET_TIME_FULL: u32 = 46;
const CMD_GET_TIME_DIFF: u32 = 47;
const CMD_MESSAGE_OPEN: u32 = 30;
const CMD_MESSAGE_SEND: u32 = 31;
const CMD_MESSAGE_RECEIVE: u32 = 32;
const CMD_MESSAGE_CLOSE: u32 = 33;

// RPCI message types
const RPCI_CHANNEL: u16 = 0x4F4C;

// VMware backdoor register state
const VmwareRegs = extern struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
    esi: u32,
    edi: u32,
};

// Service state
var running: bool = true;
var sync_interval_ms: u64 = 60000; // Default: sync time every 60 seconds

pub fn main() void {
    syscall.print("VMware Tools Service Starting...\n");

    // Register as service
    syscall.register_service("vmware_tools") catch |err| {
        printError("Failed to register vmware_tools service", err);
        return;
    };
    syscall.print("Registered 'vmware_tools' service\n");

    // Check hypervisor type
    const hv_type = getHypervisorType();
    if (hv_type != 1 and hv_type != 2) { // 1=vmware, 2=virtualbox
        syscall.print("VMware Tools: Not running under VMware/VirtualBox (type=");
        printDec(hv_type);
        syscall.print("), service disabled\n");
        return;
    }

    syscall.print("VMware Tools: Detected compatible hypervisor\n");

    // Check if backdoor is accessible
    if (!detectBackdoor()) {
        syscall.print("VMware Tools: Backdoor not available\n");
        return;
    }

    syscall.print("VMware Tools: Backdoor detected, starting service loop\n");

    // Main service loop
    serviceLoop();
}

fn serviceLoop() void {
    var last_time_sync: u64 = 0;

    while (running) {
        // Sleep for a bit (1 second)
        syscall.sleep_ms(1000) catch {};

        // Get current time (rough, for interval checking)
        const now = getMonotonicTime();

        // Time synchronization
        if (now - last_time_sync >= sync_interval_ms) {
            if (syncTime()) {
                last_time_sync = now;
            }
        }

        // TODO: Handle RPCI messages for shutdown requests
        // TODO: Handle screen resolution hints
    }
}

fn getHypervisorType() u32 {
    // SYS_GET_HYPERVISOR = 1051
    const result = syscall.syscall0(1051);
    if (@as(isize, @bitCast(result)) < 0) return 0;
    return @truncate(result);
}

fn detectBackdoor() bool {
    var regs = VmwareRegs{
        .eax = BACKDOOR_MAGIC,
        .ebx = ~BACKDOOR_MAGIC,
        .ecx = CMD_GET_VERSION,
        .edx = BACKDOOR_PORT,
        .esi = 0,
        .edi = 0,
    };

    // SYS_VMWARE_BACKDOOR = 1050
    const result = syscall.syscall1(1050, @intFromPtr(&regs));
    if (@as(isize, @bitCast(result)) < 0) {
        return false;
    }

    // Check if magic was returned
    return regs.ebx == BACKDOOR_MAGIC;
}

fn syncTime() bool {
    // Get host time via VMware backdoor
    var regs = VmwareRegs{
        .eax = BACKDOOR_MAGIC,
        .ebx = 0,
        .ecx = CMD_GET_TIME_FULL,
        .edx = BACKDOOR_PORT,
        .esi = 0,
        .edi = 0,
    };

    const result = syscall.syscall1(1050, @intFromPtr(&regs));
    if (@as(isize, @bitCast(result)) < 0) {
        return false;
    }

    // regs.eax contains lower 32 bits of seconds since epoch
    // regs.ebx contains upper 32 bits of seconds
    // regs.ecx contains microseconds
    const host_secs_lo = regs.eax;
    const host_secs_hi = regs.ebx;
    _ = regs.ecx; // microseconds - unused for now

    const host_secs: u64 = (@as(u64, host_secs_hi) << 32) | host_secs_lo;
    _ = host_secs;

    // TODO: Set system time via settimeofday syscall
    // For now, just log that we got the time
    // syscall.print("VMware Tools: Host time synced\n");

    return true;
}

fn getMonotonicTime() u64 {
    return syscall.gettime_ms() catch 0;
}

// Helper functions

fn printError(msg: []const u8, err: anyerror) void {
    syscall.print(msg);
    syscall.print(": ");
    syscall.print(@errorName(err));
    syscall.print("\n");
}

fn printDec(value: u64) void {
    if (value == 0) {
        syscall.print("0");
        return;
    }
    var buf: [20]u8 = undefined;
    var i: usize = 20;
    var v = value;
    while (v > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    syscall.print(buf[i..]);
}

export fn _start() noreturn {
    main();
    syscall.exit(0);
}

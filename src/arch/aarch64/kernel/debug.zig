// AArch64 Debug help
//
// Provides diagnostic utilities for exception handlers and kernel debugging.
//
// SECURITY: All handler pointers use atomic operations to prevent torn
// reads/writes during SMP operation. This matches the pattern used in
// interrupts/root.zig.

const std = @import("std");
const syscall = @import("syscall.zig");

// Console writer callback - set by interrupts package
// SECURITY: Use atomic operations to prevent torn pointer on SMP
var console_writer: ?*const fn ([]const u8) void = null;

/// Set the console writer for debug output
/// SECURITY: Uses atomic store with release ordering to ensure visibility
pub fn setConsoleWriter(writer: ?*const fn ([]const u8) void) void {
    @atomicStore(?*const fn ([]const u8) void, &console_writer, writer, .release);
}

/// Simple hex printing helpers (since we can't use std.fmt in some contexts)
fn write(msg: []const u8) void {
    // SECURITY: Use atomic load with acquire ordering to synchronize with setter
    if (@atomicLoad(?*const fn ([]const u8) void, &console_writer, .acquire)) |w| w(msg);
}

fn printHex64(val: u64) void {
    const chars = "0123456789ABCDEF";
    var buf: [18]u8 = [_]u8{0} ** 18;
    buf[0] = '0';
    buf[1] = 'x';
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        buf[17 - i] = chars[@as(usize, @truncate((val >> @as(u6, @intCast(i * 4))) & 0xF))];
    }
    write(&buf);
}

/// Dump all registers from a syscall frame (or exception frame)
/// NOTE: SyscallFrame uses x86 field names for cross-platform compatibility.
/// See syscall.zig header for the mapping: rax=x0, rdi=x1, rsi=x2, rdx=x3,
/// rbp=x29, r15=x30. x8 is named directly as it's the syscall number register.
pub fn dumpRegisters(frame: *const syscall.SyscallFrame) void {
    write("=== AArch64 Register Dump ===\n");
    write("  X0:  "); printHex64(frame.rax);  write("  X1:  "); printHex64(frame.rdi);  write("\n");
    write("  X2:  "); printHex64(frame.rsi);  write("  X3:  "); printHex64(frame.rdx);  write("\n");
    write("  X8:  "); printHex64(frame.x8);   write("  X29: "); printHex64(frame.rbp);  write("\n");
    write("  X30: "); printHex64(frame.r15);  write("  ELR: "); printHex64(frame.elr);  write("\n");
    write("  SPSR:"); printHex64(frame.spsr); write("  SP:  "); printHex64(frame.sp_el0);write("\n");
}

pub fn dumpControlRegisters() void {
    write("Control Registers:\n");
    const sctlr = asm volatile ("mrs %[ret], sctlr_el1" : [ret] "=r" (-> u64));
    write("  SCTLR_EL1: "); printHex64(sctlr); write("\n");
    const ttbr0 = asm volatile ("mrs %[ret], ttbr0_el1" : [ret] "=r" (-> u64));
    write("  TTBR0_EL1: "); printHex64(ttbr0); write("\n");
}

pub fn dumpPageFaultInfo(frame: *const syscall.SyscallFrame) void {
    _ = frame;
    const far = asm volatile ("mrs %[ret], far_el1" : [ret] "=r" (-> u64));
    const esr = asm volatile ("mrs %[ret], esr_el1" : [ret] "=r" (-> u64));
    write("Page Fault Details:\n");
    write("  Faulting Address (FAR): "); printHex64(far); write("\n");
    write("  Exception Syndrome (ESR): "); printHex64(esr); write("\n");
}

pub fn init() void {}

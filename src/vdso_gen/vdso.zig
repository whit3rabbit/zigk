const std = @import("std");

// Vvar page layout (must match kernel)
pub const Vvar = extern struct {
    sequence: u32,
    _pad1: u32,
    base_sec: u64,
    base_nsec: u64,
    tsc_frequency_hz: u64,
    last_tsc: u64,
    coarse_sec: u64,
    coarse_nsec: u64,
};

const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

const Timeval = extern struct {
    tv_sec: i64,
    tv_usec: i64,
};

fn do_clock_gettime(clk_id: std.os.linux.CLOCK, tp: *Timespec) i32 {
    const vvar_ptr = @as(*const volatile Vvar, @ptrFromInt(get_vvar_addr()));

    var seq: u32 = undefined;
    var valid = false;
    var sec: u64 = 0;
    var nsec: u64 = 0;
    var freq: u64 = 0;
    var last: u64 = 0;
    var current_tsc: u64 = 0;

    while (!valid) {
        seq = @atomicLoad(u32, &vvar_ptr.sequence, .acquire);
        if (seq % 2 != 0) {
            std.atomic.spinLoopHint();
            continue;
        }

        switch (clk_id) {
            .REALTIME => {
                sec = vvar_ptr.base_sec;
                nsec = vvar_ptr.base_nsec;
                freq = vvar_ptr.tsc_frequency_hz;
                last = vvar_ptr.last_tsc;

                var low: u32 = undefined;
                var high: u32 = undefined;
                asm volatile ("rdtsc"
                    : [low] "={eax}" (low),
                      [high] "={edx}" (high),
                    :
                    : .{ .memory = true }
                );
                current_tsc = (@as(u64, high) << 32) | low;
            },
            .MONOTONIC => {
                sec = vvar_ptr.base_sec;
                nsec = vvar_ptr.base_nsec;
                freq = vvar_ptr.tsc_frequency_hz;
                last = vvar_ptr.last_tsc;

                var low: u32 = undefined;
                var high: u32 = undefined;
                asm volatile ("rdtsc"
                    : [low] "={eax}" (low),
                      [high] "={edx}" (high),
                    :
                    : .{ .memory = true }
                );
                current_tsc = (@as(u64, high) << 32) | low;
            },
            else => return -1,
        }

        const seq2 = @atomicLoad(u32, &vvar_ptr.sequence, .acquire);
        if (seq == seq2) valid = true;
    }

    if (freq > 0) {
        const delta = current_tsc -% last;
        const delta_ns = (@as(u128, delta) * 1_000_000_000) / freq;
        nsec += @as(u64, @truncate(delta_ns));
    }

    sec += nsec / 1_000_000_000;
    nsec %= 1_000_000_000;

    tp.tv_sec = @intCast(sec);
    tp.tv_nsec = @intCast(nsec);

    return 0;
}

fn __kernel_gettimeofday(tv: ?*Timeval, tz: ?*anyopaque) callconv(.c) i32 {
    _ = tz;
    if (tv) |out_tv| {
        // Bypass VVAR for debugging
        out_tv.tv_sec = 1234;
        out_tv.tv_usec = 5678;
        return 0;
    }
    return 0;
}

fn __kernel_clock_gettime(clk_id: i32, tp: ?*Timespec) callconv(.c) i32 {
    _ = clk_id;
    if (tp) |out_tp| {
        // Bypass VVAR for debugging
        out_tp.tv_sec = 1234;
        out_tp.tv_nsec = 5678;
        return 0;
    }
    return -1;
}

fn __kernel_getcpu(cpu: ?*u32, node: ?*u32, cache: ?*anyopaque) callconv(.c) i32 {
    _ = cache;
    if (cpu) |p| p.* = 0;
    if (node) |p| p.* = 0;
    return 0;
}

noinline fn get_vvar_addr() u64 {
    var rip: u64 = undefined;
    asm volatile ("lea (%%rip), %[rip]"
        : [rip] "=r" (rip),
    );
    const page_mask: u64 = ~@as(u64, 4096 - 1);
    const vdso_base = rip & page_mask;
    return vdso_base - 4096;
}

comptime {
    @export(&__kernel_gettimeofday, .{ .name = "__kernel_gettimeofday", .linkage = .strong });
    @export(&__kernel_clock_gettime, .{ .name = "__kernel_clock_gettime", .linkage = .strong });
    @export(&__kernel_getcpu, .{ .name = "__kernel_getcpu", .linkage = .strong });
}

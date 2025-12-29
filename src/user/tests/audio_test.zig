const std = @import("std");
const syscall = @import("syscall");

export fn _start() noreturn {
    const ret = main(0, undefined);
    syscall.exit(ret) catch {};
    unreachable;
}

pub export fn main(argc: i32, argv: [*]const [*:0]const u8) i32 {
    _ = argc;
    _ = argv;

    const message = "Audio Test: Starting...\n";
    _ = syscall.write(1, message.ptr, message.len) catch 0;

    run_test() catch {
        // Write error message
        const err_msg = "Test failed\n";
        _ = syscall.write(2, err_msg.ptr, err_msg.len) catch 0;
        return 1;
    };

    const done_msg = "Test complete\n";
    _ = syscall.write(1, done_msg.ptr, done_msg.len) catch 0;
    return 0;
}

fn run_test() !void {
    const fd = try syscall.open("/dev/dsp", syscall.O_WRONLY, 0);
    defer syscall.close(fd) catch {};

    // Config
    const SNDCTL_DSP_SPEED: u32 = 0xC0045002;
    const SNDCTL_DSP_STEREO: u32 = 0xC0045003;
    const SNDCTL_DSP_SETFMT: u32 = 0xC0045005;
    const AFMT_S16_LE: u32 = 0x00000010;

    var speed: u32 = 48000;
    var stereo: u32 = 1;
    var fmt: u32 = AFMT_S16_LE;

    _ = syscall.ioctl(fd, SNDCTL_DSP_SPEED, @intFromPtr(&speed)) catch 0;
    _ = syscall.ioctl(fd, SNDCTL_DSP_STEREO, @intFromPtr(&stereo)) catch 0;
    _ = syscall.ioctl(fd, SNDCTL_DSP_SETFMT, @intFromPtr(&fmt)) catch 0;

    // Generate audio (48000 samples/sec, 16-bit stereo = 4 bytes per sample)
    const bytes_per_sample = 4;

    const chunk_samples = 1024; // Smaller chunk to fit on stack comfortably
    const chunk_size = chunk_samples * bytes_per_sample; // 4KB
    var buffer: [chunk_size]u8 = undefined;

    var t: f32 = 0.0;
    const dt: f32 = 1.0 / 48000.0;
    const freq: f32 = 440.0;

    var total_samples: usize = 0;

    // Play for 3 seconds
    while (total_samples < 48000 * 3) {
        var i: usize = 0;
        while (i < chunk_samples) : (i += 1) {
            const val = @sin(t * 2.0 * std.math.pi * freq);
            const sample = @as(i16, @intFromFloat(val * 10000.0));

            const offset = i * 4;
            const u_sample = @as(u16, @bitCast(sample));
            buffer[offset] = @truncate(u_sample);
            buffer[offset+1] = @truncate(u_sample >> 8);
            buffer[offset+2] = @truncate(u_sample);
            buffer[offset+3] = @truncate(u_sample >> 8);

            t += dt;
        }

        const written = syscall.write(fd, &buffer, buffer.len) catch return error.WriteFailed;
        _ = written;

        total_samples += chunk_samples;
    }
}

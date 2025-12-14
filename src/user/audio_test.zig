const std = @import("std");
const syscall = @import("syscall");

pub export fn main(argc: i32, argv: [*]const [*:0]const u8) i32 {
    _ = argc;
    _ = argv;

    const message = "Audio Test: Starting...\n";
    _ = syscall.write(1, message);

    run_test() catch |err| {
        // Write error message
        _ = syscall.write(2, "Test failed\n");
        return 1;
    };

    _ = syscall.write(1, "Test complete\n");
    return 0;
}

fn run_test() !void {
    const fd = try syscall.open("/dev/dsp", syscall.O_WRONLY);
    defer _ = syscall.close(fd);

    // Config
    const SNDCTL_DSP_SPEED: u32 = 0xC0045002;
    const SNDCTL_DSP_STEREO: u32 = 0xC0045003;
    const SNDCTL_DSP_SETFMT: u32 = 0xC0045005;
    const AFMT_S16_LE: u32 = 0x00000010;

    var speed: u32 = 48000;
    var stereo: u32 = 1;
    var fmt: u32 = AFMT_S16_LE;

    _ = syscall.ioctl(fd, SNDCTL_DSP_SPEED, @intFromPtr(&speed));
    _ = syscall.ioctl(fd, SNDCTL_DSP_STEREO, @intFromPtr(&stereo));
    _ = syscall.ioctl(fd, SNDCTL_DSP_SETFMT, @intFromPtr(&fmt));

    // Generate 1 second of audio
    const samples_per_sec = 48000;
    const bytes_per_sample = 4; // 16-bit stereo

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

        const written = syscall.write(fd, &buffer);
        if (written < 0) return error.WriteFailed;

        total_samples += chunk_samples;
    }
}

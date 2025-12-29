const std = @import("std");
const syscall = @import("syscall");
const sound = @import("uapi").sound;

export fn _start() noreturn {
    const ret = main(0, undefined);
    syscall.exit(ret) catch {};
    unreachable;
}

pub export fn main(argc: i32, argv: [*]const [*:0]const u8) i32 {
    _ = argc;
    _ = argv;

    _ = syscall.write(1, "sound_test: start\n".ptr, "sound_test: start\n".len) catch 0;

    run() catch {
        _ = syscall.write(2, "sound_test: failed\n".ptr, "sound_test: failed\n".len) catch 0;
        return 1;
    };

    _ = syscall.write(1, "sound_test: done\n".ptr, "sound_test: done\n".len) catch 0;
    return 0;
}

fn run() !void {
    const fd = try syscall.open("/dev/dsp", syscall.O_WRONLY, 0);
    defer syscall.close(fd) catch {};

    try configureS16Stereo(fd, 44100);
    try verifyOutputSpace(fd);
    try playToneS16(fd, 440.0, 1.5, 44100);

    // Switch to U8 mono to exercise format conversions.
    try configureU8Mono(fd, 22050);
    try verifyOutputSpace(fd);
    try playToneU8(fd, 660.0, 1.0, 22050);
}

fn configureS16Stereo(fd: i32, rate: u32) !void {
    var speed = rate;
    var channels: u32 = 2;
    var fmt: u32 = sound.AFMT_S16_LE;
    _ = try syscall.ioctl(fd, sound.SNDCTL_DSP_SPEED, @intFromPtr(&speed));
    _ = try syscall.ioctl(fd, sound.SNDCTL_DSP_CHANNELS, @intFromPtr(&channels));
    _ = try syscall.ioctl(fd, sound.SNDCTL_DSP_SETFMT, @intFromPtr(&fmt));
}

fn configureU8Mono(fd: i32, rate: u32) !void {
    var speed = rate;
    var channels: u32 = 1;
    var fmt: u32 = sound.AFMT_U8;
    _ = try syscall.ioctl(fd, sound.SNDCTL_DSP_SPEED, @intFromPtr(&speed));
    _ = try syscall.ioctl(fd, sound.SNDCTL_DSP_CHANNELS, @intFromPtr(&channels));
    _ = try syscall.ioctl(fd, sound.SNDCTL_DSP_SETFMT, @intFromPtr(&fmt));
}

const AudioBufInfo = extern struct {
    fragments: u32,
    fragstotal: u32,
    fragsize: u32,
    bytes: u32,
};

fn verifyOutputSpace(fd: i32) !void {
    var info: AudioBufInfo = .{ .fragments = 0, .fragstotal = 0, .fragsize = 0, .bytes = 0 };
    _ = try syscall.ioctl(fd, sound.SNDCTL_DSP_GETOSPACE, @intFromPtr(&info));
    if (info.bytes == 0) return error.Unexpected;
}

fn playToneS16(fd: i32, freq: f32, seconds: f32, rate: u32) !void {
    const frames_total = @as(usize, @intFromFloat(seconds * @as(f32, @floatFromInt(rate))));
    const bytes_per_frame: usize = 4;
    const chunk_frames = 1024;
    const chunk_bytes = chunk_frames * bytes_per_frame;
    var buffer: [chunk_bytes]u8 = undefined;

    var t: f32 = 0.0;
    const dt: f32 = 1.0 / @as(f32, @floatFromInt(rate));

    var frames_written: usize = 0;
    while (frames_written < frames_total) {
        const remaining = frames_total - frames_written;
        const frames = if (remaining < chunk_frames) remaining else chunk_frames;

        fillS16Stereo(buffer[0 .. frames * bytes_per_frame], freq, &t, dt);
        const slice = buffer[0 .. frames * bytes_per_frame];
        try writeAll(fd, slice);

        frames_written += frames;
    }
}

fn playToneU8(fd: i32, freq: f32, seconds: f32, rate: u32) !void {
    const frames_total = @as(usize, @intFromFloat(seconds * @as(f32, @floatFromInt(rate))));
    const bytes_per_frame: usize = 1;
    const chunk_frames = 1024;
    const chunk_bytes = chunk_frames * bytes_per_frame;
    var buffer: [chunk_bytes]u8 = undefined;

    var t: f32 = 0.0;
    const dt: f32 = 1.0 / @as(f32, @floatFromInt(rate));

    var frames_written: usize = 0;
    while (frames_written < frames_total) {
        const remaining = frames_total - frames_written;
        const frames = if (remaining < chunk_frames) remaining else chunk_frames;

        fillU8Mono(buffer[0..frames], freq, &t, dt);
        const slice = buffer[0..frames];
        try writeAll(fd, slice);

        frames_written += frames;
    }
}

fn fillS16Stereo(out: []u8, freq: f32, t: *f32, dt: f32) void {
    var i: usize = 0;
    while (i < out.len) : (i += 4) {
        const val = std.math.sin(t.* * 2.0 * std.math.pi * freq);
        const sample = @as(i16, @intFromFloat(val * 12000.0));
        const u_sample = @as(u16, @bitCast(sample));
        out[i] = @truncate(u_sample);
        out[i + 1] = @truncate(u_sample >> 8);
        out[i + 2] = @truncate(u_sample);
        out[i + 3] = @truncate(u_sample >> 8);
        t.* += dt;
    }
}

fn fillU8Mono(out: []u8, freq: f32, t: *f32, dt: f32) void {
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const val = std.math.sin(t.* * 2.0 * std.math.pi * freq);
        const sample = @as(i32, @intFromFloat(val * 64.0)) + 128;
        out[i] = @truncate(@as(u8, @intCast(std.math.clamp(sample, 0, 255))));
        t.* += dt;
    }
}

fn writeAll(fd: i32, buf: []const u8) !void {
    var offset: usize = 0;
    while (offset < buf.len) {
        const wrote = syscall.write(fd, buf.ptr + offset, buf.len - offset) catch |err| {
            if (err == error.Interrupted) continue;
            return err;
        };
        if (wrote == 0) return;
        offset += wrote;
    }
}

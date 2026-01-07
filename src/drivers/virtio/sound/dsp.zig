// VirtIO-Sound OSS /dev/dsp Interface
//
// Provides OSS (Open Sound System) compatibility for legacy applications
// like Doom via the /dev/dsp device file.
//
// Supported ioctls:
// - SNDCTL_DSP_SPEED    - Set sample rate
// - SNDCTL_DSP_STEREO   - Set mono/stereo
// - SNDCTL_DSP_CHANNELS - Set channel count
// - SNDCTL_DSP_SETFMT   - Set audio format
// - SNDCTL_DSP_GETOSPACE - Get available buffer space
// - SNDCTL_DSP_SYNC     - Wait for completion
// - SNDCTL_DSP_RESET    - Reset device

const std = @import("std");
const fd = @import("fd");
const user_mem = @import("user_mem");
const sound = @import("uapi").sound;
const root = @import("root.zig");
const config = @import("config.zig");

// =============================================================================
// OSS Buffer Info Structure (for GETOSPACE/GETISPACE)
// =============================================================================

/// Audio buffer info structure (matches OSS)
pub const AudioBufInfo = extern struct {
    /// Number of fragment buffers available
    fragments: i32,
    /// Total number of fragment buffers
    fragstotal: i32,
    /// Size of each fragment in bytes
    fragsize: i32,
    /// Total bytes available
    bytes: i32,
};

// =============================================================================
// /dev/dsp File Operations
// =============================================================================

/// File operations for /dev/dsp
pub const dsp_ops = fd.FileOps{
    .read = null, // Capture not implemented
    .write = dspWrite,
    .close = dspClose,
    .seek = null,
    .stat = null,
    .ioctl = dspIoctl,
    .mmap = null,
    .poll = dspPoll,
    .truncate = null,
};

/// Write audio data to device
fn dspWrite(fd_ctx: *fd.FileDescriptor, buf: []const u8) isize {
    _ = fd_ctx;

    const driver = root.getDriver() orelse return -1;

    if (buf.len == 0) return 0;

    const written = driver.write(buf);
    return written;
}

/// Close the device
fn dspClose(fd_ctx: *fd.FileDescriptor) isize {
    _ = fd_ctx;

    const driver = root.getDriver() orelse return 0;

    // Sync and reset
    driver.sync();
    driver.reset();
    return 0;
}

/// Handle ioctl calls
fn dspIoctl(fd_ctx: *fd.FileDescriptor, cmd: u64, arg: u64) isize {
    _ = fd_ctx;

    const driver = root.getDriver() orelse return -1;

    return handleOssIoctl(driver, @truncate(cmd), arg);
}

/// Poll for events
fn dspPoll(fd_ctx: *fd.FileDescriptor, requested_events: u32) u32 {
    _ = fd_ctx;

    const driver = root.getDriver() orelse return 0;

    var events: u32 = 0;

    // Check if we can write (POLLOUT)
    if (driver.canWrite()) {
        events |= 0x0004; // EPOLLOUT
    }

    // Check if we can read (POLLIN) - capture
    if (driver.canRead()) {
        events |= 0x0001; // EPOLLIN
    }

    return events & requested_events;
}

// =============================================================================
// OSS ioctl Handler
// =============================================================================

/// Handle OSS ioctl commands
fn handleOssIoctl(driver: *root.VirtioSoundDriver, cmd: u32, arg: usize) isize {
    switch (cmd) {
        sound.SNDCTL_DSP_RESET => {
            driver.reset();
            return 0;
        },

        sound.SNDCTL_DSP_SYNC => {
            driver.sync();
            return 0;
        },

        sound.SNDCTL_DSP_SPEED => {
            // Read requested rate from user
            var rate: u32 = 0;
            if (user_mem.copyFromUser(std.mem.asBytes(&rate), arg) != 0) {
                return -14; // EFAULT
            }

            // Set and clamp rate
            const actual = driver.setSampleRate(rate);

            // Write back actual rate
            if (user_mem.copyToUser(arg, std.mem.asBytes(&actual)) != 0) {
                return -14; // EFAULT
            }

            return 0;
        },

        sound.SNDCTL_DSP_STEREO => {
            // Read mono/stereo flag
            var stereo: u32 = 0;
            if (user_mem.copyFromUser(std.mem.asBytes(&stereo), arg) != 0) {
                return -14; // EFAULT
            }

            driver.oss_channels = if (stereo != 0) 2 else 1;

            // Write back what we set
            const result: u32 = if (driver.oss_channels == 2) 1 else 0;
            if (user_mem.copyToUser(arg, std.mem.asBytes(&result)) != 0) {
                return -14; // EFAULT
            }

            return 0;
        },

        sound.SNDCTL_DSP_CHANNELS => {
            // Read requested channels
            var channels: u32 = 0;
            if (user_mem.copyFromUser(std.mem.asBytes(&channels), arg) != 0) {
                return -14; // EFAULT
            }

            // Clamp to 1 or 2
            driver.oss_channels = if (channels >= 2) 2 else 1;

            // Write back actual
            if (user_mem.copyToUser(arg, std.mem.asBytes(&driver.oss_channels)) != 0) {
                return -14; // EFAULT
            }

            return 0;
        },

        sound.SNDCTL_DSP_SETFMT => {
            // Read requested format
            var format: u32 = 0;
            if (user_mem.copyFromUser(std.mem.asBytes(&format), arg) != 0) {
                return -14; // EFAULT
            }

            // Query current format
            if (format == sound.AFMT_QUERY) {
                if (user_mem.copyToUser(arg, std.mem.asBytes(&driver.oss_format)) != 0) {
                    return -14; // EFAULT
                }
                return 0;
            }

            // Set format
            const actual = driver.setFormat(format);

            // Write back actual
            if (user_mem.copyToUser(arg, std.mem.asBytes(&actual)) != 0) {
                return -14; // EFAULT
            }

            return 0;
        },

        sound.SNDCTL_DSP_GETOSPACE => {
            // Get available output buffer space
            const available = driver.getAvailableSpace();
            const buf_size = config.Limits.BUFFER_SIZE;
            const fragments = available / buf_size;
            const total_fragments = config.Limits.NUM_BUFFERS;

            const info = AudioBufInfo{
                .fragments = @intCast(fragments),
                .fragstotal = @intCast(total_fragments),
                .fragsize = @intCast(buf_size),
                .bytes = @intCast(available),
            };

            if (user_mem.copyToUser(arg, std.mem.asBytes(&info)) != 0) {
                return -14; // EFAULT
            }

            return 0;
        },

        sound.SNDCTL_DSP_GETISPACE => {
            // Get available input buffer space (capture)
            // Not fully implemented, return empty
            const info = AudioBufInfo{
                .fragments = 0,
                .fragstotal = @intCast(config.Limits.NUM_BUFFERS),
                .fragsize = @intCast(config.Limits.BUFFER_SIZE),
                .bytes = 0,
            };

            if (user_mem.copyToUser(arg, std.mem.asBytes(&info)) != 0) {
                return -14; // EFAULT
            }

            return 0;
        },

        sound.SNDCTL_DSP_GETBLKSIZE => {
            // Return fragment size
            const blksize: u32 = config.Limits.BUFFER_SIZE;

            if (user_mem.copyToUser(arg, std.mem.asBytes(&blksize)) != 0) {
                return -14; // EFAULT
            }

            return 0;
        },

        else => {
            // Unknown ioctl - return ENOTTY per POSIX semantics
            // Returning success would hide bugs and violate fail-secure principle
            return -25; // ENOTTY
        },
    }
}

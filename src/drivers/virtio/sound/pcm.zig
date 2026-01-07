// VirtIO-Sound PCM Stream Management
//
// Manages PCM audio streams for playback and capture.
// Handles stream state, parameter negotiation, and audio buffer management.

const std = @import("std");
const config = @import("config.zig");
const request = @import("request.zig");
const pmm = @import("pmm");
const hal = @import("hal");
const sync = @import("sync");

// =============================================================================
// Stream State
// =============================================================================

/// PCM stream state machine
pub const StreamState = enum {
    /// Stream is not initialized
    idle,
    /// Stream parameters are set, ready to start
    prepared,
    /// Stream is actively playing/recording
    running,
    /// Stream is stopped (can restart)
    stopped,
    /// Stream encountered an error
    error_state,
};

// =============================================================================
// Ring Buffer for Audio Data
// =============================================================================

/// Ring buffer for double-buffering audio data
pub const RingBuffer = struct {
    /// Backing memory (kernel virtual address)
    buffer: []u8,

    /// Physical address of buffer (for DMA)
    phys_addr: u64,

    /// Total buffer size
    size: usize,

    /// Write position (producer)
    write_pos: usize,

    /// Read position (consumer)
    read_pos: usize,

    /// Lock for concurrent access
    lock: sync.Spinlock,

    const Self = @This();

    /// Allocate and initialize a ring buffer
    pub fn init(size_pages: usize) ?*Self {
        const heap = @import("heap");
        const self = heap.allocator().create(Self) catch return null;

        // Allocate physical pages for DMA
        const phys = pmm.allocZeroedPages(size_pages) orelse {
            heap.allocator().destroy(self);
            return null;
        };

        const virt = hal.paging.physToVirt(phys);
        const size = size_pages * 4096;

        self.* = Self{
            .buffer = @as([*]u8, @ptrFromInt(@intFromPtr(virt)))[0..size],
            .phys_addr = phys,
            .size = size,
            .write_pos = 0,
            .read_pos = 0,
            .lock = .{},
        };

        return self;
    }

    /// Free the ring buffer
    pub fn deinit(self: *Self) void {
        const heap = @import("heap");
        const pages = (self.size + 4095) / 4096;
        pmm.freePages(self.phys_addr, pages);
        heap.allocator().destroy(self);
    }

    /// Write data to the ring buffer
    /// Returns number of bytes written
    pub fn write(self: *Self, data: []const u8) usize {
        const held = self.lock.acquire();
        defer held.release();

        const free = self.freeSpaceInternal();
        const to_write = @min(data.len, free);

        if (to_write == 0) return 0;

        // Write in one or two chunks depending on wrap
        const first_chunk = @min(to_write, self.size - self.write_pos);
        @memcpy(self.buffer[self.write_pos..][0..first_chunk], data[0..first_chunk]);

        if (to_write > first_chunk) {
            const second_chunk = to_write - first_chunk;
            @memcpy(self.buffer[0..second_chunk], data[first_chunk..][0..second_chunk]);
        }

        self.write_pos = (self.write_pos + to_write) % self.size;
        return to_write;
    }

    /// Read data from the ring buffer
    /// Returns number of bytes read
    pub fn read(self: *Self, out: []u8) usize {
        const held = self.lock.acquire();
        defer held.release();

        const avail_bytes = self.availableInternal();
        const to_read = @min(out.len, avail_bytes);

        if (to_read == 0) return 0;

        // Read in one or two chunks depending on wrap
        const first_chunk = @min(to_read, self.size - self.read_pos);
        @memcpy(out[0..first_chunk], self.buffer[self.read_pos..][0..first_chunk]);

        if (to_read > first_chunk) {
            const second_chunk = to_read - first_chunk;
            @memcpy(out[first_chunk..][0..second_chunk], self.buffer[0..second_chunk]);
        }

        self.read_pos = (self.read_pos + to_read) % self.size;
        return to_read;
    }

    /// Get pointer and size for next contiguous read region
    /// Used for submitting to VirtIO without copying
    pub fn peekContiguous(self: *Self) struct { ptr: [*]u8, phys: u64, len: usize } {
        const held = self.lock.acquire();
        defer held.release();

        const avail_bytes = self.availableInternal();
        const contiguous = @min(avail_bytes, self.size - self.read_pos);

        return .{
            .ptr = self.buffer.ptr + self.read_pos,
            .phys = self.phys_addr + self.read_pos,
            .len = contiguous,
        };
    }

    /// Consume bytes after they have been processed
    pub fn consume(self: *Self, bytes: usize) void {
        const held = self.lock.acquire();
        defer held.release();

        const avail_bytes = self.availableInternal();
        const to_consume = @min(bytes, avail_bytes);
        self.read_pos = (self.read_pos + to_consume) % self.size;
    }

    /// Get available data to read
    pub fn available(self: *Self) usize {
        const held = self.lock.acquire();
        defer held.release();
        return self.availableInternal();
    }

    fn availableInternal(self: *const Self) usize {
        if (self.write_pos >= self.read_pos) {
            return self.write_pos - self.read_pos;
        } else {
            return self.size - self.read_pos + self.write_pos;
        }
    }

    /// Get free space for writing
    pub fn freeSpace(self: *Self) usize {
        const held = self.lock.acquire();
        defer held.release();
        return self.freeSpaceInternal();
    }

    fn freeSpaceInternal(self: *const Self) usize {
        // Reserve one byte to distinguish full from empty
        return self.size - self.availableInternal() - 1;
    }

    /// Reset buffer to empty state
    pub fn reset(self: *Self) void {
        const held = self.lock.acquire();
        defer held.release();
        self.write_pos = 0;
        self.read_pos = 0;
        // Zero buffer to prevent info leaks
        @memset(self.buffer, 0);
    }
};

// =============================================================================
// PCM Stream
// =============================================================================

/// PCM audio stream
pub const PcmStream = struct {
    /// Stream ID (assigned by device)
    stream_id: u32,

    /// Stream direction
    direction: u8,

    /// Current state
    state: StreamState,

    /// Negotiated format index
    format: u8,

    /// Negotiated rate index
    rate: u8,

    /// Number of channels
    channels: u8,

    /// Buffer size in bytes (period * periods)
    buffer_bytes: u32,

    /// Period size in bytes (interrupt interval)
    period_bytes: u32,

    /// Device capabilities (from PCM_INFO)
    supported_formats: u64,
    supported_rates: u64,
    channels_min: u8,
    channels_max: u8,

    /// Ring buffer for this stream
    ring_buffer: ?*RingBuffer,

    /// Bytes played/captured since start
    bytes_processed: u64,

    /// Underrun/overrun count
    xrun_count: u32,

    const Self = @This();

    /// Initialize a stream from PCM_INFO response
    /// SECURITY: Validates device-provided parameters to prevent DoS
    pub fn init(stream_id: u32, info: *const request.PcmInfo) Self {
        // Validate and sanitize device-provided channel limits
        // If device provides invalid values (min > max), use safe defaults
        var ch_min = info.channels_min;
        var ch_max = info.channels_max;

        if (ch_min > ch_max) {
            // Device provided invalid range - swap them
            ch_min = info.channels_max;
            ch_max = info.channels_min;
        }
        // Ensure at least 1 channel and reasonable max (32 is typical hardware limit)
        if (ch_min == 0) ch_min = 1;
        if (ch_max == 0) ch_max = 2;
        if (ch_max > 32) ch_max = 32;

        return Self{
            .stream_id = stream_id,
            .direction = info.direction,
            .state = .idle,
            .format = 0,
            .rate = 0,
            .channels = 0,
            .buffer_bytes = 0,
            .period_bytes = 0,
            .supported_formats = info.formats,
            .supported_rates = info.rates,
            .channels_min = ch_min,
            .channels_max = ch_max,
            .ring_buffer = null,
            .bytes_processed = 0,
            .xrun_count = 0,
        };
    }

    /// Check if stream is output (playback)
    pub fn isOutput(self: *const Self) bool {
        return self.direction == config.StreamDirection.OUTPUT;
    }

    /// Check if stream is input (capture)
    pub fn isInput(self: *const Self) bool {
        return self.direction == config.StreamDirection.INPUT;
    }

    /// Check if format is supported
    pub fn supportsFormat(self: *const Self, format: u64) bool {
        return (self.supported_formats & format) != 0;
    }

    /// Check if rate is supported
    pub fn supportsRate(self: *const Self, rate: u64) bool {
        return (self.supported_rates & rate) != 0;
    }

    /// Check if channel count is valid
    pub fn supportsChannels(self: *const Self, ch: u8) bool {
        return ch >= self.channels_min and ch <= self.channels_max;
    }

    /// Allocate ring buffer for this stream
    pub fn allocateBuffer(self: *Self) bool {
        if (self.ring_buffer != null) return true;

        // Allocate based on buffer_bytes or default
        const size = if (self.buffer_bytes > 0)
            self.buffer_bytes
        else
            config.Limits.BUFFER_POOL_SIZE;

        const pages = (size + 4095) / 4096;
        self.ring_buffer = RingBuffer.init(pages);
        return self.ring_buffer != null;
    }

    /// Free ring buffer
    pub fn freeBuffer(self: *Self) void {
        if (self.ring_buffer) |rb| {
            rb.deinit();
            self.ring_buffer = null;
        }
    }

    /// Reset stream state
    pub fn reset(self: *Self) void {
        self.state = .idle;
        self.bytes_processed = 0;
        self.xrun_count = 0;
        if (self.ring_buffer) |rb| {
            rb.reset();
        }
    }

    /// Get bytes per frame (channels * sample_size)
    pub fn bytesPerFrame(self: *const Self) u32 {
        const sample_bytes: u32 = switch (self.format) {
            0...4 => 1, // 8-bit formats
            5, 6 => 2, // 16-bit formats
            7...12 => 3, // 24-bit packed formats
            13...18 => 4, // 32-bit formats
            19 => 4, // float
            20 => 8, // float64
            else => 2, // default to 16-bit
        };
        return sample_bytes * self.channels;
    }

    /// Get sample rate in Hz
    pub fn sampleRateHz(self: *const Self) u32 {
        const rate_mask: u64 = @as(u64, 1) << @intCast(self.rate);
        return config.PcmRate.toHz(rate_mask) orelse 48000;
    }
};

// =============================================================================
// Stream Manager
// =============================================================================

/// Manages all PCM streams for a device
pub const StreamManager = struct {
    /// All streams (indexed by stream_id)
    streams: [config.Limits.MAX_STREAMS]?PcmStream,

    /// Number of configured streams
    stream_count: u8,

    /// Currently active output stream (for OSS single-stream mode)
    active_output: ?u32,

    /// Currently active input stream
    active_input: ?u32,

    /// Lock for stream access
    lock: sync.Spinlock,

    const Self = @This();

    /// Initialize empty stream manager
    pub fn init() Self {
        return Self{
            .streams = [_]?PcmStream{null} ** config.Limits.MAX_STREAMS,
            .stream_count = 0,
            .active_output = null,
            .active_input = null,
            .lock = .{},
        };
    }

    /// Add a stream from PCM_INFO
    pub fn addStream(self: *Self, stream_id: u32, info: *const request.PcmInfo) bool {
        const held = self.lock.acquire();
        defer held.release();

        if (stream_id >= config.Limits.MAX_STREAMS) return false;
        if (self.streams[stream_id] != null) return false;

        self.streams[stream_id] = PcmStream.init(stream_id, info);
        self.stream_count += 1;
        return true;
    }

    /// Get a stream by ID
    pub fn getStream(self: *Self, stream_id: u32) ?*PcmStream {
        if (stream_id >= config.Limits.MAX_STREAMS) return null;
        if (self.streams[stream_id] == null) return null;
        return &self.streams[stream_id].?;
    }

    /// Find first output stream
    pub fn findOutputStream(self: *Self) ?*PcmStream {
        const held = self.lock.acquire();
        defer held.release();

        for (&self.streams) |*ms| {
            if (ms.*) |*s| {
                if (s.isOutput()) return s;
            }
        }
        return null;
    }

    /// Find first input stream
    pub fn findInputStream(self: *Self) ?*PcmStream {
        const held = self.lock.acquire();
        defer held.release();

        for (&self.streams) |*ms| {
            if (ms.*) |*s| {
                if (s.isInput()) return s;
            }
        }
        return null;
    }

    /// Get or set active output stream
    pub fn getActiveOutput(self: *Self) ?*PcmStream {
        if (self.active_output) |id| {
            return self.getStream(id);
        }
        // Auto-select first output stream
        if (self.findOutputStream()) |s| {
            self.active_output = s.stream_id;
            return s;
        }
        return null;
    }

    /// Reset all streams
    pub fn resetAll(self: *Self) void {
        const held = self.lock.acquire();
        defer held.release();

        for (&self.streams) |*ms| {
            if (ms.*) |*s| {
                s.reset();
            }
        }
        self.active_output = null;
        self.active_input = null;
    }

    /// Clean up all streams
    pub fn deinit(self: *Self) void {
        for (&self.streams) |*ms| {
            if (ms.*) |*s| {
                s.freeBuffer();
                ms.* = null;
            }
        }
        self.stream_count = 0;
    }
};

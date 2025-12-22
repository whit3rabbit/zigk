// E1000e Packet Buffer Pool
//
// Pre-allocated packet buffer pool for RX processing.
// Eliminates heap allocation under spinlock in processRxLimited().

const sync = @import("sync");
const config = @import("config.zig");

/// Pre-allocated packet buffer pool for RX processing.
/// Eliminates heap allocation under spinlock in processRxLimited().
///
/// Benefits:
/// - No nested spinlock acquisition (heap has its own lock)
/// - Bounded allocation latency (O(n) worst case, typically O(1))
/// - No OOM during packet processing
/// - No heap fragmentation from packet-sized allocations
///
/// Callers MUST release buffers back to the pool after processing.
pub const PacketPool = struct {
    /// Pre-allocated packet buffers
    /// Each buffer is BUFFER_SIZE bytes (2048), total ~2MB for 1024 buffers
    /// Security: Zero-initialize to prevent info leaks on error paths or partial reads
    buffers: [config.PACKET_POOL_SIZE][config.BUFFER_SIZE]u8 = [_][config.BUFFER_SIZE]u8{[_]u8{0} ** config.BUFFER_SIZE} ** config.PACKET_POOL_SIZE,

    /// Bitmap tracking which buffers are allocated
    allocated: [config.PACKET_POOL_SIZE]bool = [_]bool{false} ** config.PACKET_POOL_SIZE,

    /// Hint for O(1) allocation: first index that might be free
    free_head: usize = 0,

    /// Count of free buffers (for debugging/stats)
    free_count: usize = config.PACKET_POOL_SIZE,

    /// Lock for thread-safe access
    lock: sync.Spinlock = .{},

    const Self = @This();

    /// Acquire a buffer from the pool.
    /// Returns null if pool is exhausted (backpressure signal).
    /// Caller MUST call release() when done with the buffer.
    pub fn acquire(self: *Self) ?[]u8 {
        const held = self.lock.acquire();
        defer held.release();

        if (self.free_count == 0) return null;

        // Linear search from free_head hint
        var i = self.free_head;
        while (i < config.PACKET_POOL_SIZE) : (i += 1) {
            if (!self.allocated[i]) {
                self.allocated[i] = true;
                self.free_count -= 1;
                // Advance hint past this allocation
                self.free_head = i + 1;
                return &self.buffers[i];
            }
        }

        // Wrap around if we started mid-pool
        i = 0;
        while (i < self.free_head) : (i += 1) {
            if (!self.allocated[i]) {
                self.allocated[i] = true;
                self.free_count -= 1;
                self.free_head = i + 1;
                return &self.buffers[i];
            }
        }

        return null;
    }

    /// Return a buffer to the pool.
    /// Safe to call with slices shorter than BUFFER_SIZE (only pointer is checked).
    pub fn release(self: *Self, buf: []u8) void {
        const held = self.lock.acquire();
        defer held.release();

        // Calculate index from pointer arithmetic
        const base = @intFromPtr(&self.buffers[0]);
        const ptr = @intFromPtr(buf.ptr);

        // Validate pointer is within our buffer range
        if (ptr < base) return;
        const offset = ptr - base;

        // Security: Verify pointer is properly aligned to buffer boundary
        // Misaligned pointers indicate corruption or incorrect buffer usage
        if (offset % config.BUFFER_SIZE != 0) return;

        const idx = offset / config.BUFFER_SIZE;

        // Validate index and that it was actually allocated
        if (idx >= config.PACKET_POOL_SIZE) return;
        if (!self.allocated[idx]) return; // Double-free protection

        self.allocated[idx] = false;
        self.free_count += 1;

        // Reset hint if this buffer is before current hint
        if (idx < self.free_head) {
            self.free_head = idx;
        }
    }

    /// Get current pool statistics
    pub fn getStats(self: *Self) struct { free: usize, used: usize } {
        const held = self.lock.acquire();
        defer held.release();
        return .{
            .free = self.free_count,
            .used = config.PACKET_POOL_SIZE - self.free_count,
        };
    }
};

/// Global packet pool instance for RX buffer allocation
pub var packet_pool: PacketPool = .{};

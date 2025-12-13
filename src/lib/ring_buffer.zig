// Generic Ring Buffer
//
// Fixed-size circular buffer for interrupt-safe I/O operations.
// Used by keyboard driver for scancode and ASCII character buffering.
//
// Spec Reference: Spec 003 data-model.md
//
// Features:
//   - Comptime-configurable capacity
//   - push() drops oldest on overflow (ring buffer semantics)
//   - pop() returns null if empty
//   - No dynamic allocation - suitable for interrupt context

const std = @import("std");

/// Generic ring buffer with comptime-specified capacity
///
/// Features overwrite-on-overflow semantics: if the buffer is full,
/// pushing a new element overwrites the oldest element.
///
/// T: Element type (e.g., u8 for bytes)
/// capacity: Maximum number of elements (must be power of 2 for efficient modulo)
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    // Validate capacity is power of 2 for efficient wraparound
    comptime {
        if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
            @compileError("RingBuffer capacity must be a power of 2");
        }
    }

    return struct {
        const Self = @This();

        /// Mask for efficient modulo (capacity - 1)
        const MASK: usize = capacity - 1;

        /// Storage array
        buffer: [capacity]T = undefined,

        /// Index of next element to read (oldest element)
        head: usize = 0,

        /// Index of next write position
        tail: usize = 0,

        /// Current number of elements (0 to capacity)
        count: usize = 0,

        /// Push an element to the buffer
        /// If buffer is full, drops the oldest element (ring semantics)
        /// Returns true if an element was dropped
        pub fn push(self: *Self, value: T) bool {
            const dropped = self.count == capacity;

            if (dropped) {
                // Buffer full - advance head to drop oldest
                self.head = (self.head + 1) & MASK;
            } else {
                self.count += 1;
            }

            // Write at tail position
            self.buffer[self.tail] = value;
            self.tail = (self.tail + 1) & MASK;

            return dropped;
        }

        /// Pop the oldest element from the buffer
        /// Returns null if buffer is empty
        pub fn pop(self: *Self) ?T {
            if (self.count == 0) {
                return null;
            }

            const value = self.buffer[self.head];
            self.head = (self.head + 1) & MASK;
            self.count -= 1;

            return value;
        }

        /// Peek at the oldest element without removing it
        pub fn peek(self: *const Self) ?T {
            if (self.count == 0) {
                return null;
            }
            return self.buffer[self.head];
        }

        /// Check if the buffer is empty
        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }

        /// Check if the buffer is full
        pub fn isFull(self: *const Self) bool {
            return self.count == capacity;
        }

        /// Get current number of elements
        pub fn len(self: *const Self) usize {
            return self.count;
        }

        /// Get buffer capacity
        pub fn getCapacity() usize {
            return capacity;
        }

        /// Clear all elements
        pub fn clear(self: *Self) void {
            self.head = 0;
            self.tail = 0;
            self.count = 0;
        }
    };
}

// =============================================================================
// Unit Tests
// =============================================================================

test "ring buffer basic push/pop" {
    var buf = RingBuffer(u8, 4){};

    try std.testing.expect(buf.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), buf.len());

    // Push elements
    try std.testing.expect(!buf.push(1));
    try std.testing.expect(!buf.push(2));
    try std.testing.expect(!buf.push(3));

    try std.testing.expectEqual(@as(usize, 3), buf.len());
    try std.testing.expect(!buf.isEmpty());
    try std.testing.expect(!buf.isFull());

    // Pop and verify FIFO order
    try std.testing.expectEqual(@as(?u8, 1), buf.pop());
    try std.testing.expectEqual(@as(?u8, 2), buf.pop());
    try std.testing.expectEqual(@as(?u8, 3), buf.pop());
    try std.testing.expectEqual(@as(?u8, null), buf.pop());

    try std.testing.expect(buf.isEmpty());
}

test "ring buffer overflow drops oldest" {
    var buf = RingBuffer(u8, 4){};

    // Fill buffer
    _ = buf.push(1);
    _ = buf.push(2);
    _ = buf.push(3);
    _ = buf.push(4);

    try std.testing.expect(buf.isFull());
    try std.testing.expectEqual(@as(usize, 4), buf.len());

    // Push more - should drop oldest
    try std.testing.expect(buf.push(5)); // drops 1
    try std.testing.expect(buf.push(6)); // drops 2

    // Buffer should contain 3, 4, 5, 6
    try std.testing.expectEqual(@as(usize, 4), buf.len());
    try std.testing.expectEqual(@as(?u8, 3), buf.pop());
    try std.testing.expectEqual(@as(?u8, 4), buf.pop());
    try std.testing.expectEqual(@as(?u8, 5), buf.pop());
    try std.testing.expectEqual(@as(?u8, 6), buf.pop());
}

test "ring buffer peek" {
    var buf = RingBuffer(u8, 4){};

    try std.testing.expectEqual(@as(?u8, null), buf.peek());

    _ = buf.push(42);
    try std.testing.expectEqual(@as(?u8, 42), buf.peek());
    try std.testing.expectEqual(@as(usize, 1), buf.len()); // peek doesn't remove

    _ = buf.pop();
    try std.testing.expectEqual(@as(?u8, null), buf.peek());
}

test "ring buffer clear" {
    var buf = RingBuffer(u8, 4){};

    _ = buf.push(1);
    _ = buf.push(2);
    _ = buf.push(3);

    buf.clear();

    try std.testing.expect(buf.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), buf.len());
    try std.testing.expectEqual(@as(?u8, null), buf.pop());
}

test "ring buffer wraparound" {
    var buf = RingBuffer(u8, 4){};

    // Fill and empty multiple times to test wraparound
    for (0..10) |i| {
        _ = buf.push(@truncate(i));
    }

    // Should have last 4 values: 6, 7, 8, 9
    try std.testing.expectEqual(@as(?u8, 6), buf.pop());
    try std.testing.expectEqual(@as(?u8, 7), buf.pop());
    try std.testing.expectEqual(@as(?u8, 8), buf.pop());
    try std.testing.expectEqual(@as(?u8, 9), buf.pop());
}

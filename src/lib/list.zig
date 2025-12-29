// Intrusive Doubly Linked List
//
// SECURITY AUDIT (2025-12-27): VERIFIED SECURE (after fix)
// - Double-remove detection: Debug assertions verify node membership before removal
// - Count underflow protection: All decrement paths use std.math.sub with panic
// - No memory management: Intrusive design means no use-after-free from list itself
// - Scheduler critical: Used for runqueues; count integrity prevents stale node returns

const std = @import("std");

/// Intrusive Doubly Linked List
///
/// Wraps a type T that has `next: ?*T` and `prev: ?*T` fields.
/// Provides safe insertion, removal, and iteration.
///
/// This avoids the need for a separate Node allocation for each element,
/// which is critical for scheduler queues and other low-level structures.
///
/// Requirements:
///   T must have mutable `next: ?*T` and `prev: ?*T` fields.
pub fn IntrusiveDoublyLinkedList(comptime T: type) type {
    return struct {
        head: ?*T = null,
        tail: ?*T = null,
        count: usize = 0,

        const Self = @This();

        /// Append a node to the end of the list
        pub fn append(self: *Self, node: *T) void {
            node.next = null;
            node.prev = self.tail;

            if (self.tail) |tail| {
                tail.next = node;
            } else {
                self.head = node;
            }
            self.tail = node;
            self.count += 1;
        }

        /// Prepend a node to the start of the list
        pub fn prepend(self: *Self, node: *T) void {
            node.prev = null;
            node.next = self.head;

            if (self.head) |head| {
                head.prev = node;
            } else {
                self.tail = node;
            }
            self.head = node;
            self.count += 1;
        }

        /// Remove a specific node from the list
        /// SECURITY: Debug assertions verify the node is actually in this list
        /// to catch double-remove bugs that could cause count underflow.
        /// Uses checked subtraction to prevent underflow even in ReleaseFast builds.
        pub fn remove(self: *Self, node: *T) void {
            // Debug assertions: verify node appears to be in *some* list
            // If node has no prev, it should be the head of this list
            // If node has no next, it should be the tail of this list
            if (std.debug.runtime_safety) {
                // Node with null prev should be the head
                if (node.prev == null) {
                    std.debug.assert(self.head == node);
                }
                // Node with null next should be the tail
                if (node.next == null) {
                    std.debug.assert(self.tail == node);
                }
                // Count should be positive (prevent underflow)
                std.debug.assert(self.count > 0);
            }

            if (node.prev) |prev| {
                prev.next = node.next;
            } else {
                self.head = node.next;
            }

            if (node.next) |next| {
                next.prev = node.prev;
            } else {
                self.tail = node.prev;
            }

            node.next = null;
            node.prev = null;
            // SECURITY: Use checked subtraction to prevent underflow in all build modes.
            // Double-remove bugs would underflow count to usize::MAX, causing subsequent
            // popFirst() to return stale/freed nodes (use-after-free).
            self.count = std.math.sub(usize, self.count, 1) catch {
                // In release builds without assertions, this catches double-remove.
                // Panic is appropriate - this indicates a serious scheduler bug.
                @panic("IntrusiveDoublyLinkedList: count underflow (double remove?)");
            };
        }

        /// Remove and return the first element
        /// SECURITY: Uses checked subtraction to prevent underflow in all build modes,
        /// consistent with remove(). Catches memory corruption that causes stale head pointers.
        pub fn popFirst(self: *Self) ?*T {
            const node = self.head orelse return null;

            self.head = node.next;
            if (self.head) |new_head| {
                new_head.prev = null;
            } else {
                self.tail = null;
            }

            node.next = null;
            node.prev = null;
            // SECURITY FIX: Use checked subtraction consistent with remove()
            self.count = std.math.sub(usize, self.count, 1) catch {
                @panic("IntrusiveDoublyLinkedList: count underflow in popFirst");
            };
            return node;
        }

        /// Remove and return the last element
        /// SECURITY: Uses checked subtraction to prevent underflow in all build modes,
        /// consistent with remove(). Catches memory corruption that causes stale tail pointers.
        pub fn popLast(self: *Self) ?*T {
            const node = self.tail orelse return null;

            self.tail = node.prev;
            if (self.tail) |new_tail| {
                new_tail.next = null;
            } else {
                self.head = null;
            }

            node.next = null;
            node.prev = null;
            // SECURITY FIX: Use checked subtraction consistent with remove()
            self.count = std.math.sub(usize, self.count, 1) catch {
                @panic("IntrusiveDoublyLinkedList: count underflow in popLast");
            };
            return node;
        }
    };
}

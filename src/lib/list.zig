/// Intrusive Doubly Linked List
///
/// Wraps a type T that has `next: ?*T` and `prev: ?*T` fields.
/// Provides safe insertion, removal, and iteration.
///
/// This avoids the need for a separate Node allocation for each element,
/// which is critical for scheduler queues and other low-level structures.
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
        pub fn remove(self: *Self, node: *T) void {
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
            self.count -= 1;
        }

        /// Remove and return the first element
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
            self.count -= 1;
            return node;
        }

        /// Remove and return the last element
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
            self.count -= 1;
            return node;
        }
    };
}

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

// Simplified VMA struct for testing the algorithm
const Vma = struct {
    start: usize,
    end: usize,
    prev: ?*Vma = null,
    next: ?*Vma = null,
};

// Simplified VMM structure to test list manipulation
const TestVmm = struct {
    head: ?*Vma = null,
    allocator: Allocator,

    pub fn init(allocator: Allocator) TestVmm {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TestVmm) void {
        var current = self.head;
        while (current) |node| {
            const next = node.next;
            self.allocator.destroy(node);
            current = next;
        }
    }

    pub fn insert(self: *TestVmm, start: usize, end: usize) !void {
        const new_vma = try self.allocator.create(Vma);
        new_vma.* = .{ .start = start, .end = end };
        
        // Simple sorted insert
        if (self.head == null) {
            self.head = new_vma;
            return;
        }

        var curr = self.head;
        var prev: ?*Vma = null;
        while (curr) |node| {
            if (node.start > start) break;
            prev = node;
            curr = node.next;
        }

        if (prev) |p| {
            new_vma.next = p.next;
            new_vma.prev = p;
            p.next = new_vma;
            if (new_vma.next) |next| next.prev = new_vma;
        } else {
            // Insert at head
            new_vma.next = self.head;
            if (self.head) |h| h.prev = new_vma;
            self.head = new_vma;
        }
    }

    // The split logic we want to implement in the kernel
    pub fn munmap(self: *TestVmm, start: usize, len: usize) !void {
        const end = start + len;
        
        var curr = self.head;
        while (curr) |vma| {
            const next_vma = vma.next; // Save next since we might free current

            // Check overlap
            if (vma.start < end and vma.end > start) {
                // Determine intersection
                const intersect_start = @max(vma.start, start);
                const intersect_end = @min(vma.end, end);

                // Case 1: Unmapping entire VMA
                if (intersect_start == vma.start and intersect_end == vma.end) {
                    self.removeVma(vma);
                    self.allocator.destroy(vma);
                }
                // Case 2: Unmapping start of VMA (shrink from left)
                else if (intersect_start == vma.start) {
                    vma.start = intersect_end;
                }
                // Case 3: Unmapping end of VMA (shrink from right)
                else if (intersect_end == vma.end) {
                    vma.end = intersect_start;
                }
                // Case 4: Hole in middle (Split)
                else {
                    // Create new VMA for the right part
                    const new_node = try self.allocator.create(Vma);
                    new_node.* = .{
                        .start = intersect_end,
                        .end = vma.end,
                        .prev = vma,
                        .next = vma.next,
                    };

                    // Update links
                    if (vma.next) |next| next.prev = new_node;
                    vma.next = new_node;
                    
                    // Update original VMA (left part)
                    vma.end = intersect_start;
                }
            }
            curr = next_vma;
        }
    }

    fn removeVma(self: *TestVmm, vma: *Vma) void {
        if (vma.prev) |prev| {
            prev.next = vma.next;
        } else {
            self.head = vma.next;
        }
        if (vma.next) |next| {
            next.prev = vma.prev;
        }
    }
};

test "VMA splitting logic" {
    var vmm = TestVmm.init(testing.allocator);
    defer vmm.deinit();

    // Map [100, 200)
    try vmm.insert(100, 200);

    // Unmap [140, 160) - Should split into [100, 140) and [160, 200)
    try vmm.munmap(140, 20);

    var count: usize = 0;
    var curr = vmm.head;
    while (curr) |node| {
        if (count == 0) {
            try testing.expectEqual(@as(usize, 100), node.start);
            try testing.expectEqual(@as(usize, 140), node.end);
        } else if (count == 1) {
            try testing.expectEqual(@as(usize, 160), node.start);
            try testing.expectEqual(@as(usize, 200), node.end);
        }
        curr = node.next;
        count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "VMA edge shrinking" {
    var vmm = TestVmm.init(testing.allocator);
    defer vmm.deinit();

    // Map [100, 200)
    try vmm.insert(100, 200);

    // Unmap [100, 120) - Shrink left
    try vmm.munmap(100, 20);
    
    // Unmap [180, 200) - Shrink right
    try vmm.munmap(180, 20);

    const node = vmm.head.?;
    try testing.expectEqual(@as(usize, 120), node.start);
    try testing.expectEqual(@as(usize, 180), node.end);
    try testing.expect(node.next == null);
}

const std = @import("std");

// WARNING: This file duplicates logic from `src/net/ipv4/reassembly.zig` to facilitate
// unit testing without pulling in the entire kernel dependency tree (HAL, Sync, etc).
// If `ReassemblyEntry`, `Hole`, or `updateHoles` change in the source, this test MUST be updated.
// This test verifies the correctness of the overlap detection algorithm in isolation.

const MAX_IP_PACKET_SIZE: usize = 65535;

const ReassemblyEntry = struct {
    holes: [64]Hole,
    hole_count: usize,

    const Hole = struct {
        start: usize,
        end: usize,
    };
};

// Logic from reassembly.zig
fn updateHoles(e: *ReassemblyEntry, start: usize, end: usize) void {
    var i: usize = 0;
    while (i < e.hole_count) {
        var h = &e.holes[i];

        // Case 1: Fragment completely covers hole - remove hole
        if (start <= h.start and end >= h.end) {
            removeHole(e, i);
            continue; // Don't increment i
        }

        // Case 2: Fragment inside hole - split hole
        if (start > h.start and end < h.end) {
            if (e.hole_count >= 64) {
                return;
            }
            const new_hole = ReassemblyEntry.Hole{ .start = end, .end = h.end };
            h.end = start;
            e.holes[e.hole_count] = new_hole;
            e.hole_count += 1;
            i += 1;
            continue;
        }

        // Case 3: Overlap start of hole
        if (start <= h.start and end > h.start) {
            h.start = end;
        }

        // Case 4: Overlap end of hole
        if (start < h.end and end >= h.end) {
            h.end = start;
        }

        i += 1;
    }
}

fn removeHole(e: *ReassemblyEntry, idx: usize) void {
    if (idx >= e.hole_count) return;
    const last = e.hole_count - 1;
    if (idx != last) {
        e.holes[idx] = e.holes[last];
    }
    e.hole_count -= 1;
}

// THE BUGGY FUNCTION (STUB)
fn isRegionOverlapping_Buggy(e: *const ReassemblyEntry, start: usize, end: usize) bool {
    _ = start; _ = end; _ = e;
    return false;
}

// THE FIXED FUNCTION
fn isRegionOverlapping_Fixed(e: *const ReassemblyEntry, start: usize, end: usize) bool {
    for (0..e.hole_count) |i| {
        const h = e.holes[i];
        if (start >= h.start and end <= h.end) {
            return false;
        }
    }
    return true;
}

test "teardrop vulnerability reproduction" {
    // FORCE FAIL TO VERIFY RUN
    // try std.testing.expect(false);

    // Setup initial state
    var e = ReassemblyEntry{
        .holes = undefined,
        .hole_count = 1,
    };
    e.holes[0] = .{ .start = 0, .end = MAX_IP_PACKET_SIZE };

    // Receive Fragment 1: [0, 8)
    const f1_start = 0;
    const f1_end = 8;
    // Check overlap
    try std.testing.expect(isRegionOverlapping_Buggy(&e, f1_start, f1_end) == false);
    try std.testing.expect(isRegionOverlapping_Fixed(&e, f1_start, f1_end) == false);
    // Update
    updateHoles(&e, f1_start, f1_end);
    // Holes should be [8, 65535)
    try std.testing.expect(e.hole_count == 1);
    try std.testing.expect(e.holes[0].start == 8);

    // Receive Fragment 2: [16, 24) (Creates a gap 8..16)
    const f2_start = 16;
    const f2_end = 24;
    try std.testing.expect(isRegionOverlapping_Buggy(&e, f2_start, f2_end) == false);
    try std.testing.expect(isRegionOverlapping_Fixed(&e, f2_start, f2_end) == false);
    updateHoles(&e, f2_start, f2_end);
    // Holes: [8, 16), [24, 65535)
    try std.testing.expect(e.hole_count == 2);

    // Receive Overlapping Fragment 3: [4, 12).
    // Overlaps filled region [0, 8) (specifically 4..8) and empty region [8, 12).
    const f3_start = 4;
    const f3_end = 12;

    // BUGGY behavior: Returns false (No overlap detected) -> Vulnerable
    try std.testing.expect(isRegionOverlapping_Buggy(&e, f3_start, f3_end) == false);

    // FIXED behavior: Returns true (Overlap detected) -> Secure
    try std.testing.expect(isRegionOverlapping_Fixed(&e, f3_start, f3_end) == true);

    // Receive Fragment 4: [8, 16). Matches Hole 0 exactly.
    // Should be valid.
    const f4_start = 8;
    const f4_end = 16;
    try std.testing.expect(isRegionOverlapping_Fixed(&e, f4_start, f4_end) == false);
}

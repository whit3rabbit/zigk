// IPv4 Reassembly Management
//
// Handles reassembly of fragmented IPv4 packets (RFC 791).
// Maintains a cache of partial packets and assembles them into complete datagrams.

const std = @import("std");
const packet = @import("../core/packet.zig");
const ipv4 = @import("ipv4.zig");
const sync = @import("../sync.zig");
const PacketBuffer = packet.PacketBuffer;

/// Maximum size of an IP packet (64KB)
const MAX_IP_PACKET_SIZE: usize = 65535;

/// Maximum time to hold fragments (seconds)
/// Reduced from RFC 791's 60-120s to mitigate reassembly DoS attacks
const REASSEMBLY_TIMEOUT: u64 = 15;

/// Maximum concurrent reassemblies
/// Increased significantly to handle many small flows (DoS protection)
/// Memory usage is now capped by MAX_TOTAL_MEMORY, not just slot count.
const MAX_REASSEMBLIES: usize = 128;

/// Maximum total memory used by reassembly buffers (512KB)
/// Prevents memory exhaustion DoS while allowing many small flows
const MAX_TOTAL_MEMORY: usize = 512 * 1024;

/// Minimum fragment payload size (except for first/last fragments)
/// SECURITY: Prevents fragment bomb attacks where attacker sends many tiny
/// fragments (8 bytes each) to exhaust hole tracking (64 slots).
/// RFC 791 allows 8-byte fragments but real traffic uses much larger sizes.
/// Middle fragments smaller than this are suspicious and dropped.
const MIN_FRAGMENT_SIZE: usize = 256;

/// Fragment reassembly entry
const ReassemblyEntry = struct {
    used: bool,
    key: FragmentKey,
    timer: u64, // Creation timestamp (ticks)
    
    /// Reassembly buffer (holds IP payload)
    /// Dynamically allocated to save memory.
    buffer: []u8,
    
    /// Total expected length of IP payload (0 if unknown)
    total_len: usize,
    
    /// Bytes received so far (approximate, for heuristics)
    received_len: usize,
    
    /// Hole descriptor list (simplified)
    holes: [64]Hole, // Support up to 64 fragments/holes (limit complexity)
    hole_count: usize,
    
    const Hole = struct {
        start: usize,
        end: usize, // Exlusive
    };
    
    fn init(key: FragmentKey, timer: u64) ReassemblyEntry {
        var e = ReassemblyEntry{
            .used = true,
            .key = key,
            .timer = timer,
            .buffer = &[_]u8{}, // Empty initially
            .total_len = 0,
            .received_len = 0,
            .holes = undefined,
            .hole_count = 1,
        };
        // Initial hole covers entire theoretical range until we know total_len
        // We set it to 65535 initially
        e.holes[0] = Hole{ .start = 0, .end = MAX_IP_PACKET_SIZE };
        return e;
    }
    
    fn deinit(self: *ReassemblyEntry, allocator: std.mem.Allocator) void {
        if (self.buffer.len > 0) {
            allocator.free(self.buffer);
            if (current_memory_usage >= self.buffer.len) {
                current_memory_usage -= self.buffer.len;
            } else {
                current_memory_usage = 0; // Safety against underflow
            }
        }
        self.buffer = &[_]u8{};
    }
};

/// Key to identify IP fragments (src, dst, proto, id)
const FragmentKey = struct {
    src_ip: u32,
    dst_ip: u32,
    protocol: u8,
    id: u16,
};

/// Global reassembly cache
var cache: [MAX_REASSEMBLIES]ReassemblyEntry = undefined;
var cache_initialized: bool = false;

/// IRQ-safe spinlock for concurrent access protection
/// SECURITY NOTE: sync.Spinlock MUST disable interrupts during acquire/release
/// to prevent TOCTOU races between overlap check and memcpy. The spinlock
/// prevents concurrent CPU access, but IRQs could still preempt if not disabled.
/// Verify your Spinlock implementation uses CLI/STI or equivalent.
var lock: sync.Spinlock = .{};
var current_tick: u64 = 0;
var reassembly_allocator: std.mem.Allocator = undefined;
var current_memory_usage: usize = 0;

/// Initialize module
pub fn init(allocator: std.mem.Allocator) void {
    if (!cache_initialized) {
        reassembly_allocator = allocator;
        for (&cache) |*entry| {
            entry.used = false;
            entry.buffer = &[_]u8{};
        }
        current_memory_usage = 0;
        cache_initialized = true;
    }
}

/// Update timer tick
pub fn tick() void {
    current_tick +%= 1;
}

/// Result of reassembly
pub const ReassemblyResult = struct {
    slice: []u8,
    entry_id: usize,
};

/// Process a fragment of an IPv4 packet
/// Returns:
///   - ReassemblyResult if complete (caller MUST call freeEntry)
///   - null if incomplete or dropped
pub fn processFragment(
    src_ip: u32,
    dst_ip: u32,
    protocol: u8,
    id: u16,
    frag_offset: u16,
    more_fragments: bool,
    payload: []const u8
) ?ReassemblyResult {
    const held = lock.acquire();
    defer held.release();
    
    // Safety check: if init() wasn't called properly
    if (!cache_initialized) return null;

    const key = FragmentKey{
        .src_ip = src_ip,
        .dst_ip = dst_ip,
        .protocol = protocol,
        .id = id,
    };

    // Find existing entry
    var entry: ?*ReassemblyEntry = null;
    var entry_idx: usize = 0;
    
    for (&cache, 0..) |*e, i| {
        if (e.used and std.meta.eql(e.key, key)) {
            entry = e;
            entry_idx = i;
            break;
        }
    }

    // Allocate new entry if not found
    if (entry == null) {
        if (allocateEntry()) |res| {
            entry = res.ptr;
            entry_idx = res.index;
            entry.?.* = ReassemblyEntry.init(key, current_tick);
        } else {
            return null; // Cache full
        }
    }
    
    const e = entry.?;

    // Calculate fragment position
    const start = std.math.mul(usize, @as(usize, frag_offset), 8) catch return null;

    if (start >= MAX_IP_PACKET_SIZE) return null;
    if (payload.len > MAX_IP_PACKET_SIZE - start) return null;

    const end = start + payload.len;
    if (end > MAX_IP_PACKET_SIZE) return null;

    // SECURITY: Reject suspiciously small fragments to prevent fragment bomb DoS.
    // Attackers can send many 8-byte fragments to exhaust our 64-slot hole list.
    // Exception: first fragment (offset=0) may be small, last fragment (!more_fragments)
    // may be a remainder. Only middle fragments are suspicious if tiny.
    const is_first_fragment = (frag_offset == 0);
    if (!is_first_fragment and more_fragments and payload.len < MIN_FRAGMENT_SIZE) {
        // Middle fragment too small - likely attack, drop entire flow
        e.used = false;
        e.deinit(reassembly_allocator);
        return null;
    }
    
    // Ensure buffer is large enough
    if (end > e.buffer.len) {
        // Grow needed
        // Align to 2KB
        var new_len = (end + 2047) & ~@as(usize, 2047);
        if (new_len > MAX_IP_PACKET_SIZE) new_len = MAX_IP_PACKET_SIZE;

        // Check global memory budget
        // SECURITY: Use checked arithmetic to prevent integer overflow.
        // In ReleaseFast mode, wrapping could bypass the memory limit check
        // if new_len < current_len due to corruption or race conditions.
        const current_len = e.buffer.len;
        const additional = std.math.sub(usize, new_len, current_len) catch {
            // Underflow means new_len < current_len (should not happen normally)
            // Treat as corruption/attack and drop flow
            e.used = false;
            e.deinit(reassembly_allocator);
            return null;
        };

        // Use checked add for memory limit check to prevent overflow bypass
        const projected_usage = std.math.add(usize, current_memory_usage, additional) catch {
            // Overflow - would exceed addressable memory, definitely over limit
            e.used = false;
            e.deinit(reassembly_allocator);
            return null;
        };

        if (projected_usage > MAX_TOTAL_MEMORY) {
            // Memory Limit Exceeded
            // Drop entire flow
            e.used = false;
            e.deinit(reassembly_allocator);
            return null;
        }

        if (e.buffer.len == 0) {
            // New allocation
            e.buffer = reassembly_allocator.alloc(u8, new_len) catch {
                e.used = false;
                // e.deinit not needed (buffer empty)
                return null;
            };
        } else {
            // Reallocation
            const new_buf = reassembly_allocator.realloc(e.buffer, new_len) catch {
                e.used = false;
                e.deinit(reassembly_allocator);
                return null;
            };
            e.buffer = new_buf;
        }
        // Safe to add now - we already verified it won't overflow
        current_memory_usage += additional;
    }

    // Update total length if this is the last fragment
    if (!more_fragments) {
        e.total_len = end;
        // Truncate any holes that go beyond total_len
        for (0..e.hole_count) |i| {
            if (e.holes[i].end > e.total_len) {
                e.holes[i].end = e.total_len;
            }
        }
    }

    // SECURITY: Reject overlapping fragments (Teardrop/Ping-of-Death defense)
    // Overlapping fragments can cause undefined behavior when reassembled and
    // have been used in historic attacks. RFC 5722 mandates dropping them.
    // NOTE: This check and the subsequent memcpy must be atomic with respect to
    // other fragment processing. The spinlock above must disable IRQs to prevent
    // a TOCTOU race where another IRQ modifies hole list between check and copy.
    if (isRegionOverlapping(e, start, end)) {
        e.used = false;
        e.deinit(reassembly_allocator);
        return null;
    }

    // Copy data to buffer (protected by spinlock held above)
    @memcpy(e.buffer[start..end], payload);

    // Update holes
    updateHoles(e, start, end);

    // Check if entry was invalidated (e.g., too many holes)
    if (!e.used) {
        e.deinit(reassembly_allocator);
        return null; 
    }

    // Check completion
    if (isComplete(e)) {
        const payload_slice = e.buffer[0..e.total_len];
        return ReassemblyResult{
            .slice = payload_slice,
            .entry_id = entry_idx,
        };
    }

    return null;
}

/// Free a reassembly entry after consumption
pub fn freeEntry(id: usize) void {
    const held = lock.acquire();
    defer held.release();

    if (id < MAX_REASSEMBLIES) {
        cache[id].used = false;
        cache[id].deinit(reassembly_allocator);
    }
}

const Allocation = struct {
    ptr: *ReassemblyEntry,
    index: usize,
};

var eviction_counter: usize = 0;

/// Allocate a cache entry with improved eviction policy
fn allocateEntry() ?Allocation {
    // 1. Find free entry first (fast path)
    for (&cache, 0..) |*e, i| {
        if (!e.used) return Allocation{ .ptr = e, .index = i };
    }

    // 2. Find timed-out entry or track oldest
    var oldest_idx: usize = 0;
    var oldest_age: u64 = 0;
    var youngest_age: u64 = std.math.maxInt(u64);

    for (&cache, 0..) |*e, i| {
        const age = current_tick -% e.timer;

        // Immediately evict timed-out entries
        if (age >= REASSEMBLY_TIMEOUT) {
            e.used = false;
            e.deinit(reassembly_allocator);
            return Allocation{ .ptr = e, .index = i };
        }

        // Track oldest for LRU
        if (age > oldest_age) {
            oldest_age = age;
            oldest_idx = i;
        }

        // Track youngest
        if (age < youngest_age) {
            youngest_age = age;
        }
    }

    // 3. Random eviction if under attack (all young)
    const attack_threshold: u64 = 2; 
    if (youngest_age < attack_threshold and oldest_age < attack_threshold) {
        eviction_counter +%= 1;
        const random_idx = eviction_counter % MAX_REASSEMBLIES;
        cache[random_idx].used = false;
        cache[random_idx].deinit(reassembly_allocator);
        return Allocation{ .ptr = &cache[random_idx], .index = random_idx };
    }

    // 4. Normal case: evict oldest
    cache[oldest_idx].used = false;
    cache[oldest_idx].deinit(reassembly_allocator);
    return Allocation{ .ptr = &cache[oldest_idx], .index = oldest_idx };
}

/// Update holes by removing the covered range [start, end)
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
                // Cannot split hole - too many fragments. Mark entry invalid.
                e.used = false;
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

/// Check if a fragment region overlaps with already-filled data
fn isRegionOverlapping(e: *const ReassemblyEntry, start: usize, end: usize) bool {
    for (0..e.hole_count) |i| {
        const h = e.holes[i];
        if (start >= h.start and end <= h.end) {
            return false;
        }
    }
    return true;
}

/// Check if reassembly is complete
fn isComplete(e: *const ReassemblyEntry) bool {
    if (e.total_len == 0) return false; 
    
    for (0..e.hole_count) |i| {
        if (e.holes[i].start < e.total_len) return false;
    }
    
    return true;
}

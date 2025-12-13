// Kernel Heap Allocator
//
// Free-list allocator with immediate coalescing for dynamic kernel allocations.
// Implements the std.mem.Allocator interface for Zig standard library compatibility.
//
// Design:
//   - Free-list with boundary tags (header + footer) for O(1) coalescing
//   - Immediate coalescing on free() to prevent fragmentation
//   - First-fit allocation strategy (simple, good cache locality)
//   - Minimum allocation size: 32 bytes (header + footer + min payload)
//   - Alignment: 16 bytes (required for SSE and cache lines)
//   - Thread-safe via Spinlock (protects all global state)
//
// Memory Layout:
//   [BlockHeader][Payload...][BlockFooter] [BlockHeader][Payload...][BlockFooter] ...
//
// Constitution Compliance (Principle IX - Heap Hygiene):
//   - Tracks allocated_bytes for leak detection
//   - No implicit allocations
//   - All allocations go through this explicit allocator
//   - Spinlock protects against interrupt-driven corruption

const std = @import("std");

// Conditional imports: kernel modules only available in freestanding mode
const is_freestanding = @import("builtin").os.tag == .freestanding;

const console = if (is_freestanding) @import("console") else struct {
    pub fn info(comptime fmt: []const u8, args: anytype) void {
        _ = fmt;
        _ = args;
    }
    pub fn warn(comptime fmt: []const u8, args: anytype) void {
        _ = fmt;
        _ = args;
    }
    pub fn err(comptime fmt: []const u8, args: anytype) void {
        _ = fmt;
        _ = args;
    }
    pub fn debug(comptime fmt: []const u8, args: anytype) void {
        _ = fmt;
        _ = args;
    }
};

const config = @import("config");

// Sync module for Spinlock - thread-safe heap operations
const sync = if (is_freestanding)
    @import("sync")
else
    // Test stub for host-side testing
    struct {
        pub const Spinlock = struct {
            pub const Held = struct {
                pub fn release(_: Held) void {}
            };
            pub fn acquire(_: *Spinlock) Held {
                return .{};
            }
        };
    };

// Constants
pub const ALIGNMENT: usize = 16; // 16-byte alignment for SSE compatibility
pub const MIN_BLOCK_SIZE: usize = 64; // Minimum block size (32 hdr + 16 payload + 16 ftr)

/// Block header stored at the start of each block.
///
/// Contains the block size and allocation flag (in one field).
/// For free blocks, it contains pointers to the previous and next free blocks (intrusive list).
/// Also contains a magic number for heap corruption detection.
pub const BlockHeader = extern struct {
    // Size of the entire block including header and footer
    // Lowest bit indicates if block is allocated (1) or free (0)
    size_and_flags: usize,
    // Pointer to previous free block (only valid when block is free)
    prev_free: ?*BlockHeader,
    // Pointer to next free block (only valid when block is free)
    next_free: ?*BlockHeader,
    
    // Magic number for integrity verification
    // Repurposing padding field (was 8 bytes)
    magic: usize = ALLOCATOR_MAGIC,

    // "HEAPZIGK" in hex
    pub const ALLOCATOR_MAGIC: usize = 0x48454150_5A49474B;

    const ALLOCATED_FLAG: usize = 1;
    const SIZE_MASK: usize = ~@as(usize, ALLOCATED_FLAG);

    pub fn getSize(self: *const BlockHeader) usize {
        return self.size_and_flags & SIZE_MASK;
    }

    pub fn setSize(self: *BlockHeader, size: usize) void {
        self.size_and_flags = (self.size_and_flags & ALLOCATED_FLAG) | (size & SIZE_MASK);
    }

    pub fn isAllocated(self: *const BlockHeader) bool {
        return (self.size_and_flags & ALLOCATED_FLAG) != 0;
    }

    pub fn setAllocated(self: *BlockHeader, allocated: bool) void {
        if (allocated) {
            self.size_and_flags |= ALLOCATED_FLAG;
        } else {
            self.size_and_flags &= SIZE_MASK;
        }
    }

    /// Get the block footer (at end of block)
    pub fn getFooter(self: *BlockHeader) *BlockFooter {
        const addr = @intFromPtr(self) + self.getSize() - @sizeOf(BlockFooter);
        return @ptrFromInt(addr);
    }

    /// Get payload pointer (after header)
    pub fn getPayload(self: *BlockHeader) [*]u8 {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(BlockHeader));
    }

    /// Get next block in memory (if within heap bounds)
    pub fn getNextBlock(self: *BlockHeader, end_addr: usize) ?*BlockHeader {
        const next_addr = @intFromPtr(self) + self.getSize();
        if (next_addr >= end_addr) {
            return null;
        }
        return @ptrFromInt(next_addr);
    }

    /// Get previous block in memory using its footer
    /// Returns null if no valid previous block exists or if corruption is detected
    pub fn getPrevBlock(self: *BlockHeader, start_addr: usize) ?*BlockHeader {
        const self_addr = @intFromPtr(self);
        if (self_addr <= start_addr) {
            return null;
        }

        // Defensive check: ensure we have room to read the footer
        // Must have at least BlockFooter size between start_addr and self_addr
        const footer_size = @sizeOf(BlockFooter);
        if (self_addr < start_addr + footer_size) {
            return null;
        }

        // Read footer of previous block
        const prev_footer: *BlockFooter = @ptrFromInt(self_addr - footer_size);

        // Defensive check: validate footer size before subtraction
        // Corrupted footer could have size > self_addr, causing underflow
        if (prev_footer.size > self_addr or prev_footer.size < MIN_BLOCK_SIZE) {
            // Corrupted footer detected - size is impossible
            return null;
        }

        const prev_addr = self_addr - prev_footer.size;
        if (prev_addr < start_addr) {
            return null;
        }

        return @ptrFromInt(prev_addr);
    }

    // 4 usize fields = 32 bytes on x86_64
    comptime {
        if (@sizeOf(BlockHeader) != 32) @compileError("BlockHeader must be 32 bytes");
        if (@alignOf(BlockHeader) != 8) @compileError("BlockHeader must have 8-byte alignment");
    }
};

/// Block footer stored at the end of each block.
///
/// Used for immediate coalescing: allows finding the start of the previous block
/// from the current block's header address.
pub const BlockFooter = extern struct {
    size: usize, // Matches the size in header (without flags)
    // Padding to ensure 16-byte size (preserves alignment for next block)
    // 1 * 8 = 8 bytes, need 8 more to reach 16
    _padding: usize = 0,

    comptime {
        if (@sizeOf(BlockFooter) != 16) @compileError("BlockFooter must be 16 bytes");
    }
};

// Heap state (protected by heap_lock)
var heap_start: usize = 0;
var heap_end: usize = 0;
var free_list_head: ?*BlockHeader = null;
var allocated_bytes: usize = 0;
var allocation_count: usize = 0;
var free_block_count: usize = 0;
var initialized: bool = false;

// Spinlock protecting all heap state
// Must be acquired before any heap operation that modifies global state
var heap_lock: sync.Spinlock = .{};

/// Initialize the heap with a memory region
///
/// Sets up the initial free block covering the entire region.
/// Alignments are enforced.
///
/// Arguments:
///   start: Virtual address of the heap memory
///   size: Size of the heap in bytes
pub fn init(start: usize, size: usize) void {
    if (initialized) {
        return;
    }

    // Align start up and size down
    heap_start = std.mem.alignForward(usize, start, ALIGNMENT);
    const adjusted_size = size - (heap_start - start);
    heap_end = heap_start + std.mem.alignBackward(usize, adjusted_size, ALIGNMENT);

    if (heap_end <= heap_start + MIN_BLOCK_SIZE) {
        if (is_freestanding) {
            console.err("Heap: Region too small!", .{});
        }
        return;
    }

    // Create initial free block spanning entire heap
    const initial_block: *BlockHeader = @ptrFromInt(heap_start);
    const block_size = heap_end - heap_start;

    initial_block.size_and_flags = block_size; // Not allocated
    initial_block.prev_free = null;
    initial_block.next_free = null;
    initial_block.magic = BlockHeader.ALLOCATOR_MAGIC;

    // Set footer
    const footer = initial_block.getFooter();
    footer.size = block_size;
    footer._padding = 0; // Hygiene

    // Initialize free list
    free_list_head = initial_block;
    free_block_count = 1;
    allocated_bytes = 0;
    allocation_count = 0;

    initialized = true;

    if (is_freestanding) {
        console.info("Heap: Initialized {d} KB at {x}", .{ block_size / 1024, heap_start });
    }
}

/// Reset heap state (for testing)
pub fn reset() void {
    heap_start = 0;
    heap_end = 0;
    free_list_head = null;
    allocated_bytes = 0;
    allocation_count = 0;
    free_block_count = 0;
    initialized = false;
}

/// Allocate memory from the heap
///
/// Uses a first-fit strategy to find a suitable free block.
/// Splits the block if it is significantly larger than requested.
/// Thread-safe: acquires global heap lock.
///
/// Returns: Slice to allocated memory, or null if OOM.
pub fn alloc(size: usize) ?[]u8 {
    if (!initialized or size == 0) {
        return null;
    }

    // Security: Reject obviously excessive allocation requests
    // This prevents integer overflow in size calculations below
    const max_alloc_size: usize = 1024 * 1024 * 1024; // 1 GB max single allocation
    if (size > max_alloc_size) {
        if (is_freestanding and config.debug_memory) {
            console.warn("Heap: Rejecting excessive allocation: {d} bytes", .{size});
        }
        return null;
    }

    // Acquire lock for thread-safe access to heap state
    const held = heap_lock.acquire();
    defer held.release();

    // Calculate required block size (header + payload + footer, aligned)
    // Using checked arithmetic to detect overflow
    const payload_size = std.mem.alignForward(usize, size, ALIGNMENT);
    const overhead = @sizeOf(BlockHeader) + @sizeOf(BlockFooter);

    // Check for overflow: payload_size + overhead must not wrap
    if (payload_size > std.math.maxInt(usize) - overhead) {
        if (is_freestanding and config.debug_memory) {
            console.warn("Heap: Size overflow detected for allocation of {d} bytes", .{size});
        }
        return null;
    }

    const required_size = payload_size + overhead;
    const min_size = @max(required_size, MIN_BLOCK_SIZE);

    // First-fit search through free list
    var current = free_list_head;
    while (current) |block| {
        if (block.getSize() >= min_size) {
            // Found a suitable block
            return allocateFromBlock(block, min_size);
        }
        current = block.next_free;
    }

    // No suitable block found
    if (is_freestanding and config.debug_memory) {
        console.warn("Heap: OOM - requested {d} bytes", .{size});
    }
    return null;
}

/// Free previously allocated memory
///
/// Marks the block as free and attempts to coalesce it with adjacent free blocks
/// (both previous and next) to reduce fragmentation.
/// Thread-safe: acquires global heap lock.
pub fn free(buf: []u8) void {
    if (!initialized) {
        return;
    }

    const ptr_addr = @intFromPtr(buf.ptr);
    if (ptr_addr < heap_start or ptr_addr >= heap_end) {
        if (is_freestanding) {
            console.warn("Heap: Invalid free at {x}", .{ptr_addr});
        }
        return;
    }

    // Acquire lock for thread-safe access to heap state
    const held = heap_lock.acquire();
    defer held.release();

    // Get block header from payload pointer
    const header: *BlockHeader = @ptrFromInt(ptr_addr - @sizeOf(BlockHeader));

    // Verify magic number before touching anything else
    if (header.magic != BlockHeader.ALLOCATOR_MAGIC) {
        if (is_freestanding) {
            console.panic("Heap: Corruption detected! Invalid magic {x} at {x}", .{header.magic, ptr_addr});
        }
        return;
    }

    if (!header.isAllocated()) {
        if (is_freestanding) {
            console.warn("Heap: Double-free at {x}", .{ptr_addr});
        }
        return;
    }

    const block_size = header.getSize();
    const payload_size = block_size - @sizeOf(BlockHeader) - @sizeOf(BlockFooter);

    // Update statistics
    if (allocated_bytes >= payload_size) {
        allocated_bytes -= payload_size;
    }
    if (allocation_count > 0) {
        allocation_count -= 1;
    }

    // Mark block as free
    header.setAllocated(false);

    // Coalesce with adjacent free blocks
    var coalesced_block = header;
    var coalesced_size = block_size;

    // Try to coalesce with next block
    if (header.getNextBlock(heap_end)) |next_block| {
        if (!next_block.isAllocated()) {
            // Remove next block from free list (decrements free_block_count)
            removeFromFreeList(next_block);
            // Absorb next block
            coalesced_size += next_block.getSize();
        }
    }

    // Try to coalesce with previous block
    if (header.getPrevBlock(heap_start)) |prev_block| {
        if (!prev_block.isAllocated()) {
            // Remove previous block from free list (decrements free_block_count)
            removeFromFreeList(prev_block);
            // Previous block absorbs current
            coalesced_block = prev_block;
            coalesced_size += prev_block.getSize();
        }
    }

    // Update coalesced block
    coalesced_block.setSize(coalesced_size);
    coalesced_block.setAllocated(false);

    // Update footer
    const footer = coalesced_block.getFooter();
    footer.size = coalesced_size;
    footer._padding = 0; // Hygiene

    // Add to free list
    addToFreeList(coalesced_block);

    if (is_freestanding and config.debug_memory) {
        console.debug("Heap: Freed {d} bytes, coalesced to {d}", .{ payload_size, coalesced_size });
    }
}

/// Reallocate memory (grow or shrink)
pub fn realloc(buf: []u8, old_size: usize, new_size: usize) ?[]u8 {
    if (new_size == 0) {
        free(buf);
        return null;
    }

    if (old_size == 0) {
        return alloc(new_size);
    }

    // Simple implementation: allocate new, copy, free old
    const new_ptr = alloc(new_size) orelse return null;
    const copy_size = @min(old_size, new_size);

    // Copy data
    const src = buf[0..copy_size];
    const dst = new_ptr[0..copy_size];
    @memcpy(dst, src);

    free(buf);
    return new_ptr;
}

/// Allocate zeroed memory
pub fn allocZeroed(size: usize) ?[]u8 {
    const slice = alloc(size) orelse return null;
    @memset(slice[0..size], 0);
    return slice;
}

/// Get total allocated bytes (for leak detection)
pub fn getAllocatedBytes() usize {
    return allocated_bytes;
}

/// Get number of active allocations
pub fn getAllocationCount() usize {
    return allocation_count;
}

/// Get number of free blocks
pub fn getFreeBlockCount() usize {
    return free_block_count;
}

/// Get total free bytes
pub fn getFreeBytes() usize {
    var total: usize = 0;
    var current = free_list_head;
    while (current) |block| {
        total += block.getSize() - @sizeOf(BlockHeader) - @sizeOf(BlockFooter);
        current = block.next_free;
    }
    return total;
}

/// Check heap integrity (for debugging)
pub fn checkIntegrity() bool {
    if (!initialized) return true;

    var addr = heap_start;
    while (addr < heap_end) {
        const header: *BlockHeader = @ptrFromInt(addr);
        const size = header.getSize();

        // Check magic
        if (header.magic != BlockHeader.ALLOCATOR_MAGIC) {
            if (is_freestanding) {
                 console.err("Heap: Corrupt block magic at {x}", .{addr});
            }
            return false;
        }

        if (size < MIN_BLOCK_SIZE or addr + size > heap_end) {
            if (is_freestanding) {
                console.err("Heap: Corrupt block at {x}, size={d}", .{ addr, size });
            }
            return false;
        }

        const footer = header.getFooter();
        if (footer.size != size) {
            if (is_freestanding) {
                console.err("Heap: Header/footer mismatch at {x}", .{addr});
            }
            return false;
        }

        addr += size;
    }

    return true;
}

/// Std.mem.Allocator interface wrapper
pub fn allocator() std.mem.Allocator {
    return .{
        .ptr = undefined,
        .vtable = &.{
            .alloc = stdAlloc,
            .resize = stdResize,
            .remap = stdRemap,
            .free = stdFree,
        },
    };
}

// std.mem.Allocator vtable implementation
fn stdAlloc(_: *anyopaque, len: usize, ptr_align: std.mem.Alignment, _: usize) ?[*]u8 {
    // Our heap always aligns to ALIGNMENT (16), which should satisfy most requests
    // std.mem.Alignment.toByteUnits returns usize (not optional in 0.15.x)
    const align_bytes = ptr_align.toByteUnits();
    if (align_bytes > ALIGNMENT) {
        // Log warning when alignment cannot be satisfied
        // This helps debug unexpected allocation failures (e.g., SIMD requiring 32/64-byte alignment)
        console.warn("Heap: Unsupported alignment {d} > {d} for {d} byte allocation", .{
            align_bytes,
            ALIGNMENT,
            len,
        });
        return null;
    }
    const slice = alloc(len) orelse return null;
    return slice.ptr;
}

fn stdResize(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    // Simple resize: only support shrinking or exact size
    if (new_len <= buf.len) {
        return true;
    }
    return false;
}

fn stdRemap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    // We do not support remapping
    return null;
}

fn stdFree(_: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
    free(buf);
}

// Internal helper functions

fn allocateFromBlock(block: *BlockHeader, required_size: usize) ?[]u8 {
    const block_size = block.getSize();

    // Remove from free list first (this decrements free_block_count)
    removeFromFreeList(block);

    // Check if we should split the block
    const remaining = block_size - required_size;
    if (remaining >= MIN_BLOCK_SIZE) {
        // Split: create new free block from remainder
        block.setSize(required_size);
        block.setAllocated(true);
        // Magic should already be set, but ensure it stays
        block.magic = BlockHeader.ALLOCATOR_MAGIC;

        // Update footer for allocated block
        var footer = block.getFooter();
        footer.size = required_size;
        footer._padding = 0; // Hygiene

        // Create new free block
        const new_block: *BlockHeader = @ptrFromInt(@intFromPtr(block) + required_size);
        new_block.size_and_flags = remaining;
        new_block.setAllocated(false);
        new_block.prev_free = null;
        new_block.next_free = null;
        new_block.magic = BlockHeader.ALLOCATOR_MAGIC;

        // Set footer for new block
        const new_footer = new_block.getFooter();
        new_footer.size = remaining;
        new_footer._padding = 0; // Hygiene

        // Add new block to free list (this increments free_block_count)
        addToFreeList(new_block);
    } else {
        // Use entire block (already removed from free list, count already decremented)
        block.setAllocated(true);
    }

    const payload_size = block.getSize() - @sizeOf(BlockHeader) - @sizeOf(BlockFooter);
    allocated_bytes += payload_size;
    allocation_count += 1;

    if (is_freestanding and config.debug_memory) {
        console.debug("Heap: Allocated {d} bytes at {x}", .{ payload_size, @intFromPtr(block.getPayload()) });
    }

    return block.getPayload()[0..payload_size];
}

fn addToFreeList(block: *BlockHeader) void {
    block.prev_free = null;
    block.next_free = free_list_head;

    if (free_list_head) |head| {
        head.prev_free = block;
    }

    free_list_head = block;
    free_block_count += 1;
}

fn removeFromFreeList(block: *BlockHeader) void {
    if (block.prev_free) |prev| {
        prev.next_free = block.next_free;
    } else {
        // Block is head of list
        free_list_head = block.next_free;
    }

    if (block.next_free) |next| {
        next.prev_free = block.prev_free;
    }

    block.prev_free = null;
    block.next_free = null;

    if (free_block_count > 0) {
        free_block_count -= 1;
    }
}

/// Debug: Print heap statistics
pub fn printStats() void {
    if (is_freestanding) {
        console.info("Heap Stats:", .{});
        console.info("  Allocated bytes: {d}", .{allocated_bytes});
        console.info("  Allocation count: {d}", .{allocation_count});
        console.info("  Free blocks: {d}", .{free_block_count});
        console.info("  Free bytes: {d}", .{getFreeBytes()});
        console.info("  Integrity: {}", .{checkIntegrity()});
    }
}

// Memory allocator (stdlib.h)
//
// Provides malloc, free, realloc, calloc with security improvements:
// - Integer overflow protection in size calculations
// - Address-ordered block list for safe coalescing
// - Physical adjacency checks before merging
// - Double-linked list for efficiency

const syscall = @import("syscall.zig");
const internal = @import("../internal.zig");
const errno_mod = @import("../errno.zig");

/// Header for memory blocks
/// Uses double-linked list for efficient coalescing
const BlockHeader = struct {
    magic: u32, // Debug: heap corruption detection
    size: usize, // Size of user data (not including header)
    next: ?*BlockHeader,
    prev: ?*BlockHeader, // For coalescing with previous block
    free: bool,

    /// Get pointer to user data area
    fn userData(self: *BlockHeader) *anyopaque {
        return @ptrCast(@as([*]u8, @ptrCast(self)) + @sizeOf(BlockHeader));
    }

    /// Get header from user data pointer
    fn fromUserData(ptr: *anyopaque) *BlockHeader {
        const header_ptr = @as([*]u8, @ptrCast(ptr)) - @sizeOf(BlockHeader);
        return @ptrCast(@alignCast(header_ptr));
    }

    /// Check if this block has valid magic (debug mode only)
    fn isValid(self: *const BlockHeader) bool {
        return self.magic == internal.HEAP_MAGIC or
            self.magic == internal.FREED_MAGIC;
    }

    /// Check if other block is physically adjacent after this one
    fn isAdjacent(self: *const BlockHeader, other: *const BlockHeader) bool {
        const self_end = @as(usize, @intFromPtr(self)) + @sizeOf(BlockHeader) + self.size;
        return self_end == @intFromPtr(other);
    }
};

/// Head of the allocation list (Lowest Address)
var head: ?*BlockHeader = null;

/// Minimum block size (avoids tiny fragments)
const MIN_BLOCK_SIZE: usize = 32;

/// Allocate memory
/// Returns null on failure (size 0, overflow, or out of memory)
pub export fn malloc(size: usize) ?*anyopaque {
    if (size == 0) return null;

    // Align size to 16 bytes (required for SSE/FPU state)
    const aligned_size = internal.alignTo16(size);

    // SECURITY FIX: Check for overflow when adding header size
    const total_size = internal.checkedAdd(aligned_size, @sizeOf(BlockHeader)) orelse {
        errno_mod.errno = errno_mod.ENOMEM;
        return null;
    };

    // First-fit search through free list (address ordered)
    var current = head;
    var best_fit: ?*BlockHeader = null;
    var best_fit_size: usize = ~@as(usize, 0);

    // Traverse to find best fit AND find tail if needed
    var tail: ?*BlockHeader = null;

    while (current) |block| {
        if (internal.DEBUG_HEAP and !block.isValid()) {
            @panic("libc: heap corruption detected in malloc scan");
        }

        if (block.free and block.size >= aligned_size) {
            // Use best-fit to reduce fragmentation
            if (block.size < best_fit_size) {
                best_fit = block;
                best_fit_size = block.size;

                // Exact match - use immediately
                if (block.size == aligned_size) break;
            }
        }
        
        tail = block; // Track tail for appending if needed
        current = block.next;
    }

    if (best_fit) |block| {
        // Try to split block if it's large enough
        const remaining = block.size - aligned_size;
        // Need space for header + min data
        if (remaining >= @sizeOf(BlockHeader) + MIN_BLOCK_SIZE) {
            // Split the block
            // New block goes AFTER current block
            const new_block_ptr = @as([*]u8, @ptrCast(block)) + @sizeOf(BlockHeader) + aligned_size;
            const new_block: *BlockHeader = @ptrCast(@alignCast(new_block_ptr));

            new_block.magic = internal.HEAP_MAGIC;
            new_block.size = remaining - @sizeOf(BlockHeader);
            new_block.free = true;
            new_block.next = block.next;
            new_block.prev = block;

            if (block.next) |next| {
                next.prev = new_block;
            }

            block.next = new_block;
            block.size = aligned_size;
        }

        block.magic = internal.HEAP_MAGIC;
        block.free = false;
        return block.userData();
    }

    // No suitable free block found, allocate new one
    // New block will be at highest address, so append to tail
    const ptr = syscall.sbrk(@intCast(total_size)) catch {
        errno_mod.errno = errno_mod.ENOMEM;
        return null;
    };

    const block: *BlockHeader = @ptrCast(@alignCast(ptr));
    block.magic = internal.HEAP_MAGIC;
    block.size = aligned_size;
    block.free = false;
    block.next = null;
    block.prev = tail;

    if (tail) |t| {
        t.next = block;
    } else {
        head = block;
    }

    return block.userData();
}

/// Free allocated memory
/// Implements block coalescing to reduce fragmentation
/// Debug mode: detects double-free and heap corruption
pub export fn free(ptr: ?*anyopaque) void {
    if (ptr == null) return;

    const block = BlockHeader.fromUserData(ptr.?);

    // DEBUG: Check for heap corruption and double-free
    if (internal.DEBUG_HEAP) {
        if (!block.isValid()) {
            @panic("libc: heap corruption detected in free()");
        }
        if (block.magic == internal.FREED_MAGIC) {
            @panic("libc: double-free detected");
        }
        block.magic = internal.FREED_MAGIC;
    }

    // Mark as free
    block.free = true;

    // SECURITY FIX: Coalesce with adjacent free blocks
    coalesceBlocks(block);
}

/// Coalesce block with adjacent free blocks
/// Requires strict adjacency check since list order != physical order
/// (Though with our new malloc, list order SHOULD == physical order,
/// but safe checks are critical)
fn coalesceBlocks(block: *BlockHeader) void {
    // Try to coalesce with next block
    if (block.next) |next| {
        // Must be free AND physically adjacent
        if (next.free and block.isAdjacent(next)) {
            // Merge next block into current
            // block extends to cover next
            block.size += @sizeOf(BlockHeader) + next.size;
            block.next = next.next;
            if (next.next) |nn| {
                nn.prev = block;
            }
            // Invalidate merged block magic
            if (internal.DEBUG_HEAP) next.magic = 0;
        }
    }

    // Try to coalesce with previous block
    if (block.prev) |prev| {
        // Must be free AND physically adjacent
        if (prev.free and prev.isAdjacent(block)) {
            // Merge current block into previous
            prev.size += @sizeOf(BlockHeader) + block.size;
            prev.next = block.next;
            if (block.next) |bn| {
                bn.prev = prev;
            }
            // Invalidate merged block magic
            if (internal.DEBUG_HEAP) block.magic = 0;
        }
    }
}

/// Reallocate memory block
/// Debug mode: validates heap integrity before reallocation
pub export fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
    // realloc(NULL, size) is equivalent to malloc(size)
    if (ptr == null) return malloc(size);

    // realloc(ptr, 0) is equivalent to free(ptr)
    if (size == 0) {
        free(ptr);
        return null;
    }

    const block = BlockHeader.fromUserData(ptr.?);

    // DEBUG: Check for heap corruption
    if (internal.DEBUG_HEAP) {
        if (!block.isValid()) {
            @panic("libc: heap corruption detected in realloc()");
        }
    }

    const aligned_size = internal.alignTo16(size);

    // Current block is big enough
    if (block.size >= aligned_size) {
        // TODO: Split if significantly oversized?
        // For now, simple standard behavior
        return ptr;
    }

    // Try to expand into next block if it's free and adjacent
    if (block.next) |next| {
        if (next.free and block.isAdjacent(next)) {
            const combined = block.size + @sizeOf(BlockHeader) + next.size;
            if (combined >= aligned_size) {
                // Absorb next block
                block.size = combined;
                block.next = next.next;
                if (next.next) |nn| {
                    nn.prev = block;
                }
                if (internal.DEBUG_HEAP) next.magic = 0;
                
                // If we absorbed too much, we could split again here?
                // Leaving as simple expansion for now.
                return ptr;
            }
        }
    }

    // Need to allocate new block and copy
    const new_ptr = malloc(size);
    if (new_ptr == null) return null;

    // Copy old data using safeCopy to avoid @memcpy recursion
    const copy_size = @min(block.size, size);
    const src = @as([*]const u8, @ptrCast(ptr.?));
    const dst = @as([*]u8, @ptrCast(new_ptr.?));
    internal.safeCopy(dst, src, copy_size);

    free(ptr);
    return new_ptr;
}

/// Allocate and zero memory for array
pub export fn calloc(nmemb: usize, size: usize) ?*anyopaque {
    if (nmemb == 0 or size == 0) return null;

    // SECURITY FIX: Check for multiplication overflow
    const total = internal.checkedMultiply(nmemb, size) orelse {
        errno_mod.errno = errno_mod.ENOMEM;
        return null;
    };

    const ptr = malloc(total);
    if (ptr) |p| {
        // Zero the memory using safeFill to avoid @memset recursion
        const bytes = @as([*]u8, @ptrCast(p));
        internal.safeFill(bytes, 0, total);
    }
    return ptr;
}

/// Allocate aligned memory
/// For alignments > 16, stores offset to allow proper freeing via aligned_free
pub export fn aligned_alloc(alignment: usize, size: usize) ?*anyopaque {
    // Alignment must be power of 2
    if (alignment == 0 or (alignment & (alignment - 1)) != 0) {
        errno_mod.errno = errno_mod.EINVAL;
        return null;
    }

    // Size must be multiple of alignment
    if (size % alignment != 0) {
        errno_mod.errno = errno_mod.EINVAL;
        return null;
    }

    // Our malloc already aligns to 16 bytes
    if (alignment <= 16) {
        return malloc(size);
    }

    // For larger alignments, over-allocate and store offset for aligned_free
    // Layout: [raw malloc] ... [offset (usize)] [aligned user data]
    const extra = internal.checkedAdd(size, alignment + @sizeOf(usize)) orelse {
        errno_mod.errno = errno_mod.ENOMEM;
        return null;
    };

    const raw_ptr = malloc(extra) orelse return null;
    const raw_addr = @intFromPtr(raw_ptr);

    // Calculate aligned address, leaving room for offset storage
    const aligned_addr = (raw_addr + @sizeOf(usize) + alignment - 1) & ~(alignment - 1);

    // Store offset just before aligned address
    const offset_ptr: *usize = @ptrFromInt(aligned_addr - @sizeOf(usize));
    offset_ptr.* = aligned_addr - raw_addr;

    return @ptrFromInt(aligned_addr);
}

/// Free memory allocated by aligned_alloc with alignment > 16
/// IMPORTANT: Only use this for pointers from aligned_alloc with alignment > 16
/// For alignment <= 16, use regular free()
pub export fn aligned_free(ptr: ?*anyopaque) void {
    if (ptr == null) return;

    const aligned_addr = @intFromPtr(ptr.?);

    // Validate that we can read the offset (address must be > sizeof(usize))
    if (aligned_addr < @sizeOf(usize)) {
        if (internal.DEBUG_HEAP) {
            @panic("libc: aligned_free called with invalid address");
        }
        return;
    }

    const offset_ptr: *const usize = @ptrFromInt(aligned_addr - @sizeOf(usize));
    const offset = offset_ptr.*;

    // SECURITY: Validate offset is reasonable
    // - Must be at least sizeof(usize) (room for offset storage)
    // - Must not exceed aligned_addr (would underflow)
    // - Must not exceed a reasonable maximum (e.g., 4KB alignment max)
    const MAX_REASONABLE_OFFSET: usize = 4096 + @sizeOf(usize);

    if (offset < @sizeOf(usize) or offset > aligned_addr or offset > MAX_REASONABLE_OFFSET) {
        if (internal.DEBUG_HEAP) {
            @panic("libc: heap corruption detected in aligned_free - invalid offset");
        }
        return;
    }

    const original_addr = aligned_addr - offset;
    free(@ptrFromInt(original_addr));
}

/// POSIX memalign
pub export fn posix_memalign(memptr: ?*?*anyopaque, alignment: usize, size: usize) c_int {
    if (memptr == null) return errno_mod.EINVAL;

    const ptr = aligned_alloc(alignment, size);
    if (ptr == null) {
        return errno_mod.ENOMEM;
    }

    memptr.?.* = ptr;
    return 0;
}

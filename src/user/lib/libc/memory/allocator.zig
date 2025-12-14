// Memory allocator (stdlib.h)
//
// Provides malloc, free, realloc, calloc with security improvements:
// - Integer overflow protection in size calculations
// - Block coalescing to reduce fragmentation
// - Double-linked list for efficient coalescing

const syscall = @import("syscall.zig");
const internal = @import("../internal.zig");
const errno_mod = @import("../errno.zig");

/// Header for memory blocks
/// Uses double-linked list for efficient coalescing
const BlockHeader = struct {
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
};

/// Head of the allocation list
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

    // First-fit search through free list
    var current = head;
    var best_fit: ?*BlockHeader = null;
    var best_fit_size: usize = ~@as(usize, 0);

    while (current) |block| {
        if (block.free and block.size >= aligned_size) {
            // Use best-fit to reduce fragmentation
            if (block.size < best_fit_size) {
                best_fit = block;
                best_fit_size = block.size;

                // Exact match - use immediately
                if (block.size == aligned_size) break;
            }
        }
        current = block.next;
    }

    if (best_fit) |block| {
        // Try to split block if it's large enough
        const remaining = block.size - aligned_size;
        if (remaining >= MIN_BLOCK_SIZE + @sizeOf(BlockHeader)) {
            // Split the block
            const new_block_ptr = @as([*]u8, @ptrCast(block)) + @sizeOf(BlockHeader) + aligned_size;
            const new_block: *BlockHeader = @ptrCast(@alignCast(new_block_ptr));

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

        block.free = false;
        return block.userData();
    }

    // No suitable free block found, allocate new one
    const ptr = syscall.sbrk(@intCast(total_size)) catch {
        errno_mod.errno = errno_mod.ENOMEM;
        return null;
    };

    const block: *BlockHeader = @ptrCast(@alignCast(ptr));
    block.size = aligned_size;
    block.free = false;
    block.prev = null;

    // Prepend to list
    block.next = head;
    if (head) |h| {
        h.prev = block;
    }
    head = block;

    return block.userData();
}

/// Free allocated memory
/// Implements block coalescing to reduce fragmentation
pub export fn free(ptr: ?*anyopaque) void {
    if (ptr == null) return;

    const block = BlockHeader.fromUserData(ptr.?);

    // Mark as free
    block.free = true;

    // SECURITY FIX: Coalesce with adjacent free blocks
    coalesceBlocks(block);
}

/// Coalesce block with adjacent free blocks
fn coalesceBlocks(block: *BlockHeader) void {
    // Try to coalesce with next block
    if (block.next) |next| {
        if (next.free) {
            // Merge next block into current
            block.size += @sizeOf(BlockHeader) + next.size;
            block.next = next.next;
            if (next.next) |nn| {
                nn.prev = block;
            }
        }
    }

    // Try to coalesce with previous block
    if (block.prev) |prev| {
        if (prev.free) {
            // Merge current block into previous
            prev.size += @sizeOf(BlockHeader) + block.size;
            prev.next = block.next;
            if (block.next) |bn| {
                bn.prev = prev;
            }
        }
    }
}

/// Reallocate memory block
pub export fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
    // realloc(NULL, size) is equivalent to malloc(size)
    if (ptr == null) return malloc(size);

    // realloc(ptr, 0) is equivalent to free(ptr)
    if (size == 0) {
        free(ptr);
        return null;
    }

    const block = BlockHeader.fromUserData(ptr.?);
    const aligned_size = internal.alignTo16(size);

    // Current block is big enough
    if (block.size >= aligned_size) {
        // Could split here if significantly oversized, but keep simple for now
        return ptr;
    }

    // Try to expand into next block if it's free
    if (block.next) |next| {
        if (next.free) {
            const combined = block.size + @sizeOf(BlockHeader) + next.size;
            if (combined >= aligned_size) {
                // Absorb next block
                block.size = combined;
                block.next = next.next;
                if (next.next) |nn| {
                    nn.prev = block;
                }
                return ptr;
            }
        }
    }

    // Need to allocate new block and copy
    const new_ptr = malloc(size);
    if (new_ptr == null) return null;

    // Copy old data
    const copy_size = @min(block.size, size);
    const src = @as([*]const u8, @ptrCast(ptr.?));
    const dst = @as([*]u8, @ptrCast(new_ptr.?));
    @memcpy(dst[0..copy_size], src[0..copy_size]);

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
        // Zero the memory
        const bytes = @as([*]u8, @ptrCast(p));
        @memset(bytes[0..total], 0);
    }
    return ptr;
}

/// Allocate aligned memory
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

    // For larger alignments, over-allocate and adjust
    const extra = internal.checkedAdd(size, alignment) orelse {
        errno_mod.errno = errno_mod.ENOMEM;
        return null;
    };

    const ptr = malloc(extra) orelse return null;
    const addr = @intFromPtr(ptr);
    const aligned_addr = (addr + alignment - 1) & ~(alignment - 1);

    // Note: This leaks the unaligned portion - acceptable for simple allocator
    return @ptrFromInt(aligned_addr);
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

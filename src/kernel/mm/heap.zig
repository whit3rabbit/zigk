//! Kernel Heap Allocator
//!
//! Free-list allocator with immediate coalescing for dynamic kernel allocations.
//! Implements the `std.mem.Allocator` interface for Zig standard library compatibility.
//!
//! Design:
//!   - Free-list with boundary tags (header + footer) for O(1) coalescing
//!   - Immediate coalescing on `free()` to prevent fragmentation
//!   - First-fit allocation strategy (simple, good cache locality)
//!   - Minimum allocation size: 32 bytes (header + footer + min payload)
//!   - Alignment: 64 bytes (required for XSAVE/AVX-512 and cache lines)
//!   - Thread-safe via Spinlock (protects all global state)
//!
//! Memory Layout:
//!   `[BlockHeader][Payload...][BlockFooter] [BlockHeader][Payload...][BlockFooter] ...`
//!
//! Constitution Compliance (Principle IX - Heap Hygiene):
//!   - Tracks allocated_bytes for leak detection
//!   - No implicit allocations
//!   - All allocations go through this explicit allocator
//!   - Spinlock protects against interrupt-driven corruption

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
const slab = @import("slab");

// HAL import for TSC-based canary initialization (freestanding only)
const hal = if (is_freestanding) @import("hal") else struct {
    pub const timing = struct {
        pub fn rdtsc() u64 {
            return 0x12345678ABCD; // Test fallback
        }
    };
    pub const entropy = struct {
        pub fn isInitialized() bool {
            return false; // No hardware entropy in test mode
        }
        pub fn tryFillWithHardwareEntropy(_: []u8) bool {
            return false; // No hardware entropy in test mode
        }
    };
};

const mem = if (is_freestanding) hal.mem else struct {
    pub fn copy(dest: [*]u8, src: [*]const u8, n: usize) void {
        if (n == 0) return;
        @memcpy(dest[0..n], src[0..n]);
    }

    pub fn fill(dest: [*]u8, value: u8, n: usize) void {
        if (n == 0) return;
        @memset(dest[0..n], value);
    }
};

// Per-boot randomized canary - initialized with TSC in init()
// Security: Prevents attackers from predicting canary value at compile time
// Note: TSC provides weak entropy but is available before PRNG init
var heap_canary: u64 = 0xDEADBEEFCAFEBABE; // Default until init()

// Legacy constant for reference (kept for documentation)
const HEAP_CANARY_DEFAULT: u64 = 0xDEADBEEFCAFEBABE;

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
pub const ALIGNMENT: usize = 64; // 64-byte alignment for XSAVE/AVX-512 compatibility
pub const MIN_BLOCK_SIZE: usize = 128; // Minimum block size (64 hdr + 48 min payload + 16 ftr)

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

    // Padding to make BlockHeader exactly 64 bytes
    // This ensures payload starts at a 64-byte aligned address when the block
    // itself is 64-byte aligned, satisfying XSAVE/AVX-512 alignment requirements
    _padding: [32]u8 = [_]u8{0} ** 32,

    // "HEAP__ZK" in hex
    pub const ALLOCATOR_MAGIC: usize = 0x48454150_5F5F5A4B;

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
    /// Security: Validates header magic and size consistency to prevent footer-based attacks
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

        // Validate footer canary (detects buffer overruns into footer)
        if (prev_footer.canary != heap_canary) {
            return null;
        }

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

        // Critical security check: validate the header at computed address
        const prev_block: *BlockHeader = @ptrFromInt(prev_addr);

        // Verify magic to ensure we're pointing at a real block header
        if (prev_block.magic != ALLOCATOR_MAGIC) {
            return null;
        }

        // Verify header size matches footer size (consistency check)
        // This catches attacks where footer is crafted to point to arbitrary memory
        if (prev_block.getSize() != prev_footer.size) {
            return null;
        }

        return prev_block;
    }

    // 4 usize fields + 32-byte padding = 64 bytes on x86_64
    // 64-byte header ensures payload starts at 64-byte aligned address
    comptime {
        if (@sizeOf(BlockHeader) != 64) @compileError("BlockHeader must be 64 bytes");
        if (@alignOf(BlockHeader) != 8) @compileError("BlockHeader must have 8-byte alignment");
    }
};

/// Block footer stored at the end of each block.
///
/// Used for immediate coalescing: allows finding the start of the previous block
/// from the current block's header address.
pub const BlockFooter = extern struct {
    size: usize, // Matches the size in header (without flags)
    // Canary for overrun detection (payload writes should never reach here)
    // Default is compile-time constant; setFooter() overwrites with per-boot random value
    canary: u64 = HEAP_CANARY_DEFAULT,

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

    // SECURITY FIX: Initialize per-boot random canary using hardware entropy + TSC
    // Previously only used TSC which has limited entropy (~20-30 bits).
    // Now we try RDRAND first, then mix with TSC for additional entropy.
    const tsc = hal.timing.rdtsc();

    // Try to get hardware entropy (RDRAND) if available
    var hw_entropy: u64 = 0;
    if (is_freestanding and hal.entropy.isInitialized()) {
        // Use hardware entropy if available
        var entropy_buf: [8]u8 = [_]u8{0} ** 8;
        if (hal.entropy.tryFillWithHardwareEntropy(&entropy_buf)) {
            hw_entropy = @bitCast(entropy_buf);
        }
    }

    // Mix all entropy sources: hardware entropy + TSC + constant
    // This ensures at least TSC-level entropy even without RDRAND
    heap_canary = HEAP_CANARY_DEFAULT ^ hw_entropy ^ tsc ^ (tsc >> 17) ^ (tsc << 31);

    // Ensure canary is never zero (would make corruption detection trivial)
    if (heap_canary == 0) {
        heap_canary = HEAP_CANARY_DEFAULT;
    }

    // Log security status
    if (is_freestanding) {
        if (hw_entropy != 0) {
            console.info("Heap: Canary seeded with hardware entropy + TSC", .{});
        } else {
            console.warn("Heap: Canary seeded with TSC only (weaker)", .{});
        }
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
    setFooter(footer, block_size);

    // Initialize free list
    free_list_head = initial_block;
    free_block_count = 1;
    allocated_bytes = 0;
    allocation_count = 0;

    initialized = true;

    if (is_freestanding) {
        console.info("Heap: Initialized {d} KB at {x}", .{ block_size / 1024, heap_start });
    }

    // DISABLED: Slab allocator requires page-aligned backing allocations
    // slab.setBackingAllocator(backingAlloc, backingFree);
    // slab.init();
}

// Backing allocator functions for slab (uses free-list allocator directly)
fn backingAlloc(size: usize) ?[]u8 {
    return allocFromFreeList(size);
}

fn backingFree(buf: []u8) void {
    freeToFreeList(buf);
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
/// Small allocations (<=2KB) use the slab allocator for O(1) performance.
/// Large allocations use the free-list allocator with first-fit strategy.
/// Thread-safe: acquires global heap lock.
///
/// Returns: Slice to allocated memory, or null if OOM.
pub fn alloc(size: usize) ?[]u8 {
    if (!initialized or size == 0) {
        return null;
    }

    // Use slab allocator for small allocations (16-2048 bytes)
    // Slab allocator uses PMM directly for page-aligned slabs
    if (slab.isSizeSlabbed(size)) {
        if (slab.alloc(size)) |result| {
            return result[0..size];
        }
    }

    return allocFromFreeList(size);
}

/// Internal: Allocate from the free-list allocator (used by slab for backing memory)
fn allocFromFreeList(size: usize) ?[]u8 {
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
    const overhead = @sizeOf(BlockHeader) + @sizeOf(BlockFooter); // 64 + 16 = 80

    // Check for overflow: size + overhead must not wrap
    if (size > std.math.maxInt(usize) - overhead) {
        if (is_freestanding and config.debug_memory) {
            console.warn("Heap: Size overflow detected for allocation of {d} bytes", .{size});
        }
        return null;
    }

    // Total block size must be 64-byte aligned so that when we split blocks,
    // the next block starts at a 64-byte aligned address. This ensures all
    // payloads are 64-byte aligned (since header is 64 bytes).
    const required_size = std.mem.alignForward(usize, size + overhead, ALIGNMENT);
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
/// Marks the block as free and attempts to coalesce it with adjacent free blocks.
/// Thread-safe: acquires global heap lock.
pub fn free(buf: []u8) void {
    if (!initialized) {
        return;
    }

    // DISABLED: Slab allocator (see alloc() comment)
    // if (slab.free(buf)) {
    //     return;
    // }

    freeToFreeList(buf);
}

/// Internal: Free to the free-list allocator (used by slab for returning slabs)
fn freeToFreeList(buf: []u8) void {
    if (!initialized) {
        return;
    }

    // Acquire lock FIRST to prevent TOCTOU race conditions
    // (heap_start/heap_end could change between check and use)
    const held = heap_lock.acquire();
    defer held.release();

    const ptr_addr = @intFromPtr(buf.ptr);

    // Bounds check must be INSIDE critical section to avoid TOCTOU
    // Also require space for header before ptr_addr (Vuln 5 fix)
    if (ptr_addr < heap_start + @sizeOf(BlockHeader) or ptr_addr >= heap_end) {
        if (is_freestanding) {
            console.warn("Heap: Invalid free at {x}", .{ptr_addr});
        }
        return;
    }

    // Get block header from payload pointer
    const header: *BlockHeader = @ptrFromInt(ptr_addr - @sizeOf(BlockHeader));

    // Verify magic number before touching anything else
    if (header.magic != BlockHeader.ALLOCATOR_MAGIC) {
        if (is_freestanding) {
            console.panic("Heap: Corruption detected! Invalid magic {x} at {x}", .{ header.magic, ptr_addr });
        }
        return;
    }

    if (!header.isAllocated()) {
        // Double-free is a serious bug - panic in Debug mode
        if (@import("builtin").mode == .Debug) {
            @panic("Heap: Double-free detected - possible exploit attempt");
        }
        if (is_freestanding) {
            console.warn("Heap: Double-free at {x}", .{ptr_addr});
        }
        return;
    }

    const block_size = header.getSize();
    const header_addr = @intFromPtr(header);
    const block_end = std.math.add(usize, header_addr, block_size) catch {
        if (is_freestanding) {
            console.panic("Heap: Corruption detected! Block size overflow at {x}", .{ptr_addr});
        }
        return;
    };
    if (block_size < MIN_BLOCK_SIZE or block_end > heap_end) {
        if (is_freestanding) {
            console.panic("Heap: Corruption detected! Invalid block size {d} at {x}", .{ block_size, ptr_addr });
        }
        return;
    }

    const footer = header.getFooter();
    if (footer.size != block_size or footer.canary != heap_canary) {
        if (is_freestanding) {
            console.panic("Heap: Corruption detected! Footer mismatch at {x}", .{ptr_addr});
        }
        return;
    }

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
    // Security: Validate magic and use checked arithmetic to prevent exploitation
    var coalesced_block = header;
    var coalesced_size = block_size;

    // Try to coalesce with next block
    if (header.getNextBlock(heap_end)) |next_block| {
        // Validate magic BEFORE trusting any metadata (prevents unsafe unlink attack)
        if (next_block.magic != BlockHeader.ALLOCATOR_MAGIC) {
            if (is_freestanding) {
                console.panic("Heap: Corrupt next block magic at {x}", .{@intFromPtr(next_block)});
            }
            return;
        }
        if (!next_block.isAllocated()) {
            const next_size = next_block.getSize();
            // Validate size is reasonable (within heap bounds)
            if (next_size < MIN_BLOCK_SIZE or next_size > heap_end - heap_start) {
                if (is_freestanding) {
                    console.panic("Heap: Corrupt next block size {d}", .{next_size});
                }
                return;
            }
            // Use checked arithmetic to detect overflow
            coalesced_size = std.math.add(usize, coalesced_size, next_size) catch {
                if (is_freestanding) {
                    console.panic("Heap: Coalesce overflow with next block", .{});
                }
                return;
            };
            // Remove next block from free list (decrements free_block_count)
            removeFromFreeList(next_block);
        }
    }

    // Try to coalesce with previous block
    if (header.getPrevBlock(heap_start)) |prev_block| {
        // Validate magic BEFORE trusting any metadata (prevents unsafe unlink attack)
        if (prev_block.magic != BlockHeader.ALLOCATOR_MAGIC) {
            if (is_freestanding) {
                console.panic("Heap: Corrupt prev block magic at {x}", .{@intFromPtr(prev_block)});
            }
            return;
        }
        if (!prev_block.isAllocated()) {
            const prev_size = prev_block.getSize();
            // Validate size is reasonable
            if (prev_size < MIN_BLOCK_SIZE or prev_size > heap_end - heap_start) {
                if (is_freestanding) {
                    console.panic("Heap: Corrupt prev block size {d}", .{prev_size});
                }
                return;
            }
            // Use checked arithmetic to detect overflow
            coalesced_size = std.math.add(usize, coalesced_size, prev_size) catch {
                if (is_freestanding) {
                    console.panic("Heap: Coalesce overflow with prev block", .{});
                }
                return;
            };
            // Remove previous block from free list (decrements free_block_count)
            removeFromFreeList(prev_block);
            // Previous block absorbs current
            coalesced_block = prev_block;
        }
    }

    // Update coalesced block
    coalesced_block.setSize(coalesced_size);
    coalesced_block.setAllocated(false);

    // Update footer
    const coalesced_footer = coalesced_block.getFooter();
    setFooter(coalesced_footer, coalesced_size);

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
    mem.copy(dst.ptr, src.ptr, copy_size);

    free(buf);
    return new_ptr;
}

/// Allocate zeroed memory
pub fn allocZeroed(size: usize) ?[]u8 {
    const slice = alloc(size) orelse return null;
    mem.fill(slice.ptr, 0, size);
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
        if (footer.size != size or footer.canary != heap_canary) {
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
    // std.mem.Alignment.toByteUnits returns usize (not optional in 0.15+)
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
        const footer = block.getFooter();
        setFooter(footer, required_size);

        // Create new free block
        const new_block: *BlockHeader = @ptrFromInt(@intFromPtr(block) + required_size);
        new_block.size_and_flags = remaining;
        new_block.setAllocated(false);
        new_block.prev_free = null;
        new_block.next_free = null;
        new_block.magic = BlockHeader.ALLOCATOR_MAGIC;

        // Set footer for new block
        const new_footer = new_block.getFooter();
        setFooter(new_footer, remaining);

        // Add new block to free list (this increments free_block_count)
        addToFreeList(new_block);
    } else {
        // Use entire block (already removed from free list, count already decremented)
        block.setAllocated(true);
        setFooter(block.getFooter(), block.getSize());
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

fn setFooter(footer: *BlockFooter, size: usize) void {
    footer.size = size;
    footer.canary = heap_canary;
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
        // Print slab allocator stats
        slab.printStats();
    }
}

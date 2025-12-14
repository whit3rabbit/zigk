// Memory module aggregator
//
// Re-exports all memory allocation functions.

const allocator = @import("allocator.zig");

// Standard C allocation functions
pub const malloc = allocator.malloc;
pub const free = allocator.free;
pub const realloc = allocator.realloc;
pub const calloc = allocator.calloc;

// Aligned allocation
pub const aligned_alloc = allocator.aligned_alloc;
pub const aligned_free = allocator.aligned_free;
pub const posix_memalign = allocator.posix_memalign;

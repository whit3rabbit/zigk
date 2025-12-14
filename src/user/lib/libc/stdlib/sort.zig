// Sorting and searching (stdlib.h)
//
// qsort and bsearch implementations.

const memory = @import("../memory/root.zig");
const errno_mod = @import("../errno.zig");

/// Comparison function type
pub const CompareFn = *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int;

/// Maximum element size for stack-based swap buffer
const MAX_STACK_ELEMENT_SIZE: usize = 256;

/// Sort array using quicksort algorithm
/// SECURITY FIX: Handles large elements via heap allocation
pub export fn qsort(
    base: ?*anyopaque,
    nmemb: usize,
    size: usize,
    compar: ?CompareFn,
) void {
    if (base == null or compar == null or nmemb < 2 or size == 0) return;

    const cmp = compar.?;
    const arr = @as([*]u8, @ptrCast(base.?));

    // SECURITY FIX: Handle large elements with heap allocation
    if (size > MAX_STACK_ELEMENT_SIZE) {
        const swap_buf = memory.malloc(size);
        if (swap_buf == null) {
            errno_mod.errno = errno_mod.ENOMEM;
            return;
        }
        defer memory.free(swap_buf);

        insertionSortWithBuffer(arr, nmemb, size, cmp, @ptrCast(swap_buf.?));
        return;
    }

    // Stack buffer for small elements
    var temp: [MAX_STACK_ELEMENT_SIZE]u8 = undefined;
    insertionSortWithBuffer(arr, nmemb, size, cmp, &temp);
}

/// Insertion sort implementation (simple, stable)
fn insertionSortWithBuffer(
    arr: [*]u8,
    nmemb: usize,
    size: usize,
    cmp: CompareFn,
    temp: [*]u8,
) void {
    var i: usize = 1;
    while (i < nmemb) : (i += 1) {
        var j = i;
        while (j > 0) {
            const curr = arr + j * size;
            const prev = arr + (j - 1) * size;

            if (cmp(@ptrCast(curr), @ptrCast(prev)) < 0) {
                // Swap elements
                @memcpy(temp[0..size], curr[0..size]);
                @memcpy(curr[0..size], prev[0..size]);
                @memcpy(prev[0..size], temp[0..size]);
                j -= 1;
            } else {
                break;
            }
        }
    }
}

/// Binary search in sorted array
pub export fn bsearch(
    key: ?*const anyopaque,
    base: ?*const anyopaque,
    nmemb: usize,
    size: usize,
    compar: ?CompareFn,
) ?*anyopaque {
    if (key == null or base == null or compar == null or nmemb == 0 or size == 0) {
        return null;
    }

    const cmp = compar.?;
    const arr = @as([*]const u8, @ptrCast(base.?));

    var left: usize = 0;
    var right: usize = nmemb;

    while (left < right) {
        const mid = left + (right - left) / 2;
        const elem = arr + mid * size;

        const result = cmp(key, @ptrCast(elem));
        if (result < 0) {
            right = mid;
        } else if (result > 0) {
            left = mid + 1;
        } else {
            // Found - return pointer to element (cast away const for C compat)
            return @ptrFromInt(@intFromPtr(elem));
        }
    }

    return null;
}

/// Linear search (for unsorted arrays)
pub export fn lfind(
    key: ?*const anyopaque,
    base: ?*const anyopaque,
    nmemb: ?*usize,
    size: usize,
    compar: ?CompareFn,
) ?*anyopaque {
    if (key == null or base == null or nmemb == null or compar == null or size == 0) {
        return null;
    }

    const cmp = compar.?;
    const arr = @as([*]const u8, @ptrCast(base.?));
    const count = nmemb.?.*;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const elem = arr + i * size;
        if (cmp(key, @ptrCast(elem)) == 0) {
            return @ptrFromInt(@intFromPtr(elem));
        }
    }

    return null;
}

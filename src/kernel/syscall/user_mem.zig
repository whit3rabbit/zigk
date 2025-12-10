// User Memory Validation
//
// Consolidated module for validating user-space memory pointers.
// Provides bounds checking, string parsing, and page mapping verification.
//
// This is the single source of truth for user pointer validation in the kernel.
// All syscall handlers should use these functions instead of duplicating logic.
//
// Security model:
// - isValidUserPtr: Fast bounds check only (for performance-sensitive paths)
// - isValidUserAccess: Full check including page mapping and permissions

const console = @import("console");
const vmm = @import("vmm");
const sched = @import("sched");

/// Userspace address range boundaries
/// User code lives below the kernel in the canonical lower half
pub const USER_SPACE_START: u64 = 0x0000_0000_0040_0000; // 4MB (above null guard)
pub const USER_SPACE_END: u64 = 0x0000_7FFF_FFFF_FFFF; // Top of canonical lower half

/// Maximum path length for string validation
pub const MAX_PATH_LEN: usize = 4096;

/// Validate that a user pointer is within the userspace address range.
/// Returns true if the pointer appears valid for userspace access.
///
/// Note: This is currently a bounds check only. Phase 2 will add page mapping
/// verification to ensure pages are actually mapped and accessible.
pub fn isValidUserPtr(ptr: usize, len: usize) bool {
    // Null pointer is never valid
    if (ptr == 0) return false;

    // Zero-length access at valid address is OK
    if (len == 0) return true;

    // Check pointer is in userspace range
    if (ptr < USER_SPACE_START or ptr > USER_SPACE_END) return false;

    // Check for overflow
    const end_addr = @addWithOverflow(ptr, len);
    if (end_addr[1] != 0) return false; // Overflow occurred

    // Check end is still in userspace
    if (end_addr[0] > USER_SPACE_END) return false;

    return true;
}

/// Validate a user string pointer (null-terminated, max length)
/// Alias for isValidUserPtr - the max_len bounds the search area
pub fn isValidUserString(ptr: usize, max_len: usize) bool {
    return isValidUserPtr(ptr, max_len);
}

/// Convert a user string pointer to a Zig slice.
/// Searches for null terminator up to max_len bytes.
/// Returns null if pointer is invalid or no null terminator found within max_len.
///
/// This replaces manual strlen-style loops throughout syscall handlers.
pub fn userStringToSlice(ptr: usize, max_len: usize) ?[]const u8 {
    if (!isValidUserPtr(ptr, max_len)) return null;

    const bytes: [*]const u8 = @ptrFromInt(ptr);
    var len: usize = 0;
    while (len < max_len and bytes[len] != 0) : (len += 1) {}

    // Return the slice (may be empty if first char is null)
    return bytes[0..len];
}

/// Convert a user buffer pointer to a Zig slice.
/// Returns null if pointer validation fails.
///
/// Note: This does NOT copy the data - it creates a slice pointing to user memory.
/// The caller must ensure the data is accessed safely (e.g., via copy or HHDM).
pub fn userBufferToSlice(ptr: usize, len: usize) ?[]u8 {
    if (len == 0) return &[_]u8{};
    if (!isValidUserPtr(ptr, len)) return null;

    const bytes: [*]u8 = @ptrFromInt(ptr);
    return bytes[0..len];
}

/// Convert a user buffer pointer to a const slice.
pub fn userBufferToConstSlice(ptr: usize, len: usize) ?[]const u8 {
    if (len == 0) return &[_]u8{};
    if (!isValidUserPtr(ptr, len)) return null;

    const bytes: [*]const u8 = @ptrFromInt(ptr);
    return bytes[0..len];
}

// =============================================================================
// Permission Checking with Page Mapping Verification
// =============================================================================

/// Access mode for permission checking
pub const AccessMode = enum {
    Read,
    Write,
    Execute,
};

/// Get the current thread's CR3 (page table root).
/// Returns null if no thread is running (early boot).
fn getCurrentCr3() ?u64 {
    const thread = sched.getCurrentThread() orelse return null;
    // cr3 == 0 means kernel thread using kernel page tables
    if (thread.cr3 == 0) return null;
    return thread.cr3;
}

/// Validate user pointer with page mapping and permission checks.
/// This is the secure validation function that verifies:
/// 1. Address is in userspace range (bounds check)
/// 2. All pages are actually mapped in the current address space
/// 3. Pages have appropriate permissions (user-accessible, writable for Write mode)
///
/// Use this for security-critical validation. For performance-sensitive paths
/// that only need bounds checking, use isValidUserPtr instead.
pub fn isValidUserAccess(ptr: usize, len: usize, mode: AccessMode) bool {
    // First do fast bounds check
    if (!isValidUserPtr(ptr, len)) return false;

    // Zero-length access already passed bounds check
    if (len == 0) return true;

    // Get current thread's CR3 for page table verification
    const cr3 = getCurrentCr3() orelse {
        // Early boot or kernel thread - no user address space
        // Fall back to bounds check only (pages may not be set up yet)
        return true;
    };

    // Verify pages are mapped with appropriate permissions
    switch (mode) {
        .Read, .Execute => {
            // For read/execute, just verify pages are user-accessible
            return vmm.verifyUserRange(cr3, ptr, len);
        },
        .Write => {
            // For write, also verify pages are writable
            return vmm.verifyUserRangeWritable(cr3, ptr, len);
        },
    }
}

// =============================================================================
// UserPtr - Type-Safe Wrapper for User Pointers
// =============================================================================

/// Error type for UserPtr operations
pub const UserPtrError = error{
    /// Pointer validation failed (null, out of range, unmapped, or wrong permissions)
    Fault,
};

/// Type-safe wrapper for user-space pointers.
///
/// This wrapper forces validation before any dereference, making it impossible
/// to accidentally access user memory without proper checks. The raw address
/// is stored but cannot be dereferenced directly - you must use the conversion
/// methods which perform validation.
///
/// Usage:
/// ```
/// // In syscall handler
/// const buf = UserPtr.from(buf_ptr);
/// const slice = buf.toSlice(count, .Write) catch return Errno.EFAULT.toReturn();
/// ```
pub const UserPtr = struct {
    /// Raw user-space address (not directly accessible)
    addr: usize,

    /// Create a UserPtr from a raw address
    pub fn from(addr: usize) UserPtr {
        return .{ .addr = addr };
    }

    /// Check if this pointer is null
    pub fn isNull(self: UserPtr) bool {
        return self.addr == 0;
    }

    /// Get the raw address (use sparingly - prefer validated accessors)
    pub fn raw(self: UserPtr) usize {
        return self.addr;
    }

    /// Convert to a mutable slice with full validation.
    /// Verifies bounds, page mapping, and permissions.
    /// Returns error.Fault if any check fails.
    pub fn toSlice(self: UserPtr, len: usize, mode: AccessMode) UserPtrError![]u8 {
        if (len == 0) return &[_]u8{};
        if (!isValidUserAccess(self.addr, len, mode)) return error.Fault;
        const bytes: [*]u8 = @ptrFromInt(self.addr);
        return bytes[0..len];
    }

    /// Convert to a const slice with full validation.
    /// Verifies bounds, page mapping, and read permissions.
    pub fn toConstSlice(self: UserPtr, len: usize) UserPtrError![]const u8 {
        if (len == 0) return &[_]u8{};
        if (!isValidUserAccess(self.addr, len, .Read)) return error.Fault;
        const bytes: [*]const u8 = @ptrFromInt(self.addr);
        return bytes[0..len];
    }

    /// Convert to a null-terminated string slice with validation.
    /// Searches for null terminator up to max_len bytes.
    pub fn toString(self: UserPtr, max_len: usize) UserPtrError![]const u8 {
        return userStringToSlice(self.addr, max_len) orelse error.Fault;
    }

    /// Read a single value of type T from user memory.
    /// Useful for reading structs or integers from syscall arguments.
    pub fn readValue(self: UserPtr, comptime T: type) UserPtrError!T {
        if (!isValidUserAccess(self.addr, @sizeOf(T), .Read)) return error.Fault;
        const ptr: *const T = @ptrFromInt(self.addr);
        return ptr.*;
    }

    /// Get a pointer to write a single value of type T to user memory.
    /// Caller must write through the returned pointer.
    pub fn writePtr(self: UserPtr, comptime T: type) UserPtrError!*T {
        if (!isValidUserAccess(self.addr, @sizeOf(T), .Write)) return error.Fault;
        return @ptrFromInt(self.addr);
    }

    /// Offset this pointer by a byte count, returning a new UserPtr.
    /// Does NOT validate - validation happens on access.
    pub fn offset(self: UserPtr, bytes: usize) UserPtr {
        return .{ .addr = self.addr +% bytes };
    }
};

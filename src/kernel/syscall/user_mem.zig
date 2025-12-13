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
    if (end_addr[0] > USER_SPACE_END + 1) return false;

    return true;
}

/// Copy a null-terminated string from user memory to a kernel buffer.
/// Returns a slice of the kernel buffer containing the string (excluding null).
/// Returns error.Fault if a fault occurs before null is found.
/// Returns error.NameTooLong if null is not found within the buffer.
pub fn copyStringFromUser(dest: []u8, src: usize) ![]u8 {
    if (dest.len == 0) return &[_]u8{};
    if (src == 0) return error.Fault;

    // Validate pointer before casting to avoid non-canonical address panic
    // We don't know string length yet, so check if start is in user space
    if (!isValidUserPtr(src, 1)) return error.Fault;

    // Use raw copy to pull as much as possible
    const rem = _asm_copy_from_user(dest.ptr, @ptrFromInt(src), dest.len);
    const copied = dest.len - rem;

    // Search for null terminator in what we managed to copy
    if (std.mem.indexOfScalar(u8, dest[0..copied], 0)) |len| {
        return dest[0..len];
    }

    // No null terminator found
    if (rem > 0) {
        // We hit a fault before finding the terminator
        return error.Fault;
    }

    // Buffer filled but no null terminator
    return error.NameTooLong;
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
// Safe Copy Primitives (Assembly)
// =============================================================================

extern fn _asm_copy_from_user(dest: *anyopaque, src: *const anyopaque, len: usize) usize;
extern fn _asm_copy_to_user(dest: *anyopaque, src: *const anyopaque, len: usize) usize;

/// Copy data from user memory to kernel memory safely.
/// Returns number of bytes NOT copied (0 on success).
/// On fault, returns remaining bytes.
pub fn copyFromUser(dest: []u8, src: usize) usize {
    if (!isValidUserPtr(src, dest.len)) return dest.len;
    return _asm_copy_from_user(dest.ptr, @ptrFromInt(src), dest.len);
}

/// Copy data from kernel memory to user memory safely.
/// Returns number of bytes NOT copied (0 on success).
/// On fault, returns remaining bytes.
pub fn copyToUser(dest: usize, src: []const u8) usize {
    if (!isValidUserPtr(dest, src.len)) return src.len;
    return _asm_copy_to_user(@ptrFromInt(dest), src.ptr, src.len);
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
/// var kbuf: [64]u8 = undefined;
/// const len = buf.copyToKernel(&kbuf) catch return Errno.EFAULT.toReturn();
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

    /// Copy data from user memory to a kernel buffer.
    /// Returns error.Fault if the copy fails (pointer invalid or unmapped).
    /// Returns the number of bytes copied (always equal to buf.len on success).
    pub fn copyToKernel(self: UserPtr, buf: []u8) UserPtrError!usize {
        if (copyFromUser(buf, self.addr) != 0) {
            return error.Fault;
        }
        return buf.len;
    }

    /// Copy data from a kernel buffer to user memory.
    /// Returns error.Fault if the copy fails.
    /// Returns the number of bytes copied (always equal to buf.len on success).
    pub fn copyFromKernel(self: UserPtr, buf: []const u8) UserPtrError!usize {
        if (copyToUser(self.addr, buf) != 0) {
            return error.Fault;
        }
        return buf.len;
    }

    /// Read a single value of type T from user memory.
    /// Useful for reading structs or integers from syscall arguments.
    pub fn readValue(self: UserPtr, comptime T: type) UserPtrError!T {
        var val: T = undefined;
        const bytes = std.mem.asBytes(&val);
        if (copyFromUser(bytes, self.addr) != 0) {
            return error.Fault;
        }
        return val;
    }

    /// Write a single value of type T to user memory.
    pub fn writeValue(self: UserPtr, val: anytype) UserPtrError!void {
        const bytes = std.mem.asBytes(&val);
        if (copyToUser(self.addr, bytes) != 0) {
            return error.Fault;
        }
    }

    /// Offset this pointer by a byte count, returning a new UserPtr.
    /// Does NOT validate - validation happens on access.
    pub fn offset(self: UserPtr, bytes: usize) UserPtr {
        return .{ .addr = self.addr +% bytes };
    }
};

const std = @import("std");

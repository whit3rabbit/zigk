//! Permission Checking Module
//!
//! Implements POSIX-style permission checking with capability override.
//! Used by syscall handlers to verify file access permissions.

const std = @import("std");
const process_mod = @import("process");
const vfs = @import("fs_meta"); // Use shared metadata
const meta = @import("fs_meta");

const capabilities = @import("capabilities");
const fd_mod = @import("fd");

/// Access request types (matches Linux access() mode flags)
pub const AccessRequest = enum(u8) {
    Read = 4, // R_OK
    Write = 2, // W_OK
    Execute = 1, // X_OK
};

/// Check if process can access file with requested permissions
///
/// Order of checks:
/// 1. Root (euid == 0) bypasses all checks
/// 2. POSIX mode bits checked against euid/egid
/// 3. FileCapability checked as fallback grant
///
/// Returns: true if access allowed, false if denied
pub fn checkAccess(
    proc: *process_mod.Process,
    file_meta: meta.FileMeta,

    request: AccessRequest,
    path: []const u8,
) bool {
    // Root bypass - euid 0 can access anything
    if (proc.euid == 0) return true;

    // Extract permission bits (lower 9 bits)
    const mode = file_meta.mode & 0o777;

    // Determine which permission set applies based on uid/gid
    var applicable_bits: u32 = undefined;

    if (proc.euid == file_meta.uid) {
        // Owner permissions (bits 6-8)
        applicable_bits = (mode >> 6) & 7;
    } else if (proc.egid == file_meta.gid) {
        // Group permissions (bits 3-5)
        // Note: This is simplified - Linux also checks supplementary groups
        applicable_bits = (mode >> 3) & 7;
    } else {
        // Other permissions (bits 0-2)
        applicable_bits = mode & 7;
    }

    // Check if requested access is allowed
    const request_bits = @intFromEnum(request);
    if ((applicable_bits & request_bits) == request_bits) {
        return true;
    }

    // Fallback: Check FileCapability for write operations
    return checkCapabilityOverride(proc, request, path);
}

/// Check both read and write access (for O_RDWR)
pub fn checkReadWriteAccess(
    proc: *process_mod.Process,
    file_meta: meta.FileMeta,

    path: []const u8,
) bool {
    return checkAccess(proc, file_meta, .Read, path) and
        checkAccess(proc, file_meta, .Write, path);
}

/// Check if process has capability override for the operation
fn checkCapabilityOverride(
    proc: *process_mod.Process,
    request: AccessRequest,
    path: []const u8,
) bool {
    // Map access request to capability operation
    const cap_op: u8 = switch (request) {
        .Write => capabilities.FileCapability.WRITE_OP,
        .Read => 0, // No read capability override yet
        .Execute => 0, // No execute capability override yet
    };

    // No capability override available for this operation
    if (cap_op == 0) return false;

    // Check if process has FileCapability for this path
    return proc.hasFileCapability(path, cap_op);
}

/// Check if process can create a file at the given path
pub fn checkCreatePermission(
    proc: *process_mod.Process,
    path: []const u8,
) bool {
    // Root can create anywhere
    if (proc.euid == 0) return true;

    // Check for CREATE capability
    return proc.hasFileCapability(path, capabilities.FileCapability.CREATE_OP);
}

/// Convert open flags to required access type
pub fn flagsToAccess(flags: u32) AccessRequest {
    const access_mode = flags & fd_mod.O_ACCMODE;
    return switch (access_mode) {
        fd_mod.O_RDONLY => .Read,
        fd_mod.O_WRONLY => .Write,
        fd_mod.O_RDWR => .Read, // Caller should also check Write separately
        else => .Read,
    };
}

/// Check if flags require write access
pub fn flagsRequireWrite(flags: u32) bool {
    const access_mode = flags & fd_mod.O_ACCMODE;
    return access_mode == fd_mod.O_WRONLY or access_mode == fd_mod.O_RDWR;
}

/// Apply umask to mode for file creation
pub fn applyUmask(mode: u32, umask: u32) u32 {
    return mode & ~umask;
}

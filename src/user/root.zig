// Zscapek Userland Module Root
//
// Provides userland runtime components:
//   - crt0: Entry point with SysV ABI stack setup
//   - syscall: Type-safe syscall wrappers
//   - uapi: Syscall numbers and errno codes
//
// Usage:
//   const user = @import("user");
//   user.syscall.print("Hello from userland!\n");

// Syscall numbers and error codes (shared with kernel)
pub const uapi = @import("uapi");

// Re-export uapi types for convenience
pub const SyscallError = uapi.errno.Errno;

// Note: crt0 is typically linked directly, not imported
// pub const crt0 = @import("crt0.zig");

// Note: syscall.zig has its own uapi import via build system
// This root module provides high-level re-exports

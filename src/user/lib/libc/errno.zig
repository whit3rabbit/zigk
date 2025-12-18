// Global errno for libc compatibility
//
// This provides the global errno variable required by C programs.
//
// SECURITY WARNING: This errno is NOT thread-local.
// In multithreaded programs, errno values can be corrupted by concurrent
// calls from other threads, potentially causing security-sensitive code
// to misinterpret error conditions.
//
// TODO: When kernel TLS support is available, change to:
//   pub threadlocal var errno: c_int = 0;

/// Global errno variable - set by libc functions on error
/// WARNING: NOT THREAD-SAFE - use with caution in multithreaded code.
/// Check errno immediately after a failing call before any other
/// operations that might modify it.
pub export var errno: c_int = 0;

// Common error codes (matching Linux values)
// These are the most commonly used in libc functions

/// Operation not permitted
pub const EPERM: c_int = 1;

/// No such file or directory
pub const ENOENT: c_int = 2;

/// Interrupted system call
pub const EINTR: c_int = 4;

/// I/O error
pub const EIO: c_int = 5;

/// Bad file descriptor
pub const EBADF: c_int = 9;

/// Resource temporarily unavailable
pub const EAGAIN: c_int = 11;

/// Out of memory
pub const ENOMEM: c_int = 12;

/// Permission denied
pub const EACCES: c_int = 13;

/// Bad address
pub const EFAULT: c_int = 14;

/// Invalid argument
pub const EINVAL: c_int = 22;

/// Too many open files
pub const EMFILE: c_int = 24;

/// No space left on device
pub const ENOSPC: c_int = 28;

/// Math result not representable
pub const ERANGE: c_int = 34;

/// Function not implemented
pub const ENOSYS: c_int = 38;

/// Value too large for defined data type
pub const EOVERFLOW: c_int = 75;

// Error string table for strerror
pub const error_strings = [_][:0]const u8{
    "Success",                       // 0
    "Operation not permitted",       // 1 EPERM
    "No such file or directory",     // 2 ENOENT
    "No such process",               // 3 ESRCH
    "Interrupted system call",       // 4 EINTR
    "I/O error",                     // 5 EIO
    "No such device or address",     // 6 ENXIO
    "Argument list too long",        // 7 E2BIG
    "Exec format error",             // 8 ENOEXEC
    "Bad file descriptor",           // 9 EBADF
    "No child processes",            // 10 ECHILD
    "Resource temporarily unavailable", // 11 EAGAIN
    "Out of memory",                 // 12 ENOMEM
    "Permission denied",             // 13 EACCES
    "Bad address",                   // 14 EFAULT
    "Block device required",         // 15 ENOTBLK
    "Device or resource busy",       // 16 EBUSY
    "File exists",                   // 17 EEXIST
    "Cross-device link",             // 18 EXDEV
    "No such device",                // 19 ENODEV
    "Not a directory",               // 20 ENOTDIR
    "Is a directory",                // 21 EISDIR
    "Invalid argument",              // 22 EINVAL
    "File table overflow",           // 23 ENFILE
    "Too many open files",           // 24 EMFILE
    "Not a typewriter",              // 25 ENOTTY
    "Text file busy",                // 26 ETXTBSY
    "File too large",                // 27 EFBIG
    "No space left on device",       // 28 ENOSPC
    "Illegal seek",                  // 29 ESPIPE
    "Read-only file system",         // 30 EROFS
    "Too many links",                // 31 EMLINK
    "Broken pipe",                   // 32 EPIPE
    "Math argument out of domain",   // 33 EDOM
    "Math result not representable", // 34 ERANGE
    "Resource deadlock would occur", // 35 EDEADLK
    "File name too long",            // 36 ENAMETOOLONG
    "No record locks available",     // 37 ENOLCK
    "Function not implemented",      // 38 ENOSYS
};

/// Unknown error message for out-of-range errno values
pub const unknown_error: [:0]const u8 = "Unknown error";

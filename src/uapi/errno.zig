// ZigK Error Numbers
//
// Standard Linux errno values for syscall error returns.
// Error codes are returned as negative values in RAX (e.g., -ENOENT = -2).
//
// Usage in syscall handlers:
//   return @bitCast(-@as(isize, @intFromEnum(errno.ENOENT)));

/// Error number type - matches Linux errno values
pub const Errno = enum(i32) {
    /// Success (not an error)
    SUCCESS = 0,

    /// Operation not permitted
    EPERM = 1,

    /// No such file or directory
    ENOENT = 2,

    /// No such process
    ESRCH = 3,

    /// Interrupted system call
    EINTR = 4,

    /// I/O error
    EIO = 5,

    /// No such device or address
    ENXIO = 6,

    /// Argument list too long
    E2BIG = 7,

    /// Exec format error
    ENOEXEC = 8,

    /// Bad file descriptor
    EBADF = 9,

    /// No child processes
    ECHILD = 10,

    /// Resource temporarily unavailable (try again)
    EAGAIN = 11,

    /// Out of memory
    ENOMEM = 12,

    /// Permission denied
    EACCES = 13,

    /// Bad address
    EFAULT = 14,

    /// Block device required
    ENOTBLK = 15,

    /// Device or resource busy
    EBUSY = 16,

    /// File exists
    EEXIST = 17,

    /// Cross-device link
    EXDEV = 18,

    /// No such device
    ENODEV = 19,

    /// Not a directory
    ENOTDIR = 20,

    /// Is a directory
    EISDIR = 21,

    /// Invalid argument
    EINVAL = 22,

    /// File table overflow
    ENFILE = 23,

    /// Too many open files
    EMFILE = 24,

    /// Not a typewriter
    ENOTTY = 25,

    /// Text file busy
    ETXTBSY = 26,

    /// File too large
    EFBIG = 27,

    /// No space left on device
    ENOSPC = 28,

    /// Illegal seek
    ESPIPE = 29,

    /// Read-only file system
    EROFS = 30,

    /// Too many links
    EMLINK = 31,

    /// Broken pipe
    EPIPE = 32,

    /// Math argument out of domain
    EDOM = 33,

    /// Math result not representable
    ERANGE = 34,

    /// Resource deadlock would occur
    EDEADLK = 35,

    /// File name too long
    ENAMETOOLONG = 36,

    /// No record locks available
    ENOLCK = 37,

    /// Function not implemented
    ENOSYS = 38,

    /// Directory not empty
    ENOTEMPTY = 39,

    /// Too many symbolic links encountered
    ELOOP = 40,

    /// No message of desired type
    ENOMSG = 42,

    /// Identifier removed
    EIDRM = 43,

    // Socket errors

    /// Socket operation on non-socket
    ENOTSOCK = 88,

    /// Protocol not supported
    EPROTONOSUPPORT = 93,

    /// Socket type not supported
    ESOCKTNOSUPPORT = 94,

    /// Address family not supported
    EAFNOSUPPORT = 97,

    /// Address already in use
    EADDRINUSE = 98,

    /// Cannot assign requested address
    EADDRNOTAVAIL = 99,

    // Network errors (commonly used)

    /// Network is down
    ENETDOWN = 100,

    /// Network is unreachable
    ENETUNREACH = 101,

    /// Connection reset by peer
    ECONNRESET = 104,

    /// Transport endpoint is already connected
    EISCONN = 106,

    /// Transport endpoint is not connected
    ENOTCONN = 107,

    /// Connection timed out
    ETIMEDOUT = 110,

    /// Connection refused
    ECONNREFUSED = 111,

    /// Host is unreachable
    EHOSTUNREACH = 113,

    /// Operation already in progress
    EALREADY = 114,

    /// Operation now in progress
    EINPROGRESS = 115,

    /// Convert errno to negative return value for syscall
    pub fn toReturn(self: Errno) isize {
        return -@as(isize, @intFromEnum(self));
    }

    /// Create errno from negative return value
    pub fn fromReturn(ret: isize) ?Errno {
        if (ret >= 0) return null;
        return @enumFromInt(-@as(i32, @truncate(ret)));
    }
};

// Convenience aliases matching C naming
pub const EPERM = Errno.EPERM;
pub const ENOENT = Errno.ENOENT;
pub const ESRCH = Errno.ESRCH;
pub const EINTR = Errno.EINTR;
pub const EIO = Errno.EIO;
pub const ENXIO = Errno.ENXIO;
pub const E2BIG = Errno.E2BIG;
pub const ENOEXEC = Errno.ENOEXEC;
pub const EBADF = Errno.EBADF;
pub const ECHILD = Errno.ECHILD;
pub const EAGAIN = Errno.EAGAIN;
pub const ENOMEM = Errno.ENOMEM;
pub const EACCES = Errno.EACCES;
pub const EFAULT = Errno.EFAULT;
pub const ENOTBLK = Errno.ENOTBLK;
pub const EBUSY = Errno.EBUSY;
pub const EEXIST = Errno.EEXIST;
pub const EXDEV = Errno.EXDEV;
pub const ENODEV = Errno.ENODEV;
pub const ENOTDIR = Errno.ENOTDIR;
pub const EISDIR = Errno.EISDIR;
pub const EINVAL = Errno.EINVAL;
pub const ENFILE = Errno.ENFILE;
pub const EMFILE = Errno.EMFILE;
pub const ENOTTY = Errno.ENOTTY;
pub const ETXTBSY = Errno.ETXTBSY;
pub const EFBIG = Errno.EFBIG;
pub const ENOSPC = Errno.ENOSPC;
pub const ESPIPE = Errno.ESPIPE;
pub const EROFS = Errno.EROFS;
pub const EMLINK = Errno.EMLINK;
pub const EPIPE = Errno.EPIPE;
pub const EDOM = Errno.EDOM;
pub const ERANGE = Errno.ERANGE;
pub const EDEADLK = Errno.EDEADLK;
pub const ENAMETOOLONG = Errno.ENAMETOOLONG;
pub const ENOLCK = Errno.ENOLCK;
pub const ENOSYS = Errno.ENOSYS;
pub const ENOTEMPTY = Errno.ENOTEMPTY;
pub const ELOOP = Errno.ELOOP;
pub const ENOMSG = Errno.ENOMSG;
pub const EIDRM = Errno.EIDRM;
pub const ENOTSOCK = Errno.ENOTSOCK;
pub const EPROTONOSUPPORT = Errno.EPROTONOSUPPORT;
pub const ESOCKTNOSUPPORT = Errno.ESOCKTNOSUPPORT;
pub const EAFNOSUPPORT = Errno.EAFNOSUPPORT;
pub const EADDRINUSE = Errno.EADDRINUSE;
pub const EADDRNOTAVAIL = Errno.EADDRNOTAVAIL;
pub const ENETDOWN = Errno.ENETDOWN;
pub const ENETUNREACH = Errno.ENETUNREACH;
pub const ECONNRESET = Errno.ECONNRESET;
pub const ETIMEDOUT = Errno.ETIMEDOUT;
pub const ECONNREFUSED = Errno.ECONNREFUSED;
pub const EHOSTUNREACH = Errno.EHOSTUNREACH;
pub const EALREADY = Errno.EALREADY;
pub const EINPROGRESS = Errno.EINPROGRESS;
pub const EISCONN = Errno.EISCONN;
pub const ENOTCONN = Errno.ENOTCONN;

/// EWOULDBLOCK is typically the same as EAGAIN on Linux
pub const EWOULDBLOCK = EAGAIN;

// =============================================================================
// Syscall Error Set
// =============================================================================
// Error set for syscall handlers using Zig's error union pattern.
// Errors are converted to negative isize at the syscall dispatch boundary.

/// Syscall error type - maps to errno values
/// Used for syscall handlers that return SyscallError!usize
pub const SyscallError = error{
    EPERM,
    ENOENT,
    ESRCH,
    EINTR,
    EIO,
    ENXIO,
    E2BIG,
    ENOEXEC,
    EBADF,
    ECHILD,
    EAGAIN,
    ENOMEM,
    EACCES,
    EFAULT,
    ENOTBLK,
    EBUSY,
    EEXIST,
    EXDEV,
    ENODEV,
    ENOTDIR,
    EISDIR,
    EINVAL,
    ENFILE,
    EMFILE,
    ENOTTY,
    ETXTBSY,
    EFBIG,
    ENOSPC,
    ESPIPE,
    EROFS,
    EMLINK,
    EPIPE,
    EDOM,
    ERANGE,
    EDEADLK,
    ENAMETOOLONG,
    ENOLCK,
    ENOSYS,
    ENOTEMPTY,
    ELOOP,
    ENOMSG,
    EIDRM,
    ENOTSOCK,
    EPROTONOSUPPORT,
    ESOCKTNOSUPPORT,
    EAFNOSUPPORT,
    EADDRINUSE,
    EADDRNOTAVAIL,
    ENETDOWN,
    ENETUNREACH,
    ECONNRESET,
    ETIMEDOUT,
    ECONNREFUSED,
    EHOSTUNREACH,
    EALREADY,
    EINPROGRESS,
    EISCONN,
    ENOTCONN,
};

/// Convert SyscallError to negative isize return value for syscall ABI
pub fn errorToReturn(err: SyscallError) isize {
    const errno_val: i32 = switch (err) {
        error.EPERM => 1,
        error.ENOENT => 2,
        error.ESRCH => 3,
        error.EINTR => 4,
        error.EIO => 5,
        error.ENXIO => 6,
        error.E2BIG => 7,
        error.ENOEXEC => 8,
        error.EBADF => 9,
        error.ECHILD => 10,
        error.EAGAIN => 11,
        error.ENOMEM => 12,
        error.EACCES => 13,
        error.EFAULT => 14,
        error.ENOTBLK => 15,
        error.EBUSY => 16,
        error.EEXIST => 17,
        error.EXDEV => 18,
        error.ENODEV => 19,
        error.ENOTDIR => 20,
        error.EISDIR => 21,
        error.EINVAL => 22,
        error.ENFILE => 23,
        error.EMFILE => 24,
        error.ENOTTY => 25,
        error.ETXTBSY => 26,
        error.EFBIG => 27,
        error.ENOSPC => 28,
        error.ESPIPE => 29,
        error.EROFS => 30,
        error.EMLINK => 31,
        error.EPIPE => 32,
        error.EDOM => 33,
        error.ERANGE => 34,
        error.EDEADLK => 35,
        error.ENAMETOOLONG => 36,
        error.ENOLCK => 37,
        error.ENOSYS => 38,
        error.ENOTEMPTY => 39,
        error.ELOOP => 40,
        error.ENOMSG => 42,
        error.EIDRM => 43,
        error.ENOTSOCK => 88,
        error.EPROTONOSUPPORT => 93,
        error.ESOCKTNOSUPPORT => 94,
        error.EAFNOSUPPORT => 97,
        error.EADDRINUSE => 98,
        error.EADDRNOTAVAIL => 99,
        error.ENETDOWN => 100,
        error.ENETUNREACH => 101,
        error.ECONNRESET => 104,
        error.EISCONN => 106,
        error.ENOTCONN => 107,
        error.ETIMEDOUT => 110,
        error.ECONNREFUSED => 111,
        error.EHOSTUNREACH => 113,
        error.EALREADY => 114,
        error.EINPROGRESS => 115,
    };
    return -@as(isize, errno_val);
}

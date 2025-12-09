// Socket error definitions and errno mapping.

pub const SocketError = error{
    BadFd,
    AfNotSupported,
    TypeNotSupported,
    NoSocketsAvailable,
    AddrInUse,
    AddrNotAvail,
    NetworkDown,
    NetworkUnreachable,
    WouldBlock,
    TimedOut,
    InvalidArg,
    AlreadyConnected,
    NotConnected,
    ConnectionRefused,
    ConnectionReset,
    AccessDenied,
    NoResources,
    SystemError, // Scheduler/thread integration not available
};

const uapi = @import("uapi");
const E = uapi.errno.Errno; // Assuming we want the enum type to access values if they are static? Or are they declarations?
// If E is the enum type, `E.EBADF` works.

pub fn errorToErrno(err: SocketError) isize {
    return switch (err) {
        SocketError.BadFd => -@as(isize, @intFromEnum(E.EBADF)),
        SocketError.AfNotSupported => -@as(isize, @intFromEnum(E.EAFNOSUPPORT)),
        SocketError.TypeNotSupported => -@as(isize, @intFromEnum(E.ESOCKTNOSUPPORT)),
        SocketError.NoSocketsAvailable => -@as(isize, @intFromEnum(E.ENFILE)),
        SocketError.AddrInUse => -@as(isize, @intFromEnum(E.EADDRINUSE)),
        SocketError.AddrNotAvail => -@as(isize, @intFromEnum(E.EADDRNOTAVAIL)),
        SocketError.NetworkDown => -@as(isize, @intFromEnum(E.ENETDOWN)),
        SocketError.NetworkUnreachable => -@as(isize, @intFromEnum(E.ENETUNREACH)),
        SocketError.WouldBlock => -@as(isize, @intFromEnum(E.EAGAIN)),
        SocketError.TimedOut => -@as(isize, @intFromEnum(E.ETIMEDOUT)),
        SocketError.InvalidArg => -@as(isize, @intFromEnum(E.EINVAL)),
        SocketError.AlreadyConnected => -@as(isize, @intFromEnum(E.EISCONN)),
        SocketError.NotConnected => -@as(isize, @intFromEnum(E.ENOTCONN)),
        SocketError.ConnectionRefused => -@as(isize, @intFromEnum(E.ECONNREFUSED)),
        SocketError.ConnectionReset => -@as(isize, @intFromEnum(E.ECONNRESET)),
        SocketError.AccessDenied => -@as(isize, @intFromEnum(E.EACCES)),
        SocketError.NoResources => -@as(isize, @intFromEnum(E.ENOMEM)),
        SocketError.SystemError => -@as(isize, @intFromEnum(E.ENOSYS)),
    };
}

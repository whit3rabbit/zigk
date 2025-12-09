/// TCP error set and errno mapping.
pub const TcpError = error{
    NoResources,
    AlreadyConnected,
    NotConnected,
    NetworkError,
    WouldBlock,
    ConnectionRefused,
    ConnectionReset,
    ConnectionClosed,
    TimedOut,
};

/// Convert TcpError to Linux errno
pub fn errorToErrno(err: TcpError) isize {
    return switch (err) {
        TcpError.NoResources => -12, // ENOMEM
        TcpError.AlreadyConnected => -106, // EISCONN
        TcpError.NotConnected => -107, // ENOTCONN
        TcpError.NetworkError => -101, // ENETUNREACH
        TcpError.WouldBlock => -11, // EAGAIN
        TcpError.ConnectionRefused => -111, // ECONNREFUSED
        TcpError.ConnectionReset => -104, // ECONNRESET
        TcpError.ConnectionClosed => 0, // Not an error - return 0 for EOF
        TcpError.TimedOut => -110, // ETIMEDOUT
    };
}

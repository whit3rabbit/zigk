
pub const POLLIN: u16 = 0x0001;
pub const POLLPRI: u16 = 0x0002;
pub const POLLOUT: u16 = 0x0004;
pub const POLLERR: u16 = 0x0008;
pub const POLLHUP: u16 = 0x0010;
pub const POLLNVAL: u16 = 0x0020;
pub const POLLRDNORM: u16 = 0x0040;
pub const POLLRDBAND: u16 = 0x0080;
pub const POLLWRNORM: u16 = 0x0100;
pub const POLLWRBAND: u16 = 0x0200;
pub const POLLMSG: u16 = 0x0400;
pub const POLLREMOVE: u16 = 0x1000;
pub const POLLRDHUP: u16 = 0x2000;

pub const PollFd = extern struct {
    fd: i32,
    events: u16,
    revents: u16,
};

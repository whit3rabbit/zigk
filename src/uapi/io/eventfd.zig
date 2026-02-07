// Eventfd API Definitions (Linux x86_64 compatible)
//
// eventfd is a kernel object that provides a wait/notify mechanism
// via file descriptor semantics. Used for event notification between threads.

/// eventfd2 flags
pub const EFD_CLOEXEC: u32 = 0x80000; // Set close-on-exec flag (same as O_CLOEXEC)
pub const EFD_NONBLOCK: u32 = 0x800; // Set non-blocking mode (same as O_NONBLOCK)
pub const EFD_SEMAPHORE: u32 = 0x1; // Semaphore mode: read returns 1, write increments counter

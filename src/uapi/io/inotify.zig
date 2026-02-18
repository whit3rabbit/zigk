// Inotify API Definitions (Linux compatible)
//
// inotify provides a file monitoring mechanism via file descriptors.
// Watches can be added on files or directories to receive events
// when filesystem changes occur.

/// Event types (mask bits)
pub const IN_ACCESS: u32 = 0x00000001; // File was accessed
pub const IN_MODIFY: u32 = 0x00000002; // File was modified
pub const IN_ATTRIB: u32 = 0x00000004; // Metadata changed
pub const IN_CLOSE_WRITE: u32 = 0x00000008; // Writable file closed
pub const IN_CLOSE_NOWRITE: u32 = 0x00000010; // Unwritable file closed
pub const IN_OPEN: u32 = 0x00000020; // File was opened
pub const IN_MOVED_FROM: u32 = 0x00000040; // File moved from X
pub const IN_MOVED_TO: u32 = 0x00000080; // File moved to Y
pub const IN_CREATE: u32 = 0x00000100; // Subfile was created
pub const IN_DELETE: u32 = 0x00000200; // Subfile was deleted
pub const IN_DELETE_SELF: u32 = 0x00000400; // Self was deleted
pub const IN_MOVE_SELF: u32 = 0x00000800; // Self was moved

/// Convenience combinations
pub const IN_CLOSE: u32 = IN_CLOSE_WRITE | IN_CLOSE_NOWRITE;
pub const IN_MOVE: u32 = IN_MOVED_FROM | IN_MOVED_TO;
pub const IN_ALL_EVENTS: u32 = 0x00000FFF; // All of the above

/// Queue overflow: fired when event queue is full (wd = -1, no name)
pub const IN_Q_OVERFLOW: u32 = 0x00004000;

/// Special flags for inotify_add_watch
pub const IN_ONESHOT: u32 = 0x80000000; // Only send event once
pub const IN_MASK_ADD: u32 = 0x20000000; // Add events to existing watch mask

/// Flags for inotify_init1
pub const IN_NONBLOCK: u32 = 0x800; // Same as O_NONBLOCK
pub const IN_CLOEXEC: u32 = 0x80000; // Same as O_CLOEXEC

/// inotify_event structure (variable-length: header + name)
/// The name field follows immediately after this header in the read buffer.
/// len includes padding to align subsequent events.
pub const InotifyEvent = extern struct {
    wd: i32, // Watch descriptor
    mask: u32, // Event mask
    cookie: u32, // Cookie for rename pairing (0 for non-rename events)
    len: u32, // Length of name field (including null and padding)
};

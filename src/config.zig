// ZigK Kernel Configuration Constants
//
// Compile-time configuration for kernel behavior.
// These constants can be overridden via build options if needed.

/// Kernel version string
pub const version = "0.1.0";

/// Kernel name
pub const name = "ZigK";

/// Default kernel stack size per thread (16 KB)
pub const default_stack_size: usize = 16 * 1024;

/// Kernel heap size (2 MB as specified in plan.md)
pub const heap_size: usize = 2 * 1024 * 1024;

/// Maximum number of threads
pub const max_threads: usize = 64;

/// Timer frequency in Hz (10ms quantum)
pub const timer_hz: u32 = 100;

/// Serial port baud rate for debug output
pub const serial_baud: u32 = 115200;

/// Enable debug output
pub const debug_enabled: bool = true;

/// Enable verbose memory allocation logging
pub const debug_memory: bool = false;

/// Enable verbose scheduler logging
pub const debug_scheduler: bool = false;

/// Enable verbose network logging
pub const debug_network: bool = false;

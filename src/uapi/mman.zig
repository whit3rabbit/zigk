// MMap Flags and Protections
//
// Compliant with Linux x86_64 ABI

/// Page protection flags
pub const PROT_READ: usize = 0x1;
pub const PROT_WRITE: usize = 0x2;
pub const PROT_EXEC: usize = 0x4;
pub const PROT_NONE: usize = 0x0;

/// Map flags
pub const MAP_SHARED: usize = 0x01;
pub const MAP_PRIVATE: usize = 0x02;
pub const MAP_FIXED: usize = 0x10;
pub const MAP_ANONYMOUS: usize = 0x20;
pub const MAP_GROWSDOWN: usize = 0x0100;
pub const MAP_DENYWRITE: usize = 0x0800;
pub const MAP_EXECUTABLE: usize = 0x1000;
pub const MAP_LOCKED: usize = 0x2000;
pub const MAP_NORESERVE: usize = 0x4000;
pub const MAP_POPULATE: usize = 0x8000;
pub const MAP_NONBLOCK: usize = 0x10000;
pub const MAP_STACK: usize = 0x20000;
pub const MAP_HUGETLB: usize = 0x40000;

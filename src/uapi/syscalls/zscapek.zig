// Zscapek Custom Extensions
//
// These syscalls are unique to Zscapek and use numbers 1000+.

/// Write debug message to kernel log
pub const SYS_DEBUG_LOG: usize = 1000;
/// Get framebuffer info
pub const SYS_GET_FB_INFO: usize = 1001;
/// Map framebuffer into process address space
pub const SYS_MAP_FB: usize = 1002;
/// Flush framebuffer to display (trigger present)
pub const SYS_FB_FLUSH: usize = 1006;
/// Read raw keyboard scancode (non-blocking)
pub const SYS_READ_SCANCODE: usize = 1003;
/// Read ASCII character from input buffer (blocking)
pub const SYS_GETCHAR: usize = 1004;
/// Write character to console
pub const SYS_PUTCHAR: usize = 1005;

// Input/Mouse Syscalls (1010-1019)
/// Read next input event (non-blocking)
pub const SYS_READ_INPUT_EVENT: usize = 1010;
/// Get current cursor position
pub const SYS_GET_CURSOR_POSITION: usize = 1011;
/// Set cursor bounds (screen dimensions)
pub const SYS_SET_CURSOR_BOUNDS: usize = 1012;
/// Set input mode (relative/absolute/raw)
pub const SYS_SET_INPUT_MODE: usize = 1013;

// IPC & Microkernel Syscalls (1020-1029)
/// Send an IPC message to a process (blocking)
pub const SYS_SEND: usize = 1020;
/// Receive an IPC message (blocking)
pub const SYS_RECV: usize = 1021;
/// Wait for a hardware interrupt (blocking)
pub const SYS_WAIT_INTERRUPT: usize = 1022;
/// Connect kernel logger to IPC backend
pub const SYS_REGISTER_IPC_LOGGER: usize = 1025;
/// Register the current process as a named service
pub const SYS_REGISTER_SERVICE: usize = 1026;
/// Lookup a service PID by name
pub const SYS_LOOKUP_SERVICE: usize = 1027;

// DMA/MMIO Syscalls (1030-1039)
/// Map physical MMIO region into userspace
pub const SYS_MMAP_PHYS: usize = 1030;
/// Allocate DMA-capable memory with known physical address
pub const SYS_ALLOC_DMA: usize = 1031;
/// Free DMA memory previously allocated with SYS_ALLOC_DMA
pub const SYS_FREE_DMA: usize = 1032;
/// Enumerate PCI devices
pub const SYS_PCI_ENUMERATE: usize = 1033;
/// Read PCI configuration space register
pub const SYS_PCI_CONFIG_READ: usize = 1034;
/// Write PCI configuration space register
pub const SYS_PCI_CONFIG_WRITE: usize = 1035;

// Port I/O Syscalls (1036-1037)
/// Write byte to I/O port
pub const SYS_OUTB: usize = 1036;
/// Read byte from I/O port
pub const SYS_INB: usize = 1037;

// Ring Buffer IPC Syscalls (1040-1049)
/// Create a new ring buffer for zero-copy IPC
pub const SYS_RING_CREATE: usize = 1040;
/// Attach to an existing ring as consumer
pub const SYS_RING_ATTACH: usize = 1041;
/// Detach from a ring (producer or consumer)
pub const SYS_RING_DETACH: usize = 1042;
/// Wait for entries to become available (consumer)
pub const SYS_RING_WAIT: usize = 1043;
/// Notify consumer that entries are available (producer)
pub const SYS_RING_NOTIFY: usize = 1044;
/// Wait for entries on any of multiple rings (MPSC consumer)
pub const SYS_RING_WAIT_ANY: usize = 1045;

// IOMMU-protected DMA syscalls (1046-1047)
/// Allocate IOMMU-protected DMA memory for a specific device
pub const SYS_ALLOC_IOMMU_DMA: usize = 1046;
/// Free IOMMU-protected DMA memory
pub const SYS_FREE_IOMMU_DMA: usize = 1047;

// Hypervisor Syscalls (1050-1059)
/// Execute VMware hypercall command (requires CAP_HYPERVISOR)
pub const SYS_VMWARE_HYPERCALL: usize = 1050;
/// Get hypervisor type (returns HypervisorType enum value)
pub const SYS_GET_HYPERVISOR: usize = 1051;

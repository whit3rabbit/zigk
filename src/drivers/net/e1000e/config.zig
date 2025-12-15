// E1000e Driver Configuration Constants
//
// Reference: Intel 82574L Gigabit Ethernet Controller Datasheet (316080)

const pmm = @import("pmm");

/// Number of RX descriptors (must be multiple of 8)
pub const RX_DESC_COUNT: usize = 512;

/// Number of TX descriptors (must be multiple of 8)
pub const TX_DESC_COUNT: usize = 512;

/// Size of each packet buffer
pub const BUFFER_SIZE: usize = 2048;

/// Pool size: 2x descriptor count for double-buffering headroom
pub const PACKET_POOL_SIZE: usize = 1024;

// Compile-time validation of configuration constants
// These ensure driver correctness at compile time rather than runtime
comptime {
    // Intel 82574L requires descriptor counts to be multiples of 8
    // Reference: Datasheet Section 3.2.6 and 3.3.6
    if (RX_DESC_COUNT % 8 != 0) {
        @compileError("RX_DESC_COUNT must be a multiple of 8");
    }
    if (TX_DESC_COUNT % 8 != 0) {
        @compileError("TX_DESC_COUNT must be a multiple of 8");
    }

    // Descriptor indices (rx_cur, tx_cur) are u16, so counts must fit
    if (RX_DESC_COUNT > 65535) {
        @compileError("RX_DESC_COUNT exceeds u16 range");
    }
    if (TX_DESC_COUNT > 65535) {
        @compileError("TX_DESC_COUNT exceeds u16 range");
    }

    // Buffer size must match RCTL.BSIZE setting (0 = 2048 bytes)
    // and not exceed page size for simple PMM allocation
    if (BUFFER_SIZE != 2048) {
        @compileError("BUFFER_SIZE must be 2048 to match RCTL.BSIZE=0");
    }

    // Buffer size must not exceed page size to ensure single-page allocation
    // in allocateRings() does not overflow. Hardware-provided packet length
    // is clamped to BUFFER_SIZE, so this bounds the trust boundary.
    if (BUFFER_SIZE > pmm.PAGE_SIZE) {
        @compileError("BUFFER_SIZE must not exceed PAGE_SIZE for single-page allocation");
    }
}

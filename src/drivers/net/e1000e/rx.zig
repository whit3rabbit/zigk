// E1000e RX Path Operations
//
// Receive packet processing with NAPI-style polling.

const hal = @import("hal");
const console = @import("console");

const regs = @import("regs.zig");
const desc = @import("desc.zig");
const config = @import("config.zig");
const pool = @import("pool.zig");
const types = @import("types.zig");

const mmio = hal.mmio;
const E1000e = types.E1000e;

/// Batch size for RDT updates (same as Linux E1000_RX_BUFFER_WRITE)
/// Updating RDT every N descriptors reduces register write overhead while
/// ensuring hardware doesn't starve during large batch processing.
pub const RX_BUFFER_WRITE: usize = 16;

/// Process received packets with a budget (NAPI-style polling)
///
/// Implements a receive path similar to Linux e1000_clean_rx_irq:
/// - Processes up to `limit` packets per call
/// - Updates RDT periodically to return descriptors to hardware
/// - Uses memory barriers to ensure descriptor visibility
/// - Uses pre-allocated packet pool to avoid heap allocation under spinlock
///
/// RDT (Receive Descriptor Tail) Semantics:
/// Per Intel 82574L Datasheet Section 3.2.6: "The tail pointer points to
/// one location beyond the last valid descriptor in the descriptor ring."
/// Hardware writes to descriptors from HEAD to TAIL-1 (inclusive).
/// Setting RDT = rx_cur means hardware can use all descriptors up to rx_cur-1.
///
/// Callback takes ownership of buffer and MUST free via packet_pool.release()
///
/// Returns number of packets processed
pub fn processRxLimited(driver: *E1000e, callback: *const fn ([]u8) void, limit: usize) usize {
    console.debug("E1000e: processRxLimited self={*} cb={*} limit={d}", .{ driver, callback, limit });

    var processed: usize = 0;
    var batch_count: usize = 0;

    while (processed < limit) {
        // Acquire buffer from packet pool OUTSIDE driver spinlock.
        // This avoids nested spinlock acquisition (pool has its own lock).
        const pkt_buf = pool.packet_pool.acquire() orelse {
            // Pool exhausted - backpressure signal, stop processing
            break;
        };

        const held = driver.lock.acquire();

        const rx_desc = &driver.rx_ring[driver.rx_cur];

        // Check if descriptor has a packet (DD = Descriptor Done)
        if ((rx_desc.status & desc.RxDesc.STATUS_DD) == 0) {
            held.release();
            pool.packet_pool.release(pkt_buf);
            break; // No more packets ready
        }

        // Memory barrier: ensure we see all hardware writes to descriptor
        // fields before reading length/data. Required because hardware and
        // software access the same memory without locks.
        mmio.readBarrier();

        // Check for receive errors
        if (rx_desc.errors != 0) {
            logRxErrors(driver, rx_desc.errors);
            // Fall through to reset descriptor
        } else if ((rx_desc.status & desc.RxDesc.STATUS_EOP) != 0) {
            // Valid complete packet received (EOP = End of Packet)
            // Clamp length to buffer size and validate minimum Ethernet frame size
            const raw_len: usize = @min(@as(usize, rx_desc.length), config.BUFFER_SIZE);

            // Minimum Ethernet frame: 14 bytes (6 dst + 6 src + 2 ethertype)
            // Packets smaller than this are malformed and should be dropped
            if (raw_len < 14) {
                driver.rx_dropped +%= 1;
            } else {
                const buf = driver.rx_buffers[driver.rx_cur];

                // Copy packet to pool buffer to avoid use-after-free.
                // The descriptor buffer will be reused immediately, so we must
                // copy before returning the descriptor to hardware.
                @memcpy(pkt_buf[0..raw_len], buf[0..raw_len]);

                driver.rx_packets +%= 1;
                driver.rx_bytes +%= raw_len;

                // Reset descriptor for hardware reuse before releasing lock
                rx_desc.status = 0;
                rx_desc.errors = 0;
                rx_desc.length = 0;

                // Advance to next descriptor (comptime validates RX_DESC_COUNT fits u16)
                driver.rx_cur = @intCast((@as(u32, driver.rx_cur) + 1) % config.RX_DESC_COUNT);
                processed += 1;
                batch_count += 1;

                // Periodic RDT update (like Linux E1000_RX_BUFFER_WRITE)
                if (batch_count >= RX_BUFFER_WRITE) {
                    updateRdt(driver);
                    batch_count = 0;
                }

                held.release();

                // Callback OUTSIDE spinlock - callback takes ownership of buffer
                // and MUST call packet_pool.release() when done
                callback(pkt_buf[0..raw_len]);
                continue;
            }
        }

        // Error path or non-EOP packet: reset descriptor and return buffer to pool
        rx_desc.status = 0;
        rx_desc.errors = 0;
        rx_desc.length = 0;

        driver.rx_cur = @intCast((@as(u32, driver.rx_cur) + 1) % config.RX_DESC_COUNT);
        processed += 1;
        batch_count += 1;

        if (batch_count >= RX_BUFFER_WRITE) {
            updateRdt(driver);
            batch_count = 0;
        }

        held.release();
        pool.packet_pool.release(pkt_buf);
    }

    // Final RDT update for any remaining processed descriptors
    if (batch_count > 0) {
        const held = driver.lock.acquire();
        updateRdt(driver);
        held.release();
    }

    return processed;
}

/// Process all received packets (legacy wrapper)
pub fn processRx(driver: *E1000e, callback: *const fn ([]u8) void) void {
    _ = processRxLimited(driver, callback, config.RX_DESC_COUNT);
}

/// Update RDT register to return processed descriptors to hardware
///
/// Per Intel 82574L Datasheet: RDT points one beyond the last valid
/// descriptor. Setting RDT = rx_cur makes descriptors from HEAD to
/// rx_cur-1 available for hardware to write to.
///
/// Note: If rx_cur == HEAD (software caught up completely), this results
/// in zero available descriptors momentarily. This is acceptable because:
/// 1. Hardware has internal packet buffering
/// 2. The next interrupt/poll will process new packets quickly
/// 3. This matches the Intel-specified behavior
pub fn updateRdt(driver: *E1000e) void {
    // Write barrier ensures all descriptor resets are visible to hardware
    // before we update the tail pointer. Without this, hardware might see
    // the new tail but stale descriptor contents.
    mmio.writeBarrier();

    // RDT = rx_cur per Intel spec: "one beyond the last valid descriptor"
    driver.regs.write(.rdt, driver.rx_cur);
}

/// Check if there are packets waiting
/// Thread safety: Acquires driver.lock briefly to read rx_cur atomically
/// with respect to processRxLimited() which modifies it.
pub fn hasPackets(driver: *E1000e) bool {
    // Acquire lock to prevent TOCTOU race with processRxLimited()
    // which modifies rx_cur. Without this, we could check the wrong
    // descriptor if rx_cur is updated between our read and the check.
    const held = driver.lock.acquire();
    const rx_desc = &driver.rx_ring[driver.rx_cur];
    const has_packet = (rx_desc.status & desc.RxDesc.STATUS_DD) != 0;
    held.release();

    if (has_packet) {
        // Ensure subsequent reads see hardware writes
        mmio.readBarrier();
    }
    return has_packet;
}

/// Set RX callback for packet processing
/// Thread-safe: uses atomic store to prevent torn pointer write if worker is reading
pub fn setRxCallback(driver: *E1000e, callback: *const fn ([]u8) void) void {
    @atomicStore(?*const fn ([]u8) void, &driver.rx_callback, callback, .release);
}

/// Log decoded RX errors and update statistics
pub fn logRxErrors(driver: *E1000e, errors: u8) void {
    // Update statistics
    driver.rx_errors +%= 1;
    if ((errors & desc.RXERR.CE) != 0) {
        driver.rx_crc_errors +%= 1;
    }

    var buf: [48]u8 = undefined;
    var len: usize = 0;

    if ((errors & desc.RXERR.CE) != 0) {
        @memcpy(buf[len..][0..4], "CRC ");
        len += 4;
    }
    if ((errors & desc.RXERR.SE) != 0) {
        @memcpy(buf[len..][0..4], "SYM ");
        len += 4;
    }
    if ((errors & desc.RXERR.SEQ) != 0) {
        @memcpy(buf[len..][0..4], "SEQ ");
        len += 4;
    }
    if ((errors & desc.RXERR.TCPE) != 0) {
        @memcpy(buf[len..][0..5], "TCPE ");
        len += 5;
    }
    if ((errors & desc.RXERR.IPE) != 0) {
        @memcpy(buf[len..][0..4], "IPE ");
        len += 4;
    }
    if ((errors & desc.RXERR.RXE) != 0) {
        @memcpy(buf[len..][0..5], "FIFO ");
        len += 5;
    }

    if (len > 0) {
        console.warn("E1000e: RX errors: {s}(0x{x:0>2})", .{ buf[0..len], errors });
    } else {
        console.warn("E1000e: RX error 0x{x:0>2}", .{errors});
    }
}

// E1000e TX Path Operations
//
// Transmit packet handling with watchdog.

const hal = @import("hal");
const console = @import("console");
const io = @import("io");

const regs = @import("regs.zig");
const desc = @import("desc.zig");
const ctl = @import("ctl.zig");
const config = @import("config.zig");
const types = @import("types.zig");
const init = @import("init.zig");

const mmio = hal.mmio;
const E1000e = types.E1000e;

/// TX watchdog threshold - number of consecutive stall checks before reset
pub const TX_WATCHDOG_THRESHOLD: u16 = 100;

/// Transmit a packet (similar to Linux e1000_xmit_frame)
///
/// Queues a packet for transmission by:
/// 1. Finding an available descriptor (DD=1 means hardware finished with it)
/// 2. Copying packet data to the descriptor's buffer
/// 3. Setting up descriptor fields (length, command, checksum offload)
/// 4. Advancing TDT to notify hardware
///
/// TX Ring Flow:
/// - Software writes to descriptor at tx_cur, advances TDT = tx_cur + 1
/// - Hardware reads from TDH, transmits, sets DD=1, advances TDH
/// - Ring is full when (TDT + 1) mod N == TDH
/// - Ring is empty when TDT == TDH
///
/// Returns true on success, false if TX ring is full or packet invalid
pub fn transmit(driver: *E1000e, data: []const u8) bool {
    // Validate packet size
    if (data.len > config.BUFFER_SIZE or data.len == 0) {
        return false;
    }

    const held = driver.lock.acquire();
    defer held.release();

    // Check if current descriptor is available (DD=1 means completed)
    //
    // Per Intel 82574L Datasheet Section 3.3.3:
    // The DD (Descriptor Done) bit is set by hardware AFTER the packet
    // has been transmitted and the descriptor buffer is no longer needed.
    // This is the authoritative signal that the descriptor can be reused.
    //
    // Note: We intentionally do NOT read TDH register here. Reading TDH
    // adds PCI latency and is unnecessary - the DD bit is the definitive
    // indicator per Intel spec. Linux e1000e driver also trusts DD alone.
    const tx_desc = &driver.tx_ring[driver.tx_cur];
    if ((tx_desc.status & desc.TxDesc.STATUS_DD) == 0) {
        // Hardware hasn't finished with this descriptor yet
        driver.tx_dropped += 1;
        return false;
    }

    // Memory barrier: ensure we see hardware's writes to status field
    // before we read or overwrite any descriptor fields
    mmio.readBarrier();

    // Parse packet for hardware checksum offloading
    // E1000e can insert TCP/UDP checksums if we provide CSS (start) and CSO (offset)
    var css: u8 = 0; // Checksum Start: byte offset where checksum calculation begins
    var cso: u8 = 0; // Checksum Offset: byte offset within L4 header for checksum field
    var cmd_extra: u8 = 0;

    // Attempt checksum offload for IPv4 + TCP/UDP packets
    // Minimum size: Ethernet (14) + IPv4 minimum (20) = 34 bytes
    if (data.len >= 34) {
        // Parse EtherType at offset 12-13 (big endian)
        const eth_type = (@as(u16, data[12]) << 8) | data[13];

        if (eth_type == 0x0800) { // IPv4
            // IPv4 header: version/IHL at offset 14, protocol at offset 23
            const ver_ihl = data[14];
            const ip_ver = ver_ihl >> 4;
            const ip_ihl = ver_ihl & 0x0F; // Header length in 32-bit words

            if (ip_ver == 4 and ip_ihl >= 5) {
                const ip_header_len = @as(usize, ip_ihl) * 4;
                const l4_offset = 14 + ip_header_len;
                const ip_proto = data[23];

                // Verify packet has enough data for L4 header
                if (l4_offset + 8 <= data.len) {
                    if (ip_proto == 6) { // TCP
                        // TCP checksum is at offset 16 within TCP header
                        // CSO is absolute offset from packet start per Intel spec
                        css = @intCast(l4_offset);
                        cso = @intCast(l4_offset + 16);
                        cmd_extra = desc.TxDesc.CMD_IC;
                    } else if (ip_proto == 17) { // UDP
                        // UDP checksum is at offset 6 within UDP header
                        // CSO is absolute offset from packet start per Intel spec
                        css = @intCast(l4_offset);
                        cso = @intCast(l4_offset + 6);
                        cmd_extra = desc.TxDesc.CMD_IC;
                    }
                }
            }
        }
    }

    // Copy packet data to descriptor's pre-allocated buffer
    const buf = driver.tx_buffers[driver.tx_cur];
    @memcpy(buf[0..data.len], data);

    // Configure descriptor for transmission
    // CMD_EOP: End of Packet (entire packet in one descriptor)
    // CMD_IFCS: Insert Frame Check Sequence (hardware appends CRC)
    // CMD_RS: Report Status (hardware will set DD when complete)
    // CMD_IC: Insert Checksum (if checksum offload is configured)
    tx_desc.* = desc.TxDesc{
        .buffer_addr = driver.tx_buffers_phys[driver.tx_cur],
        .length = @truncate(data.len),
        .cso = cso,
        .cmd = desc.TxDesc.CMD_EOP | desc.TxDesc.CMD_IFCS | desc.TxDesc.CMD_RS | cmd_extra,
        .status = 0, // Clear DD; hardware will set it after transmission
        .css = css,
        .special = 0,
    };

    // Advance software tail pointer
    driver.tx_cur = @truncate((@as(u32, driver.tx_cur) + 1) % config.TX_DESC_COUNT);

    // Write barrier ensures descriptor contents are visible to hardware
    // before we update TDT. Without this, hardware might see the new
    // tail but stale descriptor data.
    mmio.writeBarrier();

    // Notify hardware by writing TDT
    // Per Intel spec: TDT points one beyond the last valid descriptor
    // Setting TDT = tx_cur queues the descriptor we just wrote
    driver.regs.write(.tdt, driver.tx_cur);

    driver.tx_packets += 1;
    driver.tx_bytes += data.len;

    return true;
}

/// Check for TX ring stall and reset if stuck
/// Call periodically from timer tick or worker thread
pub fn checkTxWatchdog(driver: *E1000e) void {
    const tdh = driver.regs.read(.tdh);
    const tdt = driver.regs.read(.tdt);

    // If TDH == TDT, ring is empty - no stall possible
    if (tdh == tdt) {
        driver.tx_watchdog_stall_count = 0;
        return;
    }

    // If TDH hasn't moved and ring not empty, potential stall
    if (tdh == driver.tx_watchdog_last_tdh) {
        driver.tx_watchdog_stall_count += 1;
        if (driver.tx_watchdog_stall_count >= TX_WATCHDOG_THRESHOLD) {
            console.err("E1000e: TX watchdog triggered (TDH={d} TDT={d})", .{ tdh, tdt });
            resetTx(driver);
        }
    } else {
        driver.tx_watchdog_stall_count = 0;
    }
    driver.tx_watchdog_last_tdh = tdh;
}

/// Reset TX subsystem after watchdog timeout
pub fn resetTx(driver: *E1000e) void {
    console.warn("E1000e: Resetting TX subsystem", .{});

    // Disable transmitter
    var tctl = driver.readTctl();
    tctl.enable = false;
    driver.writeTctl(tctl);

    // Reset head and tail pointers
    driver.regs.write(.tdh, 0);
    driver.regs.write(.tdt, 0);
    driver.tx_cur = 0;

    // Mark all descriptors as done
    for (0..config.TX_DESC_COUNT) |i| {
        driver.tx_ring[i].status = desc.TxDesc.STATUS_DD;
    }

    // Re-enable transmitter
    tctl.enable = true;
    driver.writeTctl(tctl);

    // Reset watchdog state
    driver.tx_watchdog_stall_count = 0;
    driver.tx_watchdog_last_tdh = 0;

    console.info("E1000e: TX reset complete", .{});
}

// -----------------------------------------------------------------------------
// Async TX Interface
// -----------------------------------------------------------------------------

/// Async transmit error types
pub const AsyncTxError = error{
    InvalidPacket,
    RingFull,
    InvalidState,
};

/// Transmit a packet asynchronously with IoRequest completion
///
/// Unlike `transmit()` which returns immediately with success/failure,
/// this function queues an IoRequest that will be completed when the
/// hardware finishes transmitting the packet (DD bit set in descriptor).
///
/// Flow:
/// 1. Caller allocates IoRequest via io.allocRequest(.net_tx)
/// 2. This function queues packet and stores IoRequest in pending_tx_requests
/// 3. Hardware transmits and sets DD bit
/// 4. TX interrupt fires, IRQ handler completes pending IoRequests
/// 5. Caller's Future becomes ready with bytes_sent
///
/// @param driver E1000e driver instance
/// @param data Packet data (copied to descriptor buffer)
/// @param io_request IoRequest to complete on TX completion
/// @return error if packet invalid or ring full
pub fn transmitAsync(driver: *E1000e, data: []const u8, io_request: *io.IoRequest) AsyncTxError!void {
    // Validate packet size
    if (data.len > config.BUFFER_SIZE or data.len == 0) {
        io_request.complete(.{ .err = .EINVAL });
        return error.InvalidPacket;
    }

    const held = driver.lock.acquire();
    defer held.release();

    // Check if current descriptor is available (DD=1 means completed)
    const tx_desc = &driver.tx_ring[driver.tx_cur];
    if ((tx_desc.status & desc.TxDesc.STATUS_DD) == 0) {
        // Ring full - fail immediately rather than blocking
        driver.tx_dropped += 1;
        io_request.complete(.{ .err = .EAGAIN });
        return error.RingFull;
    }

    // Memory barrier: ensure we see hardware's writes before modifying
    mmio.readBarrier();

    // Store IoRequest for completion in IRQ handler
    // The IRQ handler will scan completed descriptors and complete these
    driver.pending_tx_requests[driver.tx_cur] = io_request;

    // Transition IoRequest to in_progress
    _ = io_request.compareAndSwapState(.pending, .in_progress);

    // Store packet length for completion handler
    io_request.op_data = .{
        .net_tx = .{
            .bytes_queued = @intCast(data.len),
            .descriptor_idx = driver.tx_cur,
        },
    };

    // Parse packet for hardware checksum offloading (same logic as sync transmit)
    var css: u8 = 0;
    var cso: u8 = 0;
    var cmd_extra: u8 = 0;

    if (data.len >= 34) {
        const eth_type = (@as(u16, data[12]) << 8) | data[13];
        if (eth_type == 0x0800) { // IPv4
            const ver_ihl = data[14];
            const ip_ver = ver_ihl >> 4;
            const ip_ihl = ver_ihl & 0x0F;
            if (ip_ver == 4 and ip_ihl >= 5) {
                const ip_header_len = @as(usize, ip_ihl) * 4;
                const l4_offset = 14 + ip_header_len;
                const ip_proto = data[23];
                if (l4_offset + 8 <= data.len) {
                    if (ip_proto == 6) { // TCP
                        css = @intCast(l4_offset);
                        cso = @intCast(l4_offset + 16);
                        cmd_extra = desc.TxDesc.CMD_IC;
                    } else if (ip_proto == 17) { // UDP
                        css = @intCast(l4_offset);
                        cso = @intCast(l4_offset + 6);
                        cmd_extra = desc.TxDesc.CMD_IC;
                    }
                }
            }
        }
    }

    // Copy packet data to descriptor's buffer
    const buf = driver.tx_buffers[driver.tx_cur];
    @memcpy(buf[0..data.len], data);

    // Configure descriptor for transmission
    tx_desc.* = desc.TxDesc{
        .buffer_addr = driver.tx_buffers_phys[driver.tx_cur],
        .length = @truncate(data.len),
        .cso = cso,
        .cmd = desc.TxDesc.CMD_EOP | desc.TxDesc.CMD_IFCS | desc.TxDesc.CMD_RS | cmd_extra,
        .status = 0, // Clear DD; hardware will set it after transmission
        .css = css,
        .special = 0,
    };

    // Advance software tail pointer
    driver.tx_cur = @truncate((@as(u32, driver.tx_cur) + 1) % config.TX_DESC_COUNT);

    // Write barrier ensures descriptor is visible before TDT update
    mmio.writeBarrier();

    // Notify hardware by writing TDT
    driver.regs.write(.tdt, driver.tx_cur);

    driver.tx_packets += 1;
    driver.tx_bytes += data.len;

    // IoRequest will be completed by processTxCompletions() in IRQ handler
}

/// Process completed TX descriptors and complete pending IoRequests
///
/// Called from IRQ handler when TXDW interrupt fires.
/// Scans from tx_completion_idx up to current TDH, completing any
/// pending IoRequests for descriptors with DD=1.
///
/// Thread safety: Must be called from IRQ context or with driver.lock held
pub fn processTxCompletions(driver: *E1000e) void {
    // Read hardware head pointer - this is where hardware has consumed up to
    const tdh = driver.regs.read(.tdh);
    const tdh16: u16 = @truncate(tdh);

    // Scan from last processed index up to hardware head
    // Note: We can't just iterate from tx_completion_idx to tdh because
    // the ring wraps around. We need to check DD bit on each descriptor.
    var completed: u32 = 0;
    var idx = driver.tx_completion_idx;

    // Limit iterations to prevent infinite loop (full ring = TX_DESC_COUNT - 1)
    var iterations: u32 = 0;
    const max_iterations = config.TX_DESC_COUNT;

    while (iterations < max_iterations) : (iterations += 1) {
        // Stop if we've caught up to software tail
        if (idx == driver.tx_cur) break;

        const tx_desc = &driver.tx_ring[idx];

        // Check DD bit - descriptor done if set
        if ((tx_desc.status & desc.TxDesc.STATUS_DD) == 0) {
            // Hardware hasn't finished this descriptor yet
            break;
        }

        // Complete pending IoRequest if any
        if (driver.pending_tx_requests[idx]) |io_req| {
            // Success: packet was transmitted
            const bytes_sent: usize = tx_desc.length;
            io_req.complete(.{ .ok = bytes_sent });
            driver.pending_tx_requests[idx] = null;
            completed += 1;
        }

        // Advance to next descriptor
        idx = @truncate((@as(u32, idx) + 1) % config.TX_DESC_COUNT);
    }

    driver.tx_completion_idx = idx;

    // Suppress unused variable warning for tdh16 (used for debugging)
    _ = tdh16;
}

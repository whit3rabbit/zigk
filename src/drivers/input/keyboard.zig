//! PS/2 Keyboard Driver
//!
//! Handles keyboard input via IRQ1 (PS/2 controller port 1).
//! Provides both raw scancodes (for games) and ASCII characters (for shell).
//!
//! Features:
//! - Dual ring buffers: `scancode_buffer` (raw) and `ascii_buffer` (translated).
//! - Rich `KeyEvent` type for advanced input handling.
//! - PS/2 Set 1 scancode support with layout translation (US QWERTY, Dvorak).
//! - Blocking reads with optional timeout.
//! - Proper interrupt/thread synchronization to prevent lost wakeups.

const hal = @import("hal");
const sync = @import("sync");
const ring_buffer = @import("ring_buffer");
const console = @import("console");
const uapi = @import("uapi");
const sched = @import("sched");
const thread_mod = @import("thread");
const io = @import("io");
const user_mem = @import("user_mem");

// Import extracted modules
const ps2 = @import("ps2");
const keyboard_event = @import("keyboard_event.zig");
const scancode_translator = @import("ps2/scancode_translator.zig");
const layout_mod = @import("layout.zig");
const us_layout = @import("layouts/us.zig");
const dvorak_layout = @import("layouts/dvorak.zig");

// Re-export public types
pub const StatusReg = ps2.StatusReg;
pub const KeyEvent = keyboard_event.KeyEvent;
pub const ErrorStats = keyboard_event.ErrorStats;

// =============================================================================
// Ring Buffer Types
// =============================================================================

/// Ring buffer sizes (must be power of 2)
const ASCII_BUFFER_SIZE: usize = 256;
const SCANCODE_BUFFER_SIZE: usize = 64;
const EVENT_BUFFER_SIZE: usize = 64;

/// ASCII character ring buffer type
pub const AsciiBuffer = ring_buffer.RingBuffer(u8, ASCII_BUFFER_SIZE);

/// Raw scancode ring buffer type
pub const ScancodeBuffer = ring_buffer.RingBuffer(u8, SCANCODE_BUFFER_SIZE);

/// KeyEvent ring buffer type
pub const EventBuffer = ring_buffer.RingBuffer(KeyEvent, EVENT_BUFFER_SIZE);

// =============================================================================
// Keyboard State
// =============================================================================

/// Keyboard state including buffers and modifier keys
pub const KeyboardState = struct {
    /// Buffer for ASCII characters (shell reads from here)
    ascii_buffer: AsciiBuffer = .{},

    /// Buffer for raw scancodes (games read from here)
    scancode_buffer: ScancodeBuffer = .{},

    /// Buffer for rich key events (advanced applications)
    event_buffer: EventBuffer = .{},

    /// Scancode translator (handles modifier state and ASCII translation)
    translator: scancode_translator.ScancodeTranslator,

    /// Thread blocked waiting for keyboard input (for blocking reads)
    blocked_thread: ?*thread_mod.Thread = null,

    /// Pending async read request (Phase 2 async I/O)
    /// Type-erased to avoid cyclic dependency; cast to *io.IoRequest when used
    pending_read: ?*anyopaque = null,

    comptime {
        // Warn if struct exceeds reasonable size (not a hard error)
        if (@sizeOf(@This()) > 2048) {
            @compileLog("KeyboardState size: ", @sizeOf(@This()), " bytes");
        }
    }

    pub fn init() KeyboardState {
        return .{
            .translator = scancode_translator.ScancodeTranslator.init(&us_layout.layout_def),
        };
    }
};

// Global keyboard state (protected by keyboard_lock)
var keyboard_state: KeyboardState = KeyboardState.init();
var keyboard_lock: sync.Spinlock = .{};
var keyboard_initialized: bool = false;
var error_stats: ErrorStats = .{};
/// Public IRQ counter for diagnostics
pub var irq_count: u32 = 0;

// =============================================================================
// Public API
// =============================================================================

/// Inject a scancode from an external source (e.g., USB HID driver)
pub fn injectScancode(scancode: u8) void {
    // Check initialization - translator needs valid layout
    if (!keyboard_initialized) {
        console.warn("KB: injectScancode(0x{x}) called before init!", .{scancode});
        return;
    }
    const flags = hal.cpu.disableInterruptsSaveFlags();
    const held = keyboard_lock.acquire();

    // Store raw scancode in buffer (mimic behavior of handleIrq)
    if (keyboard_state.scancode_buffer.push(scancode)) {
        error_stats.buffer_overruns +%= 1;
    }

    processScancode(scancode);

    // Wake up blocked threads if needed
    if (keyboard_state.blocked_thread) |blocked| {
        if (!keyboard_state.ascii_buffer.isEmpty()) {
            keyboard_state.blocked_thread = null;
            held.release();
            hal.cpu.restoreInterrupts(flags);
            sched.unblock(blocked);
            return;
        }
    }

    held.release();
    hal.cpu.restoreInterrupts(flags);
}

/// Initialize keyboard state for USB HID keyboards (no PS/2 controller setup)
/// Call this when a USB keyboard is detected to enable scancode injection.
pub fn initForUsb() void {
    if (keyboard_initialized) {
        return;
    }

    console.info("Keyboard: initializing for USB HID", .{});

    // Reset keyboard state (initializes translator with US layout)
    keyboard_state = KeyboardState.init();
    error_stats = .{};

    keyboard_initialized = true;
    console.info("Keyboard: USB HID ready", .{});
}

/// Initialize the keyboard driver with proper PS/2 controller setup
pub fn init() void {
    if (keyboard_initialized) {
        return;
    }

    console.info("PS/2 keyboard: initializing controller", .{});

    // 1. Disable devices during setup
    ps2.sendCommand(ps2.CMD_DISABLE_FIRST_PORT);
    ps2.sendCommand(ps2.CMD_DISABLE_SECOND_PORT);

    // 2. Flush output buffer (discard stale data from BIOS/firmware)
    ps2.flushBuffer();

    // 3. Read config, disable IRQs temporarily
    ps2.sendCommand(ps2.CMD_READ_CONFIG);
    var config = ps2.readData() orelse 0x00;
    config &= ~ps2.CONFIG_FIRST_PORT_IRQ;
    config &= ~ps2.CONFIG_SECOND_PORT_IRQ;

    ps2.sendCommand(ps2.CMD_WRITE_CONFIG);
    ps2.sendData(config);

    // 4. Self-test (0xAA -> expect 0x55)
    ps2.sendCommand(ps2.CMD_SELF_TEST);
    const self_test_result = ps2.readData();
    if (self_test_result) |result| {
        if (result != ps2.SELF_TEST_PASSED) {
            console.warn("PS/2 self-test returned 0x{X:0>2}, expected 0x55", .{result});
        }
    } else {
        console.warn("PS/2 self-test timeout (no response)", .{});
    }

    // 5. Test first port (0xAB -> expect 0x00)
    ps2.sendCommand(ps2.CMD_TEST_FIRST_PORT);
    const port_test_result = ps2.readData();
    if (port_test_result) |result| {
        if (result != ps2.PORT_TEST_PASSED) {
            console.warn("PS/2 port test returned 0x{X:0>2}, expected 0x00", .{result});
        }
    } else {
        console.warn("PS/2 port test timeout (no response)", .{});
    }

    // 6. Enable first port
    ps2.sendCommand(ps2.CMD_ENABLE_FIRST_PORT);

    // 7. Enable IRQ and translation for first port
    ps2.sendCommand(ps2.CMD_READ_CONFIG);
    config = ps2.readData() orelse 0x00;
    config |= ps2.CONFIG_FIRST_PORT_IRQ;
    config |= ps2.CONFIG_TRANSLATION; // Enable Set 1 translation

    ps2.sendCommand(ps2.CMD_WRITE_CONFIG);
    ps2.sendData(config);

    // 8. Enable Keyboard Scanning
    ps2.sendData(ps2.KBD_CMD_ENABLE);
    const ack = ps2.readData();
    if (ack) |a| {
        if (a != ps2.KBD_ACK) {
            console.warn("PS/2 keyboard: enable failed, got 0x{X:0>2}", .{a});
        }
    } else {
        console.warn("PS/2 keyboard: enable timeout", .{});
    }

    // 9. Flush any stale data again
    ps2.flushBuffer();

    // 10. Reset keyboard state
    keyboard_state = KeyboardState.init();
    error_stats = .{};

    keyboard_initialized = true;
    console.info("PS/2 keyboard: initialized", .{});

    // Verify final PS/2 configuration for diagnostics
    ps2.sendCommand(ps2.CMD_READ_CONFIG);
    const final_config = ps2.readData() orelse 0xFF;
    console.info("PS/2 config: 0x{X:0>2} (IRQ1_EN={}, XLAT={})", .{
        final_config,
        (final_config & ps2.CONFIG_FIRST_PORT_IRQ) != 0,
        (final_config & ps2.CONFIG_TRANSLATION) != 0,
    });
}

/// Handle keyboard IRQ (called from interrupt handler)
/// Reads scancode from port and populates all buffers
pub fn handleIrq() void {
    // Count all IRQs for diagnostics (even before init check)
    irq_count +%= 1;
    if (irq_count == 1 or irq_count % 100 == 0) {
        console.info("KBD IRQ #{d}", .{irq_count});
    }

    if (!keyboard_initialized) {
        // Just read and discard to acknowledge
        _ = hal.io.inb(ps2.DATA_PORT);
        return;
    }

    // Check status register before reading data (prevents spurious reads)
    const status = ps2.StatusReg.read();

    if (!status.hasData()) {
        // No data ready - spurious interrupt
        if (error_stats.spurious_irqs % 100 == 0) {
            console.debug("KBD: Spurious IRQ (Status=0x{X:0>2})", .{@as(u8, @bitCast(status))});
        }
        error_stats.spurious_irqs +%= 1;
        return;
    }

    // Skip mouse data - let mouse IRQ handler deal with it
    if (status.isMouseData()) {
        console.debug("KBD: Mouse data ignored (Status=0x{X:0>2})", .{@as(u8, @bitCast(status))});
        return;
    }

    // Check for transmission errors
    if (status.hasError()) {
        console.warn("KBD: Error (Status=0x{X:0>2})", .{@as(u8, @bitCast(status))});
        if (status.parity_error) error_stats.parity_errors +%= 1;
        if (status.timeout_error) error_stats.timeout_errors +%= 1;
        // Read and discard bad data
        _ = hal.io.inb(ps2.DATA_PORT);
        return;
    }

    // Read scancode from keyboard data port
    const scancode = hal.io.inb(ps2.DATA_PORT);
    console.debug("KBD: Scancode 0x{X:0>2}", .{scancode});

    // Acquire lock to protect buffer access
    const held = keyboard_lock.acquire();

    // Always store raw scancode for games (FR-030a)
    // Track buffer overruns for debugging
    if (keyboard_state.scancode_buffer.push(scancode)) {
        error_stats.buffer_overruns +%= 1;
    }

    // Process scancode for ASCII translation and event generation
    processScancode(scancode);

    // Complete pending async read request if one exists (Phase 2)
    // Takes priority over blocking thread since async is explicit
    if (keyboard_state.pending_read) |pending_ptr| {
        if (!keyboard_state.ascii_buffer.isEmpty()) {
            const request: *io.IoRequest = @ptrCast(@alignCast(pending_ptr));
            keyboard_state.pending_read = null;

            // Pop character and copy to user buffer
            if (keyboard_state.ascii_buffer.pop()) |c| {
                // If request has a buffer, copy character there
                if (request.buf_ptr != 0 and request.buf_len > 0) {
                    // Security: Use SMAP-compliant UserPtr for safe kernel->user copy
                    // This prevents TOCTOU races where the page could be unmapped
                    // between validation and access
                    const uptr = user_mem.UserPtr.from(request.buf_ptr);
                    if (uptr.copyFromKernel(&[_]u8{c})) |_| {
                        _ = request.complete(.{ .success = 1 });
                    } else |_| {
                        _ = request.complete(.{ .err = error.EFAULT });
                    }
                } else {
                    // No buffer - return character as result value
                    _ = request.complete(.{ .success = @as(usize, c) });
                }
            }

            held.release();
            return;
        }
    }

    // Wake any thread blocked waiting for input
    // Only wake if we added a printable character (ascii_buffer not empty)
    if (keyboard_state.blocked_thread) |blocked| {
        if (!keyboard_state.ascii_buffer.isEmpty()) {
            keyboard_state.blocked_thread = null;
            held.release();
            // Unblock outside the lock to avoid deadlock with scheduler
            sched.unblock(blocked);
            return;
        }
    }

    held.release();
}

/// Process a scancode and update keyboard state
/// Translates to ASCII when appropriate and stores in buffers
fn processScancode(scancode: u8) void {
    // Use the translator to handle the scancode
    if (keyboard_state.translator.translate(scancode)) |result| {
        // Store the event
        _ = keyboard_state.event_buffer.push(result.event);

        // Store ASCII if available
        if (result.ascii) |ascii| {
            _ = keyboard_state.ascii_buffer.push(ascii);
        }

        // Handle console scrolling for Page Up/Down
        if (result.scroll) |scroll| {
            console.scroll(scroll.lines, scroll.up);
        }
    }
}

/// Get an ASCII character from the input buffer (non-blocking)
/// Returns null if buffer is empty
/// Syscall: SYS_GETCHAR (1004) - but blocking version would loop on this
pub fn getChar() ?u8 {
    const flags = hal.cpu.disableInterruptsSaveFlags();
    const held = keyboard_lock.acquire();
    defer {
        held.release();
        hal.cpu.restoreInterrupts(flags);
    }

    return keyboard_state.ascii_buffer.pop();
}

/// Get an ASCII character from the input buffer (blocking with optional timeout)
/// Returns null on timeout, character otherwise.
///
/// timeout_ticks: Number of scheduler ticks to wait, or null for infinite.
///
/// NOTE: Uses proper interrupt/lock ordering to prevent race conditions.
/// The lock is released before blocking, but interrupts remain disabled
/// until sched.block() atomically re-enables them.
pub fn getCharBlockingTimeout(timeout_ticks: ?u64) ?u8 {
    const start_tick = if (timeout_ticks != null) sched.getTickCount() else 0;

    while (true) {
        // Fast path: try non-blocking read
        if (getChar()) |c| {
            return c;
        }

        // Check timeout before blocking
        if (timeout_ticks) |max| {
            if (sched.getTickCount() -% start_tick >= max) {
                return null;
            }
        }

        // Need to block - must be atomic with checking buffer
        // Disable interrupts to prevent IRQ between check and block
        const saved_flags = hal.cpu.disableInterruptsSaveFlags();

        {
            const held = keyboard_lock.acquire();
            defer held.release();

            // Double-check after acquiring lock (TOCTOU prevention)
            if (keyboard_state.ascii_buffer.pop()) |c| {
                hal.cpu.restoreInterrupts(saved_flags);
                return c;
            }

            // No character - register ourselves as blocked
            if (sched.getCurrentThread()) |curr| {
                keyboard_state.blocked_thread = curr;
            }
        }
        // Lock released here, interrupts still disabled

        // Block the thread - this atomically enables interrupts and halts
        // The keyboard IRQ will wake us when a character arrives
        sched.block();
        // When we wake up, loop to check buffer again (handles spurious wakeups)
    }
}

/// Get an ASCII character from the input buffer (blocking, infinite timeout)
/// Blocks the calling thread until a character is available.
/// Returns the character when available.
pub fn getCharBlocking() u8 {
    // Infinite timeout - will always return a character
    return getCharBlockingTimeout(null).?;
}

/// Queue an async read request for keyboard input (Phase 2 async I/O)
///
/// If a character is immediately available, completes the request synchronously.
/// Otherwise, queues the request to be completed when the next keypress arrives.
///
/// Returns:
///   - true if request was queued (will complete later via IRQ)
///   - false if completed immediately (check request.result)
///
/// The request.buf_ptr/buf_len can optionally specify a user buffer.
/// If provided, the character will be copied there. Otherwise,
/// the character value is returned in request.result.success.
pub fn getCharAsync(request: *io.IoRequest) bool {
    const flags = hal.cpu.disableInterruptsSaveFlags();
    const held = keyboard_lock.acquire();

    // Check if a character is immediately available
    if (keyboard_state.ascii_buffer.pop()) |c| {
        // Complete immediately
        if (request.buf_ptr != 0 and request.buf_len > 0) {
            // Security: Use SMAP-compliant UserPtr for safe kernel->user copy
            // This prevents TOCTOU races where the page could be unmapped
            // between validation and access
            const uptr = user_mem.UserPtr.from(request.buf_ptr);
            if (uptr.copyFromKernel(&[_]u8{c})) |_| {
                _ = request.complete(.{ .success = 1 });
            } else |_| {
                _ = request.complete(.{ .err = error.EFAULT });
            }
        } else {
            _ = request.complete(.{ .success = @as(usize, c) });
        }
        held.release();
        hal.cpu.restoreInterrupts(flags);
        return false; // Completed immediately
    }

    // No character available - queue the request
    // Security: Check pending_read BEFORE changing request state to avoid TOCTOU
    // where state transitions to .pending but request is rejected, leaving
    // the request in an inconsistent state.
    if (keyboard_state.pending_read != null) {
        _ = request.complete(.{ .err = error.EBUSY });
        held.release();
        return false;
    }

    // Now safe to transition from idle to pending
    if (!request.compareAndSwapState(.idle, .pending)) {
        // Request not in idle state - fail
        _ = request.complete(.{ .err = error.EINVAL });
        held.release();
        hal.cpu.restoreInterrupts(flags);
        return false;
    }

    keyboard_state.pending_read = request;
    // Request is now owned by IRQ handler

    held.release();
    hal.cpu.restoreInterrupts(flags);
    return true; // Queued for later completion
}

/// Cancel a pending async keyboard read request
/// Returns true if the request was cancelled, false if not found or already complete
pub fn cancelPendingRead(request: *io.IoRequest) bool {
    const held = keyboard_lock.acquire();
    defer held.release();

    if (keyboard_state.pending_read) |pending_ptr| {
        const pending: *io.IoRequest = @ptrCast(@alignCast(pending_ptr));
        if (pending == request) {
            keyboard_state.pending_read = null;
            return request.cancel();
        }
    }
    return false;
}

/// Get a KeyEvent from the event buffer (non-blocking)
/// Returns null if buffer is empty
pub fn getEvent() ?KeyEvent {
    const held = keyboard_lock.acquire();
    defer held.release();

    return keyboard_state.event_buffer.pop();
}

/// Get a raw scancode from the buffer (non-blocking)
/// Returns null if buffer is empty
/// Syscall: SYS_READ_SCANCODE (1003)
pub fn getScancode() ?u8 {
    const held = keyboard_lock.acquire();
    defer held.release();

    return keyboard_state.scancode_buffer.pop();
}

/// Check if there are characters available
pub fn hasChar() bool {
    const held = keyboard_lock.acquire();
    defer held.release();

    return !keyboard_state.ascii_buffer.isEmpty();
}

/// Check if there are scancodes available
pub fn hasScancode() bool {
    const held = keyboard_lock.acquire();
    defer held.release();

    return !keyboard_state.scancode_buffer.isEmpty();
}

/// Check if there are events available
pub fn hasEvent() bool {
    const held = keyboard_lock.acquire();
    defer held.release();

    return !keyboard_state.event_buffer.isEmpty();
}

/// Get current modifier key states
pub fn getModifiers() struct { shift: bool, ctrl: bool, alt: bool, caps: bool } {
    const held = keyboard_lock.acquire();
    defer held.release();

    return keyboard_state.translator.getModifiers();
}

/// Get error statistics (for debugging)
pub fn getErrorStats() ErrorStats {
    return error_stats;
}

// =============================================================================
// Layout Management
// =============================================================================

/// Set the current keyboard layout
pub fn setLayout(new_layout: *const layout_mod.Layout) void {
    const held = keyboard_lock.acquire();
    defer held.release();
    keyboard_state.translator.setLayout(new_layout);
    console.info("Keyboard: Switched layout to {s}", .{new_layout.name});
}

/// Get the current layout name
pub fn getLayoutName() []const u8 {
    return keyboard_state.translator.layout.name;
}

// Available built-in layouts
pub const layouts = struct {
    pub const us = &us_layout.layout_def;
    pub const dvorak = &dvorak_layout.layout_def;
};

// =============================================================================
// Unit Tests
// =============================================================================

test "StatusReg packed struct size" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(StatusReg));
}

test "KeyEvent toAscii" {
    const std = @import("std");

    const char_event = KeyEvent{ .char = 'x' };
    try std.testing.expectEqual(@as(?u8, 'x'), char_event.toAscii());

    const ctrl_event = KeyEvent{ .control = .escape };
    try std.testing.expectEqual(@as(?u8, 0x1B), ctrl_event.toAscii());

    const nav_event = KeyEvent{ .navigation = .up };
    try std.testing.expectEqual(@as(?u8, 0x80), nav_event.toAscii());

    const func_event = KeyEvent{ .function = .f1 };
    try std.testing.expectEqual(@as(?u8, null), func_event.toAscii());
}

test "layout switching" {
    const std = @import("std");

    // Reset state for test
    keyboard_state = KeyboardState.init();

    // Test default US layout
    try std.testing.expectEqual(@as(u8, 'a'), keyboard_state.translator.layout.unshifted[0x1E]);

    // Switch to Dvorak
    keyboard_state.translator.setLayout(layouts.dvorak);
    // In Dvorak, scancode 0x1E ('a' position) is still 'a'.
    try std.testing.expectEqual(@as(u8, 'a'), keyboard_state.translator.layout.unshifted[0x1E]);

    // Test 's' key (0x1F): US='s', Dvorak='o'
    try std.testing.expectEqual(@as(u8, 'o'), keyboard_state.translator.layout.unshifted[0x1F]);

    // Switch back
    keyboard_state.translator.setLayout(layouts.us);
    try std.testing.expectEqual(@as(u8, 's'), keyboard_state.translator.layout.unshifted[0x1F]);
}

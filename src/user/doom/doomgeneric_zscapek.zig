// Doomgeneric Platform Implementation for Zscapek
//
// Implements the platform hooks required by doomgeneric:
// - DG_Init(): Initialize framebuffer
// - DG_DrawFrame(): Blit screen buffer to framebuffer
// - DG_GetKey(): Read keyboard input
// - DG_SleepMs(): Sleep for milliseconds
// - DG_GetTicksMs(): Get monotonic time
// - DG_SetWindowTitle(): No-op for framebuffer

const syscall = @import("syscall");

// Doom screen dimensions
pub const DOOMGENERIC_RESX: u32 = 640;
pub const DOOMGENERIC_RESY: u32 = 400;

// Platform state
var fb_ptr: ?[*]u8 = null;
var fb_info: syscall.FramebufferInfo = undefined;
var fb_initialized: bool = false;

// Key queue for buffered input
const KEY_QUEUE_SIZE = 64;
var key_queue: [KEY_QUEUE_SIZE]KeyEvent = undefined;
var key_queue_head: usize = 0;
var key_queue_tail: usize = 0;

// Extended scancode state (0xE0 prefix)
var extended_scancode: bool = false;

const KeyEvent = struct {
    pressed: c_int, // 1 = pressed, 0 = released
    key: c_int, // Doom key code
};

// Doom key codes (from doomkeys.h)
const KEY_RIGHTARROW = 0xae;
const KEY_LEFTARROW = 0xac;
const KEY_UPARROW = 0xad;
const KEY_DOWNARROW = 0xaf;
const KEY_ESCAPE = 27;
const KEY_ENTER = 13;
const KEY_TAB = 9;
const KEY_BACKSPACE = 127;
const KEY_RSHIFT = 0x80 + 0x36;
const KEY_RCTRL = 0x80 + 0x1d;
const KEY_RALT = 0x80 + 0x38;
const KEY_F1 = 0x80 + 0x3b;
const KEY_F2 = 0x80 + 0x3c;
const KEY_F3 = 0x80 + 0x3d;
const KEY_F4 = 0x80 + 0x3e;
const KEY_F5 = 0x80 + 0x3f;
const KEY_F6 = 0x80 + 0x40;
const KEY_F7 = 0x80 + 0x41;
const KEY_F8 = 0x80 + 0x42;
const KEY_F9 = 0x80 + 0x43;
const KEY_F10 = 0x80 + 0x44;
const KEY_F11 = 0x80 + 0x57;
const KEY_F12 = 0x80 + 0x58;
const KEY_PAUSE = 0xff;

// Doom event structures (from d_event.h)
const evtype_t = enum(c_int) {
    ev_keydown,
    ev_keyup,
    ev_mouse,
    ev_joystick,
    ev_quit,
};

const event_t = extern struct {
    type: evtype_t,
    data1: c_int,
    data2: c_int,
    data3: c_int,
    data4: c_int,
};

extern fn D_PostEvent(ev: *const event_t) void;

// Doomgeneric provides this buffer (640x400 ARGB pixels)
extern var DG_ScreenBuffer: [*]u32;

/// Initialize the platform
pub export fn DG_Init() void {
    // Get framebuffer info
    syscall.get_framebuffer_info(&fb_info) catch {
        return;
    };

    // Map framebuffer
    fb_ptr = syscall.map_framebuffer() catch {
        return;
    };

    // Set cursor bounds
    syscall.set_cursor_bounds(fb_info.width, fb_info.height) catch {};

    fb_initialized = true;
}

/// Draw the current frame to the framebuffer
pub export fn DG_DrawFrame() void {
    if (!fb_initialized or fb_ptr == null) return;

    const fb = fb_ptr.?;
    const screen = DG_ScreenBuffer;

    // Calculate centering offset if framebuffer is larger than Doom screen
    const x_offset: u32 = if (fb_info.width > DOOMGENERIC_RESX)
        (fb_info.width - DOOMGENERIC_RESX) / 2
    else
        0;
    const y_offset: u32 = if (fb_info.height > DOOMGENERIC_RESY)
        (fb_info.height - DOOMGENERIC_RESY) / 2
    else
        0;

    // Bytes per pixel in framebuffer
    const fb_bpp = fb_info.bpp / 8;

    var y: u32 = 0;
    while (y < DOOMGENERIC_RESY and y + y_offset < fb_info.height) : (y += 1) {
        var x: u32 = 0;
        while (x < DOOMGENERIC_RESX and x + x_offset < fb_info.width) : (x += 1) {
            // Get source pixel (0x00RRGGBB format from Doom)
            const src_idx = y * DOOMGENERIC_RESX + x;
            const pixel = screen[src_idx];

            // Extract RGB components
            const r: u8 = @truncate((pixel >> 16) & 0xFF);
            const g: u8 = @truncate((pixel >> 8) & 0xFF);
            const b: u8 = @truncate(pixel & 0xFF);

            // Convert to framebuffer format using shift values
            var dest_pixel: u32 = 0;
            dest_pixel |= @as(u32, r) << @intCast(fb_info.red_shift);
            dest_pixel |= @as(u32, g) << @intCast(fb_info.green_shift);
            dest_pixel |= @as(u32, b) << @intCast(fb_info.blue_shift);

            // Calculate destination offset
            const dest_offset = (y + y_offset) * fb_info.pitch + (x + x_offset) * fb_bpp;

            // Write pixel to framebuffer
            if (fb_bpp == 4) {
                const dest: *u32 = @ptrCast(@alignCast(fb + dest_offset));
                dest.* = dest_pixel;
            } else if (fb_bpp == 3) {
                fb[dest_offset] = @truncate(dest_pixel);
                fb[dest_offset + 1] = @truncate(dest_pixel >> 8);
                fb[dest_offset + 2] = @truncate(dest_pixel >> 16);
            }
        }
    }

    // Flush to screen (required for VirtIO-GPU)
    syscall.flush_framebuffer() catch {};
}

/// Sleep for specified milliseconds
pub export fn DG_SleepMs(ms: u32) void {
    const sec: i64 = @intCast(ms / 1000);
    const nsec: i64 = @intCast((ms % 1000) * 1_000_000);
    const req = syscall.Timespec{
        .tv_sec = sec,
        .tv_nsec = nsec,
    };
    syscall.nanosleep(&req, null) catch {};
}

/// Get monotonic time in milliseconds
pub export fn DG_GetTicksMs() u32 {
    var ts: syscall.Timespec = undefined;
    syscall.clock_gettime(.MONOTONIC, &ts) catch return 0;
    const ms: u64 = @as(u64, @intCast(ts.tv_sec)) * 1000 +
        @as(u64, @intCast(ts.tv_nsec)) / 1_000_000;
    return @truncate(ms);
}

// Mouse state
var mouse_x_accum: i32 = 0;
var mouse_y_accum: i32 = 0;
var mouse_buttons: i32 = 0;
var mouse_buttons_prev: i32 = 0;

/// Get keyboard input
/// Returns 1 if a key event is available, 0 otherwise
pub export fn DG_GetKey(pressed: *c_int, doom_key: *u8) c_int {
    // Poll for mouse input events
    pollInputEvents();

    // Check if we need to post a mouse event
    // We only post if there was movement or button change
    if (mouse_x_accum != 0 or mouse_y_accum != 0 or mouse_buttons != mouse_buttons_prev) {
        // Doom expects Y to be inverted (Forward is +Y in game)
        // Previous i_input.c logic had event.data3 = -y * 8;
        // We replicate that here.
        const ev = event_t{
            .type = .ev_mouse,
            .data1 = @intCast(mouse_buttons),
            .data2 = @intCast(mouse_x_accum * 8), // Scale sensitivity
            .data3 = @intCast(-mouse_y_accum * 8), // Negate Y
            .data4 = 0,
        };
        D_PostEvent(&ev);

        mouse_x_accum = 0;
        mouse_y_accum = 0;
        mouse_buttons_prev = mouse_buttons;
    }

    // Poll for keyboard scancodes
    pollScancodes();

    // Then return queued events
    if (key_queue_head != key_queue_tail) {
        const event = key_queue[key_queue_tail];
        key_queue_tail = (key_queue_tail + 1) % KEY_QUEUE_SIZE;
        pressed.* = event.pressed;
        doom_key.* = @truncate(@as(c_uint, @bitCast(event.key)));
        return 1;
    }

    return 0;
}

/// Set window title (no-op for framebuffer)
pub export fn DG_SetWindowTitle(title: [*:0]const u8) void {
    _ = title;
}

fn pollInputEvents() void {
    var event: syscall.uapi.input.InputEvent = .{
        .timestamp_ns = 0,
        .event_type = .EV_SYN,
        .code = 0,
        .value = 0,
    };
    while (true) {
        syscall.read_input_event(&event) catch |err| {
            if (err == error.WouldBlock) break;
            break;
        };
        
        processInputEvent(event);
    }
}

fn processInputEvent(event: syscall.uapi.input.InputEvent) void {
    const uapi = syscall.uapi;
    const input = uapi.input;

    switch (event.event_type) {
        input.EventType.EV_REL => {
            switch (event.code) {
                input.RelCode.X => mouse_x_accum += event.value,
                input.RelCode.Y => mouse_y_accum += event.value,
                else => {},
            }
        },
        input.EventType.EV_KEY => {
            const pressed: c_int = if (event.value != 0) 1 else 0;
             switch (event.code) {
                 input.BtnCode.LEFT => {
                     if (pressed != 0) mouse_buttons |= 1 else mouse_buttons &= ~@as(i32, 1);
                 },
                 input.BtnCode.RIGHT => {
                     if (pressed != 0) mouse_buttons |= 2 else mouse_buttons &= ~@as(i32, 2);
                 },
                 input.BtnCode.MIDDLE => {
                     if (pressed != 0) mouse_buttons |= 4 else mouse_buttons &= ~@as(i32, 4);
                 },
                 else => {
                     // Ignore keyboard events here (handled by pollScancodes via keyboard driver)
                 }, 
            }
        },
        else => {},
    }
}

// Poll for scancodes and convert to key events
fn pollScancodes() void {
    while (true) {
        const scancode = syscall.read_scancode() catch |err| {
            if (err == error.WouldBlock) break;
            break;
        };

        processScancode(scancode);
    }
}

// Process a single PS/2 Set 1 scancode
fn processScancode(scancode: u8) void {
    // Handle extended scancode prefix
    if (scancode == 0xE0) {
        extended_scancode = true;
        return;
    }

    // Extract press/release (bit 7)
    const released = (scancode & 0x80) != 0;
    const code = scancode & 0x7F;

    // Map to Doom key
    const doom_key = if (extended_scancode)
        mapExtendedScancode(code)
    else
        mapScancode(code);

    extended_scancode = false;

    if (doom_key != 0) {
        queueKeyEvent(if (released) 0 else 1, doom_key);
    }
}

// Queue a key event
fn queueKeyEvent(pressed: c_int, key: c_int) void {
    const next_head = (key_queue_head + 1) % KEY_QUEUE_SIZE;
    if (next_head == key_queue_tail) return; // Queue full

    key_queue[key_queue_head] = .{
        .pressed = pressed,
        .key = key,
    };
    key_queue_head = next_head;
}

// Map PS/2 Set 1 scancode to Doom key
fn mapScancode(code: u8) c_int {
    return switch (code) {
        0x01 => KEY_ESCAPE,
        0x0E => KEY_BACKSPACE,
        0x0F => KEY_TAB,
        0x1C => KEY_ENTER,
        0x1D => KEY_RCTRL,
        0x2A, 0x36 => KEY_RSHIFT,
        0x38 => KEY_RALT,
        0x39 => ' ', // Space
        0x3B => KEY_F1,
        0x3C => KEY_F2,
        0x3D => KEY_F3,
        0x3E => KEY_F4,
        0x3F => KEY_F5,
        0x40 => KEY_F6,
        0x41 => KEY_F7,
        0x42 => KEY_F8,
        0x43 => KEY_F9,
        0x44 => KEY_F10,
        0x57 => KEY_F11,
        0x58 => KEY_F12,
        // Letter keys (QWERTY layout)
        0x10 => 'q',
        0x11 => 'w',
        0x12 => 'e',
        0x13 => 'r',
        0x14 => 't',
        0x15 => 'y',
        0x16 => 'u',
        0x17 => 'i',
        0x18 => 'o',
        0x19 => 'p',
        0x1E => 'a',
        0x1F => 's',
        0x20 => 'd',
        0x21 => 'f',
        0x22 => 'g',
        0x23 => 'h',
        0x24 => 'j',
        0x25 => 'k',
        0x26 => 'l',
        0x2C => 'z',
        0x2D => 'x',
        0x2E => 'c',
        0x2F => 'v',
        0x30 => 'b',
        0x31 => 'n',
        0x32 => 'm',
        // Number keys
        0x02 => '1',
        0x03 => '2',
        0x04 => '3',
        0x05 => '4',
        0x06 => '5',
        0x07 => '6',
        0x08 => '7',
        0x09 => '8',
        0x0A => '9',
        0x0B => '0',
        0x0C => '-',
        0x0D => '=',
        // Punctuation
        0x1A => '[',
        0x1B => ']',
        0x27 => ';',
        0x28 => '\'',
        0x29 => '`',
        0x2B => '\\',
        0x33 => ',',
        0x34 => '.',
        0x35 => '/',
        else => 0,
    };
}

// Map extended PS/2 Set 1 scancode to Doom key
fn mapExtendedScancode(code: u8) c_int {
    return switch (code) {
        0x48 => KEY_UPARROW,
        0x50 => KEY_DOWNARROW,
        0x4B => KEY_LEFTARROW,
        0x4D => KEY_RIGHTARROW,
        0x1D => KEY_RCTRL, // Right Ctrl
        0x38 => KEY_RALT, // Right Alt
        else => 0,
    };
}

const std = @import("std");
const syscall = @import("syscall");

// PS/2 Ports
const PORT_DATA = 0x60;
const PORT_CMD = 0x64;

// Commands
const CMD_DISABLE_FIRST = 0xAD;
const CMD_DISABLE_SECOND = 0xA7;
const CMD_ENABLE_FIRST = 0xAE;
const CMD_ENABLE_SECOND = 0xA8;
const CMD_READ_CONFIG = 0x20;
const CMD_WRITE_CONFIG = 0x60;
const CMD_WRITE_MOUSE = 0xD4;

// Mouse Commands
const MOUSE_CMD_RESET = 0xFF;
const MOUSE_CMD_SET_DEFAULTS = 0xF6;
const MOUSE_CMD_ENABLE_STREAMING = 0xF4;
const MOUSE_CMD_SET_SAMPLE_RATE = 0xF3;
const MOUSE_CMD_GET_DEVICE_ID = 0xF2;

// Keyboard Commands
const KBD_CMD_SET_LEDS = 0xED;

// Responses
const ACK = 0xFA;
const RESEND = 0xFE;

// Config Bits
const CFG_IRQ1 = 0x01;
const CFG_IRQ12 = 0x02;
const CFG_XLAT = 0x40;

// IPC Types (Must match kernel/syscall/ipc.zig)
const INPUT_TYPE_KEYBOARD = 1;
const INPUT_TYPE_MOUSE = 2;

const InputHeader = extern struct {
    type: u32,
    _pad: u32,
};

const KeyboardEvent = extern struct {
    header: InputHeader,
    scancode: u8,
};

const MouseEvent = extern struct {
    header: InputHeader,
    dx: i16,
    dy: i16,
    dz: i8,
    buttons: u8,
};

pub fn main() !void {
    // 1. Initialize Controller (Simplified)
    // Disable devices
    try syscall.outb(PORT_CMD, CMD_DISABLE_FIRST);
    try syscall.outb(PORT_CMD, CMD_DISABLE_SECOND);

    // Flush buffer
    while ((try syscall.inb(PORT_CMD)) & 1 != 0) {
        _ = try syscall.inb(PORT_DATA);
    }

    // Read Config
    try syscall.outb(PORT_CMD, CMD_READ_CONFIG);
    var config = try syscall.inb(PORT_DATA);

    // Enable IRQs and Translation
    config |= CFG_IRQ1;
    config |= CFG_IRQ12;
    config |= CFG_XLAT;

    // Write Config
    try syscall.outb(PORT_CMD, CMD_WRITE_CONFIG);
    try syscall.outb(PORT_DATA, config);

    // Enable devices
    try syscall.outb(PORT_CMD, CMD_ENABLE_FIRST);
    try syscall.outb(PORT_CMD, CMD_ENABLE_SECOND);

    // 2. Fork Keyboard Child
    const pid_kbd = try syscall.fork();
    if (pid_kbd == 0) {
        return keyboardLoop();
    }

    // 3. Fork Mouse Child
    const pid_mouse = try syscall.fork();
    if (pid_mouse == 0) {
        return mouseLoop();
    }

    // 4. Parent Loop (Keep alive)
    while (true) {
        // Sleep 10s
        _ = syscall.nanosleep(10 * 1000 * 1000 * 1000);
    }
}

// Write a byte to the keyboard (Port 0x60 directly)
fn writeKeyboard(val: u8) !void {
     // Wait for input buffer empty
    while ((try syscall.inb(PORT_CMD) & 2) != 0) {}
    try syscall.outb(PORT_DATA, val);
}

// Helper to wait for ACK
fn expectKbAck() !void {
     // We need to poll for ACK, but be careful not to eat IRQ data or mouse data?
     // Actually, in polling mode for sending commands we might race with IRQ handler if active.
     // But for now we just busy wait carefully.
     var timeout: usize = 10000;
     while (timeout > 0) : (timeout -= 1) {
         const s = try syscall.inb(PORT_CMD);
         if ((s & 1) != 0) {
             const d = try syscall.inb(PORT_DATA);
             if (d == ACK) return;
             // If unrelated data, we technically lost it here. 
             // Ideally we shouldn't send commands while heavy traffic.
         }
     }
     return error.Timeout;
}

fn keyboardLoop() !void {
    var caps_lock: bool = false;
    var num_lock: bool = false;
    var scroll_lock: bool = false;

    while (true) {
        // Wait for IRQ 1
        _ = try syscall.wait_interrupt(1);

        // Read Status
        const status = try syscall.inb(PORT_CMD);
        if ((status & 1) == 0) continue; // Spurious

        // Ignore if it's mouse data (Bit 5 set)
        if ((status & 0x20) != 0) {
            continue;
        }

        // Read Scancode
        const scancode = try syscall.inb(PORT_DATA);

        // LED Logic (on press only)
        // Caps Lock: 0x3A
        // Num Lock: 0x45
        // Scroll Lock: 0x46
        var led_changed = false;
        if (scancode == 0x3A) {
             caps_lock = !caps_lock;
             led_changed = true;
        } else if (scancode == 0x45) {
             num_lock = !num_lock;
             led_changed = true;
        } else if (scancode == 0x46) {
             scroll_lock = !scroll_lock;
             led_changed = true;
        }

        if (led_changed) {
             var led_byte: u8 = 0;
             if (scroll_lock) led_byte |= 1;
             if (num_lock) led_byte |= 2;
             if (caps_lock) led_byte |= 4;
             
             // Send LED command (Best effort, ignore errors to not hang input)
             writeKeyboard(KBD_CMD_SET_LEDS) catch {};
             // We can't easily wait for ACK here inside IRQ loop without risking recursion or lag
             // So we just blindly write the data byte next. 
             // Real drivers use a state machine. This is "fast hack" mode.
             // Small busy wait for buffer empty?
             while ((try syscall.inb(PORT_CMD) & 2) != 0) {}
             try syscall.outb(PORT_DATA, led_byte);
        }

        // Create IPC Message
        var evt = KeyboardEvent{
            .header = .{ .type = INPUT_TYPE_KEYBOARD, ._pad = 0 },
            .scancode = scancode,
        };
        const bytes = std.mem.asBytes(&evt);

        // Send to Kernel (PID 0)
        _ = syscall.send(0, bytes) catch {};
    }
}

// Write a byte to the mouse (via 0xD4)
fn writeMouse(val: u8) !void {
    // Wait for input buffer empty
    while ((try syscall.inb(PORT_CMD) & 2) != 0) {}
    try syscall.outb(PORT_CMD, CMD_WRITE_MOUSE);
    
    // Wait for input buffer empty again
    while ((try syscall.inb(PORT_CMD) & 2) != 0) {}
    try syscall.outb(PORT_DATA, val);
}

// Read a byte from mouse (or keyboard port) with timeout
fn readByte() !u8 {
    var timeout: usize = 10000;
    while (timeout > 0) : (timeout -= 1) {
        const s = try syscall.inb(PORT_CMD);
        if ((s & 1) != 0) {
            return try syscall.inb(PORT_DATA);
        }
    }
    return error.Timeout;
}

fn expectAck() !void {
    const b = try readByte();
    if (b != ACK) return error.NoAck;
}

fn mouseLoop() !void {
    // Mouse Initialization Sequence
    
    // 1. Reset
    writeMouse(MOUSE_CMD_RESET) catch {};
    _ = readByte() catch {}; // ACK
    _ = readByte() catch {}; // 0xAA
    _ = readByte() catch {}; // ID

    // 2. Try to enable Scroll Wheel (IntelliMouse Magic Sequence)
    // Sequence: Rate 200, Rate 100, Rate 80
    writeMouse(MOUSE_CMD_SET_SAMPLE_RATE) catch {}; expectAck() catch {};
    writeMouse(200) catch {}; expectAck() catch {};
    
    writeMouse(MOUSE_CMD_SET_SAMPLE_RATE) catch {}; expectAck() catch {};
    writeMouse(100) catch {}; expectAck() catch {};

    writeMouse(MOUSE_CMD_SET_SAMPLE_RATE) catch {}; expectAck() catch {};
    writeMouse(80) catch {}; expectAck() catch {};

    // Check Device ID
    writeMouse(MOUSE_CMD_GET_DEVICE_ID) catch {};
    expectAck() catch {};
    const device_id = readByte() catch 0;
    
    const has_wheel = (device_id == 3 or device_id == 4);
    // Packet size: 4 if wheel, 3 otherwise (usually)
    // Actually ID 3/4 implies 4 bytes.
    const packet_size: usize = if (has_wheel) 4 else 3;

    // 3. Set Defaults (Reset scaling etc)
    // Note: Setting defaults might reset sample rate, be careful. 
    // Usually safe to allow defaults + streaming.
    // writeMouse(MOUSE_CMD_SET_DEFAULTS) catch {}; expectAck() catch {};

    // 4. Enable Streaming
    writeMouse(MOUSE_CMD_ENABLE_STREAMING) catch {};
    expectAck() catch {};

    var packet: [4]u8 = undefined;
    var idx: usize = 0;

    while (true) {
        // Wait for IRQ 12
        _ = try syscall.wait_interrupt(12);

        // Read Status
        const status = try syscall.inb(PORT_CMD);
        if ((status & 1) == 0) continue; 
        
        // Only read if it IS mouse data
        if ((status & 0x20) == 0) {
            continue;
        }

        const byte = try syscall.inb(PORT_DATA);

        // Sync check (Bit 3 of Byte 0 must be 1)
        if (idx == 0 and (byte & 0x08) == 0) {
            continue; // Resync
        }

        packet[idx] = byte;
        idx += 1;

        if (idx >= packet_size) {
            idx = 0;
            
            const flags = packet[0];
            
            // X Logic
            var dx_final: i16 = @as(i16, packet[1]);
            if ((flags & 0x10) != 0) dx_final -= 256;

            // Y Logic
            var dy_final: i16 = @as(i16, packet[2]);
            if ((flags & 0x20) != 0) dy_final -= 256;
            dy_final = -dy_final; // Invert Y

            // Z Logic (Scroll Wheel)
            var dz_final: i8 = 0;
            if (has_wheel) {
                // Byte 3 is Z. Last 4 bits usually.
                // Standard IntelliMouse: Byte 3 = Z (signed 4-bit, or 8-bit depending on mode).
                // ID 03 mode: Byte 3 is Z.
                dz_final = @as(i8, @bitCast(packet[3]));
                // Usually it's lowest few bits, but let's assume raw byte for now.
                // QEMU sends raw byte.
            }

            // Buttons
            const buttons: u8 = (flags & 0x07);

            var evt = MouseEvent{
                .header = .{ .type = INPUT_TYPE_MOUSE, ._pad = 0 },
                .dx = dx_final,
                .dy = dy_final,
                .dz = dz_final,
                .buttons = buttons,
            };
            const bytes = std.mem.asBytes(&evt);
            
            _ = syscall.send(0, bytes) catch {};
        }
    }
}

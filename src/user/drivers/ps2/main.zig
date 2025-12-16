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

fn keyboardLoop() !void {
    while (true) {
        // Wait for IRQ 1
        _ = try syscall.wait_interrupt(1);

        // Read Status
        const status = try syscall.inb(PORT_CMD);
        if ((status & 1) == 0) continue; // Spurious

        // Read Scancode
        const scancode = try syscall.inb(PORT_DATA);

        // Create IPC Message
        var evt = KeyboardEvent{
            .header = .{ .type = INPUT_TYPE_KEYBOARD, ._pad = 0 },
            .scancode = scancode,
        };
        const bytes = std.mem.asBytes(&evt);

        // Send to Kernel (PID 0)
        // Note: sys_send to 0 is the special "Input Injection" call
        try syscall.send(0, bytes);
        // Ignore errors, loop forever
    }
}

fn mouseLoop() !void {
     // Mouse needs initialization too (Reset, Enable Streaming)
     // For now assuming BIOS/Controller Init did some work or defaults work.
     // Ideally we should send MOUSE_CMD_ENABLE_STREAMING (0xF4) to PORT_DATA here.
     // But we need to use 0xD4 (Write Mouse) command to 0x64.
     
     // Enable Streaming
     try syscall.outb(PORT_CMD, 0xD4);
     try syscall.outb(PORT_DATA, 0xF4); // Enable Data Reporting
     // Ack
     while ((try syscall.inb(PORT_CMD)) & 1 == 0) {}
     _ = try syscall.inb(PORT_DATA); // Read ACK

    var packet: [3]u8 = undefined;
    var idx: usize = 0;

    while (true) {
        // Wait for IRQ 12
        _ = try syscall.wait_interrupt(12);

        // Read Status
        const status = try syscall.inb(PORT_CMD);
         if ((status & 1) == 0) continue; 
         // Check if AUX bit (5) is set? usually status & 0x20
         // if ((status & 0x20) == 0) continue; // Not mouse data?

        const byte = try syscall.inb(PORT_DATA);

        // Simple Packet Assembly (3 bytes)
        // Byte 0: sync bit (3) should be 1
        if (idx == 0 and (byte & 0x08) == 0) {
            continue; // Resync
        }

        packet[idx] = byte;
        idx += 1;

        if (idx >= 3) {
            // Process Packet
            idx = 0;
            
            const flags = packet[0];
            var dx: i16 = @as(i16, packet[1]);
            var dy: i16 = @as(i16, packet[2]);

            // Sign extension (9-bit)
            if ((flags & 0x10) != 0) dx |= -256; // 0xFF00
            if ((flags & 0x20) != 0) dy |= -256;

            // Y is usually inverted ?? Kernel driver does (inverted)
            // Kernel: dy = if (bit5) 256 - val else -val.
            // Simplified here: passed as raw logic
            // Let's use standard PS/2: Y+ is up, but packets send Y+
            // Kernel mouse.zig:
            // const dy: i16 = if ((flags & 0x20) != 0) 256 - @as(i16, packet[2]) else -@as(i16, packet[2]);
            // Replicating Kernel Logic:
             const dy_final: i16 = if ((flags & 0x20) != 0)
                256 - @as(i16, packet[2])
            else
                -@as(i16, packet[2]);

            // X Logic
            const dx_final: i16 = if ((flags & 0x10) != 0)
                @as(i16, packet[1]) - 256
            else
                @as(i16, packet[1]);


            // Buttons
            const buttons: u8 = (flags & 0x07);

            var evt = MouseEvent{
                .header = .{ .type = INPUT_TYPE_MOUSE, ._pad = 0 },
                .dx = dx_final,
                .dy = dy_final,
                .dz = 0,
                .buttons = buttons,
            };
            const bytes = std.mem.asBytes(&evt);
            
            try syscall.send(0, bytes);
        }
    }
}

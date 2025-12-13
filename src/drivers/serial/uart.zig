const hal = @import("hal");
const sync = @import("sync");

pub const Serial = struct {
    port: u16,
    lock: sync.Spinlock = .{},

    const COM1: u16 = 0x3F8;

    pub fn init() Serial {
        const self = Serial{ .port = COM1 };
        
        // Disable interrupts
        hal.io.outb(self.port + 1, 0x00);
        
        // Enable DLAB (Divisor Latch Access Bit) to set baud rate
        hal.io.outb(self.port + 3, 0x80);
        
        // Set divisor to 3 (38400 baud) - standard for many emulators/hardware
        // Lo byte
        hal.io.outb(self.port + 0, 0x03);
        // Hi byte
        hal.io.outb(self.port + 1, 0x00);
        
        // Clear DLAB and configure 8 bits, no parity, 1 stop bit
        hal.io.outb(self.port + 3, 0x03);
        
        // Enable FIFO, clear them, with 14-byte threshold
        hal.io.outb(self.port + 2, 0xC7);
        
        return self;
    }

    pub fn write(self: *Serial, data: []const u8) void {
        for (data) |c| {
            self.putChar(c);
        }
    }

    pub fn putChar(self: *Serial, c: u8) void {
        const held = self.lock.acquire();
        defer held.release();
        
        // Wait for Transmit Empty bit (Bit 5 of LSR)
        while (true) {
            const status = hal.io.inb(self.port + 5);
            if ((status & 0x20) != 0) break;
            asm volatile ("pause");
        }
        hal.io.outb(self.port, c);
    }
};

const hal = @import("hal");
const sync = @import("sync");

pub const Serial = struct {
    port: u16,
    lock: sync.Spinlock = .{},

    // Callback for received bytes (to avoid circular dependency with keyboard driver)
    pub var onByteReceived: ?*const fn(byte: u8) void = null;

    const COM1: u16 = 0x3F8;

    pub fn init() Serial {
        const self = Serial{ .port = COM1 };
        
        // Disable interrupts initially to configure
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

        // Enable Received Data Available Interrupt (Bit 0 of IER)
        hal.io.outb(self.port + 1, 0x01);
        
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

    /// UART Interrupt Handler
    pub fn handleIrq() void {
        const port = COM1;
        // Read Interrupt Identification Register (IIR)
        const iir = hal.io.inb(port + 2);
        
        // Check if interrupt is pending (Bit 0 == 0 means pending)
        if ((iir & 0x01) != 0) return;

        // Check ID (Bits 1-3)
        // 010 (2) = Received Data Available
        // 110 (6) = Character Timeout (Data available)
        const id = (iir >> 1) & 0x07;
        if (id == 2 or id == 6) {
             // Read data
             const data = hal.io.inb(port);
             
             // Notify callback if set
             if (onByteReceived) |callback| {
                 callback(data);
             }
        }
    }
};

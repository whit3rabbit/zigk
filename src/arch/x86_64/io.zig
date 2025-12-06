// Port I/O operations for x86_64
// HAL layer - only place where port I/O inline assembly is permitted
//
// These functions provide the low-level interface for communicating with
// hardware devices via x86 I/O ports. All kernel code outside of src/arch/
// MUST use the hal module interface instead of importing this directly.

/// Read a byte from an I/O port
pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

/// Write a byte to an I/O port
pub inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

/// Read a word (16-bit) from an I/O port
pub inline fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[ret]"
        : [ret] "={ax}" (-> u16),
        : [port] "{dx}" (port),
    );
}

/// Write a word (16-bit) to an I/O port
pub inline fn outw(port: u16, value: u16) void {
    asm volatile ("outw %[value], %[port]"
        :
        : [value] "{ax}" (value),
          [port] "{dx}" (port),
    );
}

/// Read a double word (32-bit) from an I/O port
pub inline fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[ret]"
        : [ret] "={eax}" (-> u32),
        : [port] "{dx}" (port),
    );
}

/// Write a double word (32-bit) to an I/O port
pub inline fn outl(port: u16, value: u32) void {
    asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "{dx}" (port),
    );
}

/// Short delay using I/O port 0x80 (POST diagnostic port)
/// Used for timing-sensitive hardware operations
pub inline fn ioWait() void {
    outb(0x80, 0);
}

const std = @import("std");
const syscall = @import("syscall");

// UAPI syscalls wrapper would be nice, but we can access raw syscalls or use lib
// Using raw syscall numbers from uapi for now if syscall lib doesn't expose them
const SYS_WAIT_INTERRUPT = 1022;
const SYS_INB = 1023;
const SYS_OUTB = 1024;
const COM1 = 0x3F8;

pub fn main() void {
    syscall.print("UART Driver Starting...\n");

    // Initialize UART
    // 1. Disable Interrupts
    _ = syscall.syscall2(SYS_OUTB, COM1 + 1, 0x00);
    // 2. Set Baud Rate (38400)
    _ = syscall.syscall2(SYS_OUTB, COM1 + 3, 0x80); // Enable DLAB
    _ = syscall.syscall2(SYS_OUTB, COM1 + 0, 0x03); // Divisor Low
    _ = syscall.syscall2(SYS_OUTB, COM1 + 1, 0x00); // Divisor High
    // 3. Configure Line (8 bits, no parity, 1 stop bit)
    _ = syscall.syscall2(SYS_OUTB, COM1 + 3, 0x03);
    // 4. Configure FIFO
    _ = syscall.syscall2(SYS_OUTB, COM1 + 2, 0xC7);
    // 5. Enable Interrupts (RDAI)
    _ = syscall.syscall2(SYS_OUTB, COM1 + 1, 0x01);

    syscall.print("UART Initialized. Entering Loop...\n");

    while (true) {
        // Wait for IRQ 4
        // syscall1(SYS_WAIT_INTERRUPT, 4)
        const ret = syscall.syscall1(SYS_WAIT_INTERRUPT, 4);
        if (ret != 0) {
            syscall.print("Wait Interrupt Failed!\n"); // Should verify ret
        }

        // Read character
        const char_code = syscall.syscall1(SYS_INB, COM1);
        const char: u8 = @intCast(char_code);

        // Echo back
        _ = syscall.syscall2(SYS_OUTB, COM1, char);
    }
}

export fn _start() noreturn {
    main();
    syscall.exit(0);
}

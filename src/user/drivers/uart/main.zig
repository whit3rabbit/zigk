const std = @import("std");
const syscall = @import("syscall");

// Syscall constants
const SYS_FORK = 57;
const SYS_SEND = 1020;
const SYS_RECV = 1021;
const SYS_WAIT_INTERRUPT = 1022;
const SYS_INB = 1023;
const SYS_OUTB = 1024;
const SYS_REGISTER_IPC_LOGGER = 1025;

const COM1 = 0x3F8;
const MAX_PAYLOAD_SIZE = 64;

const Message = extern struct {
    sender_pid: u64,
    payload_len: u64,
    payload: [MAX_PAYLOAD_SIZE]u8,
};

pub fn main() void {
    syscall.print("UART Driver Starting (Split Mode)...\n");

    // Initialize UART Hardware
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
    // 5. Enable Interrupts (RDAI) - Essential for Input Process
    _ = syscall.syscall2(SYS_OUTB, COM1 + 1, 0x01);

    syscall.print("UART HW Initialized. Forking...\n");

    const pid = syscall.syscall1(SYS_FORK, 0);

    if (pid == 0) {
        // =====================================================================
        // Child Process: Input Handler (IRQ)
        // =====================================================================
        // This process waits for interrupts and handles input
        inputLoop();
    } else {
        // =====================================================================
        // Parent Process: Output Handler (IPC)
        // =====================================================================
        // This process waits for IPC messages (logs) and writes to UART
        outputLoop();
    }
}

fn inputLoop() noreturn {
    // syscall.print("[UART-IN] Input loop started\n"); // Debug
    
    while (true) {
        // Block until UART interrupt fires
        const ret = syscall.syscall1(SYS_WAIT_INTERRUPT, 4);
        if (ret != 0) {
            // syscall.print("[UART-IN] Wait Interrupt Failed!\n");
            // If failed, maybe yield or sleep?
            continue; 
        }

        // Read character (this might need loop if multiple chars buffered)
        // For simple UART, reading RBR clears the interrupt.
        const char_code = syscall.syscall1(SYS_INB, COM1);
        const char: u8 = @intCast(char_code);

        // Echo back (Simple Terminal mode)
        // In a real microkernel, we would send an IPC message to a Terminal/Shell process.
        // For now, we echo directly to hardware.
        // Note: This races with Output Process writing to same port!
        // UART hardware usually handles concurrent writes by serialization (FIFO),
        // but explicit locking might be needed in refined version. 
        _ = syscall.syscall2(SYS_OUTB, COM1, char);
        
        // Handle newline
        if (char == '\r') {
             _ = syscall.syscall2(SYS_OUTB, COM1, '\n');
        }
    }
}

fn outputLoop() noreturn {
    // syscall.print("[UART-OUT] Output loop started. Registering Logger...\n");

    // Register as the system logger
    _ = syscall.syscall0(SYS_REGISTER_IPC_LOGGER);

    var msg: Message = undefined;
    
    while (true) {
        // Block until message received
        const sender = syscall.syscall2(SYS_RECV, @intFromPtr(&msg), @sizeOf(Message));
        
        if (sender < 0) {
            // syscall.print("[UART-OUT] Recv Failed!\n");
            continue;
        }

        // Process Payload
        const len = if (msg.payload_len > MAX_PAYLOAD_SIZE) MAX_PAYLOAD_SIZE else msg.payload_len;
        const payload = msg.payload[0..len];

        // Write to UART
        for (payload) |c| {
            // Check LSR for Transmit Holding Register Empty (bit 5)
            // Ideally we should wait, but for now we blaze it (FIFO helps)
            // Proper driver would wait for THRE interrupt or poll LSR.
            
            // Poll LSR to avoid overflow
            // while ((inb(COM1 + 5) & 0x20) == 0) {}
            
            // Simpler: Just write
            _ = syscall.syscall2(SYS_OUTB, COM1, c);
        }
    }
}

export fn _start() noreturn {
    main();
    syscall.exit(0);
}

const std = @import("std");
const syscall = @import("syscall");

pub fn main() void {
    syscall.print("\nZigK Shell v0.1\n");
    syscall.print("Type 'help' for commands\n\n");

    var buffer: [128]u8 = undefined;

    while (true) {
        syscall.print("zigk> ");

        // Read line
        var len: usize = 0;
        while (len < buffer.len) {
            const c = syscall.getchar() catch {
                syscall.print("Error reading input\n");
                continue;
            };

            // Echo back
            syscall.putchar(c) catch {};

            if (c == '\n') {
                break;
            } else if (c == 0x08 or c == 0x7F) { // Backspace
                if (len > 0) {
                    len -= 1;
                    // Backspace sequence for terminal
                    syscall.print("\x08 \x08"); 
                }
            } else {
                buffer[len] = c;
                len += 1;
            }
        }

        if (len == 0) continue;

        const cmd = buffer[0..len];

        if (std.mem.eql(u8, cmd, "help")) {
            syscall.print("Available commands:\n");
            syscall.print("  help    - Show this help\n");
            syscall.print("  exit    - Exit shell\n");
            syscall.print("  clear   - Clear screen\n");
        } else if (std.mem.eql(u8, cmd, "exit")) {
            syscall.print("Exiting shell...\n");
            syscall.exit(0);
        } else if (std.mem.eql(u8, cmd, "clear")) {
             syscall.print("\x1b[2J\x1b[H");
        } else {
            syscall.print("Unknown command: ");
            syscall.print(cmd);
            syscall.print("\n");
        }
    }
}

// Entry point called by linker/crt0
export fn _start() noreturn {
    main();
    syscall.exit(0);
}

const std = @import("std");
const loader = @import("loader.zig");
const uefi = std.os.uefi;

pub fn main() void {
    const system_table = uefi.system_table;
    
    serialPrint("Phase 2: UEFI Bootloader Started\r\n");
    
    if (system_table.con_out) |con_out| {
        _ = con_out.clearScreen() catch {};

        const msg = "Hello from Zscapek Custom UEFI Bootloader!\r\n";
        for (msg) |c| {
            var buf = [2:0]u16{ c, 0 };
            _ = con_out.outputString(&buf) catch {};
        }

        const sub_msg = "Phase 2: Bootloader Skeleton Active.\r\n";
        for (sub_msg) |c| {
            var buf = [2:0]u16{ c, 0 };
            _ = con_out.outputString(&buf) catch {};
        }
    }

    if (system_table.boot_services) |bs| {
        serialPrint("Attempting to load kernel...\r\n");
        var segments: [16]loader.LoadedSegment = undefined;
        if (loader.loadKernel(bs, &segments)) |_| {
            serialPrint("Kernel segments loaded!\r\n");
            // Print count? Can't easy with serialPrint simple string
            // Just assume success
        } else |_| {
            serialPrint("Failed to load kernel: Error\r\n");
            stallForever();
        }
    }
    
    serialPrint("Exiting EfiMain\r\n");
    
    // Stall before exit
    if (system_table.boot_services) |bs| {
        _ = bs.stall(5 * 1000 * 1000) catch {};
    }
}

fn stallForever() noreturn {
    while (true) {
        asm volatile("hlt");
    }
}

fn serialWrite(data: u8) void {
    asm volatile ("outb %%al, %%dx" : : [val] "{al}" (data), [port] "{dx}" (@as(u16, 0x3F8)));
}

fn serialPrint(msg: []const u8) void {
    for (msg) |c| {
        // Removed LSR check to avoid potential hang in QEMU if UART is not perfectly emulated or ready
        serialWrite(c);
    }
}

fn serialRead(port: u16) u8 {
    return asm volatile ("inb %%dx, %%al" : [ret] "={al}" (-> u8) : [port] "{dx}" (port));
}

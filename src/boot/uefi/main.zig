const std = @import("std");
const uefi = std.os.uefi;

pub fn main() void {
    const system_table = uefi.system_table;
    
    serialPrint("Phase 2: UEFI Bootloader Started (Serial Output Active)\r\n");
    
    if (system_table.con_out) |con_out| {
        _ = con_out.clearScreen() catch {};
        
        const msg = "Hello from Zscapek Custom UEFI Bootloader (Zig Main)!\r\n";
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

    serialPrint("Stalling for 3 seconds...\r\n");

    // Stall for 3 seconds
    if (system_table.boot_services) |bs| {
        _ = bs.stall(3 * 1000 * 1000) catch {};
    }
    
    serialPrint("Exiting EfiMain (Verification Complete)\r\n");
}

fn serialWrite(data: u8) void {
    asm volatile ("outb %%al, %%dx" : : [val] "{al}" (data), [port] "{dx}" (@as(u16, 0x3F8)));
}

fn serialPrint(msg: []const u8) void {
    for (msg) |c| {
        while ((serialRead(0x3F8 + 5) & 0x20) == 0) {}
        serialWrite(c);
    }
}

fn serialRead(port: u16) u8 {
    return asm volatile ("inb %%dx, %%al" : [ret] "={al}" (-> u8) : [port] "{dx}" (port));
}

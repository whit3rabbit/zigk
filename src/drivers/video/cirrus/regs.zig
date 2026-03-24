//! Cirrus VGA Register Access Abstraction
//!
//! Provides register access for the Cirrus Logic CL-GD5446 VGA adapter.
//! Uses I/O port space for register access (VGA standard ports).
//!
//! The Cirrus chip uses indexed register access:
//! 1. Write register index to INDEX port
//! 2. Read/write value from/to DATA port

const std = @import("std");
const builtin = @import("builtin");
const hal = @import("hal");
const hw = @import("hardware.zig");

/// Register access abstraction for Cirrus VGA
pub const RegisterAccess = struct {
    const Self = @This();

    /// Read a Sequencer register
    pub fn readSeq(reg: hw.SeqReg) u8 {
        if (builtin.cpu.arch != .x86_64) return 0;
        hal.io.outb(hw.VGA_SEQ_INDEX, @intFromEnum(reg));
        return hal.io.inb(hw.VGA_SEQ_DATA);
    }

    /// Write a Sequencer register
    pub fn writeSeq(reg: hw.SeqReg, value: u8) void {
        if (builtin.cpu.arch != .x86_64) return;
        hal.io.outb(hw.VGA_SEQ_INDEX, @intFromEnum(reg));
        hal.io.outb(hw.VGA_SEQ_DATA, value);
    }

    /// Read a Graphics Controller register
    pub fn readGfx(reg: hw.GfxReg) u8 {
        if (builtin.cpu.arch != .x86_64) return 0;
        hal.io.outb(hw.VGA_GFX_INDEX, @intFromEnum(reg));
        return hal.io.inb(hw.VGA_GFX_DATA);
    }

    /// Write a Graphics Controller register
    pub fn writeGfx(reg: hw.GfxReg, value: u8) void {
        if (builtin.cpu.arch != .x86_64) return;
        hal.io.outb(hw.VGA_GFX_INDEX, @intFromEnum(reg));
        hal.io.outb(hw.VGA_GFX_DATA, value);
    }

    /// Read a CRTC register
    pub fn readCrtc(reg: hw.CrtcReg) u8 {
        if (builtin.cpu.arch != .x86_64) return 0;
        hal.io.outb(hw.VGA_CRTC_INDEX, @intFromEnum(reg));
        return hal.io.inb(hw.VGA_CRTC_DATA);
    }

    /// Write a CRTC register
    pub fn writeCrtc(reg: hw.CrtcReg, value: u8) void {
        if (builtin.cpu.arch != .x86_64) return;
        hal.io.outb(hw.VGA_CRTC_INDEX, @intFromEnum(reg));
        hal.io.outb(hw.VGA_CRTC_DATA, value);
    }

    /// Read a raw CRTC register by index
    pub fn readCrtcRaw(index: u8) u8 {
        if (builtin.cpu.arch != .x86_64) return 0;
        hal.io.outb(hw.VGA_CRTC_INDEX, index);
        return hal.io.inb(hw.VGA_CRTC_DATA);
    }

    /// Write a raw CRTC register by index
    pub fn writeCrtcRaw(index: u8, value: u8) void {
        if (builtin.cpu.arch != .x86_64) return;
        hal.io.outb(hw.VGA_CRTC_INDEX, index);
        hal.io.outb(hw.VGA_CRTC_DATA, value);
    }

    /// Read Miscellaneous Output register
    pub fn readMisc() u8 {
        if (builtin.cpu.arch != .x86_64) return 0;
        return hal.io.inb(hw.VGA_MISC_READ);
    }

    /// Write Miscellaneous Output register
    pub fn writeMisc(value: u8) void {
        if (builtin.cpu.arch != .x86_64) return;
        hal.io.outb(hw.VGA_MISC_WRITE, value);
    }

    /// Reset Attribute Controller flip-flop by reading Input Status 1
    pub fn resetAttrFlipFlop() void {
        if (builtin.cpu.arch != .x86_64) return;
        _ = hal.io.inb(hw.VGA_INPUT_STATUS_1);
    }

    /// Write an Attribute Controller register
    pub fn writeAttr(index: u8, value: u8) void {
        if (builtin.cpu.arch != .x86_64) return;
        resetAttrFlipFlop();
        hal.io.outb(hw.VGA_ATTR_INDEX, index);
        hal.io.outb(hw.VGA_ATTR_DATA_WRITE, value);
    }

    /// Enable video output via Attribute Controller
    pub fn enableVideo() void {
        if (builtin.cpu.arch != .x86_64) return;
        resetAttrFlipFlop();
        hal.io.outb(hw.VGA_ATTR_INDEX, 0x20); // Set bit 5 (PAS) to enable display
    }

    /// Disable video output via Attribute Controller
    pub fn disableVideo() void {
        if (builtin.cpu.arch != .x86_64) return;
        resetAttrFlipFlop();
        hal.io.outb(hw.VGA_ATTR_INDEX, 0x00); // Clear bit 5 (PAS) to disable display
    }

    /// Unlock Cirrus extended registers
    /// Must be called before accessing Cirrus-specific registers
    pub fn unlockCirrus() void {
        writeSeq(.EXT_SEQ_MODE, hw.CIRRUS_UNLOCK_KEY);
    }

    /// Lock Cirrus extended registers
    pub fn lockCirrus() void {
        writeSeq(.EXT_SEQ_MODE, 0x00);
    }

    /// Check if Cirrus extended registers are unlocked
    pub fn isUnlocked() bool {
        return readSeq(.EXT_SEQ_MODE) == hw.CIRRUS_UNLOCK_KEY;
    }

    /// Detect Cirrus chip by checking for valid SR7 unlock response
    /// Returns true if Cirrus VGA is detected
    pub fn detectCirrus() bool {
        if (builtin.cpu.arch != .x86_64) return false;

        // Save current SR7 value
        const saved = readSeq(.EXT_SEQ_MODE);

        // Try to unlock
        unlockCirrus();

        // Check if unlock succeeded
        const unlocked = readSeq(.EXT_SEQ_MODE) == hw.CIRRUS_UNLOCK_KEY;

        // Restore original value
        writeSeq(.EXT_SEQ_MODE, saved);

        return unlocked;
    }

    /// Unlock Hidden DAC for high color modes (15/16/24/32bpp)
    /// The Hidden DAC is accessed by reading port 0x3C6 four times,
    /// then writing the mode value on the fifth access
    pub fn unlockHiddenDac() void {
        if (builtin.cpu.arch != .x86_64) return;
        // Read 4 times to unlock
        _ = hal.io.inb(hw.CIRRUS_HIDDEN_DAC_INDEX);
        _ = hal.io.inb(hw.CIRRUS_HIDDEN_DAC_INDEX);
        _ = hal.io.inb(hw.CIRRUS_HIDDEN_DAC_INDEX);
        _ = hal.io.inb(hw.CIRRUS_HIDDEN_DAC_INDEX);
    }

    /// Write Hidden DAC mode
    pub fn writeHiddenDacMode(mode: u8) void {
        if (builtin.cpu.arch != .x86_64) return;
        unlockHiddenDac();
        hal.io.outb(hw.CIRRUS_HIDDEN_DAC_INDEX, mode);
    }

    /// Read Hidden DAC mode
    pub fn readHiddenDacMode() u8 {
        if (builtin.cpu.arch != .x86_64) return 0;
        unlockHiddenDac();
        return hal.io.inb(hw.CIRRUS_HIDDEN_DAC_INDEX);
    }

    /// Set DAC palette entry (for 8bpp mode)
    pub fn setDacColor(index: u8, r: u8, g: u8, b: u8) void {
        if (builtin.cpu.arch != .x86_64) return;
        hal.io.outb(hw.VGA_DAC_WRITE_INDEX, index);
        // DAC expects 6-bit values (0-63), shift down from 8-bit
        hal.io.outb(hw.VGA_DAC_DATA, r >> 2);
        hal.io.outb(hw.VGA_DAC_DATA, g >> 2);
        hal.io.outb(hw.VGA_DAC_DATA, b >> 2);
    }

    /// Unlock CRTC registers (clear protection bit)
    pub fn unlockCrtc() void {
        // Unlock CRTC registers by clearing bit 7 of CR11 (Vertical Retrace End)
        var cr11 = readCrtc(.V_SYNC_END);
        cr11 &= 0x7F; // Clear bit 7 (lock bit)
        writeCrtc(.V_SYNC_END, cr11);
    }

    /// Lock CRTC registers (set protection bit)
    pub fn lockCrtc() void {
        var cr11 = readCrtc(.V_SYNC_END);
        cr11 |= 0x80; // Set bit 7 (lock bit)
        writeCrtc(.V_SYNC_END, cr11);
    }

    /// Enable linear framebuffer mode
    /// Sets up Cirrus for direct framebuffer access via BAR1
    pub fn enableLinearFramebuffer() void {
        // Unlock Cirrus extensions first
        unlockCirrus();

        // Set SR7 bit 0 for extended memory map
        var sr7 = readSeq(.EXT_SEQ_MODE);
        sr7 |= 0x01; // Enable extended memory
        writeSeq(.EXT_SEQ_MODE, sr7);

        // Set GR6 for graphics mode with A0000 mapping
        var gr6 = readGfx(.MISC);
        gr6 &= 0xF0;
        gr6 |= 0x05; // Graphics mode, chain 4, A0000-BFFFF (or LFB)
        writeGfx(.MISC, gr6);

        // Enable extended mode via GRB
        var grb = readGfx(.MODE_EXT);
        grb |= 0x01; // Enable extended write modes
        writeGfx(.MODE_EXT, grb);
    }

    /// Program CRTC timing registers for a given mode
    pub fn programTiming(timing: hw.ModeTiming) void {
        // Unlock CRTC first
        unlockCrtc();

        // Disable display during programming
        disableVideo();

        // Write Miscellaneous Output Register (clock select, sync polarity)
        writeMisc(timing.misc_output);

        // Program horizontal timing
        writeCrtc(.H_TOTAL, @truncate(timing.h_total & 0xFF));
        writeCrtc(.H_DISP_END, @truncate(timing.h_disp_end & 0xFF));
        writeCrtc(.H_BLANK_START, @truncate(timing.h_blank_start & 0xFF));
        writeCrtc(.H_BLANK_END, @truncate((timing.h_blank_end & 0x1F) | 0x80)); // Bit 7 always set
        writeCrtc(.H_SYNC_START, @truncate(timing.h_sync_start & 0xFF));
        writeCrtc(.H_SYNC_END, @truncate(timing.h_sync_end & 0x1F));

        // Program vertical timing
        writeCrtc(.V_TOTAL, @truncate(timing.v_total & 0xFF));

        // Overflow register (bits 8-9 of various vertical values)
        var overflow: u8 = 0;
        overflow |= @as(u8, @truncate((timing.v_total >> 8) & 0x01));        // bit 0: V_TOTAL[8]
        overflow |= @as(u8, @truncate((timing.v_disp_end >> 7) & 0x02));     // bit 1: V_DISP_END[8]
        overflow |= @as(u8, @truncate((timing.v_sync_start >> 6) & 0x04));   // bit 2: V_SYNC_START[8]
        overflow |= @as(u8, @truncate((timing.v_blank_start >> 5) & 0x08));  // bit 3: V_BLANK_START[8]
        overflow |= 0x10; // bit 4: Line compare bit 8 (set to 1)
        overflow |= @as(u8, @truncate((timing.v_total >> 4) & 0x20));        // bit 5: V_TOTAL[9]
        overflow |= @as(u8, @truncate((timing.v_disp_end >> 3) & 0x40));     // bit 6: V_DISP_END[9]
        overflow |= @as(u8, @truncate((timing.v_sync_start >> 2) & 0x80));   // bit 7: V_SYNC_START[9]
        writeCrtc(.OVERFLOW, overflow);

        writeCrtc(.V_SYNC_START, @truncate(timing.v_sync_start & 0xFF));
        // V_SYNC_END also contains CRTC protect bit (bit 7), keep it clear to stay unlocked
        writeCrtc(.V_SYNC_END, @truncate(timing.v_sync_end & 0x0F));
        writeCrtc(.V_DISP_END, @truncate(timing.v_disp_end & 0xFF));
        writeCrtc(.V_BLANK_START, @truncate(timing.v_blank_start & 0xFF));
        writeCrtc(.V_BLANK_END, @truncate(timing.v_blank_end & 0xFF));

        // Set logical width (offset/pitch)
        writeCrtc(.OFFSET, @truncate(timing.offset & 0xFF));

        // Mode control register - enable word mode, select row scan counter
        writeCrtc(.MODE_CONTROL, 0xC3);

        // Max scan line - single scan (no character height)
        writeCrtc(.MAX_SCAN_LINE, 0x00);

        // Line compare at max (no split screen)
        writeCrtc(.LINE_COMPARE, 0xFF);

        // Enable video output
        enableVideo();
    }

    /// Set display start address (for page flipping/scrolling)
    pub fn setStartAddress(addr: u32) void {
        writeCrtc(.START_ADDR_HI, @truncate((addr >> 8) & 0xFF));
        writeCrtc(.START_ADDR_LO, @truncate(addr & 0xFF));
        // For addresses > 64KB, use Cirrus extended register
        writeCrtcRaw(0x1B, @truncate((addr >> 16) & 0x0F));
    }
};

/// Architecture-independent memory barrier for MMIO ordering
pub inline fn memoryBarrier() void {
    if (builtin.cpu.arch == .x86_64) {
        // x86 has strong memory ordering, but mfence ensures visibility
        asm volatile ("mfence" ::: .{ .memory = true });
    } else if (builtin.cpu.arch == .aarch64) {
        // DMB SY - Data Memory Barrier, full system
        asm volatile ("dmb sy" ::: .{ .memory = true });
    }
}

/// Architecture-independent CPU pause/yield hint
pub inline fn cpuPause() void {
    if (builtin.cpu.arch == .x86_64) {
        asm volatile ("pause");
    } else if (builtin.cpu.arch == .aarch64) {
        asm volatile ("yield");
    }
}

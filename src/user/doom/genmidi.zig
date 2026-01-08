//! GENMIDI Lump Loader for Doom Music
//!
//! Loads OPL3 instrument definitions from the GENMIDI lump in Doom WAD files.
//! The GENMIDI lump contains 128 melodic instruments + 47 percussion instruments.

const std = @import("std");

/// OPL2 register set for a single operator
pub const Opl2Registers = extern struct {
    /// 0x20: Tremolo, Vibrato, Sustain, KSR, Frequency Multiplier
    tremolo_vibrato: u8,
    /// 0x40: Key Scale Level, Total Level (volume)
    key_scale_output: u8,
    /// 0x60: Attack Rate, Decay Rate
    attack_decay: u8,
    /// 0x80: Sustain Level, Release Rate
    sustain_release: u8,
    /// 0xE0: Waveform Select
    wave_select: u8,
};

/// Single voice in a GENMIDI instrument
pub const GenmidiVoice = extern struct {
    /// Modulator operator parameters
    modulator: Opl2Registers,
    /// Carrier operator parameters
    carrier: Opl2Registers,
    /// Feedback/connection byte (bits 0-3: feedback, bit 4: connection)
    feedback_conn: u8,
    /// Base note offset for percussion
    base_note: u8,
    /// Padding
    _pad: [2]u8,
};

/// GENMIDI instrument definition
pub const GenmidiInstrument = extern struct {
    /// Instrument flags
    /// Bit 0: Fixed pitch (percussion)
    /// Bit 1-3: Feedback level
    /// Bit 4: Use second voice
    flags: u16,
    /// Fine tuning (-128 to +127 cents)
    fine_tuning: u8,
    /// Fixed note (for percussion)
    fixed_note: u8,
    /// Two voices (for dual-voice instruments)
    voices: [2]GenmidiVoice,
};

/// GENMIDI lump header signature
const GENMIDI_SIGNATURE: *const [8]u8 = "#OPL_II#";

/// Size of GENMIDI header
const HEADER_SIZE: usize = 8;

/// Number of melodic instruments
pub const NUM_INSTRUMENTS: usize = 128;

/// Number of percussion instruments (MIDI notes 35-81)
pub const NUM_PERCUSSION: usize = 47;

/// Total size of GENMIDI lump
pub const GENMIDI_SIZE: usize = HEADER_SIZE +
    (NUM_INSTRUMENTS * @sizeOf(GenmidiInstrument)) +
    (NUM_PERCUSSION * @sizeOf(GenmidiInstrument));

/// External WAD functions (linked from Doom)
extern fn W_GetNumForName(name: [*:0]const u8) c_int;
extern fn W_CacheLumpNum(lumpnum: c_int, tag: c_int) ?*anyopaque;
extern fn W_ReleaseLumpNum(lumpnum: c_int) void;
extern fn W_LumpLength(lump: c_uint) c_int;

/// Memory zone tags
const PU_STATIC: c_int = 1;

/// Load GENMIDI instruments from WAD
/// Returns true on success
pub fn loadGenmidi(instruments: []GenmidiInstrument, percussion: []GenmidiInstrument) bool {
    // Find GENMIDI lump
    const lump_num = W_GetNumForName("GENMIDI");
    if (lump_num < 0) {
        return false;
    }

    // Check lump size
    const lump_len = W_LumpLength(@intCast(lump_num));
    if (lump_len < @as(c_int, @intCast(GENMIDI_SIZE))) {
        return false;
    }

    // Load lump data
    const data_ptr = W_CacheLumpNum(lump_num, PU_STATIC) orelse return false;
    const data: [*]const u8 = @ptrCast(data_ptr);

    // Validate signature
    if (!std.mem.eql(u8, data[0..8], GENMIDI_SIGNATURE)) {
        W_ReleaseLumpNum(lump_num);
        return false;
    }

    // Copy instruments
    const inst_data: [*]const GenmidiInstrument = @ptrCast(@alignCast(data + HEADER_SIZE));
    const inst_count = @min(instruments.len, NUM_INSTRUMENTS);
    for (0..inst_count) |i| {
        instruments[i] = inst_data[i];
    }

    // Copy percussion (starts after melodic instruments)
    const perc_data: [*]const GenmidiInstrument = @ptrCast(@alignCast(data + HEADER_SIZE + (NUM_INSTRUMENTS * @sizeOf(GenmidiInstrument))));
    const perc_count = @min(percussion.len, NUM_PERCUSSION);
    for (0..perc_count) |i| {
        percussion[i] = perc_data[i];
    }

    // Release lump (we've copied the data)
    W_ReleaseLumpNum(lump_num);

    return true;
}

/// Check if GENMIDI lump exists in WAD
pub fn hasGenmidi() bool {
    return W_GetNumForName("GENMIDI") >= 0;
}

/// Debug: print instrument info
pub fn debugPrintInstrument(inst: *const GenmidiInstrument, index: usize) void {
    _ = index;
    _ = inst;
    // Placeholder for debug output
}

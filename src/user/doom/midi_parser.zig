//! MIDI File Parser for Doom Music Playback
//!
//! Parses Standard MIDI File format (SMF) into MidiTrack structures.
//! Supports Type 0 (single track) which is what mus2mid produces.

const std = @import("std");
const midi = @import("midi.zig");

const MidiEvent = midi.MidiEvent;
const MidiTrack = midi.MidiTrack;
const MidiHeader = midi.MidiHeader;
const EventType = midi.EventType;
const MetaType = midi.MetaType;

/// Parser error types
pub const ParseError = error{
    InvalidHeader,
    InvalidChunk,
    UnexpectedEndOfData,
    TooManyEvents,
    InvalidVariableLength,
    UnsupportedFormat,
};

/// Parse a MIDI file from raw bytes into a MidiTrack
/// Returns null on parse failure
pub fn parseMidi(data: []const u8, events_buffer: []MidiEvent) ?MidiTrack {
    var parser = Parser.init(data);

    // Parse header chunk "MThd"
    const header = parser.parseHeader() catch return null;

    // We only support format 0 (single track) from mus2mid
    if (header.format != 0 and header.format != 1) return null;

    // Initialize track with ticks per beat from header
    var track = MidiTrack.init(events_buffer, header.ticksPerBeat());

    // Parse track chunk "MTrk"
    parser.parseTrack(&track) catch return null;

    // Reset to beginning for playback
    track.reset();

    return track;
}

/// Internal parser state
const Parser = struct {
    data: []const u8,
    pos: usize,
    running_status: u8,

    fn init(data: []const u8) Parser {
        return .{
            .data = data,
            .pos = 0,
            .running_status = 0,
        };
    }

    /// Read a single byte
    fn readByte(self: *Parser) ParseError!u8 {
        if (self.pos >= self.data.len) return ParseError.UnexpectedEndOfData;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    /// Read a big-endian u16
    fn readU16(self: *Parser) ParseError!u16 {
        if (self.pos + 2 > self.data.len) return ParseError.UnexpectedEndOfData;
        const result = std.mem.readInt(u16, self.data[self.pos..][0..2], .big);
        self.pos += 2;
        return result;
    }

    /// Read a big-endian u32
    fn readU32(self: *Parser) ParseError!u32 {
        if (self.pos + 4 > self.data.len) return ParseError.UnexpectedEndOfData;
        const result = std.mem.readInt(u32, self.data[self.pos..][0..4], .big);
        self.pos += 4;
        return result;
    }

    /// Read MIDI variable-length quantity
    fn readVarLen(self: *Parser) ParseError!u32 {
        var result: u32 = 0;
        var count: u8 = 0;

        while (count < 4) {
            const b = try self.readByte();
            result = (result << 7) | @as(u32, b & 0x7F);
            if ((b & 0x80) == 0) return result;
            count += 1;
        }

        return ParseError.InvalidVariableLength;
    }

    /// Skip n bytes
    fn skip(self: *Parser, n: usize) ParseError!void {
        if (self.pos + n > self.data.len) return ParseError.UnexpectedEndOfData;
        self.pos += n;
    }

    /// Check if 4 bytes match expected chunk ID
    fn checkChunkId(self: *Parser, expected: *const [4]u8) ParseError!void {
        if (self.pos + 4 > self.data.len) return ParseError.UnexpectedEndOfData;
        if (!std.mem.eql(u8, self.data[self.pos..][0..4], expected)) {
            return ParseError.InvalidChunk;
        }
        self.pos += 4;
    }

    /// Parse MIDI header chunk
    fn parseHeader(self: *Parser) ParseError!MidiHeader {
        // Check "MThd" signature
        try self.checkChunkId("MThd");

        // Header length (always 6)
        const length = try self.readU32();
        if (length != 6) return ParseError.InvalidHeader;

        // Format, tracks, division
        const format = try self.readU16();
        const num_tracks = try self.readU16();
        const division = try self.readU16();

        return MidiHeader{
            .format = format,
            .num_tracks = num_tracks,
            .division = division,
        };
    }

    /// Parse a single MIDI track chunk
    fn parseTrack(self: *Parser, track: *MidiTrack) ParseError!void {
        // Check "MTrk" signature
        try self.checkChunkId("MTrk");

        // Track length
        const length = try self.readU32();
        const track_end = self.pos + length;

        // Parse events until end of track
        while (self.pos < track_end) {
            // Read delta time
            const delta = try self.readVarLen();

            // Read status byte (or use running status)
            var status = try self.readByte();

            // Handle running status
            if ((status & 0x80) == 0) {
                // Data byte - use running status
                self.pos -= 1; // Put back the byte
                status = self.running_status;
            } else {
                // New status byte
                if (status < 0xF0) {
                    self.running_status = status;
                }
            }

            // Parse event based on status
            const event_type: EventType = @enumFromInt(@as(u4, @truncate(status >> 4)));
            const channel: u4 = @truncate(status & 0x0F);

            switch (event_type) {
                .note_off => {
                    const key: u7 = @truncate(try self.readByte());
                    _ = try self.readByte(); // velocity (ignored for note off)
                    if (!track.addEvent(MidiEvent.noteOff(delta, channel, key))) {
                        return ParseError.TooManyEvents;
                    }
                },
                .note_on => {
                    const key: u7 = @truncate(try self.readByte());
                    const velocity: u7 = @truncate(try self.readByte());
                    // Note: velocity 0 is note off
                    if (velocity == 0) {
                        if (!track.addEvent(MidiEvent.noteOff(delta, channel, key))) {
                            return ParseError.TooManyEvents;
                        }
                    } else {
                        if (!track.addEvent(MidiEvent.noteOn(delta, channel, key, velocity))) {
                            return ParseError.TooManyEvents;
                        }
                    }
                },
                .key_pressure => {
                    _ = try self.readByte(); // key
                    _ = try self.readByte(); // pressure
                    // Ignore - not used by Doom music
                },
                .controller => {
                    const number: u7 = @truncate(try self.readByte());
                    const value: u7 = @truncate(try self.readByte());
                    if (!track.addEvent(MidiEvent.controllerChange(delta, channel, number, value))) {
                        return ParseError.TooManyEvents;
                    }
                },
                .program_change => {
                    const program: u7 = @truncate(try self.readByte());
                    if (!track.addEvent(MidiEvent.programChange(delta, channel, program))) {
                        return ParseError.TooManyEvents;
                    }
                },
                .channel_pressure => {
                    _ = try self.readByte(); // pressure
                    // Ignore - not used by Doom music
                },
                .pitch_bend => {
                    const lsb = try self.readByte();
                    const msb = try self.readByte();
                    // Pitch bend is 14-bit value centered at 0x2000 (8192)
                    // raw: 0-16383, bend: -8192 to 8191
                    const raw: u16 = (@as(u16, msb) << 7) | @as(u16, lsb);
                    const bend: i14 = @intCast(@as(i32, raw) - 8192);
                    if (!track.addEvent(MidiEvent.pitchBend(delta, channel, bend))) {
                        return ParseError.TooManyEvents;
                    }
                },
                .system => {
                    // System messages and meta events
                    if (status == 0xFF) {
                        // Meta event
                        const meta_type: MetaType = @enumFromInt(try self.readByte());
                        const meta_len = try self.readVarLen();

                        switch (meta_type) {
                            .tempo => {
                                if (meta_len == 3) {
                                    const b1 = try self.readByte();
                                    const b2 = try self.readByte();
                                    const b3 = try self.readByte();
                                    track.tempo_us_per_beat = (@as(u32, b1) << 16) |
                                        (@as(u32, b2) << 8) |
                                        @as(u32, b3);
                                } else {
                                    try self.skip(meta_len);
                                }
                            },
                            .end_of_track => {
                                // End of track marker
                                return;
                            },
                            else => {
                                // Skip other meta events
                                try self.skip(meta_len);
                            },
                        }
                    } else if (status == 0xF0 or status == 0xF7) {
                        // SysEx - skip
                        const sysex_len = try self.readVarLen();
                        try self.skip(sysex_len);
                    } else {
                        // Other system messages - skip based on type
                        // Most are 0 or 1 byte
                        switch (status) {
                            0xF1, 0xF3 => try self.skip(1),
                            0xF2 => try self.skip(2),
                            else => {},
                        }
                    }
                },
            }
        }
    }
};

/// Validate MIDI data without fully parsing
pub fn validateMidi(data: []const u8) bool {
    if (data.len < 14) return false; // Minimum: header chunk

    // Check MThd signature
    if (!std.mem.eql(u8, data[0..4], "MThd")) return false;

    // Check header length
    const header_len = std.mem.readInt(u32, data[4..8], .big);
    if (header_len != 6) return false;

    return true;
}

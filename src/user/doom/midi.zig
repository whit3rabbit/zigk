//! MIDI Data Structures for Doom Music Playback
//!
//! Defines the core structures for MIDI event representation and track storage.
//! Used by the sequencer to play back music converted from Doom's MUS format.

const std = @import("std");

/// MIDI event types (status byte high nibble)
pub const EventType = enum(u4) {
    note_off = 0x8,
    note_on = 0x9,
    key_pressure = 0xA,
    controller = 0xB,
    program_change = 0xC,
    channel_pressure = 0xD,
    pitch_bend = 0xE,
    system = 0xF,
};

/// Common MIDI controller numbers
pub const Controller = enum(u7) {
    bank_select = 0,
    modulation = 1,
    volume = 7,
    pan = 10,
    expression = 11,
    sustain = 64,
    all_sound_off = 120,
    reset_all = 121,
    all_notes_off = 123,
    _,
};

/// Meta event types (for track metadata)
pub const MetaType = enum(u8) {
    sequence_number = 0x00,
    text = 0x01,
    copyright = 0x02,
    track_name = 0x03,
    instrument_name = 0x04,
    lyric = 0x05,
    marker = 0x06,
    cue_point = 0x07,
    channel_prefix = 0x20,
    end_of_track = 0x2F,
    tempo = 0x51,
    smpte_offset = 0x54,
    time_signature = 0x58,
    key_signature = 0x59,
    _,
};

/// A single MIDI event
pub const MidiEvent = struct {
    /// Delta time in ticks since previous event
    delta_ticks: u32,
    /// Event type (from status byte)
    event_type: EventType,
    /// MIDI channel (0-15)
    channel: u4,
    /// Event-specific data
    data: EventData,

    pub const EventData = union {
        /// note_on, note_off, key_pressure
        note: struct {
            key: u7,
            velocity: u7,
        },
        /// controller change
        controller: struct {
            number: u7,
            value: u7,
        },
        /// program change
        program: u7,
        /// channel pressure (aftertouch)
        pressure: u7,
        /// pitch bend (-8192 to +8191)
        pitch_bend: i14,
        /// meta event (tempo, end of track, etc.)
        meta: struct {
            meta_type: MetaType,
            /// Length of meta data (data stored separately)
            length: u32,
        },
        /// System exclusive (not used for Doom)
        sysex: void,
    };

    /// Create a note-on event
    pub fn noteOn(delta: u32, channel: u4, key: u7, velocity: u7) MidiEvent {
        return .{
            .delta_ticks = delta,
            .event_type = .note_on,
            .channel = channel,
            .data = .{ .note = .{ .key = key, .velocity = velocity } },
        };
    }

    /// Create a note-off event
    pub fn noteOff(delta: u32, channel: u4, key: u7) MidiEvent {
        return .{
            .delta_ticks = delta,
            .event_type = .note_off,
            .channel = channel,
            .data = .{ .note = .{ .key = key, .velocity = 0 } },
        };
    }

    /// Create a program change event
    pub fn programChange(delta: u32, channel: u4, program: u7) MidiEvent {
        return .{
            .delta_ticks = delta,
            .event_type = .program_change,
            .channel = channel,
            .data = .{ .program = program },
        };
    }

    /// Create a controller change event
    pub fn controllerChange(delta: u32, channel: u4, number: u7, value: u7) MidiEvent {
        return .{
            .delta_ticks = delta,
            .event_type = .controller,
            .channel = channel,
            .data = .{ .controller = .{ .number = number, .value = value } },
        };
    }

    /// Create a pitch bend event
    pub fn pitchBend(delta: u32, channel: u4, bend: i14) MidiEvent {
        return .{
            .delta_ticks = delta,
            .event_type = .pitch_bend,
            .channel = channel,
            .data = .{ .pitch_bend = bend },
        };
    }
};

/// A parsed MIDI track containing a sequence of events
pub const MidiTrack = struct {
    /// Array of events in chronological order
    events: []MidiEvent,
    /// Number of valid events
    event_count: usize,
    /// Current playback position
    current_event: usize,
    /// Ticks remaining until next event fires
    ticks_remaining: u32,
    /// Ticks per quarter note (from MIDI header)
    ticks_per_beat: u16,
    /// Tempo in microseconds per quarter note (default 500000 = 120 BPM)
    tempo_us_per_beat: u32,

    /// Initialize an empty track
    pub fn init(events_buffer: []MidiEvent, ticks_per_beat: u16) MidiTrack {
        return .{
            .events = events_buffer,
            .event_count = 0,
            .current_event = 0,
            .ticks_remaining = 0,
            .ticks_per_beat = ticks_per_beat,
            .tempo_us_per_beat = 500000, // 120 BPM default
        };
    }

    /// Reset playback position to beginning
    pub fn reset(self: *MidiTrack) void {
        self.current_event = 0;
        self.ticks_remaining = if (self.event_count > 0)
            self.events[0].delta_ticks
        else
            0;
    }

    /// Add an event to the track
    pub fn addEvent(self: *MidiTrack, event: MidiEvent) bool {
        if (self.event_count >= self.events.len) return false;
        self.events[self.event_count] = event;
        self.event_count += 1;
        return true;
    }

    /// Check if playback has reached the end
    pub fn isFinished(self: *const MidiTrack) bool {
        return self.current_event >= self.event_count;
    }

    /// Get current event without advancing
    pub fn peekEvent(self: *const MidiTrack) ?*const MidiEvent {
        if (self.current_event >= self.event_count) return null;
        return &self.events[self.current_event];
    }

    /// Calculate samples per tick at given sample rate
    pub fn samplesPerTick(self: *const MidiTrack, sample_rate: u32) u32 {
        // samples_per_tick = (tempo_us_per_beat / ticks_per_beat) * sample_rate / 1_000_000
        // Rearrange to avoid overflow: (tempo_us * sample_rate) / (ticks * 1_000_000)
        const tempo: u64 = self.tempo_us_per_beat;
        const rate: u64 = sample_rate;
        const ticks: u64 = self.ticks_per_beat;
        return @intCast((tempo * rate) / (ticks * 1_000_000));
    }
};

/// MIDI file header information
pub const MidiHeader = struct {
    /// Format type (0 = single track, 1 = multi-track sync, 2 = multi-track async)
    format: u16,
    /// Number of tracks
    num_tracks: u16,
    /// Ticks per quarter note (if positive) or SMPTE timing (if negative)
    division: u16,

    /// Check if using SMPTE timing (not typically used by Doom)
    pub fn isSmpte(self: *const MidiHeader) bool {
        return (self.division & 0x8000) != 0;
    }

    /// Get ticks per beat (only valid if not SMPTE)
    pub fn ticksPerBeat(self: *const MidiHeader) u16 {
        if (self.isSmpte()) return 96; // Default fallback
        return self.division;
    }
};

/// Maximum events per track (memory budget ~50KB for events)
pub const MAX_EVENTS_PER_TRACK: usize = 4096;

/// Maximum tracks (Doom typically uses single-track MIDI)
pub const MAX_TRACKS: usize = 1;

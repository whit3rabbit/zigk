//! MIDI Sequencer for Doom Music Playback
//!
//! Handles tick-based timing and dispatches MIDI events to the synthesizer.
//! Runs at audio sample rate (48000 Hz) for sample-accurate timing.

const std = @import("std");
const midi = @import("midi.zig");
const opl3 = @import("opl3.zig");

const MidiEvent = midi.MidiEvent;
const MidiTrack = midi.MidiTrack;
const EventType = midi.EventType;
const Controller = midi.Controller;
const Opl3Synth = opl3.Opl3Synth;

/// MIDI sequencer state
pub const Sequencer = struct {
    /// Currently loaded track (null if none)
    track: ?*MidiTrack,

    /// Playback state
    playing: bool,
    paused: bool,
    looping: bool,

    /// Timing
    sample_rate: u32,
    samples_per_tick: u32,
    sample_accumulator: u32,

    /// Per-channel state for controllers
    channel_volume: [16]u8,
    channel_pan: [16]u8,
    channel_program: [16]u8,
    channel_pitch_bend: [16]i14,

    /// Initialize sequencer with given sample rate
    pub fn init(sample_rate: u32) Sequencer {
        const seq = Sequencer{
            .track = null,
            .playing = false,
            .paused = false,
            .looping = false,
            .sample_rate = sample_rate,
            .samples_per_tick = 0,
            .sample_accumulator = 0,
            .channel_volume = [_]u8{100} ** 16,
            .channel_pan = [_]u8{64} ** 16, // Center
            .channel_program = [_]u8{0} ** 16,
            .channel_pitch_bend = [_]i14{0} ** 16,
        };
        return seq;
    }

    /// Load a track for playback
    pub fn loadTrack(self: *Sequencer, track: *MidiTrack) void {
        self.track = track;
        self.playing = false;
        self.paused = false;

        // Calculate samples per tick based on track tempo
        self.updateTiming();

        // Reset track to beginning
        track.reset();

        // Reset channel state
        self.resetChannels();
    }

    /// Start or resume playback
    pub fn play(self: *Sequencer, loop: bool) void {
        if (self.track == null) return;

        self.looping = loop;
        self.paused = false;
        self.playing = true;
    }

    /// Stop playback
    pub fn stop(self: *Sequencer, synth: *Opl3Synth) void {
        self.playing = false;
        self.paused = false;

        // Send all notes off to synth
        synth.allNotesOff();
    }

    /// Pause playback
    pub fn pause(self: *Sequencer) void {
        self.paused = true;
    }

    /// Resume from pause
    pub fn resumePlayback(self: *Sequencer) void {
        self.paused = false;
    }

    /// Check if currently playing
    pub fn isPlaying(self: *const Sequencer) bool {
        return self.playing and !self.paused;
    }

    /// Process one audio sample worth of MIDI events
    /// Call this once per output sample (e.g., 48000 times per second)
    pub fn processSample(self: *Sequencer, synth: *Opl3Synth) void {
        if (!self.playing or self.paused) return;

        const track = self.track orelse return;

        // Accumulate samples
        self.sample_accumulator += 1;

        // Process ticks
        while (self.sample_accumulator >= self.samples_per_tick) {
            self.sample_accumulator -= self.samples_per_tick;
            self.processTick(track, synth);

            // Check if track finished
            if (track.isFinished()) {
                if (self.looping) {
                    track.reset();
                    self.resetChannels();
                } else {
                    self.playing = false;
                    synth.allNotesOff();
                    return;
                }
            }
        }
    }

    /// Process one MIDI tick
    fn processTick(self: *Sequencer, track: *MidiTrack, synth: *Opl3Synth) void {
        // Decrement ticks remaining
        if (track.ticks_remaining > 0) {
            track.ticks_remaining -= 1;
            return;
        }

        // Process all events at current tick (delta = 0 after first)
        while (!track.isFinished()) {
            const event = track.peekEvent() orelse break;

            if (event.delta_ticks > 0 and track.current_event > 0) {
                // Wait for delta ticks
                track.ticks_remaining = event.delta_ticks - 1;
                track.current_event += 1;
                return;
            }

            // Dispatch event
            self.dispatchEvent(event, synth);

            // If this was first event with delta, start counting
            if (track.current_event == 0 and event.delta_ticks > 0) {
                track.ticks_remaining = event.delta_ticks - 1;
                track.current_event += 1;
                return;
            }

            track.current_event += 1;

            // Check next event's delta
            if (track.peekEvent()) |next| {
                if (next.delta_ticks > 0) {
                    track.ticks_remaining = next.delta_ticks - 1;
                    track.current_event += 1;
                    return;
                }
            }
        }
    }

    /// Dispatch a single MIDI event to the synthesizer
    fn dispatchEvent(self: *Sequencer, event: *const MidiEvent, synth: *Opl3Synth) void {
        const ch = event.channel;

        switch (event.event_type) {
            .note_on => {
                const note = event.data.note;
                const program: u7 = @truncate(self.channel_program[ch]);
                synth.noteOn(ch, note.key, note.velocity, program);
            },
            .note_off => {
                const note = event.data.note;
                synth.noteOff(ch, note.key);
            },
            .program_change => {
                self.channel_program[ch] = event.data.program;
            },
            .controller => {
                const ctrl = event.data.controller;
                self.handleController(ch, ctrl.number, ctrl.value, synth);
            },
            .pitch_bend => {
                self.channel_pitch_bend[ch] = event.data.pitch_bend;
                synth.pitchBend(ch, event.data.pitch_bend);
            },
            .key_pressure, .channel_pressure => {
                // Ignore pressure events
            },
            .system => {
                // Meta events handled during parsing (tempo changes)
            },
        }
    }

    /// Handle controller change
    fn handleController(self: *Sequencer, channel: u4, number: u7, value: u7, synth: *Opl3Synth) void {
        const ctrl: Controller = @enumFromInt(number);

        switch (ctrl) {
            .volume => {
                self.channel_volume[channel] = value;
                synth.setChannelVolume(channel, value);
            },
            .pan => {
                self.channel_pan[channel] = value;
                synth.setChannelPan(channel, value);
            },
            .modulation => {
                synth.setModulation(channel, value);
            },
            .expression => {
                // Expression is secondary volume control
                synth.setExpression(channel, value);
            },
            .sustain => {
                synth.setSustain(channel, value >= 64);
            },
            .all_notes_off, .all_sound_off => {
                synth.channelNotesOff(channel);
            },
            .reset_all => {
                self.resetChannel(channel);
                synth.channelReset(channel);
            },
            else => {
                // Ignore other controllers
            },
        }
    }

    /// Update timing calculations when tempo changes
    fn updateTiming(self: *Sequencer) void {
        if (self.track) |track| {
            self.samples_per_tick = track.samplesPerTick(self.sample_rate);
            // Minimum 1 sample per tick to prevent infinite loops
            if (self.samples_per_tick == 0) self.samples_per_tick = 1;
        }
    }

    /// Reset all channel state to defaults
    fn resetChannels(self: *Sequencer) void {
        for (0..16) |i| {
            self.resetChannel(@intCast(i));
        }
    }

    /// Reset a single channel to defaults
    fn resetChannel(self: *Sequencer, channel: u4) void {
        self.channel_volume[channel] = 100;
        self.channel_pan[channel] = 64;
        self.channel_program[channel] = 0;
        self.channel_pitch_bend[channel] = 0;
    }
};

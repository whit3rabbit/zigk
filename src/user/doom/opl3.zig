//! OPL3 FM Synthesizer Emulator for Doom Music
//!
//! Emulates the Yamaha YMF262 (OPL3) FM synthesis chip used by Doom for music.
//! Uses GENMIDI instrument definitions from the WAD file.
//!
//! This is a simplified emulation focused on Doom music playback rather than
//! cycle-accurate hardware emulation.

const std = @import("std");
const genmidi = @import("genmidi.zig");

const GenmidiInstrument = genmidi.GenmidiInstrument;
const GenmidiVoice = genmidi.GenmidiVoice;
const Opl2Registers = genmidi.Opl2Registers;

/// Number of OPL3 channels (2-operator mode)
pub const NUM_CHANNELS: usize = 18;

/// Maximum voices for polyphony
pub const MAX_VOICES: usize = NUM_CHANNELS;

/// Sample rate for synthesis
pub const SAMPLE_RATE: u32 = 48000;

/// OPL3 internal sample rate
const OPL_RATE: u32 = 49716;

/// Envelope states
const EnvelopeState = enum {
    off,
    attack,
    decay,
    sustain,
    release,
};

/// Waveform types (OPL3 supports 8, OPL2 supports 4)
const Waveform = enum(u3) {
    sine = 0,
    half_sine = 1,
    abs_sine = 2,
    pulse_sine = 3,
    sine_even = 4,
    abs_sine_even = 5,
    square = 6,
    derived_square = 7,
};

/// Single FM operator
const Operator = struct {
    /// Envelope generator state
    env_state: EnvelopeState,
    /// Current envelope level (0 = max, 127 = min)
    env_level: u16,
    /// Phase accumulator (fixed point)
    phase: u32,
    /// Phase increment per sample
    phase_inc: u32,

    /// OPL register parameters
    attack_rate: u4,
    decay_rate: u4,
    sustain_level: u4,
    release_rate: u4,
    total_level: u6,
    key_scale_level: u2,
    multiple: u4,
    waveform: Waveform,
    tremolo: bool,
    vibrato: bool,
    sustain_flag: bool,
    key_scale_rate: bool,

    /// Initialize operator with default values
    fn init() Operator {
        return .{
            .env_state = .off,
            .env_level = 511, // Maximum attenuation
            .phase = 0,
            .phase_inc = 0,
            .attack_rate = 0,
            .decay_rate = 0,
            .sustain_level = 0,
            .release_rate = 0,
            .total_level = 63,
            .key_scale_level = 0,
            .multiple = 1,
            .waveform = .sine,
            .tremolo = false,
            .vibrato = false,
            .sustain_flag = false,
            .key_scale_rate = false,
        };
    }

    /// Key on - start envelope attack
    fn keyOn(self: *Operator) void {
        self.env_state = .attack;
        self.env_level = 511;
        self.phase = 0;
    }

    /// Key off - start envelope release
    fn keyOff(self: *Operator) void {
        if (self.env_state != .off) {
            self.env_state = .release;
        }
    }

    /// Generate one sample from this operator
    fn generate(self: *Operator, modulation: i32) i32 {
        if (self.env_state == .off) return 0;

        // Update envelope
        self.updateEnvelope();

        // Calculate phase with modulation
        const phase_with_mod = self.phase +% @as(u32, @bitCast(modulation << 10));

        // Get waveform sample
        const wave_sample = self.getWaveform(phase_with_mod >> 22);

        // Apply envelope attenuation
        const env_atten = @as(i32, self.env_level) + @as(i32, self.total_level) * 4;
        const atten = @min(env_atten, 511);

        // Attenuate sample (exponential)
        const output = (wave_sample * getAttenuation(atten)) >> 15;

        // Advance phase
        self.phase +%= self.phase_inc;

        return output;
    }

    /// Update envelope generator
    fn updateEnvelope(self: *Operator) void {
        switch (self.env_state) {
            .off => {},
            .attack => {
                // Attack phase - exponential rise
                const rate = getEnvelopeRate(self.attack_rate);
                if (rate > 0) {
                    if (self.env_level > rate) {
                        self.env_level -= rate;
                    } else {
                        self.env_level = 0;
                        self.env_state = .decay;
                    }
                }
            },
            .decay => {
                // Decay phase - linear fall to sustain level
                const rate = getEnvelopeRate(self.decay_rate);
                const sustain_target = @as(u16, self.sustain_level) * 32;
                if (self.env_level < sustain_target) {
                    self.env_level += rate;
                    if (self.env_level >= sustain_target) {
                        self.env_level = sustain_target;
                        self.env_state = .sustain;
                    }
                } else {
                    self.env_state = .sustain;
                }
            },
            .sustain => {
                // Sustain - hold level (or decay if no sustain flag)
                if (!self.sustain_flag) {
                    const rate = getEnvelopeRate(self.release_rate);
                    if (self.env_level < 511) {
                        self.env_level += rate;
                        if (self.env_level >= 511) {
                            self.env_level = 511;
                            self.env_state = .off;
                        }
                    }
                }
            },
            .release => {
                // Release phase - fall to silence
                const rate = getEnvelopeRate(self.release_rate);
                if (self.env_level < 511) {
                    self.env_level += rate;
                    if (self.env_level >= 511) {
                        self.env_level = 511;
                        self.env_state = .off;
                    }
                }
            },
        }
    }

    /// Get waveform sample for given phase (0-1023)
    fn getWaveform(self: *const Operator, phase_index: u32) i32 {
        const idx: usize = @intCast(phase_index & 0x3FF);

        return switch (self.waveform) {
            .sine => getSineTable(idx),
            .half_sine => if (idx < 512) getSineTable(idx) else 0,
            .abs_sine => getSineTable(idx & 0x1FF),
            .pulse_sine => if ((idx & 0x100) == 0) getSineTable(idx & 0xFF) else 0,
            .sine_even => getSineTable((idx * 2) & 0x3FF),
            .abs_sine_even => getSineTable((idx * 2) & 0x1FF),
            .square => if (idx < 512) 16384 else -16384,
            .derived_square => if ((idx & 0x100) == 0)
                (if (idx < 256) 16384 else -16384)
            else
                0,
        };
    }

    /// Load parameters from GENMIDI voice data
    fn loadFromGenmidi(self: *Operator, regs: Opl2Registers) void {
        // 0x20 register: tremolo, vibrato, sustain, KSR, multiple
        self.tremolo = (regs.tremolo_vibrato & 0x80) != 0;
        self.vibrato = (regs.tremolo_vibrato & 0x40) != 0;
        self.sustain_flag = (regs.tremolo_vibrato & 0x20) != 0;
        self.key_scale_rate = (regs.tremolo_vibrato & 0x10) != 0;
        self.multiple = @truncate(regs.tremolo_vibrato & 0x0F);

        // 0x40 register: key scale level, total level
        self.key_scale_level = @truncate((regs.key_scale_output >> 6) & 0x03);
        self.total_level = @truncate(regs.key_scale_output & 0x3F);

        // 0x60 register: attack rate, decay rate
        self.attack_rate = @truncate((regs.attack_decay >> 4) & 0x0F);
        self.decay_rate = @truncate(regs.attack_decay & 0x0F);

        // 0x80 register: sustain level, release rate
        self.sustain_level = @truncate((regs.sustain_release >> 4) & 0x0F);
        self.release_rate = @truncate(regs.sustain_release & 0x0F);

        // 0xE0 register: waveform
        self.waveform = @enumFromInt(@as(u3, @truncate(regs.wave_select & 0x07)));
    }
};

/// Voice allocation entry
const Voice = struct {
    /// MIDI channel this voice is assigned to
    midi_channel: u4,
    /// MIDI note number
    note: u7,
    /// Velocity
    velocity: u7,
    /// Is voice active
    active: bool,
    /// Age counter for LRU replacement
    age: u32,

    /// Carrier and modulator operators
    carrier: Operator,
    modulator: Operator,

    /// Feedback level (0-7)
    feedback: u3,
    /// Connection type (0 = FM, 1 = additive)
    connection: u1,

    /// Previous modulator output for feedback
    feedback_buf: [2]i32,

    fn init() Voice {
        return .{
            .midi_channel = 0,
            .note = 0,
            .velocity = 0,
            .active = false,
            .age = 0,
            .carrier = Operator.init(),
            .modulator = Operator.init(),
            .feedback = 0,
            .connection = 0,
            .feedback_buf = .{ 0, 0 },
        };
    }

    /// Generate one stereo sample from this voice
    fn generate(self: *Voice) i32 {
        if (!self.active) return 0;

        // Calculate feedback modulation
        var fb_mod: i32 = 0;
        if (self.feedback > 0) {
            fb_mod = (self.feedback_buf[0] + self.feedback_buf[1]) >> (8 - @as(u4, self.feedback));
        }

        // Generate modulator
        const mod_out = self.modulator.generate(fb_mod);

        // Update feedback buffer
        self.feedback_buf[1] = self.feedback_buf[0];
        self.feedback_buf[0] = mod_out;

        // Generate carrier with modulation
        const carrier_out = if (self.connection == 0)
            self.carrier.generate(mod_out) // FM mode
        else
            self.carrier.generate(0) + mod_out; // Additive mode

        // Check if voice finished
        if (self.carrier.env_state == .off and self.modulator.env_state == .off) {
            self.active = false;
        }

        return carrier_out;
    }

    /// Key on this voice
    fn keyOn(self: *Voice) void {
        self.active = true;
        self.carrier.keyOn();
        self.modulator.keyOn();
        self.feedback_buf = .{ 0, 0 };
    }

    /// Key off this voice
    fn keyOff(self: *Voice) void {
        self.carrier.keyOff();
        self.modulator.keyOff();
    }

    /// Set frequency based on MIDI note
    fn setFrequency(self: *Voice, note: u7, pitch_bend: i14) void {
        // Calculate frequency from MIDI note with pitch bend
        const base_freq = midiNoteToFreq(note, pitch_bend);

        // Calculate phase increment for carrier and modulator
        // phase_inc = freq * 2^32 / sample_rate
        const mult_c: u32 = if (self.carrier.multiple == 0) 1 else @as(u32, self.carrier.multiple) * 2;
        const mult_m: u32 = if (self.modulator.multiple == 0) 1 else @as(u32, self.modulator.multiple) * 2;

        self.carrier.phase_inc = @intCast((base_freq * mult_c * (1 << 22)) / SAMPLE_RATE);
        self.modulator.phase_inc = @intCast((base_freq * mult_m * (1 << 22)) / SAMPLE_RATE);
    }
};

/// Main OPL3 synthesizer
pub const Opl3Synth = struct {
    /// Voice pool
    voices: [MAX_VOICES]Voice,

    /// Instrument bank (from GENMIDI)
    instruments: [128]GenmidiInstrument,
    /// Percussion instruments (MIDI notes 35-81)
    percussion: [47]GenmidiInstrument,
    /// Has instruments been loaded
    instruments_loaded: bool,

    /// Global age counter for voice allocation
    age_counter: u32,

    /// Per-channel state
    channel_volume: [16]u8,
    channel_pan: [16]u8,
    channel_expression: [16]u8,
    channel_pitch_bend: [16]i14,
    channel_modulation: [16]u8,
    channel_sustain: [16]bool,

    /// Initialize synthesizer
    pub fn init() Opl3Synth {
        var synth = Opl3Synth{
            .voices = undefined,
            .instruments = undefined,
            .percussion = undefined,
            .instruments_loaded = false,
            .age_counter = 0,
            .channel_volume = [_]u8{100} ** 16,
            .channel_pan = [_]u8{64} ** 16,
            .channel_expression = [_]u8{127} ** 16,
            .channel_pitch_bend = [_]i14{0} ** 16,
            .channel_modulation = [_]u8{0} ** 16,
            .channel_sustain = [_]bool{false} ** 16,
        };

        for (&synth.voices) |*v| {
            v.* = Voice.init();
        }

        return synth;
    }

    /// Load instruments from GENMIDI data
    pub fn loadInstruments(self: *Opl3Synth, inst: []const GenmidiInstrument, perc: []const GenmidiInstrument) void {
        const inst_count = @min(inst.len, 128);
        const perc_count = @min(perc.len, 47);

        for (0..inst_count) |i| {
            self.instruments[i] = inst[i];
        }
        for (0..perc_count) |i| {
            self.percussion[i] = perc[i];
        }

        self.instruments_loaded = true;
    }

    /// Generate one stereo sample
    pub fn generateSample(self: *Opl3Synth) [2]i16 {
        var left: i32 = 0;
        var right: i32 = 0;

        // Mix all active voices
        for (&self.voices) |*voice| {
            if (!voice.active) continue;

            const sample = voice.generate();

            // Apply channel volume and panning
            const ch = voice.midi_channel;
            const vol = @divTrunc(@as(i32, self.channel_volume[ch]) * @as(i32, self.channel_expression[ch]), 127);
            const pan = self.channel_pan[ch];

            const scaled = (sample * vol) >> 7;

            // Simple panning: pan 0 = full left, 64 = center, 127 = full right
            const pan_right = @as(i32, pan) * 2;
            const pan_left = 254 - pan_right;

            left += (scaled * pan_left) >> 8;
            right += (scaled * pan_right) >> 8;
        }

        // Clamp to 16-bit range
        return .{
            @intCast(std.math.clamp(left, -32768, 32767)),
            @intCast(std.math.clamp(right, -32768, 32767)),
        };
    }

    /// Handle note on
    pub fn noteOn(self: *Opl3Synth, channel: u4, note: u7, velocity: u7, program: u7) void {
        if (!self.instruments_loaded) return;
        if (velocity == 0) {
            self.noteOff(channel, note);
            return;
        }

        // Get instrument
        const inst = if (channel == 9)
            self.getPercussion(note)
        else
            &self.instruments[program];

        if (inst == null) return;
        const instrument = inst.?;

        // Allocate voice
        const voice_idx = self.allocateVoice(channel, note);
        var voice = &self.voices[voice_idx];

        // Configure voice from instrument
        voice.midi_channel = channel;
        voice.note = note;
        voice.velocity = velocity;

        // Load operator parameters from first voice in instrument
        voice.modulator.loadFromGenmidi(instrument.voices[0].modulator);
        voice.carrier.loadFromGenmidi(instrument.voices[0].carrier);

        // Feedback and connection from instrument
        voice.feedback = @truncate((instrument.flags >> 1) & 0x07);
        voice.connection = @truncate(instrument.flags & 0x01);

        // Set frequency
        const actual_note: u7 = if (channel == 9)
            @truncate(instrument.voices[0].base_note)
        else
            note;
        voice.setFrequency(actual_note, self.channel_pitch_bend[channel]);

        // Scale total level by velocity
        const vel_scale = @as(u32, velocity) * 2;
        voice.carrier.total_level = @intCast(@min(63, @as(u32, voice.carrier.total_level) + (127 - vel_scale) / 4));

        // Start envelope
        voice.keyOn();
    }

    /// Handle note off
    pub fn noteOff(self: *Opl3Synth, channel: u4, note: u7) void {
        // Find voice playing this note
        for (&self.voices) |*voice| {
            if (voice.active and voice.midi_channel == channel and voice.note == note) {
                if (!self.channel_sustain[channel]) {
                    voice.keyOff();
                }
            }
        }
    }

    /// Handle pitch bend
    pub fn pitchBend(self: *Opl3Synth, channel: u4, bend: i14) void {
        self.channel_pitch_bend[channel] = bend;

        // Update frequency for all voices on this channel
        for (&self.voices) |*voice| {
            if (voice.active and voice.midi_channel == channel) {
                voice.setFrequency(voice.note, bend);
            }
        }
    }

    /// Set channel volume
    pub fn setChannelVolume(self: *Opl3Synth, channel: u4, volume: u7) void {
        self.channel_volume[channel] = volume;
    }

    /// Set channel pan
    pub fn setChannelPan(self: *Opl3Synth, channel: u4, pan: u7) void {
        self.channel_pan[channel] = pan;
    }

    /// Set channel expression
    pub fn setExpression(self: *Opl3Synth, channel: u4, expression: u7) void {
        self.channel_expression[channel] = expression;
    }

    /// Set channel modulation
    pub fn setModulation(self: *Opl3Synth, channel: u4, modulation: u7) void {
        self.channel_modulation[channel] = modulation;
    }

    /// Set sustain pedal
    pub fn setSustain(self: *Opl3Synth, channel: u4, on: bool) void {
        self.channel_sustain[channel] = on;

        // If sustain released, release all held notes
        if (!on) {
            for (&self.voices) |*voice| {
                if (voice.active and voice.midi_channel == channel) {
                    if (voice.carrier.env_state == .sustain or voice.modulator.env_state == .sustain) {
                        voice.keyOff();
                    }
                }
            }
        }
    }

    /// Turn off all notes on a channel
    pub fn channelNotesOff(self: *Opl3Synth, channel: u4) void {
        for (&self.voices) |*voice| {
            if (voice.active and voice.midi_channel == channel) {
                voice.keyOff();
            }
        }
    }

    /// Reset channel to defaults
    pub fn channelReset(self: *Opl3Synth, channel: u4) void {
        self.channel_volume[channel] = 100;
        self.channel_pan[channel] = 64;
        self.channel_expression[channel] = 127;
        self.channel_pitch_bend[channel] = 0;
        self.channel_modulation[channel] = 0;
        self.channel_sustain[channel] = false;
        self.channelNotesOff(channel);
    }

    /// Turn off all notes
    pub fn allNotesOff(self: *Opl3Synth) void {
        for (&self.voices) |*voice| {
            if (voice.active) {
                voice.keyOff();
            }
        }
    }

    /// Allocate a voice for a new note (LRU replacement)
    fn allocateVoice(self: *Opl3Synth, channel: u4, note: u7) usize {
        self.age_counter += 1;

        // First: look for free voice
        for (&self.voices, 0..) |*voice, i| {
            if (!voice.active) {
                voice.age = self.age_counter;
                return i;
            }
        }

        // Second: look for voice on same channel/note (re-trigger)
        for (&self.voices, 0..) |*voice, i| {
            if (voice.midi_channel == channel and voice.note == note) {
                voice.age = self.age_counter;
                return i;
            }
        }

        // Third: steal oldest voice
        var oldest_idx: usize = 0;
        var oldest_age: u32 = self.age_counter;

        for (self.voices, 0..) |voice, i| {
            if (voice.age < oldest_age) {
                oldest_age = voice.age;
                oldest_idx = i;
            }
        }

        self.voices[oldest_idx].age = self.age_counter;
        return oldest_idx;
    }

    /// Get percussion instrument for note
    fn getPercussion(self: *Opl3Synth, note: u7) ?*const GenmidiInstrument {
        if (note < 35 or note > 81) return null;
        return &self.percussion[note - 35];
    }
};

// =============================================================================
// Lookup Tables
// =============================================================================

/// Sine wave table (1024 entries, 16-bit signed)
fn getSineTable(index: usize) i32 {
    // Quarter wave, mirrored
    const quarter = index & 0xFF;
    const half = index & 0x100;
    const sign = index & 0x200;

    // Use simple approximation for quarter sine
    const angle = if (half != 0) 255 - quarter else quarter;
    var value: i32 = @intCast(angle * 64); // Linear approximation scaled

    // Apply parabolic correction for better sine shape
    value = value - ((value * value) >> 12);
    value = value * 2;

    // Apply sign
    return if (sign != 0) -value else value;
}

/// Envelope rate table
fn getEnvelopeRate(rate: u4) u16 {
    const rates = [16]u16{
        0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 16, 20, 28, 40, 64,
    };
    return rates[rate];
}

/// Attenuation table (convert dB to linear)
fn getAttenuation(level: i32) i32 {
    // Simple exponential approximation
    // level 0 = 1.0, level 511 = ~0
    if (level >= 511) return 0;
    if (level <= 0) return 32767;

    // Approximate 10^(-level/40) scaled to 32767
    const shift: u5 = @intCast(@min(31, @as(u32, @intCast(level)) / 32));
    return @as(i32, 32767) >> shift;
}

/// Convert MIDI note to frequency (Hz * 256 for fixed point)
fn midiNoteToFreq(note: u7, pitch_bend: i14) u32 {
    // Base frequency table for octave 0 (C0 to B0) in Hz * 256
    const base_freqs = [12]u32{
        4186, 4435, 4699, 4978, 5274, 5588, // C, C#, D, D#, E, F
        5920, 6272, 6645, 7040, 7459, 7902, // F#, G, G#, A, A#, B
    };

    const semitone = note % 12;
    const octave = note / 12;

    var freq = base_freqs[semitone];

    // Apply octave shift
    if (octave > 0) {
        freq <<= @intCast(octave);
    }

    // Apply pitch bend (+/- 2 semitones = 8192 units)
    if (pitch_bend != 0) {
        // Approximate: multiply by 2^(bend/8192/6)
        const bend_factor: i32 = 256 + @divTrunc(@as(i32, pitch_bend), 32);
        freq = @intCast((@as(u64, freq) * @as(u32, @intCast(@max(1, bend_factor)))) >> 8);
    }

    return freq;
}

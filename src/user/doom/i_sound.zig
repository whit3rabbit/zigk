// Doom Sound System (Zscapek /dev/dsp backend)
//
// Implements Doom's I_* sound API on top of /dev/dsp (AC97).
// Includes OPL3 FM synthesis for music playback.

const std = @import("std");
const syscall = @import("syscall");
const sound_uapi = @import("uapi").sound;

// Music modules
const midi = @import("midi.zig");
const midi_parser = @import("midi_parser.zig");
const sequencer_mod = @import("sequencer.zig");
const opl3 = @import("opl3.zig");
const genmidi = @import("genmidi.zig");

const CBool = c_int;

// -----------------------------------------------------------------------------
// Doom C ABI Types
// -----------------------------------------------------------------------------

const SfxInfo = extern struct {
    tagname: [*c]u8,
    name: [9]u8,
    priority: c_int,
    link: ?*SfxInfo,
    pitch: c_int,
    volume: c_int,
    usefulness: c_int,
    lumpnum: c_int,
    numchannels: c_int,
    driver_data: ?*anyopaque,
};

const SoundModule = extern struct {
    sound_devices: [*]snddevice_t,
    num_sound_devices: c_int,
    init: *const fn (CBool) callconv(.c) CBool,
    shutdown: *const fn () callconv(.c) void,
    get_sfx_lump_num: *const fn (*SfxInfo) callconv(.c) c_int,
    update: *const fn () callconv(.c) void,
    update_sound_params: *const fn (c_int, c_int, c_int) callconv(.c) void,
    start_sound: *const fn (*SfxInfo, c_int, c_int, c_int) callconv(.c) c_int,
    stop_sound: *const fn (c_int) callconv(.c) void,
    sound_is_playing: *const fn (c_int) callconv(.c) CBool,
    cache_sounds: *const fn (?[*]SfxInfo, c_int) callconv(.c) void,
};

const MusicModule = extern struct {
    sound_devices: [*]snddevice_t,
    num_sound_devices: c_int,
    init: *const fn () callconv(.c) CBool,
    shutdown: *const fn () callconv(.c) void,
    set_music_volume: *const fn (c_int) callconv(.c) void,
    pause: *const fn () callconv(.c) void,
    resume_music: *const fn () callconv(.c) void,
    register_song: *const fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque,
    unregister_song: *const fn (?*anyopaque) callconv(.c) void,
    play_song: *const fn (?*anyopaque, CBool) callconv(.c) void,
    stop_song: *const fn () callconv(.c) void,
    music_is_playing: *const fn () callconv(.c) CBool,
    poll: *const fn () callconv(.c) void,
};

// -----------------------------------------------------------------------------
// Doom Config Variables (bound by I_BindSoundVariables)
// -----------------------------------------------------------------------------

pub export var snd_samplerate: c_int = 48000;
pub export var snd_cachesize: c_int = 64 * 1024 * 1024;
pub export var snd_maxslicetime_ms: c_int = 28;
pub export var snd_musicdevice: c_int = SNDDEVICE_SB;
pub export var snd_sfxdevice: c_int = SNDDEVICE_SB;
pub export var snd_sbport: c_int = 0;
pub export var snd_sbirq: c_int = 0;
pub export var snd_sbdma: c_int = 0;
pub export var snd_mport: c_int = 0;

var snd_musiccmd_buf: [1:0]u8 = .{0};
pub export var snd_musiccmd: [*c]u8 = @ptrCast(&snd_musiccmd_buf);

// -----------------------------------------------------------------------------
// Doom Constants
// -----------------------------------------------------------------------------

const snddevice_t = c_int;
const SNDDEVICE_NONE: c_int = 0;
const SNDDEVICE_PCSPEAKER: c_int = 1;
const SNDDEVICE_ADLIB: c_int = 2;
const SNDDEVICE_SB: c_int = 3;
const SNDDEVICE_PAS: c_int = 4;
const SNDDEVICE_GUS: c_int = 5;
const SNDDEVICE_WAVEBLASTER: c_int = 6;
const SNDDEVICE_SOUNDCANVAS: c_int = 7;
const SNDDEVICE_GENMIDI: c_int = 8;
const SNDDEVICE_AWE32: c_int = 9;
const SNDDEVICE_CD: c_int = 10;

const PU_SOUND: c_int = 2;
const PU_STATIC: c_int = 1;

// -----------------------------------------------------------------------------
// External C Functions
// -----------------------------------------------------------------------------

extern fn W_GetNumForName(name: [*:0]const u8) c_int;
extern fn W_LumpLength(lump: c_uint) c_int;
extern fn W_CacheLumpNum(lumpnum: c_int, tag: c_int) ?*anyopaque;
extern fn W_ReleaseLumpNum(lumpnum: c_int) void;
extern fn Z_Malloc(size: c_int, tag: c_int, ptr: ?*anyopaque) ?*anyopaque;
extern fn Z_Free(ptr: ?*anyopaque) void;
extern fn M_BindVariable(name: [*:0]const u8, location: ?*anyopaque) void;
extern fn M_CheckParm(check: [*:0]const u8) c_int;
extern var snd_channels: c_int;

// MUS to MIDI conversion (from doomgeneric/mus2mid.c)
const MEMFILE = opaque {};
extern fn mem_fopen_read(buf: ?*anyopaque, buflen: usize) ?*MEMFILE;
extern fn mem_fopen_write() ?*MEMFILE;
extern fn mem_fclose(stream: ?*MEMFILE) void;
extern fn mem_get_buf(stream: ?*MEMFILE, buf: *?*anyopaque, buflen: *usize) void;
extern fn mus2mid(musinput: ?*MEMFILE, midioutput: ?*MEMFILE) CBool;

// -----------------------------------------------------------------------------
// Internal State
// -----------------------------------------------------------------------------

const SampleFpShift: u32 = 16;
const SampleFpMask: u32 = 0xFFFF;
const BytesPerFrame: usize = 4; // S16_LE stereo

const SfxCache = struct {
    sfx: *SfxInfo,
    lumpnum: c_int,
    sample_rate: u32,
    samples: [*]const u8,
    sample_count: usize,
    data_len: usize,
    refcount: u32,
    lru_prev: ?*SfxCache,
    lru_next: ?*SfxCache,
};

const ChannelState = struct {
    sfx: ?*SfxCache = null,
    pos_fp: u32 = 0,
    step_fp: u32 = 0,
    volume: u8 = 0,
    sep: u8 = 128,
};

var sound_enabled: bool = false;
var use_sfx_prefix: bool = true;
var dsp_fd: c_int = -1;

var channels_ptr: ?[*]ChannelState = null;
var channels_len: usize = 0;

var mix_accum_ptr: ?[*]i32 = null;
var mix_output_ptr: ?[*]i16 = null;
var mix_frames: usize = 0;

var cache_head: ?*SfxCache = null;
var cache_tail: ?*SfxCache = null;
var cache_bytes: usize = 0;

// -----------------------------------------------------------------------------
// Music State
// -----------------------------------------------------------------------------

var music_initialized: bool = false;
var music_volume: u8 = 127;

// OPL3 synthesizer instance
var music_synth: ?*opl3.Opl3Synth = null;

// MIDI sequencer instance
var music_sequencer: ?*sequencer_mod.Sequencer = null;

// Current track (allocated per-song)
var current_track: ?*midi.MidiTrack = null;

// Event buffer for MIDI parsing
var midi_events_buffer: ?[*]midi.MidiEvent = null;

// GENMIDI instrument banks
var genmidi_instruments: [128]genmidi.GenmidiInstrument = undefined;
var genmidi_percussion: [47]genmidi.GenmidiInstrument = undefined;
var genmidi_loaded: bool = false;

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

fn channelsSlice() []ChannelState {
    if (channels_ptr == null or channels_len == 0) return &[_]ChannelState{};
    return channels_ptr.?[0..channels_len];
}

fn mixAccumSlice() []i32 {
    if (mix_accum_ptr == null or mix_frames == 0) return &[_]i32{};
    return mix_accum_ptr.?[0 .. mix_frames * 2];
}

fn mixOutputSlice() []i16 {
    if (mix_output_ptr == null or mix_frames == 0) return &[_]i16{};
    return mix_output_ptr.?[0 .. mix_frames * 2];
}

fn allocBuffer(size: usize, tag: c_int) ?*anyopaque {
    if (size == 0) return null;
    return Z_Malloc(@intCast(size), tag, null);
}

fn freeBuffer(ptr: ?*anyopaque) void {
    if (ptr) |p| Z_Free(p);
}

fn reallocateChannels() void {
    const count = if (snd_channels > 0) @as(usize, @intCast(snd_channels)) else 8;
    if (count == channels_len and channels_ptr != null) return;

    if (channels_ptr) |ptr| {
        freeBuffer(@ptrCast(ptr));
    }

    const total_size = std.math.mul(usize, count, @sizeOf(ChannelState)) catch {
        channels_ptr = null;
        channels_len = 0;
        return;
    };
    const raw = allocBuffer(total_size, PU_STATIC) orelse {
        channels_ptr = null;
        channels_len = 0;
        return;
    };
    channels_ptr = @ptrCast(@alignCast(raw));
    channels_len = count;

    for (channelsSlice()) |*ch| {
        ch.* = .{};
    }
}

fn reallocateMixBuffers(frames_needed: usize) void {
    if (frames_needed == 0 or frames_needed == mix_frames) return;

    if (mix_accum_ptr) |ptr| freeBuffer(@ptrCast(ptr));
    if (mix_output_ptr) |ptr| freeBuffer(@ptrCast(ptr));
    mix_accum_ptr = null;
    mix_output_ptr = null;
    mix_frames = 0;

    const accum_size = std.math.mul(usize, frames_needed * 2, @sizeOf(i32)) catch return;
    const out_size = std.math.mul(usize, frames_needed * 2, @sizeOf(i16)) catch return;

    const accum_raw = allocBuffer(accum_size, PU_STATIC) orelse return;
    const out_raw = allocBuffer(out_size, PU_STATIC) orelse {
        freeBuffer(accum_raw);
        return;
    };

    mix_accum_ptr = @ptrCast(@alignCast(accum_raw));
    mix_output_ptr = @ptrCast(@alignCast(out_raw));
    mix_frames = frames_needed;
}

fn clampFrames(frames: usize) usize {
    var clamped = frames;
    if (clamped < 64) clamped = 64;
    if (clamped > 4096) clamped = 4096;
    return clamped;
}

fn desiredFrames() usize {
    var rate: usize = 48000;
    if (snd_samplerate > 0) rate = @intCast(snd_samplerate);

    var ms: usize = 28;
    if (snd_maxslicetime_ms > 0) ms = @intCast(snd_maxslicetime_ms);
    if (ms < 5) ms = 5;
    if (ms > 100) ms = 100;

    const total = std.math.mul(usize, rate, ms) catch return 0;
    return clampFrames(total / 1000);
}

const AudioBufInfo = extern struct {
    fragments: u32,
    fragstotal: u32,
    fragsize: u32,
    bytes: u32,
};

fn dspAvailableBytes() ?usize {
    if (dsp_fd < 0) return null;
    var info: AudioBufInfo = .{ .fragments = 0, .fragstotal = 0, .fragsize = 0, .bytes = 0 };
    _ = syscall.ioctl(dsp_fd, sound_uapi.SNDCTL_DSP_GETOSPACE, @intFromPtr(&info)) catch return null;
    return info.bytes;
}

fn writeAll(fd: c_int, buf: []const u8) void {
    var offset: usize = 0;
    while (offset < buf.len) {
        const res = syscall.write(fd, buf.ptr + offset, buf.len - offset) catch |err| {
            if (err == error.Interrupted) continue;
            return;
        };
        if (res == 0) return;
        offset += res;
    }
}

fn stopChannel(idx: usize) void {
    if (idx >= channels_len) return;
    var ch = &channelsSlice()[idx];
    if (ch.sfx) |sfx_cache| {
        if (sfx_cache.refcount > 0) {
            sfx_cache.refcount -= 1;
        }
        ch.sfx = null;
    }
    ch.pos_fp = 0;
    ch.step_fp = 0;
    ch.volume = 0;
    ch.sep = 128;
}

fn buildSfxLumpName(sfx: *SfxInfo, prefix: bool) [8:0]u8 {
    var name_buf: [8:0]u8 = [_:0]u8{0} ** 8;
    var pos: usize = 0;
    if (prefix) {
        name_buf[0] = 'D';
        name_buf[1] = 'S';
        pos = 2;
    }

    var i: usize = 0;
    while (pos + i < 8 and i < sfx.name.len) : (i += 1) {
        const ch = sfx.name[i];
        if (ch == 0) break;
        name_buf[pos + i] = ch;
    }

    return name_buf;
}

fn resolveSfx(sfx: *SfxInfo) *SfxInfo {
    if (sfx.link) |link| return link;
    return sfx;
}

fn attachCache(cache: *SfxCache) void {
    cache.lru_prev = null;
    cache.lru_next = cache_head;
    if (cache_head) |head| {
        head.lru_prev = cache;
    } else {
        cache_tail = cache;
    }
    cache_head = cache;
}

fn detachCache(cache: *SfxCache) void {
    if (cache.lru_prev) |prev| {
        prev.lru_next = cache.lru_next;
    } else {
        cache_head = cache.lru_next;
    }
    if (cache.lru_next) |next| {
        next.lru_prev = cache.lru_prev;
    } else {
        cache_tail = cache.lru_prev;
    }
    cache.lru_prev = null;
    cache.lru_next = null;
}

fn touchCache(cache: *SfxCache) void {
    if (cache_head == cache) return;
    detachCache(cache);
    attachCache(cache);
}

fn evictCacheIfNeeded() void {
    if (snd_cachesize <= 0) return;
    const limit = @as(usize, @intCast(snd_cachesize));

    while (cache_bytes > limit) {
        const victim = cache_tail orelse break;
        if (victim.refcount != 0) break;
        detachCache(victim);
        cache_bytes -= victim.data_len;
        victim.sfx.driver_data = null;
        W_ReleaseLumpNum(victim.lumpnum);
        freeBuffer(@ptrCast(victim));
    }
}

fn cacheSfx(sfx: *SfxInfo) ?*SfxCache {
    if (sfx.driver_data) |ptr| {
        const cache: *SfxCache = @ptrCast(@alignCast(ptr));
        touchCache(cache);
        return cache;
    }

    if (sfx.lumpnum < 0) {
        const name = buildSfxLumpName(sfx, use_sfx_prefix);
        sfx.lumpnum = W_GetNumForName(@ptrCast(&name));
    }

    const lump_len = W_LumpLength(@intCast(sfx.lumpnum));
    if (lump_len < 8) return null;

    const lump_ptr = W_CacheLumpNum(sfx.lumpnum, PU_SOUND) orelse return null;
    const lump_bytes: [*]const u8 = @ptrCast(lump_ptr);
    const lump_slice = lump_bytes[0..@intCast(lump_len)];

    const rate = std.mem.readInt(u16, lump_slice[0..2], .little);
    const sample_count_hdr = std.mem.readInt(u16, lump_slice[2..4], .little);
    const data_len_raw = @as(usize, @intCast(lump_len - 8));
    const sample_count = @min(@as(usize, sample_count_hdr), data_len_raw);
    if (sample_count == 0 or rate == 0) return null;

    const cache_raw = allocBuffer(@sizeOf(SfxCache), PU_SOUND) orelse return null;
    const cache: *SfxCache = @ptrCast(@alignCast(cache_raw));
    cache.* = .{
        .sfx = sfx,
        .lumpnum = sfx.lumpnum,
        .sample_rate = rate,
        .samples = lump_bytes + 8,
        .sample_count = sample_count,
        .data_len = sample_count,
        .refcount = 0,
        .lru_prev = null,
        .lru_next = null,
    };

    sfx.driver_data = cache;
    attachCache(cache);
    cache_bytes += sample_count;
    evictCacheIfNeeded();
    return cache;
}

fn mixChannel(idx: usize, ch: *ChannelState, accum: []i32, frames: usize, out_rate: u32) void {
    const cache = ch.sfx orelse return;
    if (cache.sample_count == 0 or out_rate == 0) return;

    const max_pos = @as(u32, @intCast(cache.sample_count)) << SampleFpShift;
    var pos = ch.pos_fp;
    const step = ch.step_fp;

    const vol: i32 = ch.volume;
    const sep: i32 = ch.sep;
    const left_scale = @divTrunc(vol * (254 - sep), 254);
    const right_scale = @divTrunc(vol * sep, 254);

    var frame_idx: usize = 0;
    while (frame_idx < frames) : (frame_idx += 1) {
        if (pos >= max_pos) {
            break;
        }

        const sample_idx = @as(usize, @intCast(pos >> SampleFpShift));
        const frac = @as(i32, @intCast(pos & SampleFpMask));

        const s0_u8 = cache.samples[sample_idx];
        const s1_u8 = if (sample_idx + 1 < cache.sample_count) cache.samples[sample_idx + 1] else s0_u8;

        const s0 = (@as(i32, s0_u8) - 128) * 256;
        const s1 = (@as(i32, s1_u8) - 128) * 256;
        const interp = s0 + (((s1 - s0) * frac) >> SampleFpShift);

        const left = @divTrunc(interp * left_scale, 127);
        const right = @divTrunc(interp * right_scale, 127);

        const out_idx = frame_idx * 2;
        accum[out_idx] += left;
        accum[out_idx + 1] += right;

        const next_pos = std.math.add(u32, pos, step) catch max_pos;
        pos = next_pos;
    }

    ch.pos_fp = pos;
    if (pos >= max_pos) {
        stopChannel(idx);
    }
}

fn mixAndWrite() void {
    if (!sound_enabled or dsp_fd < 0) return;

    const buffer_frames = desiredFrames();
    if (buffer_frames == 0) return;

    var frames = buffer_frames;
    if (dspAvailableBytes()) |bytes_avail| {
        const max_frames = bytes_avail / BytesPerFrame;
        if (max_frames == 0) return;
        if (max_frames < frames) frames = max_frames;
    }

    reallocateMixBuffers(buffer_frames);
    if (mix_frames == 0) return;

    const accum = mixAccumSlice()[0 .. frames * 2];
    const out = mixOutputSlice()[0 .. frames * 2];

    @memset(accum, 0);

    const rate = if (snd_samplerate > 0) @as(u32, @intCast(snd_samplerate)) else 48000;

    // Mix SFX channels
    for (channelsSlice(), 0..) |*ch, idx| {
        mixChannel(idx, ch, accum, frames, rate);
    }

    // Mix music (OPL3 synthesis)
    mixMusic(accum, frames);

    var i: usize = 0;
    while (i < accum.len) : (i += 1) {
        const clamped = std.math.clamp(accum[i], -32768, 32767);
        out[i] = @intCast(clamped);
    }

    const bytes = std.mem.sliceAsBytes(out);
    writeAll(dsp_fd, bytes);
}

/// Mix music into the accumulator buffer
fn mixMusic(accum: []i32, frames: usize) void {
    const seq = music_sequencer orelse return;
    const synth = music_synth orelse return;

    if (!seq.isPlaying()) return;

    // Scale factor for music volume (0-127 mapped to 0-256)
    const vol_scale: i32 = @as(i32, music_volume) * 2;

    var frame_idx: usize = 0;
    while (frame_idx < frames) : (frame_idx += 1) {
        // Process MIDI events and advance sequencer
        seq.processSample(synth);

        // Generate stereo sample from OPL3
        const sample = synth.generateSample();

        // Apply music volume and add to accumulator
        const left = @divTrunc(@as(i32, sample[0]) * vol_scale, 256);
        const right = @divTrunc(@as(i32, sample[1]) * vol_scale, 256);

        const out_idx = frame_idx * 2;
        accum[out_idx] += left;
        accum[out_idx + 1] += right;
    }
}

// -----------------------------------------------------------------------------
// I_* API (C ABI)
// -----------------------------------------------------------------------------

pub export fn I_InitSound(use_prefix: CBool) callconv(.c) void {
    use_sfx_prefix = (use_prefix != 0);

    if (M_CheckParm("-nosound") > 0 or M_CheckParm("-nosfx") > 0) {
        sound_enabled = false;
        return;
    }

    if (snd_sfxdevice == SNDDEVICE_NONE) {
        sound_enabled = false;
        return;
    }

    dsp_fd = syscall.open("/dev/dsp", syscall.O_WRONLY, 0) catch {
        sound_enabled = false;
        dsp_fd = -1;
        return;
    };

    var rate: u32 = if (snd_samplerate > 0) @intCast(snd_samplerate) else 48000;
    var channels: u32 = 2;
    var fmt: u32 = sound_uapi.AFMT_S16_LE;

    _ = syscall.ioctl(dsp_fd, sound_uapi.SNDCTL_DSP_SPEED, @intFromPtr(&rate)) catch {};
    _ = syscall.ioctl(dsp_fd, sound_uapi.SNDCTL_DSP_CHANNELS, @intFromPtr(&channels)) catch {};
    _ = syscall.ioctl(dsp_fd, sound_uapi.SNDCTL_DSP_SETFMT, @intFromPtr(&fmt)) catch {};

    snd_samplerate = @intCast(rate);
    sound_enabled = true;

    reallocateChannels();
}

pub export fn I_ShutdownSound() callconv(.c) void {
    if (dsp_fd >= 0) {
        _ = syscall.close(dsp_fd) catch {};
        dsp_fd = -1;
    }
    sound_enabled = false;

    if (channels_ptr) |ptr| {
        freeBuffer(@ptrCast(ptr));
        channels_ptr = null;
        channels_len = 0;
    }

    if (mix_accum_ptr) |ptr| freeBuffer(@ptrCast(ptr));
    if (mix_output_ptr) |ptr| freeBuffer(@ptrCast(ptr));
    mix_accum_ptr = null;
    mix_output_ptr = null;
    mix_frames = 0;

    while (cache_head) |cache| {
        detachCache(cache);
        cache.sfx.driver_data = null;
        W_ReleaseLumpNum(cache.lumpnum);
        freeBuffer(@ptrCast(cache));
    }
    cache_tail = null;
    cache_bytes = 0;
}

pub export fn I_SetChannels() callconv(.c) void {}

pub export fn I_GetSfxLumpNum(sfx: *SfxInfo) callconv(.c) c_int {
    const target = resolveSfx(sfx);
    if (target.lumpnum >= 0) return target.lumpnum;
    const name = buildSfxLumpName(target, use_sfx_prefix);
    target.lumpnum = W_GetNumForName(@ptrCast(&name));
    return target.lumpnum;
}

pub export fn I_StartSound(sfx: *SfxInfo, channel: c_int, vol: c_int, sep: c_int, pitch: c_int) callconv(.c) c_int {
    _ = pitch;
    if (!sound_enabled) return -1;
    if (channel < 0) return -1;

    const idx: usize = @intCast(channel);
    if (idx >= channels_len) return -1;

    const target = resolveSfx(sfx);
    const cache = cacheSfx(target) orelse return -1;
    touchCache(cache);

    stopChannel(idx);

    var ch = &channelsSlice()[idx];
    ch.sfx = cache;
    ch.pos_fp = 0;
    ch.volume = @intCast(@max(0, @min(127, vol)));
    ch.sep = @intCast(@max(0, @min(254, sep)));

    const out_rate: u32 = if (snd_samplerate > 0) @intCast(snd_samplerate) else 48000;
    if (out_rate == 0) return -1;
    const step = (@as(u32, cache.sample_rate) << SampleFpShift) / out_rate;
    ch.step_fp = if (step == 0) 1 else step;

    cache.refcount += 1;
    return channel;
}

pub export fn I_StopSound(handle: c_int) callconv(.c) void {
    if (handle < 0) return;
    stopChannel(@intCast(handle));
}

pub export fn I_SoundIsPlaying(handle: c_int) callconv(.c) CBool {
    if (handle < 0) return 0;
    const idx: usize = @intCast(handle);
    if (idx >= channels_len) return 0;
    return if (channelsSlice()[idx].sfx != null) 1 else 0;
}

pub export fn I_UpdateSound() callconv(.c) void {
    mixAndWrite();
}

pub export fn I_UpdateSoundParams(handle: c_int, vol: c_int, sep: c_int) callconv(.c) void {
    if (handle < 0) return;
    const idx: usize = @intCast(handle);
    if (idx >= channels_len) return;
    var ch = &channelsSlice()[idx];
    ch.volume = @intCast(@max(0, @min(127, vol)));
    ch.sep = @intCast(@max(0, @min(254, sep)));
}

pub export fn I_PrecacheSounds(sounds: ?[*]SfxInfo, count: c_int) callconv(.c) void {
    if (!sound_enabled) return;
    if (sounds == null or count <= 0) return;

    const sounds_ptr = sounds.?;
    const total: usize = @intCast(count);
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const sfx = &sounds_ptr[i];
        const target = resolveSfx(sfx);
        _ = cacheSfx(target);
    }
}

pub export fn I_InitMusic() callconv(.c) void {
    if (music_initialized) return;

    // Check for -nomusic command line option
    if (M_CheckParm("-nomusic") > 0) return;
    if (snd_musicdevice == SNDDEVICE_NONE) return;

    // Allocate MIDI events buffer
    const events_size = @sizeOf(midi.MidiEvent) * midi.MAX_EVENTS_PER_TRACK;
    const events_raw = allocBuffer(events_size, PU_STATIC) orelse return;
    midi_events_buffer = @ptrCast(@alignCast(events_raw));

    // Allocate OPL3 synthesizer
    const synth_raw = allocBuffer(@sizeOf(opl3.Opl3Synth), PU_STATIC) orelse {
        freeBuffer(events_raw);
        midi_events_buffer = null;
        return;
    };
    music_synth = @ptrCast(@alignCast(synth_raw));
    music_synth.?.* = opl3.Opl3Synth.init();

    // Load GENMIDI instrument bank
    if (genmidi.loadGenmidi(&genmidi_instruments, &genmidi_percussion)) {
        music_synth.?.loadInstruments(&genmidi_instruments, &genmidi_percussion);
        genmidi_loaded = true;
    }

    // Allocate sequencer
    const seq_raw = allocBuffer(@sizeOf(sequencer_mod.Sequencer), PU_STATIC) orelse {
        freeBuffer(synth_raw);
        freeBuffer(events_raw);
        music_synth = null;
        midi_events_buffer = null;
        return;
    };
    music_sequencer = @ptrCast(@alignCast(seq_raw));

    const rate = if (snd_samplerate > 0) @as(u32, @intCast(snd_samplerate)) else 48000;
    music_sequencer.?.* = sequencer_mod.Sequencer.init(rate);

    music_initialized = true;
}

pub export fn I_ShutdownMusic() callconv(.c) void {
    if (!music_initialized) return;

    // Stop any playing music
    I_StopSong();

    // Free current track if any
    if (current_track) |track| {
        freeBuffer(@ptrCast(track));
        current_track = null;
    }

    // Free sequencer
    if (music_sequencer) |seq| {
        freeBuffer(@ptrCast(seq));
        music_sequencer = null;
    }

    // Free synthesizer
    if (music_synth) |synth| {
        freeBuffer(@ptrCast(synth));
        music_synth = null;
    }

    // Free events buffer
    if (midi_events_buffer) |buf| {
        freeBuffer(@ptrCast(buf));
        midi_events_buffer = null;
    }

    genmidi_loaded = false;
    music_initialized = false;
}

pub export fn I_SetMusicVolume(vol: c_int) callconv(.c) void {
    // Doom volume is 0-15, scale to 0-127
    const scaled = if (vol < 0) 0 else if (vol > 15) 127 else @as(u8, @intCast(vol * 8));
    music_volume = scaled;
}

pub export fn I_PauseSong() callconv(.c) void {
    if (music_sequencer) |seq| {
        seq.pause();
    }
}

pub export fn I_ResumeSong() callconv(.c) void {
    if (music_sequencer) |seq| {
        seq.resumePlayback();
    }
}

pub export fn I_PlaySong(handle: ?*anyopaque, looping: CBool) callconv(.c) void {
    if (!music_initialized) return;
    const seq = music_sequencer orelse return;

    // Handle is a pointer to our MidiTrack
    const track: *midi.MidiTrack = @ptrCast(@alignCast(handle orelse return));

    // Load and start playback
    seq.loadTrack(track);
    seq.play(looping != 0);
}

pub export fn I_StopSong() callconv(.c) void {
    const seq = music_sequencer orelse return;
    const synth = music_synth orelse return;
    seq.stop(synth);
}

pub export fn I_RegisterSong(data: ?*anyopaque, len: c_int) callconv(.c) ?*anyopaque {
    if (!music_initialized) return null;
    if (data == null or len <= 0) return null;

    const mus_len: usize = @intCast(len);

    // Open MUS data as MEMFILE for reading
    const mus_file = mem_fopen_read(data, mus_len) orelse return null;
    defer mem_fclose(mus_file);

    // Open output MEMFILE for MIDI data
    const midi_file = mem_fopen_write() orelse return null;

    // Convert MUS to MIDI
    if (mus2mid(mus_file, midi_file) == 0) {
        mem_fclose(midi_file);
        return null;
    }

    // Get MIDI data from output
    var midi_buf: ?*anyopaque = null;
    var midi_len: usize = 0;
    mem_get_buf(midi_file, &midi_buf, &midi_len);

    if (midi_buf == null or midi_len == 0) {
        mem_fclose(midi_file);
        return null;
    }

    // Parse MIDI into track
    const events_buf = midi_events_buffer orelse {
        mem_fclose(midi_file);
        return null;
    };
    const events_slice = events_buf[0..midi.MAX_EVENTS_PER_TRACK];

    const midi_bytes: [*]const u8 = @ptrCast(midi_buf.?);
    const track_opt = midi_parser.parseMidi(midi_bytes[0..midi_len], events_slice);

    mem_fclose(midi_file);

    if (track_opt) |track| {
        // Allocate persistent track storage
        const track_raw = allocBuffer(@sizeOf(midi.MidiTrack), PU_STATIC) orelse return null;
        const track_ptr: *midi.MidiTrack = @ptrCast(@alignCast(track_raw));
        track_ptr.* = track;
        return @ptrCast(track_ptr);
    }

    return null;
}

pub export fn I_UnRegisterSong(handle: ?*anyopaque) callconv(.c) void {
    if (handle == null) return;

    // Stop if this track is playing
    if (current_track) |track| {
        if (@intFromPtr(track) == @intFromPtr(handle.?)) {
            I_StopSong();
            current_track = null;
        }
    }

    // Free the track
    freeBuffer(handle);
}

pub export fn I_MusicIsPlaying() callconv(.c) CBool {
    const seq = music_sequencer orelse return 0;
    return if (seq.isPlaying()) 1 else 0;
}

pub export fn I_BindSoundVariables() callconv(.c) void {
    M_BindVariable("snd_musicdevice", @ptrCast(&snd_musicdevice));
    M_BindVariable("snd_sfxdevice", @ptrCast(&snd_sfxdevice));
    M_BindVariable("snd_sbport", @ptrCast(&snd_sbport));
    M_BindVariable("snd_sbirq", @ptrCast(&snd_sbirq));
    M_BindVariable("snd_sbdma", @ptrCast(&snd_sbdma));
    M_BindVariable("snd_mport", @ptrCast(&snd_mport));
    M_BindVariable("snd_maxslicetime_ms", @ptrCast(&snd_maxslicetime_ms));
    M_BindVariable("snd_musiccmd", @ptrCast(&snd_musiccmd));
    M_BindVariable("snd_samplerate", @ptrCast(&snd_samplerate));
    M_BindVariable("snd_cachesize", @ptrCast(&snd_cachesize));
}

// -----------------------------------------------------------------------------
// Sound Module Exports (for optional FEATURE_SOUND use)
// -----------------------------------------------------------------------------

fn soundModuleInit(use_prefix: CBool) callconv(.c) CBool {
    I_InitSound(use_prefix);
    return if (sound_enabled) 1 else 0;
}

fn soundModuleShutdown() callconv(.c) void {
    I_ShutdownSound();
}

fn soundModuleGetLump(sfx: *SfxInfo) callconv(.c) c_int {
    return I_GetSfxLumpNum(sfx);
}

fn soundModuleUpdate() callconv(.c) void {
    I_UpdateSound();
}

fn soundModuleUpdateParams(handle: c_int, vol: c_int, sep: c_int) callconv(.c) void {
    I_UpdateSoundParams(handle, vol, sep);
}

fn soundModuleStart(sfx: *SfxInfo, channel: c_int, vol: c_int, sep: c_int) callconv(.c) c_int {
    return I_StartSound(sfx, channel, vol, sep, 0);
}

fn soundModuleStop(handle: c_int) callconv(.c) void {
    I_StopSound(handle);
}

fn soundModuleIsPlaying(handle: c_int) callconv(.c) CBool {
    return I_SoundIsPlaying(handle);
}

fn soundModuleCache(sounds: ?[*]SfxInfo, count: c_int) callconv(.c) void {
    I_PrecacheSounds(sounds, count);
}

fn musicModuleInit() callconv(.c) CBool {
    I_InitMusic();
    return if (music_initialized) 1 else 0;
}

fn musicModuleShutdown() callconv(.c) void {
    I_ShutdownMusic();
}

fn musicModuleSetVolume(vol: c_int) callconv(.c) void {
    I_SetMusicVolume(vol);
}

fn musicModulePause() callconv(.c) void {
    I_PauseSong();
}

fn musicModuleResume() callconv(.c) void {
    I_ResumeSong();
}

fn musicModuleRegister(data: ?*anyopaque, len: c_int) callconv(.c) ?*anyopaque {
    return I_RegisterSong(data, len);
}

fn musicModuleUnregister(handle: ?*anyopaque) callconv(.c) void {
    I_UnRegisterSong(handle);
}

fn musicModulePlay(handle: ?*anyopaque, looping: CBool) callconv(.c) void {
    I_PlaySong(handle, looping);
}

fn musicModuleStop() callconv(.c) void {
    I_StopSong();
}

fn musicModuleIsPlaying() callconv(.c) CBool {
    return I_MusicIsPlaying();
}

fn musicModulePoll() callconv(.c) void {
    // Music is mixed in mixAndWrite(), no separate poll needed
}

const sfx_devices = [_]snddevice_t{SNDDEVICE_SB};
const music_devices = [_]snddevice_t{SNDDEVICE_SB};

pub export const DG_sound_module: SoundModule = .{
    .sound_devices = @ptrCast(@constCast(&sfx_devices)),
    .num_sound_devices = @intCast(sfx_devices.len),
    .init = &soundModuleInit,
    .shutdown = &soundModuleShutdown,
    .get_sfx_lump_num = &soundModuleGetLump,
    .update = &soundModuleUpdate,
    .update_sound_params = &soundModuleUpdateParams,
    .start_sound = &soundModuleStart,
    .stop_sound = &soundModuleStop,
    .sound_is_playing = &soundModuleIsPlaying,
    .cache_sounds = &soundModuleCache,
};

pub export const DG_music_module: MusicModule = .{
    .sound_devices = @ptrCast(@constCast(&music_devices)),
    .num_sound_devices = @intCast(music_devices.len),
    .init = &musicModuleInit,
    .shutdown = &musicModuleShutdown,
    .set_music_volume = &musicModuleSetVolume,
    .pause = &musicModulePause,
    .resume_music = &musicModuleResume,
    .register_song = &musicModuleRegister,
    .unregister_song = &musicModuleUnregister,
    .play_song = &musicModulePlay,
    .stop_song = &musicModuleStop,
    .music_is_playing = &musicModuleIsPlaying,
    .poll = &musicModulePoll,
};

pub export const sound_sdl_module: SoundModule = DG_sound_module;
pub export const music_sdl_module: MusicModule = DG_music_module;

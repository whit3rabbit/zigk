// Doom Sound System Stubs
//
// No-op implementations for the Doom sound system.
// These stubs allow Doom to compile and run without actual sound support.

// Sound sample rate (unused but needed for linking)
pub export var snd_samplerate: c_int = 44100;

// Sound module structure expected by Doom
pub const SoundModule = extern struct {
    name: [*:0]const u8,
    init: *const fn () callconv(.c) bool,
    shutdown: *const fn () callconv(.c) void,
    get_sfx_lump_num: *const fn (*anyopaque) callconv(.c) c_int,
    update: *const fn () callconv(.c) void,
    update_sound_params: *const fn (c_int, c_int, c_int) callconv(.c) void,
    start_sound: *const fn (*anyopaque, c_int, c_int, c_int) callconv(.c) c_int,
    stop_sound: *const fn (c_int) callconv(.c) void,
    sound_is_playing: *const fn (c_int) callconv(.c) bool,
    cache_sounds: *const fn ([*]*anyopaque, c_int) callconv(.c) void,
};

// Music module structure expected by Doom
pub const MusicModule = extern struct {
    name: [*:0]const u8,
    init: *const fn () callconv(.c) bool,
    shutdown: *const fn () callconv(.c) void,
    set_music_volume: *const fn (c_int) callconv(.c) void,
    pause: *const fn () callconv(.c) void,
    resume_music: *const fn () callconv(.c) void,
    register_song: *const fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque,
    unregister_song: *const fn (?*anyopaque) callconv(.c) void,
    play_song: *const fn (?*anyopaque, bool) callconv(.c) void,
    stop_song: *const fn () callconv(.c) void,
    music_is_playing: *const fn () callconv(.c) bool,
    poll: *const fn () callconv(.c) void,
};

// Sound module implementation stubs
fn soundInit() callconv(.c) bool {
    return false; // Sound not available
}

fn soundShutdown() callconv(.c) void {}

fn soundGetSfxLumpNum(sfx: *anyopaque) callconv(.c) c_int {
    _ = sfx;
    return 0;
}

fn soundUpdate() callconv(.c) void {}

fn soundUpdateParams(handle: c_int, vol: c_int, sep: c_int) callconv(.c) void {
    _ = handle;
    _ = vol;
    _ = sep;
}

fn soundStart(sfx: *anyopaque, channel: c_int, vol: c_int, sep: c_int) callconv(.c) c_int {
    _ = sfx;
    _ = channel;
    _ = vol;
    _ = sep;
    return -1; // No sound played
}

fn soundStop(handle: c_int) callconv(.c) void {
    _ = handle;
}

fn soundIsPlaying(handle: c_int) callconv(.c) bool {
    _ = handle;
    return false;
}

fn soundCacheSounds(sounds: [*]*anyopaque, count: c_int) callconv(.c) void {
    _ = sounds;
    _ = count;
}

// Music module implementation stubs
fn musicInit() callconv(.c) bool {
    return false; // Music not available
}

fn musicShutdown() callconv(.c) void {}

fn musicSetVolume(vol: c_int) callconv(.c) void {
    _ = vol;
}

fn musicPause() callconv(.c) void {}

fn musicResume() callconv(.c) void {}

fn musicRegister(data: ?*anyopaque, len: c_int) callconv(.c) ?*anyopaque {
    _ = data;
    _ = len;
    return null;
}

fn musicUnregister(handle: ?*anyopaque) callconv(.c) void {
    _ = handle;
}

fn musicPlay(handle: ?*anyopaque, looping: bool) callconv(.c) void {
    _ = handle;
    _ = looping;
}

fn musicStop() callconv(.c) void {}

fn musicIsPlaying() callconv(.c) bool {
    return false;
}

fn musicPoll() callconv(.c) void {}

// Exported sound module
pub export const sound_sdl_module: SoundModule = .{
    .name = "stub",
    .init = &soundInit,
    .shutdown = &soundShutdown,
    .get_sfx_lump_num = &soundGetSfxLumpNum,
    .update = &soundUpdate,
    .update_sound_params = &soundUpdateParams,
    .start_sound = &soundStart,
    .stop_sound = &soundStop,
    .sound_is_playing = &soundIsPlaying,
    .cache_sounds = &soundCacheSounds,
};

// Exported music module
pub export const music_sdl_module: MusicModule = .{
    .name = "stub",
    .init = &musicInit,
    .shutdown = &musicShutdown,
    .set_music_volume = &musicSetVolume,
    .pause = &musicPause,
    .resume_music = &musicResume,
    .register_song = &musicRegister,
    .unregister_song = &musicUnregister,
    .play_song = &musicPlay,
    .stop_song = &musicStop,
    .music_is_playing = &musicIsPlaying,
    .poll = &musicPoll,
};

// These are typically referenced by doomgeneric
pub export var sound_module: ?*const SoundModule = null;
pub export var music_module: ?*const MusicModule = null;

// Additional stubs that may be needed
pub export fn I_InitSound(use_sfx: bool) callconv(.c) bool {
    _ = use_sfx;
    return true; // Pretend success
}

pub export fn I_ShutdownSound() callconv(.c) void {}

pub export fn I_SetChannels() callconv(.c) void {}

pub export fn I_GetSfxLumpNum(sfx: *anyopaque) callconv(.c) c_int {
    _ = sfx;
    return 0;
}

pub export fn I_StartSound(sfx: *anyopaque, vol: c_int, sep: c_int, pitch: c_int) callconv(.c) c_int {
    _ = sfx;
    _ = vol;
    _ = sep;
    _ = pitch;
    return -1;
}

pub export fn I_StopSound(handle: c_int) callconv(.c) void {
    _ = handle;
}

pub export fn I_SoundIsPlaying(handle: c_int) callconv(.c) bool {
    _ = handle;
    return false;
}

pub export fn I_UpdateSound() callconv(.c) void {}

pub export fn I_UpdateSoundParams(handle: c_int, vol: c_int, sep: c_int) callconv(.c) void {
    _ = handle;
    _ = vol;
    _ = sep;
}

pub export fn I_InitMusic() callconv(.c) bool {
    return true;
}

pub export fn I_ShutdownMusic() callconv(.c) void {}

pub export fn I_SetMusicVolume(vol: c_int) callconv(.c) void {
    _ = vol;
}

pub export fn I_PauseSong() callconv(.c) void {}

pub export fn I_ResumeSong() callconv(.c) void {}

pub export fn I_PlaySong(handle: ?*anyopaque, looping: bool) callconv(.c) void {
    _ = handle;
    _ = looping;
}

pub export fn I_StopSong() callconv(.c) void {}

pub export fn I_RegisterSong(data: ?*anyopaque, len: c_int) callconv(.c) ?*anyopaque {
    _ = data;
    _ = len;
    return null;
}

pub export fn I_UnRegisterSong(handle: ?*anyopaque) callconv(.c) void {
    _ = handle;
}

// Additional stubs needed by s_sound.c and d_main.c
pub export fn I_PrecacheSounds(sounds: ?*anyopaque, count: c_int) callconv(.c) void {
    _ = sounds;
    _ = count;
}

pub export fn I_MusicIsPlaying() callconv(.c) bool {
    return false;
}

pub export fn I_BindSoundVariables() callconv(.c) void {}

// Sound device variable
pub export var snd_musicdevice: c_int = 0;

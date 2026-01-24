// Doom Entry Point for ZK
//
// Initializes doomgeneric and runs the main game loop.
// The WAD file is expected to be at /doom1.wad in the InitRD.

const syscall = @import("syscall");
const std = @import("std");

// Import libc to ensure all exports are linked
// These modules contain exported C-callable functions that doomgeneric needs
pub const libc = @import("libc");
pub const platform = @import("doomgeneric_zk.zig");
pub const sound = @import("i_sound.zig");

// Force linker to keep libc exports by referencing them
comptime {
    _ = &libc.malloc;
    _ = &libc.free;
    _ = &libc.realloc;
    _ = &libc.calloc;
    // Note: printf/fprintf/sprintf/snprintf are exported directly to C
    _ = &libc.printf_impl;
    _ = &libc.fprintf_impl;
    _ = &libc.sprintf_impl;
    _ = &libc.snprintf_impl;
    _ = &libc.fopen;
    _ = &libc.fclose;
    _ = &libc.fread;
    _ = &libc.fwrite;
    _ = &libc.fseek;
    _ = &libc.ftell;
    _ = &libc.fflush;
    _ = &libc.feof;
    _ = &libc.ferror;
    _ = &libc.fputc;
    _ = &libc.fputs;
    _ = &libc.fgetc;
    _ = &libc.fgets;
    _ = &libc.putchar;
    _ = &libc.puts;
    _ = &libc.getc;
    _ = &libc.getchar;
    _ = &libc.strlen;
    _ = &libc.strcmp;
    _ = &libc.strcpy;
    _ = &libc.strncpy;
    _ = &libc.strncmp;
    _ = &libc.strcat;
    _ = &libc.strncat;
    _ = &libc.strchr;
    _ = &libc.strrchr;
    _ = &libc.strstr;
    _ = &libc.strdup;
    _ = &libc.strcasecmp;
    _ = &libc.strncasecmp;
    _ = &libc.memcpy;
    _ = &libc.memset;
    _ = &libc.memmove;
    _ = &libc.memcmp;
    _ = &libc.abs;
    _ = &libc.labs;
    _ = &libc.atoi;
    _ = &libc.atol;
    _ = &libc.strtol;
    _ = &libc.strtoul;
    _ = &libc.rand;
    _ = &libc.srand;
    _ = &libc.qsort;
    _ = &libc.getenv;
    _ = &libc.exit;
    _ = &libc.abort;
    _ = &libc.isspace;
    _ = &libc.isdigit;
    _ = &libc.isalpha;
    _ = &libc.isalnum;
    _ = &libc.isupper;
    _ = &libc.islower;
    _ = &libc.isprint;
    _ = &libc.isxdigit;
    _ = &libc.iscntrl;
    _ = &libc.isgraph;
    _ = &libc.ispunct;
    _ = &libc.toupper;
    _ = &libc.tolower;
    _ = &libc.time;
    _ = &libc.sscanf_impl;
    _ = &libc.signal;
    _ = &libc.setjmp;
    _ = &libc.longjmp;
    _ = &libc.atexit;
    _ = &libc.stdin;
    _ = &libc.stdout;
    _ = &libc.stderr;
    _ = &libc.__errno_location;
    _ = &libc.system;
    _ = &libc.mkdir;
    _ = &libc.atof;
    // Platform hooks
    _ = &platform.DG_Init;
    _ = &platform.DG_DrawFrame;
    _ = &platform.DG_SleepMs;
    _ = &platform.DG_GetTicksMs;
    _ = &platform.DG_GetKey;
    _ = &platform.DG_SetWindowTitle;
    // Sound stubs
    _ = &sound.sound_sdl_module;
    _ = &sound.music_sdl_module;
    _ = &sound.snd_musicdevice;
    _ = &sound.I_PrecacheSounds;
    _ = &sound.I_MusicIsPlaying;
    _ = &sound.I_BindSoundVariables;
}

// Import C functions from doomgeneric
extern fn doomgeneric_Create(argc: c_int, argv: [*][*:0]u8) void;
extern fn doomgeneric_Tick() void;

// Argv storage
var argv_storage: [4][*:0]u8 = undefined;
var argv_buffer: [128]u8 = undefined;

pub fn main() void {
    syscall.print("Doom for ZK starting...\n");

    // Set up argv
    // argv[0] = "doom"
    // argv[1] = "-iwad"
    // argv[2] = "/doom1.wad"
    // argv[3] = null (terminated by argc=3)

    const arg0 = "doom";
    const arg1 = "-iwad";
    const arg2 = "/doom1.wad";

    // Copy strings into buffer (null-terminated)
    var offset: usize = 0;

    syscall.print("DEBUG: ArgvBuffer at {x}\n"); // .{@intFromPtr(&argv_buffer)});
    // Note: User print syscall is string-only for now, we need to format manually or add support
    // For now, let's just print checkpoints.

    syscall.print("DEBUG: Copying arg0...\n");
    @memcpy(argv_buffer[offset .. offset + arg0.len], arg0);
    argv_buffer[offset + arg0.len] = 0;
    argv_storage[0] = @ptrCast(&argv_buffer[offset]);
    offset += arg0.len + 1;

    @memcpy(argv_buffer[offset .. offset + arg1.len], arg1);
    argv_buffer[offset + arg1.len] = 0;
    argv_storage[1] = @ptrCast(&argv_buffer[offset]);
    offset += arg1.len + 1;

    @memcpy(argv_buffer[offset .. offset + arg2.len], arg2);
    argv_buffer[offset + arg2.len] = 0;
    argv_storage[2] = @ptrCast(&argv_buffer[offset]);

    syscall.print("Calling doomgeneric_Create...\n");

    // Create the game
    doomgeneric_Create(3, &argv_storage);

    syscall.print("Entering main loop...\n");

    // Main game loop
    while (true) {
        doomgeneric_Tick();
        // Yield to kernel to prevent starvation of input processing threads
        _ = syscall.sched_yield() catch {};
    }
}

// Entry point called by linker
export fn _start() noreturn {
    main();
    syscall.exit(0);
}

// DG_ScreenBuffer is defined in doomgeneric.c, we just reference it
extern var DG_ScreenBuffer: [*]u32;

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    _ = ret_addr;
    _ = syscall.print("PANIC: ");
    _ = syscall.print(msg);
    _ = syscall.print("\n");
    syscall.exit(1);
}

# Running DOOM on Zscapek

This guide explains how to run the classic DOOM game on the Zscapek microkernel.

## Overview

Zscapek includes a port of [doomgeneric](https://github.com/ozkl/doomgeneric), a portable DOOM implementation that runs on custom platforms. The port uses the kernel's framebuffer for graphics and PS/2 keyboard for input.

## Requirements

- Zscapek kernel built with `zig build`
- DOOM1.WAD shareware file (legally free to distribute)
- QEMU or compatible x86_64 emulator

## Downloading the WAD File

The DOOM WAD file contains all game data (levels, sprites, sounds). The shareware version (DOOM1.WAD) is freely available.

### Option 1: From GitHub (Recommended)

Download from the DOOM_wads repository:

```bash
wget https://github.com/Akbar30Bill/DOOM_wads/raw/refs/heads/master/doom.wad -O initrd_contents/doom1.wad
```

### Option 2: Manual Download

1. Visit https://github.com/Akbar30Bill/DOOM_wads
2. Download `DOOM.WAD`
3. Place it in the `initrd_contents/` directory as `doom1.wad` (lowercase)

## Building the ISO

After placing the WAD file:

```bash
# Ensure the WAD is in place
ls -la initrd_contents/doom1.wad

# Build the ISO (this creates initrd.tar automatically)
zig build iso
```

The build process will:
1. Compile doom.elf (~10MB)
2. Create initrd.tar from initrd_contents/
3. Package everything into zscapek.iso

## Running DOOM

### Using QEMU

```bash
# Standard run
zig build run

# Or manually with QEMU
qemu-system-x86_64 -M q35 -m 128M -cdrom zscapek.iso -serial stdio
```

### Boot Menu

When the system boots, you'll see the Limine bootloader menu. Select:

```
Doom
```

This entry loads:
- The kernel
- initrd.tar (containing doom1.wad)
- doom.elf (the game executable)

## Controls

| Key | Action |
|-----|--------|
| Arrow Keys | Move/Turn |
| Ctrl | Fire |
| Space | Open doors/Use |
| Shift | Run |
| 1-7 | Select weapon |
| Tab | Automap |
| Escape | Menu |
| Enter | Confirm |

## Technical Details

### Platform Implementation

The DOOM port uses:
- **Graphics**: Kernel framebuffer via `sys_get_framebuffer_info` and `sys_map_framebuffer`
- **Input**: PS/2 keyboard scancodes via `sys_read_scancode`
- **Timing**: `sys_clock_gettime` and `sys_nanosleep`
- **File I/O**: InitRD filesystem via standard `fopen`/`fread`

### File Locations

| File | Purpose |
|------|---------|
| `src/user/doom/main.zig` | Entry point |
| `src/user/doom/doomgeneric_zscapek.zig` | Platform hooks |
| `src/user/doom/i_sound_stub.zig` | Sound stubs (no audio) |
| `src/user/doom/doomgeneric/` | Original DOOM source |
| `src/user/lib/libc.zig` | C library implementation |

### Screen Resolution

DOOM runs at 640x400 and is centered on the framebuffer if the display is larger.

## Known Limitations

- **No Sound**: Audio is stubbed out (silent gameplay)
- **No Mouse**: Only keyboard input is supported
- **No Save Games**: Filesystem writes are not implemented
- **Shareware Only**: Full DOOM requires purchasing the commercial WAD

## Troubleshooting

### "W_GetNumForName: PLAYPAL not found"

The WAD file is missing or incorrectly placed. Ensure:
- File exists at `initrd_contents/doom1.wad`
- Filename is lowercase
- Rebuild ISO after adding the file

### Black Screen / No Display

- Ensure framebuffer is initialized by the kernel
- Check serial output for error messages
- Verify DOOM entry is selected in boot menu

### Keyboard Not Working

- DOOM uses PS/2 scancodes
- Some virtual machines may need keyboard configuration
- Try pressing keys repeatedly if input seems stuck

## Legal Notice

DOOM is a registered trademark of id Software. The shareware version of DOOM1.WAD is freely distributable. For the full game, please purchase from official sources.

## References

- [doomgeneric](https://github.com/ozkl/doomgeneric) - Portable DOOM implementation
- [DOOM_wads Repository](https://github.com/Akbar30Bill/DOOM_wads) - WAD file downloads
- [Limine Bootloader](https://limine-bootloader.org/) - Boot protocol documentation

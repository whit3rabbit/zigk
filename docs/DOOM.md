# Running DOOM on ZK

This guide explains how to run the classic DOOM game on the ZK microkernel.

## Overview

ZK includes a port of [doomgeneric](https://github.com/ozkl/doomgeneric), a portable DOOM implementation that runs on custom platforms. The port uses the kernel's framebuffer for graphics and PS/2 keyboard for input.

## Requirements

- ZK kernel built with `zig build`
- DOOM1.WAD shareware file (legally free to distribute)
- QEMU (`qemu-system-x86_64` or `qemu-system-aarch64`)

## Architecture Support

DOOM builds for both x86_64 and aarch64:

```bash
zig build iso                    # x86_64 (default)
zig build iso -Darch=aarch64     # aarch64/ARM64
```

The aarch64 build uses C shims for va_list bootstrap to work around LLVM limitations with `@cVaArg` on ARM64.

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
3. Package everything into zk.iso

## Running DOOM

### Using QEMU

```bash
# x86_64 (default)
zig build run
zig build run-x86_64

# aarch64
zig build run -Darch=aarch64
zig build run-aarch64

# Or manually with QEMU
qemu-system-x86_64 -M q35 -m 128M -cdrom zk.iso -serial stdio
qemu-system-aarch64 -M virt -cpu max -m 512M -cdrom zk.iso -serial stdio
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
- **Input**: PS/2 keyboard scancodes via `sys_read_scancode`, mouse via `sys_read_input_event`
- **Timing**: `sys_clock_gettime` and `sys_nanosleep`
- **File I/O**: InitRD filesystem via standard `fopen`/`fread`

### File Locations

| File | Purpose |
|------|---------|
| `src/user/doom/main.zig` | Entry point |
| `src/user/doom/doomgeneric_zk.zig` | Platform hooks |
| `src/user/doom/i_sound.zig` | Sound system (/dev/dsp backend) |
| `src/user/doom/doomgeneric/` | Original DOOM source |
| `src/user/lib/libc.zig` | C library implementation |

### Screen Resolution

DOOM runs at 640x400 and is centered on the framebuffer if the display is larger.

## Known Limitations

- **No Music**: MIDI/OPL music is not implemented (SFX works via AC97)
- **No Save Games**: Filesystem writes are not implemented
- **Shareware Only**: Full DOOM requires purchasing the commercial WAD

## Input Support

- **Keyboard**: Full PS/2 keyboard support via scancodes
- **Mouse**: Relative motion and 3-button support via input events (8x sensitivity scaling)

## Troubleshooting

### "IWAD file '/doom1.wad' not found!"

The WAD file is not in the InitRD. The build system does not include it automatically.

1. Create the `initrd_contents/` directory at the project root
2. Download the WAD: `mkdir -p initrd_contents && wget https://github.com/Akbar30Bill/DOOM_wads/raw/refs/heads/master/doom.wad -O initrd_contents/doom1.wad`
3. Rebuild -- the build system copies everything from `initrd_contents/` into the InitRD tar

### "W_GetNumForName: PLAYPAL not found"

The WAD file is present but corrupt or wrong format. Ensure:
- File exists at `initrd_contents/doom1.wad`
- Filename is lowercase
- File is the shareware DOOM1.WAD (not DOOM2 or a mod)
- Rebuild after adding/replacing the file

### Title Screen Shows but Display Freezes (aarch64)

On aarch64, the framebuffer must be mapped as Non-Cacheable memory. If pixel writes are cached, they never reach the display hardware (ramfb device).

**Root cause**: The framebuffer page table entries used MAIR index 1 (Normal Write-Back) instead of MAIR index 2 (Normal Non-Cacheable). The `write_through` flag in `PageFlags` was ignored on aarch64.

**Fix**: `src/arch/aarch64/mm/paging.zig` -- the `attr_index` selection in `pageEntry()` must use MAIR index 2 when `write_through` is set:
```zig
.attr_index = if (flags.cache_disable) 0 else if (flags.write_through) 2 else 1,
```

**Symptoms**: QEMU window shows the kernel boot text but never switches to DOOM graphics, or shows the title screen once and never updates. Serial output shows "Entering main loop..." (the game runs, but display writes are invisible).

### Kernel Page Fault During Gameplay (aarch64)

Page faults in the kernel stack region (`0xffffa000...`) during DOOM gameplay, typically after navigating menus or starting a level.

**Root cause**: The `UsbDevice` struct in `src/drivers/usb/xhci/device.zig` is ~4312 bytes but was allocated from a single 4KB PMM page. The 216-byte overflow corrupted adjacent memory. On aarch64, XHCI runs in polling mode (from the timer tick callback), and the corrupted device struct caused faults when processing USB HID input events.

**Fix**: `device.zig` uses `PAGES_NEEDED` (comptime-calculated from `@sizeOf(UsbDevice)`) for both allocation and deallocation instead of hardcoded `1`.

**Symptoms**: Serial output shows `PageFault: SECURITY VIOLATION: User fault in kernel space ffffa000...` with varying addresses. Crash timing varies (may appear random). x86_64 may not crash because the adjacent HHDM page happens to contain benign data.

### Black Screen / No Display

- Ensure framebuffer is initialized by the kernel
- Check serial output for error messages
- Verify DOOM entry is selected in boot menu
- On aarch64, see "Title Screen Shows but Display Freezes" above

### Keyboard Not Working

- DOOM uses PS/2 scancodes
- On macOS with QEMU, keyboard input may not work in the graphical window due to Cocoa capture issues
- Try pressing keys repeatedly if input seems stuck
- On aarch64, keyboard input comes through USB HID (XHCI polling), not PS/2

## Legal Notice

DOOM is a registered trademark of id Software. The shareware version of DOOM1.WAD is freely distributable. For the full game, please purchase from official sources.

## References

- [doomgeneric](https://github.com/ozkl/doomgeneric) - Portable DOOM implementation
- [DOOM_wads Repository](https://github.com/Akbar30Bill/DOOM_wads) - WAD file downloads
- [Limine Bootloader](https://limine-bootloader.org/) - Boot protocol documentation

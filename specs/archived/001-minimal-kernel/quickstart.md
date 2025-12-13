# Quickstart: Zscapek Minimal Kernel

Build and run a minimal x86_64 kernel that boots via Limine, paints the screen,
and outputs debug messages via serial port.

## Prerequisites

### macOS

```bash
brew install xorriso qemu
```

Zig 0.15.x (or current stable) required. Install from [ziglang.org](https://ziglang.org/download/).

### Linux (Debian/Ubuntu)

```bash
sudo apt install xorriso qemu-system-x86
```

### Verify Installation

```bash
zig version        # Should show 0.15.x
qemu-system-x86_64 --version
xorriso --version
```

## Build and Run

### One Command

```bash
zig build run
```

This will:
1. Compile the kernel to `zig-out/bin/kernel.elf`
2. Download Limine bootloader binaries (first run only)
3. Assemble ISO filesystem
4. Create `zscapek.iso` with xorriso
5. Launch QEMU with the ISO and serial output

### Expected Result

- **QEMU window**: Dark blue screen
- **Terminal**: Serial output showing boot messages

```
Zscapek booting...
Framebuffer filled. Halting.
```

This confirms:
- Kernel booted successfully
- Serial port working (COM1)
- Framebuffer acquired from Limine
- Video memory write working
- CPU halted (low CPU usage)

### Build Only (No QEMU)

```bash
zig build iso
```

Creates `zscapek.iso` without launching QEMU. Use for testing on real hardware
or with a different emulator.

## Project Structure

```
zscapek/
├── build.zig          # Build system
├── build.zig.zon      # Dependencies (limine-zig)
├── limine.conf        # Bootloader configuration
├── src/
│   ├── main.zig       # Kernel entry point, framebuffer fill
│   ├── serial.zig     # COM1 serial port driver
│   ├── panic.zig      # Panic handler (outputs to serial)
│   ├── ssp.zig        # Stack smashing protection symbols
│   └── linker.ld      # Memory layout (high-half kernel)
├── limine/            # Limine bootloader (git clone, gitignored)
└── zscapek.iso           # Output (after build)
```

## Troubleshooting

### "xorriso not found"

Install xorriso:
```bash
# macOS
brew install xorriso

# Linux
sudo apt install xorriso
```

### "qemu-system-x86_64 not found"

Install QEMU:
```bash
# macOS
brew install qemu

# Linux
sudo apt install qemu-system-x86
```

### Limine Download Failed

If automatic download fails, manually clone Limine:
```bash
git clone https://github.com/limine-bootloader/limine.git --branch=v7.x-binary --depth=1
```

### Triple Fault / Immediate Reboot

Check:
1. Zig version is 0.15.x
2. Build completed without errors
3. Run with debug flags:

```bash
qemu-system-x86_64 -cdrom zscapek.iso -serial stdio -d int,cpu_reset -no-reboot
```

### No Serial Output

Check:
1. QEMU is run with `-serial stdio`
2. `serial.init()` is called before any output
3. COM1 port (0x3F8) is correct

### Black Screen (No Blue)

Framebuffer not initialized. Check:
1. limine.conf is correctly formatted
2. Kernel entry point exports `_start`
3. Base revision is accepted by Limine
4. Serial output for panic messages

### High CPU Usage After Boot

HLT instruction not reached. Check serial output for panic message.

## Debug Mode

For development, run QEMU with verbose debugging:

```bash
qemu-system-x86_64 \
    -cdrom zscapek.iso \
    -serial stdio \
    -d int,cpu_reset \
    -no-reboot \
    -m 128M
```

| Flag | Purpose |
|------|---------|
| `-serial stdio` | Show kernel serial output in terminal |
| `-d int,cpu_reset` | Log interrupts and CPU resets |
| `-no-reboot` | Halt on triple fault instead of reboot |
| `-m 128M` | Allocate 128MB RAM |

## Next Steps

After successful boot:
1. Modify `src/main.zig` to change the screen color
2. Add more serial debug messages
3. Run `zig build run` to see changes
4. Explore Limine's memory map request for heap initialization

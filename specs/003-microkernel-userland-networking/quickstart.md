# Quickstart: Microkernel with Userland and Networking

**Feature Branch**: `003-microkernel-userland-networking`
**Created**: 2025-12-04

## Prerequisites

### Required Tools

| Tool | Version | Purpose | Install (macOS) |
|------|---------|---------|-----------------|
| Zig | 0.15.x (or current stable) | Compiler | `brew install zig` or download from ziglang.org |
| QEMU | Any recent | x86_64 emulation | `brew install qemu` |
| xorriso | Any | ISO creation | `brew install xorriso` |
| Git | Any | Source control | `brew install git` |

**Note**: All ZigK specifications target Zig 0.15.x. See CLAUDE.md for build patterns.

### Verify Installation

```bash
zig version      # Should show 0.15.x
qemu-system-x86_64 --version
xorriso --version
```

---

## Quick Build & Run

```bash
# Clone repository (if not already done)
git clone https://github.com/your-repo/zigk.git
cd zigk

# Build and run in QEMU
zig build run

# Build only (creates ISO)
zig build

# Run with serial output to terminal
zig build run -- -serial stdio

# Run with GDB server for debugging
zig build run -- -s -S
```

---

## Build Outputs

After `zig build`:

```
zig-out/
├── bin/
│   └── kernel.elf     # Kernel ELF binary
└── iso/
    └── zigk.iso       # Bootable ISO image
```

---

## QEMU Options

**Note for Apple Silicon (macOS ARM64)**: All manual QEMU commands below require `-accel tcg` to use software emulation. The `zig build run` command handles this automatically.

### Basic Run

```bash
# macOS ARM64 (Apple Silicon)
qemu-system-x86_64 \
    -accel tcg \
    -cdrom zig-out/iso/zigk.iso \
    -m 128M \
    -serial stdio

# Intel/AMD (native)
qemu-system-x86_64 \
    -cdrom zig-out/iso/zigk.iso \
    -m 128M \
    -serial stdio
```

### With Networking (E1000)

```bash
# Add -accel tcg on Apple Silicon
qemu-system-x86_64 \
    -cdrom zig-out/iso/zigk.iso \
    -m 128M \
    -serial stdio \
    -netdev user,id=net0,hostfwd=udp::5555-:5555 \
    -device e1000,netdev=net0
```

### Ping the Kernel

With TAP networking (requires root):

```bash
# Terminal 1: Run QEMU with TAP (add -accel tcg on Apple Silicon)
sudo qemu-system-x86_64 \
    -cdrom zig-out/iso/zigk.iso \
    -m 128M \
    -serial stdio \
    -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
    -device e1000,netdev=net0,mac=52:54:00:12:34:56

# Terminal 2: Configure TAP and ping
sudo ip link set tap0 up
sudo ip addr add 10.0.2.1/24 dev tap0
ping 10.0.2.15  # Kernel's default IP
```

### Debug with GDB

```bash
# Terminal 1: Run QEMU with GDB server (add -accel tcg on Apple Silicon)
qemu-system-x86_64 \
    -cdrom zig-out/iso/zigk.iso \
    -m 128M \
    -serial stdio \
    -s -S  # -s: GDB on port 1234, -S: pause at start

# Terminal 2: Connect GDB (use lldb on macOS if gdb unavailable)
gdb zig-out/bin/kernel.elf
(gdb) target remote :1234
(gdb) break _start
(gdb) continue
```

---

## Project Structure

```
src/
├── main.zig                 # Entry point, Limine requests
├── hal/                     # Hardware Abstraction Layer
│   ├── hal.zig             # Unified HAL interface
│   └── x86_64/             # x86_64-specific code
│       ├── cpu.zig         # CPU control
│       ├── port_io.zig     # Port I/O
│       ├── gdt.zig         # GDT/TSS
│       ├── idt.zig         # IDT
│       ├── pic.zig         # 8259 PIC
│       ├── pit.zig         # Timer
│       └── pci.zig         # PCI enumeration
├── mem/                     # Memory Management
│   ├── pmm.zig             # Physical memory
│   ├── vmm.zig             # Virtual memory
│   └── heap.zig            # Kernel heap
├── drivers/                 # Device Drivers
│   ├── e1000.zig           # Network driver
│   ├── keyboard.zig        # PS/2 keyboard
│   └── serial.zig          # Serial port
├── net/                     # Network Stack
│   ├── ethernet.zig        # Ethernet parsing
│   ├── arp.zig             # ARP handling
│   ├── ipv4.zig            # IPv4 parsing
│   ├── icmp.zig            # ICMP (ping)
│   └── udp.zig             # UDP handling
├── proc/                    # Process Management
│   ├── thread.zig          # Thread structure
│   ├── scheduler.zig       # Round-robin scheduler
│   ├── syscall.zig         # Syscall handler
│   └── elf.zig             # ELF loader
└── shell/                   # Userland Shell
    └── shell.zig           # Simple command shell

limine.conf                  # Bootloader config
build.zig                    # Build system
build.zig.zon               # Dependencies
```

---

## Development Workflow

### 1. Make Changes

Edit source files in `src/`.

### 2. Build

```bash
zig build
```

Build errors will show in terminal with file:line references.

### 3. Test

```bash
# Quick test
zig build run

# With serial output
zig build run -- -serial stdio

# Test networking
zig build run -- -netdev user,id=net0 -device e1000,netdev=net0
```

### 4. Debug

```bash
# Enable debug output
zig build -Doptimize=Debug

# Run with QEMU monitor
zig build run -- -monitor stdio

# Trace interrupts
zig build run -- -d int
```

---

## Verification Checklist

### Boot Verification

- [ ] QEMU starts without triple fault
- [ ] Serial output shows "ZigK booting..."
- [ ] Framebuffer shows console output

### Memory Verification

- [ ] PMM initializes from Limine memory map
- [ ] VMM creates page tables
- [ ] Heap allocations succeed

### Interrupt Verification

- [ ] Timer interrupt fires at 100Hz
- [ ] Keyboard input works
- [ ] No spurious interrupts

### Network Verification

- [ ] E1000 device detected on PCI bus
- [ ] MAC address read from EEPROM
- [ ] ARP replies sent
- [ ] Ping replies sent

### Userland Verification

- [ ] Shell prompt appears
- [ ] Keyboard input echoed
- [ ] Basic commands work
- [ ] Syscalls return correct values

---

## Common Issues

### Triple Fault on Boot

- Check linker script for correct load address
- Verify GDT/IDT initialization order
- Enable QEMU `-d int` to see exception

### No Serial Output

- Verify `-serial stdio` flag
- Check serial port initialization (baud rate)
- Ensure serial.writeString() called

### E1000 Not Found

- Verify QEMU has `-device e1000` flag
- Check PCI enumeration code
- Confirm vendor/device ID match

### Page Fault

- Check virtual address is mapped
- Verify page table flags (present, writable)
- Use CR2 to see faulting address

### Keyboard Not Working

- Verify IRQ1 unmasked
- Check scancode translation table
- Ensure PIC EOI sent

---

## Success Criteria

### SC-001: Ping Reply

```bash
# From host
ping 10.0.2.15
# Should receive replies within 100ms
```

### SC-002: Scheduler Switching

```bash
# Serial output shows alternating:
[network] handling packet...
[shell] waiting for input...
```

### SC-003: Shell Input

```bash
# Type in QEMU window, see characters echoed
> help
Available commands: help, echo, exit
```

### SC-006: Stability

```bash
# Run for 10 minutes with ping load
ping 10.0.2.15 &
sleep 600
# No crashes, ping replies continue
```

---

## Creating an InitRD

### Build InitRD with Game Files

```bash
# Create directory structure
mkdir -p initrd_contents

# Add game data files
cp doom.wad initrd_contents/
cp doom1.wad initrd_contents/

# Create TAR archive
tar cvf initrd.tar -C initrd_contents .

# Copy to ISO boot directory
cp initrd.tar iso/boot/initrd.tar
```

### Limine Configuration

Add to `limine.conf`:

```limine
PROTOCOL=limine

/ZigK
    PROTOCOL=limine
    KERNEL_PATH=boot:///kernel.elf
    MODULE_PATH=boot:///initrd.tar
    MODULE_CMDLINE=initrd
```

### Verify InitRD Loading

```bash
# Serial output should show:
[initrd] Loaded 2.5MB from Limine module
[initrd] Found 3 files: doom.wad, doom1.wad, config.txt
```

---

## Host-Side Network Debugging

### Capture Packets with tcpdump

```bash
# Terminal 1: Run QEMU with TAP
sudo qemu-system-x86_64 \
    -cdrom zig-out/iso/zigk.iso \
    -m 128M \
    -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
    -device e1000,netdev=net0,mac=52:54:00:12:34:56

# Terminal 2: Capture all packets on tap0
sudo tcpdump -i tap0 -xx -vv

# Terminal 3: Send ping to trigger traffic
ping 10.0.2.15
```

### Verify Packet Format

Look for proper byte order in tcpdump output:

```
# Correct ARP reply (Big Endian)
0x0806        # EtherType: ARP
0x0001        # Hardware type: Ethernet
0x0800        # Protocol type: IPv4
0x0002        # Operation: Reply

# Incorrect (Little Endian - BUG!)
0x0608        # EtherType: WRONG!
```

---

## Next Steps

1. **Implement memory management** - PMM → VMM → Heap (with coalescing)
2. **Set up interrupts** - GDT → IDT → PIC → Timer (16-byte RSP alignment)
3. **Build scheduler** - Threads → Context switch → Round-robin → Idle Thread
4. **Add networking** - PCI → E1000 → Ethernet → ARP → ICMP → UDP
5. **Create InitRD** - Limine Modules → TAR parsing → File syscalls
6. **Build userland** - Syscalls → ELF loader → Shell → libc
7. **Integrate Doom** - doomgeneric → Framebuffer → Keyboard scancodes

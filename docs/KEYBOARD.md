# Keyboard Input

This document describes keyboard input handling in zscapek, covering both PS/2 and USB keyboard paths.

## Architecture Overview

```
+-------------------+     +-------------------+
|   PS/2 Keyboard   |     |   USB Keyboard    |
|   (IRQ1)          |     |   (XHCI HID)      |
+--------+----------+     +--------+----------+
         |                         |
         v                         v
+--------+----------+     +--------+----------+
| keyboard.handleIrq|     | hid.handleKeyboard|
|                   |     |     Report()      |
+--------+----------+     +--------+----------+
         |                         |
         |                         v
         |                +--------+----------+
         |                | keyboard.inject   |
         |                |     Scancode()    |
         |                +--------+----------+
         |                         |
         v                         v
+--------+-------------------------+----------+
|           scancode_buffer                   |
|         (Ring Buffer, 256 bytes)            |
+---------------------+------------------------+
                      |
                      v
+---------------------+------------------------+
|         sys_read_scancode (1003)            |
|    Polls USB events, returns scancode       |
+---------------------+------------------------+
                      |
                      v
+---------------------+------------------------+
|              Userland (Doom)                |
+----------------------------------------------+
```

## Input Paths

### PS/2 Keyboard (Legacy Path)

The PS/2 keyboard uses IRQ1 and the Intel 8042 controller at ports 0x60/0x64.

**Flow:**
1. Key press generates IRQ1
2. `keyboard.handleIrq()` reads scancode from port 0x60
3. Scancode stored in `scancode_buffer`
4. Userland retrieves via `sys_read_scancode`

**Relevant Files:**
- `src/drivers/input/keyboard.zig` - PS/2 keyboard driver
- `src/arch/x86_64/interrupts.zig` - IRQ1 handler dispatch

### USB Keyboard (Modern Path)

USB keyboards use the XHCI controller with HID Boot Protocol.

**Flow:**
1. XHCI driver detects USB keyboard during port scan
2. HID polling is started via interrupt transfers
3. When key is pressed, HID report is received
4. `hid.handleKeyboardReport()` converts to PS/2 scancodes
5. `keyboard.injectScancode()` stores in buffer
6. Userland retrieves via `sys_read_scancode`

**Relevant Files:**
- `src/drivers/usb/xhci/root.zig` - XHCI controller driver
- `src/drivers/usb/class/hid.zig` - HID class driver
- `src/drivers/input/keyboard.zig` - Scancode injection

## QEMU Configuration

### USB Keyboard (Recommended)

```bash
qemu-system-x86_64 -M q35 -m 512M -cdrom zscapek.iso \
    -device qemu-xhci,id=xhci \
    -device usb-kbd \
    -serial stdio \
    -display cocoa \
    -accel tcg
```

**Important:** The `-display` option must allow keyboard focus:
- macOS: `-display cocoa`
- Linux: `-display gtk` or `-display sdl`
- Headless with VNC: `-display vnc=:0`

With `-display none`, keyboard input cannot be captured.

### PS/2 Keyboard (Fallback)

To use PS/2 instead of USB, omit the USB keyboard device:

```bash
qemu-system-x86_64 -M q35 -m 512M -cdrom zscapek.iso \
    -device qemu-xhci,id=xhci \
    -serial stdio \
    -display cocoa \
    -accel tcg
```

## MSI-X Polling Workaround

On some platforms (notably macOS with TCG), XHCI MSI-X interrupts may not fire reliably. The kernel implements a software polling fallback:

```zig
// In sys_read_scancode (src/kernel/sys/syscall/misc/custom.zig)
pub fn sys_read_scancode() SyscallError!usize {
    // Poll USB events first (fallback for when MSI-X interrupts aren't firing)
    _ = usb.xhci.pollEvents();

    if (keyboard.getScancode()) |scancode| {
        return scancode;
    }
    return error.EAGAIN;
}
```

This ensures USB keyboard input works even without interrupt-driven event processing.

## Scancode Format

The kernel uses PS/2 Set 1 scancodes (the same format used by PC AT keyboards):

| Key | Make Code | Break Code |
|-----|-----------|------------|
| Enter | 0x1C | 0x9C |
| Escape | 0x01 | 0x81 |
| Space | 0x39 | 0xB9 |
| Up Arrow | 0xE0 0x48 | 0xE0 0xC8 |
| Down Arrow | 0xE0 0x50 | 0xE0 0xD0 |
| Left Arrow | 0xE0 0x4B | 0xE0 0xCB |
| Right Arrow | 0xE0 0x4D | 0xE0 0xCD |

Extended keys (arrows, etc.) are prefixed with 0xE0.

## Userland API

### sys_read_scancode (1003)

Non-blocking syscall to read a raw keyboard scancode.

```zig
const scancode = syscall.read_scancode() catch |err| {
    if (err == error.WouldBlock) {
        // No scancode available
    }
};
```

**Returns:**
- Scancode value (0x00-0xFF) on success
- `EAGAIN` if no scancode available

### sys_getchar (1001)

Blocking syscall to read an ASCII character.

```zig
const char = syscall.getchar();
```

This blocks until a printable character is available.

## Troubleshooting

### Keyboard not responding in QEMU

1. **Check display mode**: Ensure you're using a display that captures keyboard (not `-display none`)
2. **Focus the QEMU window**: Click inside the QEMU window to capture input
3. **Release mouse grab**: Press Ctrl+Alt+G to toggle mouse grab if needed

### No USB keyboard detected

Check serial output for:
```
[INFO]  XHCI: Found HID Boot Keyboard on interface 0
[INFO]  XHCI: USB keyboard enumerated successfully on slot 1
[INFO]  XHCI: Starting HID polling for slot 1
```

If missing, verify QEMU command includes `-device qemu-xhci,id=xhci -device usb-kbd`.

### PS/2 keyboard not working

Check for IRQ1 activity:
```
[INFO]  KBD IRQ #1
```

If no IRQs after initialization, ensure:
- IOAPIC is properly configured
- IRQ1 is unmasked: `[INFO]  Keyboard IRQ1 explicitly enabled`

## Debug Output

Enable verbose keyboard debugging by uncommenting in `src/drivers/input/keyboard.zig`:

```zig
// In handleIrq():
console.debug("KBD: scancode=0x{X:0>2}", .{scancode});
```

For USB keyboard debugging, check `src/drivers/usb/class/hid.zig`:

```zig
// In handleKeyboardReport():
console.debug("HID: key report received", .{});
```

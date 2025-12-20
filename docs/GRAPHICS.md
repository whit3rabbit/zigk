# Graphics and Debugging Subsystem

This document describes the design and implementation of the graphics and debugging subsystem in Zscapek.

## Overview

The subsystem provides a robust, layer-agnostic way to output information to the user and developer. It is designed with two primary goals:
1.  **Reliability**: Ensure debug logs are captured even in the event of partial system failure (using Polling UART).
2.  **Extensibility**: Allow swapping the underlying video hardware (Framebuffer, VirtIO-GPU, etc.) without changing the upper-level console logic.

## Architecture

### 1. Hardware Abstraction Layer (`src/drivers/video/interface.zig`)

The core of the graphics subsystem is the `GraphicsDevice` interface. This is a vtable-based abstraction that allows the kernel to interact with any video device uniformly.

```zig
pub const GraphicsDevice = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getMode: *const fn (ctx: *anyopaque) VideoMode,
        putPixel: *const fn (ctx: *anyopaque, x: u32, y: u32, color: Color) void,
        fillRect: *const fn (ctx: *anyopaque, x: u32, y: u32, w: u32, h: u32, color: Color) void,
        drawBuffer: *const fn (ctx: *anyopaque, x: u32, y: u32, w: u32, h: u32, buffer: []const u32) void,
    };
};
```

### 2. Drivers

#### Serial Port (`src/drivers/serial/uart.zig`)
-   **Chipset**: 16550 UART (Standard PC Serial).
-   **Mode**: Polling (Interrupts disabled during output). This ensures that `print` functions can be called safely from within interrupt handlers or panic contexts without deadlock or loss of data.
-   **Configuration**: 38400 baud, 8 data bits, No parity, 1 stop bit (8N1).

#### Framebuffer (`src/drivers/video/framebuffer.zig`)
-   **Backend**: Software rendering into a memory-mapped linear framebuffer.
-   **Initialization**: Configured by the Limine bootloader. The kernel does not perform mode-setting; it uses the mode provided by the bootloader.
-   **Pixel Format**: 32-bit TrueColor (BGRA/RGBA).

### 3. Graphical Console (`src/drivers/video/console.zig`)
-   **Function**: Renders text onto a `GraphicsDevice`.
-   **Font**: Embedded 8x8 bitmap font (ASCII 0x00-0x7F).
-   **Features**:
    -   Cursor tracking (x, y).
    -   Automatic wrapping.
    -   Scrolling (via software buffer shift and redraw).
    -   Basic control characters (`\n`, `\r`, `\t`, `\b`).

### 4. Kernel Integration (`src/kernel/core/debug/console.zig`)
-   The kernel's `console.print` function is a multiplexer.
-   It maintains a list of registered `Backend`s.
-   When `print` is called, the string is sent to **all** registered backends.
-   This allows simultaneous output to the serial port (for capture/debugging) and the screen (for immediate user feedback).

## Directory Structure

```text
src/drivers/
├── serial/
│   └── uart.zig        # Serial Port Driver
└── video/
    ├── root.zig        # Module export
    ├── interface.zig   # GraphicsDevice Interface
    ├── framebuffer.zig # Framebuffer Implementation
    ├── console.zig     # Text Rendering & Management
    └── font.zig        # Bitmap Font Data
```

## Future Work

1.  **Hardware Acceleration**:
    -   Implement a driver for `virtio-gpu` to offload rendering commands to the host (in QEMU/VM environments).
    -   This would be implemented as a new struct conforming to `GraphicsDevice`.

2.  **Performance Optimization**:
    -   **Double Buffering**: Render the console to a backbuffer and flip/blit only changed regions to prevent tearing.
    -   **Dirty Rectangles**: Only redraw the parts of the screen that changed during scrolling/updates.

3.  **Typography**:
    -   Support for PSF fonts (PC Screen Font) for different sizes/styles.
    -   Integration of a font rendering engine (e.g., FreeType port) for TrueType support in higher-level UI.

4.  **Terminal Emulation**:
    -   Implement ANSI escape code support (colors, cursor positioning) to support rich terminal applications (shell, vim).

5.  **Input Integration**:
    -   Couple the console with the Keyboard driver to create a fully interactive TTY.

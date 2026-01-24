#!/usr/bin/env python3
"""
UEFI API Query Tool for zk kernel bootloader.

Query UEFI protocols, boot services, and common patterns used in Zig UEFI bootloaders.

Usage:
    python uefi_query.py system       # System table structure
    python uefi_query.py boot         # Boot services overview
    python uefi_query.py event        # Event/Timer APIs
    python uefi_query.py text         # SimpleTextInput/Output protocols
    python uefi_query.py gop          # Graphics Output Protocol
    python uefi_query.py memmap       # Memory map and types
    python uefi_query.py file         # File protocol and loading
    python uefi_query.py exit         # ExitBootServices pattern
    python uefi_query.py paging       # Page table setup in UEFI (x86_64)
    python uefi_query.py aarch64      # AArch64 paging (TTBR/MAIR/TCR)
    python uefi_query.py errors       # Common errors and fixes
"""

import sys

PATTERNS = {
    "system": """
## UEFI System Table

The System Table is the main entry point to UEFI services.

### Access in Zig
```zig
const uefi = std.os.uefi;
const system_table = uefi.system_table;

// Key fields
const bs = system_table.boot_services orelse return error.NoBootServices;
const con_in = system_table.con_in;   // SimpleTextInput (nullable)
const con_out = system_table.con_out; // SimpleTextOutput (nullable)
const config_table = system_table.configuration_table;
```

### System Table Structure
| Field | Type | Description |
|-------|------|-------------|
| hdr | TableHeader | Signature, revision, CRC |
| firmware_vendor | [*:0]u16 | Null-terminated UCS-2 string |
| firmware_revision | u32 | Vendor-specific revision |
| con_in_handle | Handle | Console input device |
| con_in | ?*SimpleTextInput | Console input protocol |
| con_out_handle | Handle | Console output device |
| con_out | ?*SimpleTextOutput | Console output protocol |
| std_err_handle | Handle | Standard error device |
| std_err | ?*SimpleTextOutput | Standard error protocol |
| runtime_services | *RuntimeServices | Available after ExitBootServices |
| boot_services | ?*BootServices | NULL after ExitBootServices |
| configuration_table | [*]ConfigurationTable | ACPI, SMBIOS, etc. |

### Finding ACPI RSDP
```zig
fn findRsdp(st: *uefi.tables.SystemTable) u64 {
    const acpi20_guid = uefi.Guid{
        .time_low = 0x8868e871,
        .time_mid = 0xe4f1,
        .time_high_and_version = 0x11d3,
        .clock_seq_high_and_reserved = 0xbc,
        .clock_seq_low = 0x22,
        .node = [_]u8{ 0x00, 0x80, 0xc7, 0x3c, 0x88, 0x81 },
    };

    const entries = st.configuration_table[0..st.number_of_table_entries];
    for (entries) |entry| {
        if (std.mem.eql(u8,
            std.mem.asBytes(&entry.vendor_guid),
            std.mem.asBytes(&acpi20_guid))) {
            return @intFromPtr(entry.vendor_table);
        }
    }
    return 0;
}
```
""",

    "boot": """
## Boot Services Overview

Boot services are available only before ExitBootServices is called.

### Common Boot Services
```zig
const bs = system_table.boot_services orelse return error.NoBootServices;

// Memory allocation
const pages = bs.allocatePages(.allocate_any_pages, .loader_data, count, null);

// Protocol location
var gop: ?*uefi.protocol.GraphicsOutput = undefined;
bs.locateProtocol(&uefi.protocol.GraphicsOutput.guid, null, @ptrCast(&gop));

// Event creation (see 'event' topic for details)
const evt = bs.createEvent(.{ .timer = true }, .{}) catch return error.EventFailed;

// Timer control
bs.setTimer(evt, .relative, 10_000_000) catch {};  // 1 second

// Stall (busy wait)
bs.stall(10_000) catch {};  // 10ms (microsecond units)

// Exit boot services (see 'exit' topic)
bs._exitBootServices(image_handle, map_key);
```

### Memory Type Constants
| Type | Value | Usage |
|------|-------|-------|
| reserved_memory | 0 | Not usable |
| loader_code | 1 | UEFI app code |
| loader_data | 2 | UEFI app data |
| boot_services_code | 3 | BS code (reclaimable) |
| boot_services_data | 4 | BS data (reclaimable) |
| runtime_services_code | 5 | Must preserve mapping |
| runtime_services_data | 6 | Must preserve mapping |
| conventional_memory | 7 | Free for OS use |
| acpi_reclaim_memory | 9 | ACPI tables (reclaimable) |
| acpi_memory_nvs | 10 | ACPI NVS (preserve) |
| memory_mapped_io | 11 | MMIO regions |

### Important Notes
- All Boot Services return error unions in Zig - use `catch {}` or handle
- Boot Services become invalid after ExitBootServices
- allocatePages returns physical addresses
""",

    "event": """
## UEFI Event and Timer APIs

### Creating Events
```zig
const bs = system_table.boot_services.?;

// Create timer event
var timer_event: ?uefi.Event = null;
if (bs.createEvent(.{ .timer = true }, .{})) |evt| {
    timer_event = evt;
} else |_| {
    // Event creation failed
}

defer {
    if (timer_event) |evt| {
        bs.closeEvent(evt) catch {};
    }
}
```

### Timer Control
```zig
// Units: 100-nanosecond intervals
const ONE_SECOND: u64 = 10_000_000;  // 10^7 * 100ns = 1s
const ONE_MS: u64 = 10_000;          // 10^4 * 100ns = 1ms

// Set relative timer (one-shot, fires after delay)
bs.setTimer(timer_event.?, .relative, 5 * ONE_SECOND) catch {};

// Set periodic timer (repeating)
bs.setTimer(timer_event.?, .periodic, ONE_SECOND) catch {};

// Cancel timer
bs.setTimer(timer_event.?, .cancel, 0) catch {};
```

### Waiting for Events
```zig
// Wait for single event (blocking)
const events = [_]uefi.Event{timer_event.?};
if (bs.waitForEvent(&events)) |result| {
    // result.index is the signaled event index
    // result.event is the signaled event
} else |_| {
    // Wait failed
}

// Non-blocking check via checkEvent
// (not directly exposed, use readKeyStroke pattern instead)
```

### Keyboard + Timer Pattern (Menu)
```zig
while (true) {
    // Check keyboard (non-blocking)
    if (con_in.readKeyStroke()) |key| {
        // Handle key input
        handleKey(key);
    } else |_| {
        // No key - check timer
        if (timer_event) |evt| {
            const events = [_]uefi.Event{evt};
            if (bs.waitForEvent(&events)) |_| {
                // Timer fired
                countdown -= 1;
                if (countdown == 0) return .default;
                // Reset timer
                bs.setTimer(evt, .relative, ONE_SECOND) catch {};
            } else |_| {}
        }
    }

    // Prevent busy-wait
    bs.stall(10_000) catch {};  // 10ms
}
```

### TimerType Enum
| Value | Name | Behavior |
|-------|------|----------|
| 0 | cancel | Stop the timer |
| 1 | periodic | Fire repeatedly at interval |
| 2 | relative | Fire once after delay |
""",

    "text": """
## SimpleTextInput / SimpleTextOutput Protocols

### Console Output
```zig
const con_out = system_table.con_out orelse return error.NoConsole;

// Clear screen
_ = con_out.clearScreen() catch {};

// Set cursor position (column, row)
_ = con_out.setCursorPosition(0, 0) catch {};

// Output UCS-2 string (null-terminated)
var msg = [_:0]u16{ 'H', 'i', '\\r', '\\n', 0 };
_ = con_out.outputString(&msg) catch {};

// Helper: print ASCII string
fn printStr(con_out: *uefi.protocol.SimpleTextOutput, str: []const u8) void {
    for (str) |c| {
        var buf = [2:0]u16{ c, 0 };
        _ = con_out.outputString(&buf) catch {};
    }
}

// Helper: print with newline
fn printLine(con_out: *uefi.protocol.SimpleTextOutput, str: []const u8) void {
    printStr(con_out, str);
    var crlf = [3:0]u16{ '\\r', '\\n', 0 };
    _ = con_out.outputString(&crlf) catch {};
}
```

### Console Input
```zig
const con_in = system_table.con_in orelse return error.NoConsole;

// Reset input buffer
_ = con_in.reset(false) catch {};

// Read key (returns error if no key available - non-blocking!)
if (con_in.readKeyStroke()) |key| {
    // key.scan_code: special keys (arrows, function keys)
    // key.unicode_char: printable characters
    switch (key.scan_code) {
        0x01 => { /* Up arrow */ },
        0x02 => { /* Down arrow */ },
        0x03 => { /* Right arrow */ },
        0x04 => { /* Left arrow */ },
        else => {
            if (key.unicode_char == 0x000D) { /* Enter */ }
            if (key.unicode_char == 0x001B) { /* Escape */ }
        },
    }
} else |_| {
    // No key available (NOT an error condition)
}
```

### Key Scan Codes
| Code | Key |
|------|-----|
| 0x00 | None (use unicode_char) |
| 0x01 | Up Arrow |
| 0x02 | Down Arrow |
| 0x03 | Right Arrow |
| 0x04 | Left Arrow |
| 0x05 | Home |
| 0x06 | End |
| 0x07 | Insert |
| 0x08 | Delete |
| 0x09 | Page Up |
| 0x0A | Page Down |
| 0x0B-0x14 | F1-F10 |
| 0x17 | Escape |

### Unicode Characters
| Code | Meaning |
|------|---------|
| 0x0008 | Backspace |
| 0x0009 | Tab |
| 0x000A | Line Feed (\\n) |
| 0x000D | Carriage Return (\\r) |
| 0x001B | Escape |
| 0x0020+ | Printable ASCII |

### Key Type in Zig
```zig
// readKeyStroke returns Key.Input, not Key!
const Key = uefi.protocol.SimpleTextInput.Key;

fn handleKey(key: Key.Input) void {
    // key.scan_code: u16
    // key.unicode_char: u16
}
```
""",

    "gop": """
## Graphics Output Protocol (GOP)

### Locating GOP
```zig
const bs = system_table.boot_services.?;
var gop: ?*uefi.protocol.GraphicsOutput = undefined;

const status = bs.locateProtocol(
    &uefi.protocol.GraphicsOutput.guid,
    null,
    @ptrCast(&gop),
);

if (status != .success or gop == null) {
    return error.NoGop;
}
```

### Getting Framebuffer Info
```zig
const mode = gop.?.mode;
const info = mode.info;

const fb_info = FramebufferInfo{
    .address = mode.frame_buffer_base,
    .size = mode.frame_buffer_size,
    .width = info.horizontal_resolution,
    .height = info.vertical_resolution,
    .pitch = info.pixels_per_scan_line * 4,  // Assumes 32bpp
    .bpp = 32,
    .red_mask_shift = 16,    // Typical BGR format
    .green_mask_shift = 8,
    .blue_mask_shift = 0,
};
```

### Mode Information
```zig
const ModeInfo = extern struct {
    version: u32,
    horizontal_resolution: u32,
    vertical_resolution: u32,
    pixel_format: PixelFormat,
    pixel_information: PixelBitmask,
    pixels_per_scan_line: u32,
};

const PixelFormat = enum(u32) {
    rgb_reserved_8bit_per_color = 0,  // RGB (blue in low byte)
    bgr_reserved_8bit_per_color = 1,  // BGR (red in low byte)
    bit_mask = 2,                      // Use pixel_information
    blt_only = 3,                      // No direct framebuffer
};
```

### Drawing to Framebuffer
```zig
fn putPixel(fb: *FramebufferInfo, x: u32, y: u32, color: u32) void {
    const offset = y * fb.pitch + x * 4;
    const ptr: [*]u32 = @ptrFromInt(fb.address + offset);
    ptr[0] = color;
}

// Note: Framebuffer address is physical, but identity-mapped
// during boot services, so direct access works before ExitBootServices
```

### Mode Enumeration
```zig
// List available modes
var i: u32 = 0;
while (i < gop.?.mode.max_mode) : (i += 1) {
    var info_size: usize = undefined;
    var info: *uefi.protocol.GraphicsOutput.Mode.Info = undefined;

    if (gop.?.queryMode(i, &info_size, &info) == .success) {
        // info.horizontal_resolution, info.vertical_resolution
    }
}

// Set mode
_ = gop.?.setMode(mode_number);
```
""",

    "memmap": """
## UEFI Memory Map

### Getting Memory Map
```zig
const bs = system_table.boot_services.?;

var memmap_size: usize = 0;
var memmap_key: usize = undefined;
var desc_size: usize = undefined;
var desc_version: u32 = undefined;

// First call to get required size
_ = bs.getMemoryMap(&memmap_size, null, &memmap_key, &desc_size, &desc_version);

// Allocate buffer (add extra space for allocation itself)
memmap_size += 2 * desc_size;
const buffer = bs.allocatePool(.loader_data, memmap_size) catch return error.AllocFailed;

// Second call to get actual map
const status = bs.getMemoryMap(&memmap_size, buffer, &memmap_key, &desc_size, &desc_version);
if (status != .success) return error.MemMapFailed;
```

### Memory Descriptor
```zig
const MemoryDescriptor = extern struct {
    type: MemoryType,
    physical_start: u64,
    virtual_start: u64,
    number_of_pages: u64,
    attribute: u64,
};
```

### Memory Types for Kernel
| Type | Usable by OS | Notes |
|------|--------------|-------|
| conventional_memory | Yes | Main free memory |
| boot_services_code | Yes | After ExitBootServices |
| boot_services_data | Yes | After ExitBootServices |
| loader_code | Yes | After kernel takes over |
| loader_data | Yes | After kernel takes over |
| acpi_reclaim_memory | After parsing | ACPI tables |
| runtime_services_code | No | Keep mapped |
| runtime_services_data | No | Keep mapped |
| reserved_memory | No | Hardware reserved |
| acpi_memory_nvs | No | ACPI sleep state |
| memory_mapped_io | No | Device MMIO |

### Iterating Descriptors
```zig
var offset: usize = 0;
while (offset < memmap_size) : (offset += desc_size) {
    const desc: *uefi.tables.MemoryDescriptor = @ptrFromInt(
        @intFromPtr(buffer) + offset
    );

    if (desc.type == .conventional_memory) {
        const base = desc.physical_start;
        const size = desc.number_of_pages * 4096;
        // Add to free list
    }
}
```

### Finding Max Physical Address
```zig
fn findMaxPhysical(buffer: [*]u8, size: usize, desc_size: usize) u64 {
    var max: u64 = 0;
    var offset: usize = 0;

    while (offset < size) : (offset += desc_size) {
        const desc: *uefi.tables.MemoryDescriptor = @ptrFromInt(
            @intFromPtr(buffer) + offset
        );
        const end = desc.physical_start + desc.number_of_pages * 4096;
        if (end > max) max = end;
    }
    return max;
}
```
""",

    "file": """
## UEFI File Protocol

### Loading Files from ESP
```zig
const bs = system_table.boot_services.?;

// 1. Get loaded image protocol
var loaded_image: ?*uefi.protocol.LoadedImage = undefined;
_ = bs.handleProtocol(
    uefi.handle,
    &uefi.protocol.LoadedImage.guid,
    @ptrCast(&loaded_image),
);

// 2. Get file system from boot device
var fs: ?*uefi.protocol.SimpleFileSystem = undefined;
_ = bs.handleProtocol(
    loaded_image.?.device_handle.?,
    &uefi.protocol.SimpleFileSystem.guid,
    @ptrCast(&fs),
);

// 3. Open root volume
var root: ?*uefi.protocol.File = undefined;
_ = fs.?.openVolume(&root);

// 4. Open file
var file: ?*uefi.protocol.File = undefined;
const path = std.unicode.utf8ToUtf16LeStringLiteral("\\\\boot\\\\kernel.elf");
const status = root.?.open(&file, path, File.efi_file_mode_read, 0);
if (status != .success) return error.FileNotFound;

defer _ = file.?.close();
```

### Reading File
```zig
// Get file size
var info_size: usize = 256;
var info_buffer: [256]u8 = undefined;
_ = file.?.getInfo(&uefi.protocol.File.efi_file_info_id, &info_size, &info_buffer);

const file_info: *uefi.protocol.File.FileInfo = @ptrCast(@alignCast(&info_buffer));
const file_size = file_info.file_size;

// Allocate and read
const buffer = bs.allocatePool(.loader_data, file_size) catch return error.AllocFailed;
var read_size = file_size;
_ = file.?.read(&read_size, buffer);
```

### Seeking
```zig
// Seek to position
_ = file.?.setPosition(offset);

// Get current position
var pos: u64 = undefined;
_ = file.?.getPosition(&pos);
```

### Path Format
- Use UCS-2 (UTF-16LE) strings
- Use backslash `\\\\` as separator
- Paths are relative to volume root
- Common paths:
  - `\\\\EFI\\\\BOOT\\\\BOOTX64.EFI` - Default bootloader
  - `\\\\boot\\\\kernel.elf` - Kernel location
  - `\\\\boot\\\\initrd.tar` - Initial ramdisk
""",

    "exit": """
## ExitBootServices Pattern

### Critical Requirements
1. Memory map key MUST match current state
2. NO UEFI calls after successful exit
3. Must handle key mismatch with retry

### Standard Pattern
```zig
fn exitBootServices(bs: *uefi.tables.BootServices, image: uefi.Handle) !usize {
    var memmap_size: usize = 0;
    var memmap_key: usize = undefined;
    var desc_size: usize = undefined;
    var desc_version: u32 = undefined;

    // Get initial size
    _ = bs.getMemoryMap(&memmap_size, null, &memmap_key, &desc_size, &desc_version);
    memmap_size += 2 * desc_size;  // Room for this allocation

    const buffer = bs.allocatePool(.loader_data, memmap_size) catch
        return error.AllocFailed;

    // Get map (this may change the key!)
    _ = bs.getMemoryMap(&memmap_size, buffer, &memmap_key, &desc_size, &desc_version);

    // First attempt
    var status = bs._exitBootServices(image, memmap_key);

    if (status != .success) {
        // Map changed during allocation - get fresh key and retry
        _ = bs.getMemoryMap(&memmap_size, buffer, &memmap_key, &desc_size, &desc_version);
        status = bs._exitBootServices(image, memmap_key);

        if (status != .success) {
            // Critical failure - cannot continue
            while (true) asm volatile ("hlt");
        }
    }

    // === NO UEFI BOOT SERVICES AFTER THIS POINT ===
    return memmap_key;
}
```

### What Becomes Invalid
After ExitBootServices:
- `system_table.boot_services` -> NULL
- All Boot Services functions
- Timer events
- Console I/O (unless serial used directly)
- File system access
- Memory allocation via UEFI

### What Remains Valid
- Runtime Services (via `system_table.runtime_services`)
- Memory map (your copy)
- Framebuffer (if GOP was used)
- Any data you copied to your own buffers
- Serial port (via direct I/O, not UEFI)

### Serial Debug After Exit
```zig
fn serialWrite(data: u8) void {
    asm volatile ("outb %%al, %%dx"
        :
        : [val] "{al}" (data),
          [port] "{dx}" (@as(u16, 0x3F8)),
    );
}

fn serialPrint(msg: []const u8) void {
    for (msg) |c| {
        serialWrite(c);
    }
}
```
""",

    "paging": """
## Page Table Setup in UEFI Bootloader (x86_64)

### Memory Layout Goals
```text
Virtual Address              Physical Address
0xFFFF_FFFF_8000_0000  ->   Kernel ELF segments
0xFFFF_8000_0000_0000  ->   0x0 (HHDM - all physical memory)
0x0000_0000_0000_0000  ->   0x0 (Identity map - temporary)
```

### Page Table Allocation
```zig
fn allocatePageTable(bs: *uefi.tables.BootServices) !u64 {
    var phys: u64 = undefined;
    const status = bs.allocatePages(
        .allocate_any_pages,
        .loader_data,
        1,  // 4KB page
        &phys,
    );
    if (status != .success) return error.AllocFailed;

    // Zero the page
    const ptr: [*]u8 = @ptrFromInt(phys);
    @memset(ptr[0..4096], 0);

    return phys;
}
```

### Creating PML4 with HHDM
```zig
const HHDM_OFFSET: u64 = 0xFFFF_8000_0000_0000;
const PAGE_PRESENT: u64 = 1 << 0;
const PAGE_WRITABLE: u64 = 1 << 1;
const PAGE_HUGE: u64 = 1 << 7;  // 2MB/1GB pages

fn createPageTables(bs: *BootServices, max_phys: u64) !u64 {
    const pml4_phys = try allocatePageTable(bs);
    const pml4: [*]u64 = @ptrFromInt(pml4_phys);

    // Map HHDM (0xFFFF_8000... -> 0x0)
    const hhdm_pml4_idx = (HHDM_OFFSET >> 39) & 0x1FF;  // 256

    // Use 1GB pages if available, else 2MB
    // ... (create PDPT, PD entries)

    // Identity map low memory (temporary, for transition)
    pml4[0] = pdpt_phys | PAGE_PRESENT | PAGE_WRITABLE;

    return pml4_phys;
}
```

### Loading Page Tables
```zig
fn loadPageTables(pml4_phys: u64) void {
    // Load CR3 with new PML4
    asm volatile (
        "mov %[pml4], %%cr3"
        :
        : [pml4] "r" (pml4_phys),
        : "memory"
    );
}
```

### Kernel Segment Mapping
```zig
// Map kernel ELF segments with proper permissions
fn mapKernelSegment(
    pml4: [*]u64,
    virt: u64,
    phys: u64,
    size: u64,
    writable: bool,
    executable: bool,
) !void {
    var flags: u64 = PAGE_PRESENT;
    if (writable) flags |= PAGE_WRITABLE;
    if (!executable) flags |= (1 << 63);  // NX bit

    // Map 4KB pages for fine-grained permissions
    var offset: u64 = 0;
    while (offset < size) : (offset += 4096) {
        mapPage(pml4, virt + offset, phys + offset, flags);
    }
}
```

### Calling Convention at Kernel Entry
```zig
// UEFI uses Microsoft x64 ABI (RCX = first arg)
// Kernel expects System V AMD64 ABI (RDI = first arg)
// Must manually set RDI before jumping

const boot_info_ptr = @intFromPtr(&boot_info);
const entry_addr = kernel_entry;

asm volatile (
    \\mov %[bi], %%rdi
    \\jmp *%[entry]
    :
    : [bi] "r" (boot_info_ptr),
      [entry] "r" (entry_addr),
);
```
""",

    "errors": """
## Common UEFI Errors and Fixes

### Error Union Discarding
**Symptom:** `error union is discarded`
**Fix:** Add `catch {}` or handle the error

```zig
// Wrong
con_out.clearScreen();

// Correct
_ = con_out.clearScreen() catch {};
// or
con_out.clearScreen() catch |err| {
    // Handle error
};
```

### Wrong createEvent Arguments
**Symptom:** `expected 2 argument(s), found 4`
**Fix:** Use struct-based API

```zig
// Wrong (old API)
bs.createEvent(EVT_TIMER, TPL_CALLBACK, null, null, &event);

// Correct (Zig std.os.uefi)
const event = bs.createEvent(.{ .timer = true }, .{}) catch return error.Failed;
```

### Wrong setTimer Return
**Symptom:** `error union is discarded`
**Fix:** setTimer returns error union

```zig
// Wrong
bs.setTimer(event, .relative, 10_000_000);

// Correct
bs.setTimer(event, .relative, 10_000_000) catch {};
```

### Key Type Mismatch
**Symptom:** `expected type 'Key', found 'Key.Input'`
**Fix:** readKeyStroke returns Key.Input

```zig
// Wrong
fn handleKey(key: uefi.protocol.SimpleTextInput.Key) void { ... }

// Correct
fn handleKey(key: uefi.protocol.SimpleTextInput.Key.Input) void { ... }
```

### waitForEvent Wrong Signature
**Symptom:** `expected 1 argument(s), found 2`
**Fix:** Pass pointer to event array

```zig
// Wrong
bs.waitForEvent(1, &event, &index);

// Correct
const events = [_]uefi.Event{timer_event.?};
if (bs.waitForEvent(&events)) |result| {
    // result.index, result.event
}
```

### Protocol Location
**Symptom:** Protocol pointer is null
**Fix:** Check return status AND null

```zig
var gop: ?*uefi.protocol.GraphicsOutput = undefined;
const status = bs.locateProtocol(&gop_guid, null, @ptrCast(&gop));

// Must check BOTH
if (status != .success or gop == null) {
    return error.GopNotFound;
}
```

### String Output
**Symptom:** Garbage characters
**Fix:** Use null-terminated UCS-2

```zig
// Wrong (not null-terminated)
var msg = [_]u16{ 'H', 'i' };

// Correct (sentinel-terminated)
var msg = [_:0]u16{ 'H', 'i', 0 };
_ = con_out.outputString(&msg) catch {};
```

### ExitBootServices Failure
**Symptom:** EFI_INVALID_PARAMETER
**Fix:** Refresh memory map key immediately before call

```zig
// Memory map key changes with ANY memory operation
// Get fresh map right before exit
_ = bs.getMemoryMap(&size, buffer, &key, &desc_size, &version);
const status = bs._exitBootServices(image, key);

// If still fails, retry once more
if (status != .success) {
    _ = bs.getMemoryMap(&size, buffer, &key, &desc_size, &version);
    _ = bs._exitBootServices(image, key);
}
```
""",

    "aarch64": """
## AArch64 Paging in UEFI Bootloader

AArch64 uses a fundamentally different paging model than x86_64. Key differences:
- Two page table registers (TTBR0/TTBR1) for address space split
- Memory attributes via MAIR indirection rather than direct PTE flags
- Explicit translation control via TCR_EL1

### Address Space Split

| Register | Address Range | Purpose |
|----------|---------------|---------|
| TTBR0_EL1 | 0x0000... (lower half) | User space, identity map |
| TTBR1_EL1 | 0xFFFF... (upper half) | Kernel, HHDM |

The kernel at `0xFFFFFFFF80000000` and HHDM at `0xFFFF800000000000` require TTBR1.

### System Registers

#### MAIR_EL1 (Memory Attribute Indirection Register)
```zig
const MAIR_DEVICE: u64 = 0x00;       // Index 0: Device-nGnRnE
const MAIR_NORMAL_WB: u64 = 0xFF;    // Index 1: Normal, WB, R+W Alloc
const MAIR_NORMAL_NC: u64 = 0x44;    // Index 2: Normal, Non-Cacheable

const mair = MAIR_DEVICE | (MAIR_NORMAL_WB << 8) | (MAIR_NORMAL_NC << 16);
```

#### TCR_EL1 (Translation Control Register)
```zig
const TCR_T0SZ: u64 = 16;           // 48-bit VA for TTBR0
const TCR_T1SZ: u64 = 16;           // 48-bit VA for TTBR1
const TCR_TG0_4K: u64 = 0b00 << 14; // 4KB granule TTBR0
const TCR_TG1_4K: u64 = 0b10 << 30; // 4KB granule TTBR1
const TCR_SH_INNER: u64 = 0b11;     // Inner Shareable
const TCR_IPS_1TB: u64 = 0b010 << 32; // 40-bit PA

const tcr = TCR_T0SZ | (TCR_T1SZ << 16) | TCR_TG0_4K | TCR_TG1_4K |
    (TCR_SH_INNER << 12) | (TCR_SH_INNER << 28) | // SH0, SH1
    (0b01 << 10) | (0b01 << 26) | // ORGN0, ORGN1 (WB-WA)
    (0b01 << 8) | (0b01 << 24) |  // IRGN0, IRGN1 (WB-WA)
    TCR_IPS_1TB;
```

### Page Table Entry Format
```zig
fn toRawAarch64(flags: PageFlags, phys: u64) u64 {
    var raw: u64 = 0x3;  // Valid + Page descriptor
    if (flags.huge_page) raw = 0x1;  // Block descriptor

    raw |= (1 << 2);   // AttrIndx = 1 (Normal WB via MAIR)
    raw |= (1 << 10);  // AF (Access Flag) - REQUIRED!
    raw |= (3 << 8);   // SH = Inner Shareable

    if (flags.no_execute) raw |= (1 << 54);  // UXN
    if (!flags.writable) raw |= (1 << 7);    // AP[2] = RO
    if (flags.user) raw |= (1 << 6);         // AP[1] = EL0

    raw |= (phys & 0x000F_FFFF_FFFF_F000);
    return raw;
}
```

### Loading Page Tables
```zig
asm volatile (
    // Disable MMU
    \\\\mrs x4, sctlr_el1
    \\\\bic x5, x4, #1
    \\\\msr sctlr_el1, x5
    \\\\isb
    // Configure
    \\\\msr mair_el1, %[mair]
    \\\\msr tcr_el1, %[tcr]
    \\\\msr ttbr0_el1, %[root]
    \\\\msr ttbr1_el1, %[root]
    // Invalidate TLB
    \\\\tlbi vmalle1
    \\\\dsb sy
    \\\\isb
    // Re-enable MMU
    \\\\msr sctlr_el1, x4
    \\\\isb
    :
    : [mair] "r" (mair), [tcr] "r" (tcr), [root] "r" (pml4_phys)
    : .{ .x4 = true, .x5 = true, .memory = true }
);
```

### Common Errors

**Translation fault, zeroth level at 0xFFFFFFFF80xxxxxx**
- Cause: TTBR1 not set (only TTBR0 was configured)
- Fix: Set both TTBR0_EL1 and TTBR1_EL1

**Instruction abort after loading page tables**
- Cause: AttrIndx = 0 (Device memory) used for code
- Fix: Set AttrIndx = 1 for Normal memory: `raw |= (1 << 2);`

**Repeated faults at same address**
- Cause: AF (Access Flag) not set
- Fix: Always set: `raw |= (1 << 10);`

### Key Files
- `src/boot/uefi/paging.zig` - Dual-arch paging (x86_64/aarch64)
- `src/arch/aarch64/boot/entry.S` - Kernel entry (`kentry`)
- `src/arch/aarch64/boot/linker.ld` - Kernel high-half layout
""",
}

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    query = sys.argv[1].lower()

    if query in PATTERNS:
        print(PATTERNS[query])
    else:
        matches = [k for k in PATTERNS.keys() if query in k]
        if matches:
            for m in matches:
                print(PATTERNS[m])
        else:
            print(f"Unknown topic: {query}")
            print(f"Available: {', '.join(PATTERNS.keys())}")
            sys.exit(1)

if __name__ == "__main__":
    main()

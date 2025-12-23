# Driver Architecture

Zscapek uses a hybrid architecture where critical drivers run in the kernel for performance and boot capability, while other drivers run in userspace for stability and security.

## PCI ECAM Timing Workaround

On QEMU/TCG with macOS/Apple Silicon hosts, PCI ECAM MMIO reads may return stale or corrupted data due to timing issues. This causes device enumeration to report incorrect vendor/device IDs or class codes (commonly all devices appear as 8086:29c0 Class 06/00).

### Solution: Legacy PCI I/O Fallback

Drivers affected by this issue implement a Legacy PCI I/O probe fallback using ports 0xCF8/0xCFC. This is implemented in:

- **XHCI** (`src/drivers/usb/xhci/root.zig`): Probes for USB 3.0 controllers
- **E1000e** (`src/kernel/core/init_hw.zig:probeE1000Legacy`): Probes for Intel NICs
- **AC97** (`src/kernel/core/init_hw.zig:initAudio`): Probes for audio controllers

### Pattern

```zig
const legacy = pci.Legacy.init();
var dev_num: u5 = 0;
while (dev_num < 32) : (dev_num += 1) {
    const vendor_id = legacy.read16(0, dev_num, 0, 0x00);
    if (vendor_id == 0xFFFF) continue;

    const device_id = legacy.read16(0, dev_num, 0, 0x02);
    if (vendor_id == TARGET_VENDOR and device_id == TARGET_DEVICE) {
        // Build PciDevice struct from legacy reads
        const bar0_raw = legacy.read32(0, dev_num, 0, 0x10);
        // ... initialize driver
    }
}
```

---

## XHCI Transfer Event Residual Length

The XHCI Transfer Event TRB's `trb_transfer_length` field contains the **residual** byte count (bytes NOT transferred), not the actual transferred length. This is a common source of bugs when handling USB transfers.

### Problem

For interrupt transfers (HID keyboards/mice), if a device sends a full 8-byte boot protocol report successfully:
- `trb_transfer_length` = 0 (no residual, all bytes transferred)
- Naive code using this value directly passes an empty slice to the HID driver
- Result: keyboard input is silently dropped

### Solution

Calculate actual transferred bytes: `actual = request_length - residual`

**Location**: `src/drivers/usb/xhci/interrupts.zig`

```zig
// WRONG: Using residual as length
const data_len = @min(len, dev.report_buffer.len);

// CORRECT: Calculate actual transferred bytes
const request_len: u32 = 8; // Interrupt transfers request 8 bytes
const actual_transferred = if (len <= request_len) request_len - len else 0;
const data_len = @min(actual_transferred, dev.report_buffer.len);
```

### Affected Components

- **Interrupt Transfers** (`src/drivers/usb/xhci/interrupts.zig`): HID polling for keyboards/mice
- **Control Transfers** (`src/drivers/usb/xhci/transfer/control.zig`): Already handles this correctly

### Symptoms

- USB keyboard enumerated successfully ("Starting HID polling for slot N" appears)
- No keyboard input reaches userspace applications (e.g., Doom)
- No error messages (data silently dropped due to zero-length slice)

---

## Kernel Drivers

Kernel drivers are located in `src/drivers`. They are used for:
- Boot-critical devices (AHCI, XHCI, Console)
- Performance-critical low-level hardware interaction using `MmioDevice`

### MmioDevice Pattern
Modern kernel drivers use the `MmioDevice(RegType)` wrapper for zero-cost, type-safe MMIO access.
- **Location**: `src/arch/x86_64/mmio_device.zig` (exported via `hal.mmio_device`)
- **Usage**:
  ```zig
  const regs = MmioDevice(Regs).init(base_addr, size);
  // Typed read/write
  const val = regs.read(.CTRL);
  regs.write(.CTRL, val | 1);
  ```

### Drivers using MmioDevice
- **XHCI** (`src/drivers/usb/xhci`)
- **EHCI** (`src/drivers/usb/ehci`)
- **AHCI** (`src/drivers/storage/ahci`)
- **E1000e** (`src/drivers/net/e1000e`)

---

## DMA Memory Allocation (IOMMU-Aware)

Zscapek supports Intel VT-d IOMMU for DMA isolation, preventing devices from accessing arbitrary memory. The `dma` module provides a unified API that transparently handles IOMMU when available.

### Why IOMMU Matters

Without IOMMU, any PCI device can read/write to any physical address via DMA. A malicious or buggy device (or firmware) could:
- Read kernel memory, credentials, or encryption keys
- Overwrite kernel code or page tables
- Bypass all OS security mechanisms

With IOMMU enabled, each device gets its own I/O Virtual Address (IOVA) space, limiting DMA to explicitly mapped buffers.

### DmaBuffer API

**Location**: `src/kernel/mm/dma.zig`

```zig
const dma = @import("dma");
const iommu = @import("iommu");

// 1. Get device BDF from PCI device
const bdf = iommu.DeviceBdf{
    .bus = pci_dev.bus,
    .device = pci_dev.device,
    .func = pci_dev.func,
};

// 2. Allocate IOMMU-aware buffer (zero-initialized for security)
const buf = try dma.allocBuffer(bdf, 4096, true); // true = device can write
defer dma.freeBuffer(&buf);

// 3. For CPU access: use buf.getVirt() or buf.slice()
const cpu_ptr = buf.getVirt();
const slice = buf.slice();

// 4. For hardware registers/descriptors: use buf.device_addr
hw_regs.write(.dma_addr_lo, buf.deviceAddrLo());
hw_regs.write(.dma_addr_hi, buf.deviceAddrHi());
```

### DmaBuffer Fields

| Field | Description |
|-------|-------------|
| `phys_addr` | Physical address (for CPU access via HHDM) |
| `device_addr` | Device address (IOVA if IOMMU enabled, else same as phys_addr) |
| `size` | Requested size in bytes |
| `page_count` | Number of pages allocated |
| `iommu_mapped` | Whether IOMMU mapping was used |

**Critical**: Always use `device_addr` for hardware descriptors, not `phys_addr`. When IOMMU is enabled, the device cannot access raw physical addresses.

### Helper Methods

```zig
buf.getVirt()          // [*]u8 for CPU access
buf.slice()            // []u8 slice for CPU access
buf.getTypedPtr(T)     // *T typed pointer
buf.getVolatilePtr(T)  // *volatile T for hardware descriptors
buf.deviceAddrLo()     // Lower 32 bits of device_addr
buf.deviceAddrHi()     // Upper 32 bits of device_addr
```

### 32-Bit Controllers

For controllers that only support 32-bit DMA addresses (e.g., some EHCI, older hardware):

```zig
// Returns error.AddressTooHigh if allocated above 4GB
const buf = try dma.allocBuffer32(bdf, size, writable);
```

### Checking IOMMU Status

```zig
if (dma.isIommuAvailable()) {
    console.info("DMA isolation active", .{});
} else {
    console.warn("No IOMMU - devices have unrestricted DMA access", .{});
}
```

### Driver Integration Examples

**E1000e (Network)**:
```zig
// Allocate RX descriptor ring
driver.rx_dma = try dma.allocBuffer(bdf, rx_ring_size, true);
driver.regs.write(.rdbal, driver.rx_dma.deviceAddrLo());
driver.regs.write(.rdbah, driver.rx_dma.deviceAddrHi());
```

**AHCI (Storage)**:
```zig
// Allocate command list
port.cmd_list_dma = try dma.allocBuffer(bdf, 1024, true);
port.writeClb(port.cmd_list_dma.device_addr);
```

**XHCI (USB)**:
```zig
// Ring allocation uses device_addr for DCBAA entries
const dc = try context.DeviceContext.alloc(bdf);
ctrl.dcbaa.setSlot(slot_id, dc.device_addr);
```

### Boot-Time Allocations

For early boot allocations before PCI is initialized (e.g., console DMA):

```zig
// WARNING: Bypasses IOMMU isolation - only use during early boot
const buf = try dma.allocBufferUnsafe(size);
```

### Security Considerations

1. **Zero-Initialization**: All DMA buffers are zero-initialized to prevent kernel memory leaks
2. **Fallback Warning**: If IOMMU mapping fails, a warning is logged but allocation succeeds with raw physical address
3. **Proper Cleanup**: Always call `dma.freeBuffer()` to unmap from IOMMU and free physical memory
4. **Validation**: Buffer sizes are validated for overflow before allocation

---

## Interrupt Handling

Zscapek supports two interrupt delivery mechanisms: **Legacy ISA IRQs** (via IOAPIC) and **MSI-X** (for PCI devices). Understanding the difference is critical for driver development.

### Common Bug: Enabling Without Routing

**Problem**: `enableIrq()` only unmasks the IRQ in the IOAPIC. If the IRQ was never **routed** to a vector, enabling it does nothing -- interrupts are silently lost.

```zig
// WRONG: IRQ enabled but never routed - interrupts lost!
hal.apic.enableIrq(12);

// CORRECT: Route first, then enable
hal.apic.routeIrq(12, hal.apic.Vectors.MOUSE, 0);
hal.apic.enableIrq(12);
```

### Legacy ISA IRQ Pattern (PS/2, Serial, etc.)

For ISA devices with fixed IRQ assignments, use the two-step IOAPIC process:

```zig
// 1. Register handler with interrupt dispatcher
hal.interrupts.setMouseHandler(&mouse.handleIrq);

// 2. Route IRQ to vector in IOAPIC (creates routing entry)
hal.apic.routeIrq(irq, vector, cpu_id);

// 3. Unmask IRQ in IOAPIC
hal.apic.enableIrq(irq);
```

**Pre-routed IRQs** (done in APIC init):
- IRQ0 (Timer) -> Vector 32 (masked after LAPIC timer takes over)
- IRQ1 (Keyboard) -> Vector 33

**Must be routed by driver**:
- IRQ4 (COM1) -> Vector 36
- IRQ12 (PS/2 Mouse) -> Vector 44
- Any other legacy IRQ

### MSI-X Pattern (PCI Devices)

Modern PCI devices (XHCI, E1000e, VirtIO-GPU) use MSI-X for direct LAPIC delivery, bypassing IOAPIC entirely:

```zig
// 1. Find MSI-X capability in PCI config space
const msix_cap = pci.findMsix(ecam, pci_dev) orelse return error.NoMsix;

// 2. Allocate vector from MSI-X pool (240-254)
const vector = hal.interrupts.allocateMsixVector() orelse return error.NoVectors;

// 3. Register handler for the vector
if (!hal.interrupts.registerMsixHandler(vector, handleInterrupt)) {
    hal.interrupts.freeMsixVector(vector);
    return error.HandlerRegistration;
}

// 4. Enable MSI-X on the device (programs MSI-X table entry)
const msix_alloc = pci.enableMsix(ecam, pci_dev, &msix_cap, 0) orelse {
    hal.interrupts.unregisterMsixHandler(vector);
    return error.MsixEnable;
};

// 5. Enable all configured vectors
pci.enableMsixVectors(ecam, pci_dev, &msix_cap);
```

### Vector Assignments

| Vector | IRQ | Device | Type |
|--------|-----|--------|------|
| 32 | 0 | PIT Timer | ISA (masked) |
| 33 | 1 | PS/2 Keyboard | ISA |
| 35 | 3 | COM2 | ISA |
| 36 | 4 | COM1 | ISA |
| 44 | 12 | PS/2 Mouse | ISA |
| 48 | - | LAPIC Timer | Local |
| 240-254 | - | MSI-X Pool | PCI |
| 255 | - | Spurious | Special |

### Generic Interrupt Flow

```
Hardware Event
      |
      v
+-----+------+
| PCI Device |  <-- MSI-X: writes directly to LAPIC
+-----+------+
      |                             +----------+
      | (legacy)                    | ISA      |
      v                             | Device   |
+-----+------+                      +----+-----+
| IOAPIC     | <--------------------+    |
+-----+------+       IRQ line            |
      |                                  |
      | (routed vector)                  |
      v                                  v
+-----+------+                     +-----+------+
| LAPIC      | <-------------------| IOAPIC     |
+-----+------+     vector          +------------+
      |
      v
+-----+------+
| IDT Entry  |
+-----+------+
      |
      v
+-----+------+
| Handler    |  hal.interrupts.registerHandler(vector, fn, ctx)
+-----+------+
      |
      v
+-----+------+
| Driver     |  e.g., mouse.handleIrq(), xhci.handleInterrupt()
+-----+------+
      |
      v
+-----+------+
| Subsystem  |  e.g., input.pushRelative(), keyboard.injectScancode()
+-----+------+
      |
      v
+-----+------+
| Userspace  |  syscall: read_input_event(), read_scancode()
+------------+
```

### HID Input Flow Example

```
USB HID Device (keyboard/mouse/tablet)
      |
      v
XHCI Controller (MSI-X interrupt)
      |
      v
xhci/interrupts.zig:handleInterrupt()
      |
      v
device_manager.handleInterrupt(ctrl, dev, buffer)
      |
      v
dev.hid_driver.handleInputReport(buffer)
      |
      +---> is_keyboard? --> handleKeyboardReport() --> keyboard.injectScancode()
      |                                                        |
      |                                                        v
      |                                               scancode buffer
      |                                                        |
      |                                                        v
      |                                               sys_read_scancode()
      |
      +---> is_tablet? ----> handleTabletReport() ---> mouse.injectAbsoluteInput()
      |                                                        |
      +---> is_mouse? -----> handleMouseReport() ----> mouse.injectRawInput()
                                                               |
                                                               v
                                                      input.pushRelative/Absolute()
                                                               |
                                                               v
                                                      unified input subsystem
                                                               |
                                                               v
                                                     sys_read_input_event()
```

### Input Device Identity (Best Practice)

`read_input_event` now returns an `InputEvent` that includes a `device_id`. The kernel assigns this ID when registering each input device (PS/2 mouse, USB mouse, USB tablet). Userspace should use `device_id` to differentiate devices and choose policy (e.g., ignore tablet input when a mouse is present), rather than hardcoding type assumptions in the kernel.

### Debugging Checklist

When interrupts are not working:

1. **Is the IRQ routed?** Check boot log for "routed to vector N"
2. **Is the handler registered?** `hal.interrupts.registerHandler()` or `setXxxHandler()`
3. **Is the IRQ enabled/unmasked?** `hal.apic.enableIrq(irq)`
4. **For MSI-X: Is the vector allocated?** `allocateMsixVector()` returns non-null?
5. **For MSI-X: Is the device's MSI-X table programmed?** `pci.enableMsix()` succeeded?
6. **Does the handler push to the right subsystem?** (e.g., input subsystem vs local buffer)

---

## Userspace Drivers

Userspace drivers are located in `src/user/drivers`. They interact with the kernel via capabilities and IPC.

### Core Concepts

#### 1. Capability-Based Security
Drivers must be explicitly granted capabilities by `init_proc`:
- **Interrupts**: `SYS_WAIT_INTERRUPT(irq)`
- **I/O Ports**: `SYS_OUTB`/`SYS_INB` (restricted)
- **MMIO**: `SYS_MMAP_PHYS` (requires `PciCapability`)
- **DMA**: `SYS_ALLOC_DMA` (requires `DmaCapability`)

#### 2. Ring IPC (Zero-Copy)
High-performance drivers (like Network) use Shared Memory Rings to communicate with the system.
- **Mechanism**: Single-Producer/Single-Consumer rings mapped in both driver and client (e.g., Netstack) address spaces.
- **Syscalls**: `ring_create`, `ring_attach`, `ring_notify`, `ring_wait`
- **Pattern**:
    - **TX Ring**: Client produces packets -> Driver consumes (transmits)
    - **RX Ring**: Driver produces packets (receives) -> Client consumes

#### 3. Split-Process Architecture
To handle asynchronous events without threading complexity:
- **Input Process**: Loops on `SYS_WAIT_INTERRUPT` or `ring_wait`.
- **Output Process**: Loops on `SYS_RECV` (Legacy IPC) or `ring_wait` (Command Ring).

### Driver Implementations

#### VirtIO-Net (`src/user/drivers/virtio_net`)
- **Type**: Userspace Network Driver
- **IPC**: Uses **Ring IPC** for RX/TX data path.
- **Status**: Functional SPSC rings per direction; MPSC is supported via per-producer rings.

#### VirtIO-Blk (`src/user/drivers/virtio_blk`)
- **Type**: Userspace Storage Driver
- **Status**: Functional. Supports read/write requests, DMA, and MMIO via capabilities.

#### PS/2 Input (`src/user/drivers/ps2`)
- **Type**: Userspace Input Driver
- **Status**: Handles Keyboard/Mouse interrupt 1/12, broadcasts events.

#### UART (`src/user/drivers/uart`)
- **Type**: Userspace Serial Driver
- **Status**: Simple split-process echo server.

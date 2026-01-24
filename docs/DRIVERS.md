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

## XHCI USB Hotplug

Zscapek supports USB device hotplug (connect and disconnect detection) via the xHCI Port Status Change Event mechanism.

### Device State Machine

USB devices transition through these states during their lifecycle:

```
                    +---------------+
                    | slot_enabled  |  <-- EnableSlot command succeeded
                    +-------+-------+
                            |
                            v
                    +-------+-------+
                    |   addressed   |  <-- SetAddress command succeeded
                    +-------+-------+
                            |
                            v
                    +-------+-------+
                    |  configured   |  <-- SetConfiguration succeeded
                    +-------+-------+
                            |
                            v
                    +-------+-------+
                    |    polling    |  <-- Interrupt polling active (HID/Hub)
                    +-------+-------+
                            |
                            | (disconnect detected)
                            v
                    +-------+-------+
                    | disconnecting |  <-- Cleanup in progress
                    +-------+-------+
                            |
                            v
                    +-------+-------+
                    |   disabled    |  <-- Slot released (terminal)
                    +---------------+
```

### Hotplug Event Flow

```
Port Status Change Event (from hardware)
            |
            v
interrupts.zig: processEvents()
            |
            v
ports.zig: handlePortStatusChange(ctrl, port_id)
            |
            +---> CSC bit set + CCS=1 --> handlePortConnect()
            |                                   |
            |                                   v
            |                             resetPort() --> enumerateDevice()
            |
            +---> CSC bit set + CCS=0 --> handlePortDisconnect()
                                                |
                                                v
                                        findDevicesOnPort()
                                                |
                                                v
                                        disconnectDevice() (children first)
```

### Disconnect Handling Sequence

Safe device removal follows this sequence to prevent use-after-free and hardware state inconsistencies:

1. **Transition to `disconnecting` state** - Prevents new transfers from being queued
2. **Stop all endpoints** - Sends `StopEndpointCmd` for each active DCI
3. **Cancel pending transfers** - Marks all in-flight transfers as `Stopped`
4. **Disable slot** - Sends `DisableSlotCmd`, clears DCBAA entry
5. **Cleanup device** - Calls `dev.deinit()` to free resources

**Hub Cascade**: When a hub is disconnected, child devices are removed first (deepest-first order) to ensure proper cleanup hierarchy.

### Per-Device Locking

Each `UsbDevice` has a `device_lock` Spinlock for IRQ-safe state transitions:

```zig
pub const UsbDevice = struct {
    // ... other fields ...
    device_lock: sync.Spinlock = .{},
    state: DeviceState,
    pending_transfers: [32]?*TransferRequest,
};
```

**Lock Ordering** (must be acquired in this order to prevent deadlock):
1. `devices_lock` (global device array)
2. `UsbDevice.device_lock` (per-device)

### Transfer Request Tracking

Pending USB transfers are tracked per-device for proper cancellation during disconnect:

```zig
pub const TransferRequest = struct {
    trb_phys: u64,           // TRB physical address for matching events
    dci: u5,                 // Device Context Index
    state: atomic.Value(TransferState),
    completion_code: trb.CompletionCode,
    residual: u24,           // Bytes NOT transferred
    request_len: u24,        // Original request length
    callback: TransferCallback,
    next: ?*TransferRequest, // Intrusive list for pool
};

pub const TransferState = enum(u8) {
    pending,
    in_progress,
    completed,
    cancelled,
    failed,
};
```

### Transfer Request Pool

To prevent unbounded memory growth from malicious devices, transfer requests use a fixed-size pool:

**Location**: `src/drivers/usb/xhci/transfer_pool.zig`

- **Pool Size**: 256 requests (system-wide limit)
- **Allocation**: O(1) via intrusive free list
- **Security**: Pool exhaustion returns `null` (driver returns `EAGAIN`)

```zig
// Allocate request
const req = transfer_pool.allocRequest(dci, trb_phys, len, callback) orelse
    return error.EAGAIN;

// Free after completion
transfer_pool.freeRequest(req);
```

### Key Files

| File | Purpose |
|------|---------|
| `src/drivers/usb/xhci/ports.zig` | Port state machine, hotplug handlers |
| `src/drivers/usb/xhci/device.zig` | UsbDevice struct, TransferRequest, states |
| `src/drivers/usb/xhci/transfer_pool.zig` | Fixed-size request pool |
| `src/drivers/usb/xhci/interrupts.zig` | PortStatusChangeEvent dispatch |
| `src/drivers/usb/xhci/device_manager.zig` | stopEndpoint, disableSlot commands |
| `src/drivers/usb/xhci/trb.zig` | StopEndpointCmdTrb definition |

### Testing Hotplug

1. **QEMU USB passthrough**: Connect/disconnect physical devices
2. **Hub cascade**: Disconnect hub with attached devices to verify child cleanup
3. **Stress test**: Rapid connect/disconnect cycles to check for race conditions

---

## XHCI Async I/O Integration

USB transfers integrate with the kernel's IoRequest/Future async infrastructure, enabling both kernel-level and userspace (io_uring) async operations.

### Bridge Pattern

USB uses a **bridge pattern** where `TransferRequest` (USB-specific) links to `IoRequest` (kernel-generic):

```zig
pub const TransferRequest = struct {
    trb_phys: u64,                    // TRB physical address for event matching
    dci: u5,                          // Device Context Index
    state: atomic.Value(TransferState),
    completion_code: trb.CompletionCode, // USB-specific error
    residual: u24,                    // Bytes NOT transferred
    request_len: u24,                 // Original request length
    callback: TransferCallback,       // Optional callback (HID polling)
    io_request: ?*io.IoRequest,       // Bridge to kernel IoRequest
    next: ?*TransferRequest,          // Pool free list
};
```

This allows USB to track hardware-specific state (DCI, TRB phys, CompletionCode) while delegating kernel integration (thread wakeup, io_uring CQE posting) to IoRequest.

### Async Transfer APIs

**Location**: `src/drivers/usb/xhci/transfer/`

| Function | File | Description |
|----------|------|-------------|
| `queueBulkTransferAsync()` | `bulk.zig` | Async bulk transfer with IoRequest |
| `controlTransferAsync()` | `control.zig` | Async control transfer (3-stage) |
| `queueInterruptTransferAsync()` | `interrupt.zig` | Dual-mode interrupt transfer |

### Completion Flow

```
USB Device completes transfer
      |
      v
XHCI raises MSI-X interrupt
      |
      v
interrupts.zig: processEvents()
      |
      v
device.takePendingTransfer(dci)  <-- Under device_lock
      |
      v
TransferRequest.complete(code, residual)  <-- Outside lock
      |
      +---> Sets completion_code, residual
      |
      +---> Calls io_request.complete(toIoResult())
      |           |
      |           +---> Maps USB CompletionCode to IoResult
      |           +---> Calls sched.unblock(submitter)
      |
      v
transfer_pool.freeRequest(req)
```

**Critical Pattern**: Grab under lock, complete outside lock. This prevents holding device_lock during potentially blocking IoRequest completion.

### Interrupt Transfer Dual Mode

Interrupt transfers support two modes via the `io_request` parameter:

| Mode | io_request | Use Case |
|------|------------|----------|
| Callback | `null` | Kernel HID polling (auto re-queues) |
| IoRequest | non-null | Userspace io_uring (manual requeue) |

```zig
// Callback mode: kernel HID driver, continuous polling
queueInterruptTransferAsync(ctrl, dev, dci, null, null, null);

// IoRequest mode: userspace, one-shot for io_uring
queueInterruptTransferAsync(ctrl, dev, dci, buf_phys, buf_len, io_request);
```

### CompletionCode to IoResult Mapping

| USB CompletionCode | IoResult | errno |
|--------------------|----------|-------|
| Success, ShortPacket | `.success(bytes)` | - |
| StallError | `.err(EPERM)` | 1 |
| BabbleDetectedError, USBTransactionError, TRBError | `.err(EIO)` | 5 |
| ResourceError, NoSlotsAvailableError | `.err(ENOMEM)` | 12 |
| BandwidthError | `.err(EBUSY)` | 16 |
| Stopped, CommandAborted | `.err(ECANCELED)` | 125 |
| ContextStateError | `.err(EINVAL)` | 22 |
| EventRingFullError | `.err(EAGAIN)` | 11 |

### Async Transfer Example

```zig
const io = @import("io");
const bulk = @import("usb/xhci/transfer/bulk.zig");
const pmm = @import("pmm");

// 1. Allocate IoRequest for async operation
const req = io.allocRequest(.usb_bulk) orelse return error.ENOMEM;
defer io.freeRequest(req);

// 2. Allocate DMA buffer
const buf_phys = pmm.allocZeroedPages(1) orelse return error.ENOMEM;
defer pmm.freePages(buf_phys, 1);

// 3. Queue async bulk transfer (returns immediately)
try bulk.queueBulkTransferAsync(ctrl, dev, ep_addr, buf_phys, 512, req);

// 4. Wait for IRQ-driven completion
var future = io.Future{ .request = req };
const result = future.wait();

switch (result) {
    .success => |bytes| console.info("Transferred {} bytes", .{bytes}),
    .err => |e| return e,
    .cancelled => console.warn("Transfer cancelled", .{}),
    .pending => unreachable,
}
```

### Lock Ordering (USB-specific)

Extended from CLAUDE.md lock ordering:

```
8.5. devices_lock (USB global RwLock)
8.6. UsbDevice.device_lock (per-device Spinlock, IRQ-safe)
8.7. transfer_pool.lock (global pool Spinlock)
```

**Pattern**: Acquire device_lock -> take pending transfer -> release lock -> complete transfer.

### Cancellation on Disconnect

When a USB device disconnects:

1. Device state transitions to `.disconnecting`
2. `cancelAllPendingTransfers()` is called:
   ```zig
   pub fn cancelAllPendingTransfers(self: *UsbDevice) void {
       for (&self.pending_transfers) |*slot| {
           if (slot.*) |req| {
               _ = req.compareAndSwapState(.pending, .cancelled) or
                   req.compareAndSwapState(.in_progress, .cancelled);
               if (req.io_request) |io_req| {
                   _ = io_req.complete(.cancelled);
               }
               transfer_pool.freeRequest(req);
               slot.* = null;
           }
       }
   }
   ```
3. All pending IoRequests receive `.cancelled` result
4. Waiting threads are woken via `sched.unblock()`

---

## E1000e Async TX

The E1000e network driver supports asynchronous packet transmission via the IoRequest pattern.

### Architecture

```
transmitAsync(packet, io_request)
      |
      v
Store in pending_tx_requests[tx_cur]
      |
      v
Copy packet to TX buffer, configure descriptor
      |
      v
Write TDT (notify hardware) -- returns immediately
      |
      v
[Hardware transmits packet]
      |
      v
TXDW interrupt fires
      |
      v
processTxCompletions() scans DD bits
      |
      v
Complete IoRequests for finished descriptors
      |
      v
Caller's Future becomes ready
```

### Async TX API

**Location**: `src/drivers/net/e1000e/tx.zig`

```zig
pub fn transmitAsync(
    driver: *E1000e,
    data: []const u8,
    io_request: *io.IoRequest,
) AsyncTxError!void
```

### TX Completion Tracking

```zig
// In E1000e struct (types.zig)
pending_tx_requests: [TX_DESC_COUNT]?*io.IoRequest,  // 512 slots
tx_completion_idx: u16,  // Last processed descriptor

// IRQ handler calls processTxCompletions()
fn processTxCompletions(driver: *E1000e) void {
    while (idx != driver.tx_cur) {
        if (descriptor[idx].DD) {
            if (pending_tx_requests[idx]) |io_req| {
                io_req.complete(.{ .ok = bytes_sent });
            }
        }
        idx = (idx + 1) % TX_DESC_COUNT;
    }
}
```

### Error Handling

| Error | Meaning |
|-------|---------|
| `InvalidPacket` | Packet too large or empty |
| `RingFull` | TX descriptor ring full (DD=0) |

When ring is full, the IoRequest is completed with `.err(.EAGAIN)` immediately.

---

## Serial Async TX (UART 16550)

The UART driver supports asynchronous transmission using the THRE (Transmitter Holding Register Empty) interrupt.

### Architecture

```
writeAsync(data, io_request)
      |
      v
Send first byte
      |
      v
Enable THRE interrupt
      |
      v
[Hardware transmits byte]
      |
      v
THRE interrupt fires (transmitter ready)
      |
      v
handleTxEmptyInterrupt() sends next byte
      |
      v
[Repeat until all bytes sent]
      |
      v
Disable THRE interrupt
      |
      v
Complete IoRequest with bytes_sent
```

### Async TX API

**Location**: `src/drivers/serial/uart_16550.zig`

```zig
pub fn writeAsync(
    data: []const u8,
    io_request: *io.IoRequest,
) AsyncTxError!void
```

### State Tracking

```zig
var tx_pending: ?*io.IoRequest = null;  // Current async request
var tx_buffer: []const u8 = &.{};       // Data to transmit
var tx_index: usize = 0;                 // Next byte to send
var tx_lock = atomic.Value(bool).init(false);  // Simple spinlock
```

### Important Notes

1. **Single Writer**: Only one async TX at a time (returns `error.Busy` if already in progress)
2. **Buffer Lifetime**: Caller must ensure `data` remains valid until completion
3. **Interrupt Efficiency**: Uses byte-by-byte interrupt-driven TX rather than polling

### Error Handling

| Error | Meaning |
|-------|---------|
| `Busy` | Another async TX in progress |
| `InvalidParam` | Empty data buffer |

---

## PCI Driver Probing Framework

Zscapek implements a Linux-style PCI driver registration and probing mechanism. Drivers register a `PciDriver` struct containing an ID table and a probe function. On device discovery (boot or virtual device registration), the framework matches devices against registered drivers and calls probe on the first match.

**Location**: `src/drivers/pci/driver.zig`

### Core Types

```zig
const pci = @import("pci");

// Device ID entry (Linux: struct pci_device_id)
pub const PciDeviceId = struct {
    vendor: u16 = 0,              // PCI_ANY_ID (0xFFFF) = match any
    device: u16 = 0,
    subvendor: u16 = PCI_ANY_ID,
    subdevice: u16 = PCI_ANY_ID,
    class: u32 = 0,               // 24-bit: (class<<16 | subclass<<8 | prog_if)
    class_mask: u32 = 0,          // 0 = don't check class
    driver_data: usize = 0,       // Opaque, passed to probe
};

// Driver descriptor (Linux: struct pci_driver)
pub const PciDriver = struct {
    name: []const u8,
    id_table: []const PciDeviceId,  // Sentinel-terminated
    probe: ProbeFn,
    remove: ?RemoveFn = null,
};
```

### Registering a Driver

```zig
const my_ids = [_]pci.PciDeviceId{
    pci.deviceId(0x8086, 0x100E),            // Intel E1000 (vendor:device match)
    pci.classId(0x01, 0x06, 0xFFFF00),       // Any SATA controller (class match)
    .{},                                      // Sentinel (all-zero terminator)
};

fn myProbe(dev: *const pci.PciDevice, access: pci.PciAccess, id: *const pci.PciDeviceId) ?*anyopaque {
    _ = id;
    const ctrl = initFromPci(dev, access) catch return null;
    return @ptrCast(ctrl);
}

pub const my_driver = pci.PciDriver{
    .name = "my_driver",
    .id_table = &my_ids,
    .probe = &myProbe,
    .remove = null,
};

// During boot (e.g., in init_hw.zig):
pci.pciRegisterDriver(&my_driver) catch {};
```

### Helper Constructors

| Function | Equivalent Linux Macro | Description |
|----------|----------------------|-------------|
| `pci.deviceId(vendor, device)` | `PCI_DEVICE(v, d)` | Match specific vendor:device pair |
| `pci.classId(class, subclass, mask)` | `PCI_DEVICE_CLASS(c, m)` | Match by class code with mask |

### Matching Rules

Matching follows Linux's `pci_match_one_device()` semantics:
- `PCI_ANY_ID` (0xFFFF) in any field means "match anything"
- `class_mask = 0` means class is not checked
- Class comparison: `((id.class ^ dev_class) & id.class_mask) != 0` rejects
- First matching entry in `id_table` wins
- First driver whose probe returns non-null wins

### Boot Probe Flow

```
initNetwork()     -- PCI enumeration, hardcoded driver inits
initUsb()         -- Hardcoded XHCI/EHCI init
initAudio()       -- Hardcoded HDA/AC97 init
initStorage()     -- Hardcoded AHCI/NVMe init
initInput()       -- Hardcoded VirtIO-Input init
                     |
                     v
probeRemainingDevices()  -- Catch-all: probes unbound devices
                            against all registered PciDrivers
```

### Virtual Device Probe

When a virtual PCI device is registered via `sys_vpci_register`, the framework automatically probes it against registered drivers:

```
sys_vpci_register()
      |
      v
dev.state = .registered
      |
      v
pci.probeVirtualDeviceFromConfig(config_space, ...)
      |
      v
Matches against registered drivers, calls probe on match
```

### Thread Safety

- `driver_registry_lock` (RwLock) protects the driver table and binding arrays
- Matching is done under read lock; lock is released before calling probe
- Probe functions may allocate/sleep freely
- Write lock is only held briefly to update bindings after successful probe

### Registry Limits

- Maximum 32 registered drivers (static array, no heap allocation)
- Per-device bindings indexed by DeviceList position (max 64 physical devices)
- Virtual devices use binding slots 32-63 to avoid collision with physical devices

### Key Files

| File | Purpose |
|------|---------|
| `src/drivers/pci/driver.zig` | PciDeviceId, PciDriver, registry, matching, probe |
| `src/drivers/pci/root.zig` | Re-exports driver framework types |
| `src/kernel/core/init_hw.zig` | `probeRemainingDevices()` entry point |
| `src/kernel/sys/syscall/hw/virt_pci.zig` | Virtual device probe trigger |

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

### Architecture-Specific Behavior

MmioDevice has different characteristics on x86_64 and aarch64:

| Feature | x86_64 | aarch64 |
|---------|--------|---------|
| Bounds checking | Debug/ReleaseSafe only | Always enabled (security) |
| `pollTimed()` | Uses TSC for timeout | No-op stub (returns false) |
| `writeRaw()` | Functional | No-op stub |
| Atomic bit ops | Available (LOCK prefix) | Not available |

**Security Note**: On aarch64, bounds checking cannot be disabled. Out-of-bounds MMIO access could read/write unintended hardware registers, potentially causing privilege escalation or hardware misconfiguration.

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
| `bdf` | Device BDF for IOMMU cleanup on free |
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
5. **IOTLB Invalidation**: All IOMMU page table modifications are followed by IOTLB invalidation to prevent stale translations

### RMRR Identity Mappings

Some devices require access to firmware-reserved memory regions at boot. These Reserved Memory Region Reporting (RMRR) entries are parsed from the ACPI DMAR table and automatically identity-mapped when a device is assigned to an IOMMU domain.

**Automatic Setup**: When `getDomainForDevice()` assigns a device to a domain, it calls `setupRmrrForDevice()` to create identity mappings (IOVA == physical address) for any RMRR regions that apply to that device.

**Common RMRR Users**:
- USB controllers (legacy BIOS keyboard buffer access)
- Integrated graphics (firmware-reserved memory)
- Some network controllers

**Boot Log**: Look for messages like:
```
IOMMU: Identity-mapped RMRR 0xabc00000-0xabffffff for 00:14.0
```

---

## Architecture-Specific Notes

### x86_64

- **IOMMU**: Intel VT-d fully supported with RMRR identity mappings
- **Interrupts**: IOAPIC + LAPIC with MSI-X support (vectors 64-128)
- **MmioDevice**: Full feature set including `pollTimed()` with TSC
- **Memory Barriers**: Uses `mfence`, `lfence`, `sfence` instructions

### aarch64

- **IOMMU**: NOT IMPLEMENTED (stubs return `NotSupported`)
  - DMA allocations fall back to raw physical addresses
  - No DMA isolation on ARM systems
  - Would require ARM SMMU implementation for full support
- **Interrupts**: GIC (Generic Interrupt Controller) replaces IOAPIC/LAPIC
  - MSI-X NOT IMPLEMENTED (would require GICv3 ITS)
  - `hal.interrupts.allocateMsixVector()` returns `null`
  - `hal.interrupts.registerMsixHandler()` returns `false`
  - Drivers must use legacy interrupt routing on aarch64
- **MmioDevice**: Security-hardened variant
  - Bounds checking always enabled (cannot be disabled)
  - `pollTimed()` is a no-op stub (returns false)
  - No atomic bit operations (`setBits32Atomic`, `clearBits32Atomic` unavailable)
- **Memory Barriers**: Uses `dsb sy`, `dsb ld`, `dsb st` (ARM barriers)

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

// 2. Allocate vector from MSI-X pool (64-128 on x86_64)
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

**aarch64 Note**: MSI-X is only supported on x86_64. On aarch64, `allocateMsixVector()` returns `null` and drivers must fall back to legacy interrupt routing or implement GICv3 ITS support.

### Vector Assignments (x86_64)

| Vector | IRQ | Device | Type |
|--------|-----|--------|------|
| 32 | 0 | PIT Timer | ISA (masked) |
| 33 | 1 | PS/2 Keyboard | ISA |
| 35 | 3 | COM2 | ISA |
| 36 | 4 | COM1 | ISA |
| 44 | 12 | PS/2 Mouse | ISA |
| 48 | - | LAPIC Timer | Local |
| 64-128 | - | MSI-X Pool | PCI (x86_64 only) |
| 255 | - | Spurious | Special |

**Note**: On aarch64, the GIC (Generic Interrupt Controller) replaces IOAPIC/LAPIC. MSI-X is not currently implemented on aarch64.

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
7. **Are there garbage GSI warnings?** If boot log shows `IOAPIC: No I/O APIC for GSI <large number>`, this indicates use-after-free in APIC initialization (see below)

### APIC Initialization Pitfall (Use-After-Free)

**Problem**: The `initApic()` function in `src/kernel/core/main.zig` passes pointers to the `io_apics` and `overrides` arrays to `hal.apic.init()`, which caches them. If these are stack-allocated local variables, they become dangling pointers after `initApic()` returns.

**Symptom**: Boot log shows garbage GSI values like:
```
[WARN]  IOAPIC: No I/O APIC for GSI 2151629072
[WARN]  IOAPIC: No I/O APIC for GSI 535184920
```

These appear when `routeIrq()` is called later (for keyboard, mouse, serial) and reads garbage from the invalidated stack memory.

**Solution**: Arrays passed to `hal.apic.init()` must be static to outlive the function:

```zig
// WRONG: Stack-allocated, becomes dangling pointer
fn initApic(...) {
    var overrides: [16]?InterruptOverride = ...;
    hal.apic.init(&.{ .overrides = &overrides, ... });
}  // overrides is invalid after return!

// CORRECT: Static storage via embedded struct
fn initApic(...) {
    const overrides_static = struct {
        var data: [16]?InterruptOverride = ...;
    };
    hal.apic.init(&.{ .overrides = &overrides_static.data, ... });
}  // data persists after return
```

**Affected Arrays**: `io_apics`, `overrides` (and `madt_info` which was already correctly static)

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

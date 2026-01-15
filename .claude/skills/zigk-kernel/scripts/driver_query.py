#!/usr/bin/env python3
"""
Driver Pattern Query Tool for zigk kernel.

Query driver patterns, MmioDevice usage, Ring IPC, interrupts, and capabilities.

Usage:
    python driver_query.py mmio          # MmioDevice pattern
    python driver_query.py dma           # IOMMU-aware DMA allocation
    python driver_query.py ring          # Ring IPC pattern
    python driver_query.py capabilities  # Capability syscalls
    python driver_query.py split         # Split-process pattern
    python driver_query.py kernel        # List kernel drivers
    python driver_query.py userspace     # List userspace drivers
    python driver_query.py pci           # PCI enumeration pattern
    python driver_query.py irq           # Legacy ISA IRQ routing pattern
    python driver_query.py msix          # MSI-X interrupt pattern (x86_64 only)
    python driver_query.py input         # Input subsystem flow
    python driver_query.py arch          # Architecture differences (x86_64 vs aarch64)
    python driver_query.py template mmio # Generate MMIO driver boilerplate
    python driver_query.py template ring # Generate Ring IPC driver boilerplate
"""

import sys

PATTERNS = {
    "mmio": """
## MmioDevice Pattern (Kernel Drivers)

Location: src/arch/{x86_64,aarch64}/mm/mmio_device.zig (via hal.mmio_device)

```zig
const hal = @import("hal");

// Define register offsets as enum
const Regs = enum(u32) {
    CTRL = 0x00,
    STATUS = 0x04,
    INTR_MASK = 0x08,
};

// Initialize with BAR address
const regs = hal.mmio_device.MmioDevice(Regs).init(bar_addr, bar_size);

// Type-safe read/write (volatile, no optimization)
const status = regs.read(.STATUS);
regs.write(.CTRL, CTRL_ENABLE | CTRL_RESET);
```

### Architecture Differences

| Feature | x86_64 | aarch64 |
|---------|--------|---------|
| Bounds checking | Debug/ReleaseSafe only | Always enabled (security) |
| `pollTimed()` | Uses TSC for timeout | No-op stub (returns false) |
| `writeRaw()` | Functional | No-op stub |
| Atomic bit ops | Available (LOCK prefix) | Not available |

**Security Note**: On aarch64, bounds checking cannot be disabled. Out-of-bounds
MMIO access could cause privilege escalation or hardware misconfiguration.

### Drivers using MmioDevice
- XHCI: src/drivers/usb/xhci/
- EHCI: src/drivers/usb/ehci/
- AHCI: src/drivers/storage/ahci/
- E1000e: src/drivers/net/e1000e/
""",

    "dma": """
## IOMMU-Aware DMA Allocation

Location: src/kernel/mm/dma.zig

When IOMMU (VT-d) is available, devices cannot access raw physical addresses.
Use the dma module for all DMA buffer allocations.

**Architecture Note**: IOMMU is only implemented on x86_64 (Intel VT-d). On aarch64,
IOMMU stubs return `NotSupported` and DMA allocations fall back to raw physical
addresses (no DMA isolation). ARM SMMU would be required for full support.

### Basic Pattern
```zig
const dma = @import("dma");
const iommu = @import("iommu");

// 1. Get device BDF from PCI device
const bdf = iommu.DeviceBdf{
    .bus = pci_dev.bus,
    .device = pci_dev.device,
    .func = pci_dev.func,
};

// 2. Allocate IOMMU-aware buffer (zero-initialized)
const buf = try dma.allocBuffer(bdf, 4096, true);  // true = device can write
defer dma.freeBuffer(&buf);

// 3. CPU access via HHDM
const cpu_ptr = buf.getVirt();
const slice = buf.slice();

// 4. Hardware registers use device_addr (IOVA or physical)
hw_regs.write(.dma_addr_lo, buf.deviceAddrLo());
hw_regs.write(.dma_addr_hi, buf.deviceAddrHi());
```

### DmaBuffer Fields
| Field | Purpose |
|-------|---------|
| phys_addr | Physical address (CPU access via HHDM) |
| device_addr | Device address (IOVA if IOMMU, else phys) |
| size | Requested size in bytes |
| page_count | Number of pages allocated |
| bdf | Device BDF for IOMMU cleanup on free |
| iommu_mapped | Whether IOMMU mapping was used |

**CRITICAL**: Always use `device_addr` for hardware descriptors!

### Helper Methods
```zig
buf.getVirt()          // [*]u8 for CPU access
buf.slice()            // []u8 slice
buf.getTypedPtr(T)     // *T typed pointer
buf.getVolatilePtr(T)  // *volatile T for hardware
buf.deviceAddrLo()     // Lower 32 bits
buf.deviceAddrHi()     // Upper 32 bits
```

### 32-Bit Controllers
```zig
// Returns error.AddressTooHigh if > 4GB
const buf = try dma.allocBuffer32(bdf, size, writable);
```

### Boot-Time (No BDF)
```zig
// WARNING: Bypasses IOMMU - only for early boot
const buf = try dma.allocBufferUnsafe(size);
```

### Check IOMMU Status
```zig
if (dma.isIommuAvailable()) {
    console.info("DMA isolation active", .{});
}
```

### Drivers Using IOMMU-Aware DMA
- E1000e: src/drivers/net/e1000e/
- AHCI: src/drivers/storage/ahci/
- XHCI: src/drivers/usb/xhci/
""",

    "ring": """
## Ring IPC Pattern (Zero-Copy)

Syscalls: 1040-1045 in src/kernel/sys/syscall/io/ring.zig

### Producer (Client)
```zig
// Create ring buffer
const ring_id = syscall.ring_create(
    entry_size,    // bytes per entry
    entry_count,   // number of entries
    consumer_pid,  // who will consume
    name_ptr,      // service name (optional)
    name_len
);

// Write and notify
const slot = ring.getWriteSlot();
@memcpy(slot, data);
ring.commitWrite();
syscall.ring_notify(ring_id);  // Wake consumer
```

### Consumer (Driver)
```zig
// Attach to ring
var result: RingAttachResult = undefined;
syscall.ring_attach(ring_id, &result);
const ring = @ptrFromInt(result.virt_addr);

// Wait and process
while (true) {
    const count = syscall.ring_wait(ring_id, 1, timeout_ns);
    while (ring.getReadSlot()) |slot| {
        processEntry(slot);
        ring.advanceRead();
    }
}
```

### Multi-ring wait (MPSC)
```zig
const rings = [_]u32{ rx_ring, cmd_ring, irq_ring };
const ready = syscall.ring_wait_any(&rings, 3, 1, -1);
// ready = ring_id that has data
```
""",

    "capabilities": """
## Capability-Based Security (Userspace Drivers)

Drivers must be granted capabilities by init_proc.

| Capability | Syscall | Number | Purpose |
|------------|---------|--------|---------|
| Interrupts | wait_interrupt | 1022 | Wait for hardware IRQ |
| Port I/O | outb/inb | 1036/1037 | Direct port access |
| MMIO | mmap_phys | 1030 | Map physical memory |
| DMA | alloc_dma | 1031 | DMA-capable memory |
| PCI | pci_enumerate | 1033 | List PCI devices |
| PCI Config | pci_config_read/write | 1034/1035 | PCI config space |

### Interrupt Waiting
```zig
while (true) {
    const ret = syscall.wait_interrupt(irq_num);
    if (ret < 0) break;
    handleIrq();
}
```

### MMIO Mapping
```zig
const virt = syscall.mmap_phys(bar_phys, bar_size);
const regs: *volatile DevRegs = @ptrFromInt(virt);
```

### DMA Allocation
```zig
var result: DmaAllocResult = undefined;
syscall.alloc_dma(&result, num_pages);
// result.virt_addr = CPU access
// result.phys_addr = device access
```
""",

    "split": """
## Split-Process Pattern

For async drivers without threading. Fork into two processes:

```
+-------------------+          +-------------------+
|   Input Process   |          |  Output Process   |
+-------------------+          +-------------------+
         |                              |
   wait_interrupt(irq)            ring_wait(cmd_ring)
   or ring_wait(irq_ring)        or recv(msg)
         |                              |
   Handle hardware              Process commands
   Produce RX data              Consume TX data
```

### Implementation
```zig
pub fn main() void {
    const pid = syscall.fork();
    if (pid == 0) {
        inputProcess();   // Child: handle interrupts
    } else {
        outputProcess();  // Parent: handle commands
    }
}

fn inputProcess() void {
    while (true) {
        syscall.wait_interrupt(IRQ);
        // Read from hardware, produce to RX ring
    }
}

fn outputProcess() void {
    while (true) {
        const count = syscall.ring_wait(tx_ring, 1, -1);
        // Consume from TX ring, write to hardware
    }
}
```
""",

    "kernel": """
## Kernel Drivers

Location: src/drivers/

| Driver | Path | Purpose |
|--------|------|---------|
| XHCI | src/drivers/usb/xhci/ | USB 3.0+ host |
| EHCI | src/drivers/usb/ehci/ | USB 2.0 host |
| AHCI | src/drivers/storage/ahci/ | SATA storage |
| E1000e | src/drivers/net/e1000e/ | Intel Gigabit |
| Keyboard | src/drivers/input/keyboard.zig | PS/2 keyboard |
| Console | src/drivers/console/ | Framebuffer |
| AC97 | src/drivers/audio/ac97.zig | Audio |
| VirtIO | src/drivers/virtio/ | VirtIO base |

When to use kernel drivers:
- Boot-critical (must work before userspace)
- Performance-critical DMA
- Direct hardware control needed
""",

    "userspace": """
## Userspace Drivers

Location: src/user/drivers/

| Driver | Path | Purpose |
|--------|------|---------|
| VirtIO-Net | src/user/drivers/virtio_net/ | Network (Ring IPC) |
| VirtIO-Blk | src/user/drivers/virtio_blk/ | Block storage |
| PS/2 | src/user/drivers/ps2/ | Keyboard/Mouse |
| UART | src/user/drivers/uart/ | Serial port |

Advantages:
- Crash isolation (driver crash != kernel crash)
- Security (capability-limited)
- Easier debugging

Required capabilities from init_proc:
- SYS_WAIT_INTERRUPT for IRQ handling
- SYS_MMAP_PHYS for MMIO access
- SYS_ALLOC_DMA for DMA buffers
""",

    "pci": """
## PCI Enumeration Pattern

### Kernel Side
```zig
const pci = @import("pci");

var iter = pci.enumerate();
while (iter.next()) |dev| {
    if (dev.vendor_id == 0x8086 and dev.device_id == 0x100e) {
        // Found E1000
        const bar0 = dev.readBar(0);
        const size = dev.getBarSize(0);
        initDevice(bar0, size);
    }
}
```

### Userspace Side
```zig
var buf: [256]PciDeviceInfo = undefined;
const count = syscall.pci_enumerate(&buf, 256);

for (buf[0..count]) |dev| {
    if (dev.vendor_id == VENDOR) {
        const bar0 = syscall.pci_config_read(
            dev.bus, dev.device, dev.func, 0x10
        );
        const virt = syscall.mmap_phys(bar0 & ~@as(u32, 0xF), size);
    }
}
```

### BAR Sizing Gotcha
```zig
// WRONG - upper bits contaminate result
const size = ~bar_read + 1;

// CORRECT - mask to 32 bits
const size = (~bar_read +% 1) & 0xFFFFFFFF;
```
""",

    "irq": """
## Legacy ISA IRQ Routing (IOAPIC)

**CRITICAL**: `enableIrq()` only unmasks. You MUST call `routeIrq()` first!

### Common Bug
```zig
// WRONG: IRQ enabled but never routed - interrupts silently lost!
hal.apic.enableIrq(12);

// CORRECT: Route first, then enable
hal.apic.routeIrq(12, hal.apic.Vectors.MOUSE, 0);
hal.apic.enableIrq(12);
```

### Three-Step Pattern
```zig
// 1. Register handler with interrupt dispatcher
hal.interrupts.setMouseHandler(&mouse.handleIrq);

// 2. Route IRQ to vector in IOAPIC (creates routing entry)
hal.apic.routeIrq(irq, vector, cpu_id);

// 3. Unmask IRQ in IOAPIC
hal.apic.enableIrq(irq);
```

### Pre-routed IRQs (done in APIC init)
- IRQ0 (Timer) -> Vector 32 (masked when LAPIC timer takes over)
- IRQ1 (Keyboard) -> Vector 33

### Must Be Routed By Driver
| IRQ | Vector | Device | Constant |
|-----|--------|--------|----------|
| 4 | 36 | COM1 | hal.apic.Vectors.COM1 |
| 12 | 44 | PS/2 Mouse | hal.apic.Vectors.MOUSE |

### Vector Assignments (x86_64)
| Vector | Purpose |
|--------|---------|
| 32-47 | Legacy ISA IRQs (IRQ+32) |
| 48 | LAPIC Timer |
| 64-128 | MSI-X Pool (x86_64 only) |
| 255 | Spurious |

**aarch64 Note**: GIC (Generic Interrupt Controller) replaces IOAPIC/LAPIC.
MSI-X is not implemented on aarch64 (would require GICv3 ITS).
""",

    "msix": """
## MSI-X Interrupt Pattern (PCI Devices) - x86_64 Only

MSI-X bypasses IOAPIC - PCI device writes directly to LAPIC.

**aarch64 Note**: MSI-X is NOT implemented on aarch64. `allocateMsixVector()`
returns `null` and `registerMsixHandler()` returns `false`. Would require
GICv3 ITS implementation for full support.

### Five-Step Pattern
```zig
const pci = @import("pci");
const hal = @import("hal");

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

### Drivers Using MSI-X
- XHCI (src/drivers/usb/xhci/interrupts.zig)
- E1000e (src/drivers/net/e1000e/init.zig)
- VirtIO-GPU (src/drivers/video/virtio_gpu.zig)

### Cleanup on Error
```zig
errdefer {
    hal.interrupts.unregisterMsixHandler(vector);
    hal.interrupts.freeMsixVector(vector);
}
```

### ISR Rule
Interrupt handlers must be fast. For complex processing, wake a worker thread:
```zig
fn handleInterrupt() void {
    // Quick: acknowledge interrupt, read status
    const status = regs.read(.INTR_STATUS);
    regs.write(.INTR_STATUS, status);  // Clear

    // Wake worker thread for actual processing
    sched.unblock(worker_thread);
}
```
""",

    "input": """
## Input Subsystem Flow

### Two Syscall Paths
- **Keyboard**: `sys_read_scancode()` - reads directly from scancode buffer
- **Mouse/Tablet**: `sys_read_input_event()` - reads from unified input subsystem

### HID Input Flow
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
      +---> is_keyboard? --> handleKeyboardReport()
      |                            |
      |                            v
      |                     keyboard.injectScancode()
      |                            |
      |                            v
      |                     scancode buffer
      |                            |
      |                            v
      |                     sys_read_scancode()
      |
      +---> is_tablet? ----> handleTabletReport()
      |                            |
      |                            v
      |                     mouse.injectAbsoluteInput()
      |                            |
      +---> is_mouse? -----> handleMouseReport()
                                   |
                                   v
                            mouse.injectRawInput()
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

### Key Files
| Component | Location |
|-----------|----------|
| USB HID driver | src/drivers/usb/class/hid/driver.zig |
| PS/2 mouse | src/drivers/input/mouse.zig |
| PS/2 keyboard | src/drivers/input/keyboard.zig |
| Input subsystem | src/drivers/input/input.zig |
| XHCI interrupts | src/drivers/usb/xhci/interrupts.zig |

### Injection Functions
```zig
// For relative mouse movement
mouse.injectRawInput(dx, dy, dz, buttons);

// For absolute positioning (tablet/touchscreen)
mouse.injectAbsoluteInput(x, y, screen_w, screen_h, buttons);

// Direct scancode injection
keyboard.injectScancode(scancode);
```

### Common Bug: Local Buffer Only
Injection functions must push to BOTH local buffer AND unified input subsystem:
```zig
// In injectRawInput/injectAbsoluteInput:
if (input.isInitialized()) {
    input.pushRelative(RelCode.X, dx, timestamp);
    input.pushRelative(RelCode.Y, dy, timestamp);
    input.pushSync(timestamp);
}
```
""",

    "arch": """
## Architecture-Specific Driver Notes

### x86_64

- **IOMMU**: Intel VT-d fully supported with RMRR identity mappings
- **Interrupts**: IOAPIC + LAPIC with MSI-X support (vectors 64-128)
- **MmioDevice**: Full feature set including `pollTimed()` with TSC
- **Memory Barriers**: Uses `mfence`, `lfence`, `sfence` instructions
- **HAL Location**: src/arch/x86_64/

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
- **HAL Location**: src/arch/aarch64/

### Writing Cross-Platform Drivers

```zig
// Check for MSI-X support at runtime
if (hal.interrupts.allocateMsixVector()) |vector| {
    // x86_64: use MSI-X
    hal.interrupts.registerMsixHandler(vector, handleInterrupt);
} else {
    // aarch64 fallback: use legacy interrupt routing
    hal.apic.routeIrq(irq, vector, 0);
    hal.apic.enableIrq(irq);
}

// Check for IOMMU support
if (dma.isIommuAvailable()) {
    // x86_64: use IOVA
} else {
    // aarch64: use raw physical addresses
}
```
""",

    "template_mmio": """
// MMIO Kernel Driver Template
// Location: src/drivers/<subsystem>/<driver_name>/root.zig

const std = @import("std");
const hal = @import("hal");
const pci = @import("pci");
const pmm = @import("pmm");
const vmm = @import("vmm");
const console = @import("console");
const sync = @import("sync");

// Register offset definitions
const Regs = enum(u32) {
    CTRL = 0x00,
    STATUS = 0x04,
    INTR_MASK = 0x08,
    INTR_STATUS = 0x0C,
    // Add more registers as needed
};

// Control register bits
const CTRL = packed struct(u32) {
    enable: bool = false,
    reset: bool = false,
    intr_enable: bool = false,
    _reserved: u29 = 0,
};

// Global driver instance (for ISR access)
var g_driver: ?*Driver = null;

pub const Driver = struct {
    regs: hal.mmio_device.MmioDevice(Regs),
    irq_vector: u8,
    lock: sync.SpinLock = .{},

    pub fn init(dev: *const pci.PciDevice, ecam: pci.PciAccess) !*Driver {
        const alloc = @import("heap").allocator();
        const self = try alloc.create(Driver);
        errdefer alloc.destroy(self);

        // Get BAR0 address and size
        const bar0 = dev.readBar(ecam, 0);
        const bar_size = dev.getBarSize(ecam, 0);

        // Initialize MMIO device wrapper
        self.* = .{
            .regs = hal.mmio_device.MmioDevice(Regs).init(bar0, bar_size),
            .irq_vector = 0,
        };

        // Reset device
        self.regs.writeTyped(.CTRL, .{ .reset = true });

        // Wait for reset to complete
        while (self.regs.readTyped(.STATUS, packed struct(u32) {
            ready: bool,
            _: u31,
        }).ready == false) {
            std.atomic.spinLoopHint();
        }

        // Setup MSI-X interrupt
        if (pci.findMsix(ecam, dev)) |msix| {
            self.irq_vector = try hal.interrupts.allocateMsixVector();
            try hal.interrupts.registerMsixHandler(self.irq_vector, handleInterrupt);
            pci.enableMsix(ecam, dev, msix, self.irq_vector);
        }

        // Enable device
        self.regs.writeTyped(.CTRL, .{ .enable = true, .intr_enable = true });

        g_driver = self;
        console.printf("[driver] Initialized at BAR0=0x{x}\\n", .{bar0});
        return self;
    }

    fn handleInterrupt() void {
        const self = g_driver orelse return;

        // Read and clear interrupt status
        const status = self.regs.read(.INTR_STATUS);
        self.regs.write(.INTR_STATUS, status); // Write to clear

        // Handle interrupt...
    }
};

// Hook into kernel init (called from src/kernel/init_hw.zig)
pub fn initDriver() void {
    var iter = pci.enumerate();
    while (iter.next()) |dev| {
        if (dev.vendor_id == VENDOR_ID and dev.device_id == DEVICE_ID) {
            _ = Driver.init(dev, iter.ecam) catch |err| {
                console.printf("[driver] Init failed: {}\\n", .{err});
            };
        }
    }
}
""",

    "template_ring": """
// Ring IPC Userspace Driver Template
// Location: src/user/drivers/<driver_name>/main.zig

const std = @import("std");
const syscall = @import("syscall");
const libc = @import("libc");

const DRIVER_NAME = "my_driver";
const RING_ENTRY_SIZE = 1500;  // e.g., MTU for network
const RING_ENTRY_COUNT = 256;

pub fn main() void {
    // Register as a named service
    if (syscall.register_service(DRIVER_NAME, DRIVER_NAME.len) < 0) {
        libc.printf("Failed to register service\\n", .{});
        return;
    }

    // Create RX ring for incoming data
    const rx_ring_id = syscall.ring_create(
        RING_ENTRY_SIZE,
        RING_ENTRY_COUNT,
        0,  // No specific consumer yet
        "rx",
        2,
    );
    if (rx_ring_id < 0) {
        libc.printf("Failed to create RX ring\\n", .{});
        return;
    }

    // Fork into two processes for async handling
    const pid = syscall.fork();
    if (pid < 0) {
        libc.printf("Fork failed\\n", .{});
        return;
    }

    if (pid == 0) {
        // Child: Handle hardware interrupts
        interruptHandler();
    } else {
        // Parent: Handle client commands
        commandHandler(rx_ring_id);
    }
}

fn interruptHandler() noreturn {
    // Request interrupt capability (must be granted by init)
    const IRQ = 11;  // Your device's IRQ

    while (true) {
        const ret = syscall.wait_interrupt(IRQ);
        if (ret < 0) {
            libc.printf("wait_interrupt failed: {}\\n", .{ret});
            continue;
        }

        // Read from hardware, produce to RX ring
        handleHardwareInterrupt();
    }
}

fn commandHandler(rx_ring_id: i32) noreturn {
    while (true) {
        // Wait for commands from clients
        const count = syscall.ring_wait(rx_ring_id, 1, -1);
        if (count < 0) {
            libc.printf("ring_wait failed: {}\\n", .{count});
            continue;
        }

        // Process commands...
        processCommands();
    }
}

fn handleHardwareInterrupt() void {
    // TODO: Read from MMIO registers
    // TODO: Produce data to ring
}

fn processCommands() void {
    // TODO: Consume from ring
    // TODO: Write to hardware
}
""",
}

TEMPLATES = {
    "mmio": "template_mmio",
    "ring": "template_ring",
}

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    query = sys.argv[1].lower()

    # Handle template command
    if query == "template":
        if len(sys.argv) < 3:
            print("Usage: python driver_query.py template <type>")
            print(f"Available templates: {', '.join(TEMPLATES.keys())}")
            sys.exit(1)
        template_type = sys.argv[2].lower()
        if template_type not in TEMPLATES:
            print(f"Unknown template: {template_type}")
            print(f"Available templates: {', '.join(TEMPLATES.keys())}")
            sys.exit(1)
        print(PATTERNS[TEMPLATES[template_type]])
        return

    # Filter out template patterns from fuzzy match
    non_template_patterns = {k: v for k, v in PATTERNS.items() if not k.startswith("template_")}

    # Fuzzy match
    matches = [k for k in non_template_patterns.keys() if query in k]

    if not matches:
        print(f"Unknown pattern: {query}")
        print(f"Available: {', '.join(non_template_patterns.keys())}")
        sys.exit(1)

    for match in matches:
        print(PATTERNS[match])

if __name__ == "__main__":
    main()

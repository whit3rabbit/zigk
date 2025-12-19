#!/usr/bin/env python3
"""
Driver Pattern Query Tool for zigk kernel.

Query driver patterns, MmioDevice usage, Ring IPC, and capabilities.

Usage:
    python driver_query.py mmio          # MmioDevice pattern
    python driver_query.py ring          # Ring IPC pattern
    python driver_query.py capabilities  # Capability syscalls
    python driver_query.py split         # Split-process pattern
    python driver_query.py kernel        # List kernel drivers
    python driver_query.py userspace     # List userspace drivers
    python driver_query.py pci           # PCI enumeration pattern
"""

import sys

PATTERNS = {
    "mmio": """
## MmioDevice Pattern (Kernel Drivers)

Location: src/arch/x86_64/mmio_device.zig (via hal.mmio_device)

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

Drivers using MmioDevice:
- XHCI: src/drivers/usb/xhci/
- EHCI: src/drivers/usb/ehci/
- AHCI: src/drivers/storage/ahci/
- E1000e: src/drivers/net/e1000e/
""",

    "ring": """
## Ring IPC Pattern (Zero-Copy)

Syscalls: 1040-1045 in src/kernel/syscall/ring.zig

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
| Keyboard | src/drivers/keyboard.zig | PS/2 keyboard |
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
}

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    query = sys.argv[1].lower()

    # Fuzzy match
    matches = [k for k in PATTERNS.keys() if query in k]

    if not matches:
        print(f"Unknown pattern: {query}")
        print(f"Available: {', '.join(PATTERNS.keys())}")
        sys.exit(1)

    for match in matches:
        print(PATTERNS[match])

if __name__ == "__main__":
    main()

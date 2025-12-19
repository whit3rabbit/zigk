# Driver Architecture

Zscapek uses a hybrid architecture where critical drivers run in the kernel for performance and boot capability, while other drivers run in userspace for stability and security.

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
- **Status**: In development.

#### PS/2 Input (`src/user/drivers/ps2`)
- **Type**: Userspace Input Driver
- **Status**: Handles Keyboard/Mouse interrupt 1/12, broadcasts events.

#### UART (`src/user/drivers/uart`)
- **Type**: Userspace Serial Driver
- **Status**: Simple split-process echo server.

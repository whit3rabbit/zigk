# Userspace Driver Architecture

Zscapek is transitioning towards a microkernel architecture where device drivers run in userspace. This improves stability (drivers can't crash the kernel) and security (drivers have limited privileges).

## Core Concepts

### 1. Capability-Based Security
Drivers are not implicitly trusted. They must be explicitly granted capabilities to access hardware resources.
- **Interrupt Capabilities**: Allow a process to wait for specific IRQs (e.g., `SYS_WAIT_INTERRUPT(4)` for UART).
- **I/O Port Capabilities**: Allow access to specific x86 I/O ports (e.g., `0x3F8` for COM1).
- **Granting**: Capabilities are currently granted by the `init_proc` during system startup.

### 2. Inter-Process Communication (IPC)
Drivers communicate with the kernel and other processes via message passing.
- **`SYS_SEND(pid, msg)`**: Send a fixed-size message to a target process.
- **`SYS_RECV(msg)`**: Block until a message is received.
- **Kernel Messages**: The kernel can send messages to drivers (e.g., console logs).

### 3. Split-Process Architecture
To handle asynchronous events (interrupts) and synchronous requests (IPC) without complex threading, drivers often use a **Split-Process Model**:
- **Input Process (Child)**: Loops on `SYS_WAIT_INTERRUPT`. Handles hardware events and sends notifications.
- **Output Process (Parent)**: Loops on `SYS_RECV`. Handles requests from clients (or kernel) and writes to hardware.
- **Shared State**: The processes are created via `fork()`, sharing capabilities and file descriptors.

## Reference Implementation: UART Driver

The `uart_driver` (`src/user/drivers/uart/main.zig`) demonstrates this pattern:

### Architecture
1. **Initialization**: The driver initializes the UART hardware (baud rate, FIFO) using `SYS_OUTB`.
2. **Fork**: The process forks into an Input Handler and an Output Handler.
3. **Output Handler (Parent)**:
   - Registers as the kernel logger via `SYS_REGISTER_IPC_LOGGER`.
   - Receives log messages from the kernel via IPC.
   - Writes characters to the UART TX port.
4. **Input Handler (Child)**:
   - Waits for IRQ 4 using `SYS_WAIT_INTERRUPT`.
   - Reads characters from UART RX port.
   - Echoes characters back (currently direct echo, future: send to shell).

## Future Work

### 1. Networking (VirtIO-Net)
- **Goal**: Move the current kernel-level VirtIO-Net driver to userspace.
- **Needs**: DMA capability (mapping physical memory), VirtIO queue management in userspace.

### 2. Storage (VirtIO-Blk)
- **Goal**: Implement a userspace disk driver.
- **Needs**: Similar DMA requirements as networking.

### 3. Input (PS/2)
- **Goal**: Migrate keyboard/mouse logic from kernel `input` module to a userspace driver.
- **Status**: Doom currently uses direct syscalls for input. A dedicated driver would broadcast input events to the active window/session.

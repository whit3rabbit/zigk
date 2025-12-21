# Async I/O Subsystem

This document describes the asynchronous I/O infrastructure implemented in Phase 2 of the architecture pivot.

## Overview

The async I/O system provides two interfaces:

1. **Internal KernelIo API** - Future-based async operations for kernel subsystems
2. **Userspace io_uring API** - Linux-compatible syscalls (425-427) for applications

Both interfaces share the same underlying infrastructure: a fixed-size request pool, reactor pattern, and IRQ-driven completion.

## Architecture

```
User Process
    |
+---+---+
|       |
Blocking   io_uring
Syscalls   Syscalls
|       |
+---+---+
    |
    v
+------------------+
|   KernelIo Core  |
| (Future/Reactor) |
+------------------+
    |
+---+---+---+---+---+
|   |   |   |   |
Socket Pipe Kbd Timer Block
Async  Async Async Wheel  I/O
                      (AHCI)
```

## Core Components

### IoRequest (`src/kernel/io/types.zig`)

Single async operation with state machine:

```zig
pub const IoRequest = struct {
    id: u64,                    // Unique monotonic ID
    op: IoOpType,               // Operation type
    fd: i32,                    // File descriptor
    buf_ptr: usize,             // User buffer pointer
    buf_len: usize,             // Buffer length
    op_data: OpData,            // Operation-specific data
    submitter: ?*Thread,        // Thread to wake on completion
    next: ?*IoRequest,          // Intrusive list pointer
    user_data: u64,             // io_uring user_data passthrough
    result: IoResult,           // Completion result
    state: atomic(IoRequestState), // Current state
};
```

**State Machine:**
```
idle -> pending -> in_progress -> completed
                \-> cancelled
```

### IoResult (`src/kernel/io/types.zig`)

Tagged union for operation outcomes:

```zig
pub const IoResult = union(enum) {
    success: usize,              // Bytes transferred or fd
    err: SyscallError,           // Syscall error
    cancelled: void,             // Operation cancelled
    pending: void,               // Still in progress
};
```

### Future (`src/kernel/io/types.zig`)

Handle returned to callers for polling/waiting:

```zig
pub const Future = struct {
    request: *IoRequest,

    pub fn poll(self: *const Future) IoResult;  // Non-blocking check
    pub fn isDone(self: *const Future) bool;    // Completion check
    pub fn wait(self: *const Future) IoResult;  // Blocking wait
    pub fn cancelOp(self: *Future) bool;        // Attempt cancellation
};
```

### IoRequestPool (`src/kernel/io/pool.zig`)

Fixed-size pool of 256 pre-allocated requests:

- O(1) alloc/free via intrusive free list
- No per-operation heap allocation
- Returns null when exhausted (caller returns EAGAIN)
- Thread-safe via spinlock

### Reactor (`src/kernel/io/reactor.zig`)

Global coordinator singleton:

- Manages request pool
- Handles timer queue (sorted by expiry)
- Tick callback for timeout processing
- Statistics tracking

### Timer Wheel (`src/kernel/io/timer.zig`)

Hierarchical 3-level timer wheel for efficient timeout management:

| Level | Granularity | Range |
|-------|-------------|-------|
| L0 | 1 tick (1ms) | 0-255ms |
| L1 | 256 ticks | 256ms-65s |
| L2 | 65536 ticks | 65s-18h |

- O(1) insertion
- O(1) amortized tick processing
- Cascading from higher levels on overflow

## Supported Operations

### Socket Operations

| Operation | Function | Completion Trigger |
|-----------|----------|-------------------|
| Accept | `socket.acceptAsync()` | TCP SYN-ACK received |
| Connect | `socket.connectAsync()` | TCP handshake complete |
| Recv | `socket.recvAsync()` | Data arrives in rx.zig |
| Send | `socket.sendAsync()` | Send buffer available |

### Pipe Operations

| Operation | Function | Completion Trigger |
|-----------|----------|-------------------|
| Read | `pipe.readAsync()` | Data written by writer |
| Write | `pipe.writeAsync()` | Buffer space from reader |

### Keyboard Operations

| Operation | Function | Completion Trigger |
|-----------|----------|-------------------|
| Read | `keyboard.getCharAsync()` | IRQ1 keypress |

### Timer Operations

| Operation | Function | Completion Trigger |
|-----------|----------|-------------------|
| Timeout | `reactor.addTimer()` | Timer wheel expiry |

### Block I/O Operations (AHCI)

| Operation | Function | Completion Trigger |
|-----------|----------|-------------------|
| Read | `ahci.readSectorsAsync()` | AHCI port IRQ (command slot completes) |
| Write | `ahci.writeSectorsAsync()` | AHCI port IRQ (command slot completes) |

**Adapter-level API** (`src/drivers/storage/ahci/adapter.zig`):

| Function | Description |
|----------|-------------|
| `blockReadAsync()` | Allocate DMA buffer, submit read, return buffer phys addr |
| `blockWriteAsync()` | Submit write from existing DMA buffer |
| `copyFromDmaBuffer()` | Copy data from DMA buffer to user buffer |
| `copyToDmaBuffer()` | Copy data from user buffer to DMA buffer |
| `freeDmaBuffer()` | Release DMA buffer pages |

**IRQ-Driven Completion:**

The AHCI driver tracks pending requests per command slot (32 slots max per port). When the
AHCI controller raises an interrupt:

1. `ahciIrqHandler()` is called from the interrupt vector
2. Reads the global interrupt status register to identify active ports
3. For each port, calls `handlePortInterrupt()` which:
   - Reads command issue (CI) register to find completed slots
   - Looks up pending `IoRequest` for each completed slot
   - Calls `request.complete()` with success/error result
   - Wakes the waiting thread via `sched.unblock()`

## io_uring Syscalls

### sys_io_uring_setup (425)
### In sys_io_uring_setup (src/kernel/sys/syscall/io_uring.zig)
Create an io_uring instance.

```c
int io_uring_setup(unsigned entries, struct io_uring_params *p);
```

**Arguments:**
- `entries`: Number of SQ entries (1-256, must be power of 2)
- `params`: In/out parameter structure

**Returns:** File descriptor for the io_uring instance

### sys_io_uring_enter (426)

Submit SQEs and/or wait for CQEs.

**Interface (supports both shared memory and legacy copy modes):**

```c
int io_uring_enter(unsigned fd, unsigned to_submit,
                   unsigned min_complete, unsigned flags,
                   void *sqes_ptr, void *cqes_ptr);
```

**Arguments:**
- `fd`: io_uring file descriptor
- `to_submit`: Number of SQEs to submit
- `min_complete`: Minimum CQEs to wait for (with IORING_ENTER_GETEVENTS)
- `flags`: IORING_ENTER_* flags
- `sqes_ptr`: 0 for shared memory mode, or pointer to userspace SQE array for legacy copy mode
- `cqes_ptr`: 0 for shared memory mode, or pointer to userspace CQE array for legacy copy mode

**Returns:** Number of SQEs submitted (or CQEs ready if shared memory mode with GETEVENTS only)

**Shared Memory Mode (Linux-compatible):**
When `sqes_ptr` and `cqes_ptr` are 0, the kernel reads SQEs from the mmap'd SQ ring
and writes CQEs to the mmap'd CQ ring. This is the standard Linux io_uring interface.

**Legacy Copy Mode:**
When `sqes_ptr` is non-zero, SQEs are copied from userspace. When `cqes_ptr` is non-zero,
CQEs are copied to userspace. This mode is useful for simple testing.

### sys_io_uring_register (427)

Register resources with an io_uring instance.

```c
int io_uring_register(unsigned fd, unsigned opcode,
                      void *arg, unsigned nr_args);
```

**Supported operations:**
- `IORING_REGISTER_PROBE` (8): Query supported operations

**Unsupported (returns ENOSYS):**
- `IORING_REGISTER_BUFFERS` / `IORING_UNREGISTER_BUFFERS`
- `IORING_REGISTER_FILES` / `IORING_UNREGISTER_FILES`

## Supported io_uring Operations

| Opcode | Value | Description |
|--------|-------|-------------|
| IORING_OP_NOP | 0 | No operation (completes immediately) |
| IORING_OP_TIMEOUT | 11 | Wait for timeout |
| IORING_OP_ACCEPT | 13 | Accept TCP connection |
| IORING_OP_ASYNC_CANCEL | 14 | Cancel pending operation |
| IORING_OP_CONNECT | 16 | Connect TCP socket |
| IORING_OP_OPENAT | 18 | Open file relative to directory fd |
| IORING_OP_CLOSE | 19 | Close file descriptor |
| IORING_OP_READ | 22 | Read from fd (keyboard, files) |
| IORING_OP_WRITE | 23 | Write to fd (dispatches to sys_write) |
| IORING_OP_SEND | 26 | Send to socket |
| IORING_OP_RECV | 27 | Receive from socket |

All Linux 6.x opcodes (0-61) are defined in `src/uapi/io_ring.zig` for forward compatibility,
but unsupported opcodes return EINVAL.

## Userspace io_uring Wrapper

The userspace syscall library (`src/user/lib/syscall.zig`) provides a high-level `IoUring` wrapper
that handles ring buffer management and memory barriers:

```zig
const syscall = @import("syscall");

pub const IoUring = struct {
    ring_fd: i32,
    sq_ring: [*]u8,
    cq_ring: [*]u8,
    sqes: [*]IoUringSqe,
    sq_head: *volatile u32,
    sq_tail: *volatile u32,
    cq_head: *volatile u32,
    cq_tail: *volatile u32,
    sq_array: [*]u32,
    cqes: [*]IoUringCqe,
    sq_entries: u32,
    cq_entries: u32,
    sq_mask: u32,
    cq_mask: u32,
    local_sq_tail: u32,

    pub fn init(entries: u32) SyscallError!IoUring;  // Setup rings, mmap buffers
    pub fn deinit(self: *IoUring) void;               // Cleanup and close
    pub fn getSqeAtomicFn(self: *IoUring, populate: fn(*IoUringSqe, ?*anyopaque) void, ctx: ?*anyopaque) bool;  // Atomic get+submit
    pub fn getSqeAtomic(self: *IoUring, ctx: anytype) bool;  // Atomic with .populate() method
    pub fn submit(self: *IoUring, min_complete: u32) SyscallError!u32;  // Enter kernel
    pub fn peekCqe(self: *IoUring) ?*IoUringCqe;      // Non-blocking CQE check
    pub fn advanceCq(self: *IoUring) void;            // Consume CQE

    // Prep helpers
    pub fn prepAccept(sqe: *IoUringSqe, fd: i32, addr: ?*anyopaque,
                      addrlen: ?*anyopaque, user_data: u64) void;
    pub fn prepRecv(sqe: *IoUringSqe, fd: i32, buf: []u8, user_data: u64) void;
    pub fn prepSend(sqe: *IoUringSqe, fd: i32, buf: []const u8, user_data: u64) void;
    pub fn prepClose(sqe: *IoUringSqe, fd: i32, user_data: u64) void;
};
```

**Memory Barriers:**

The wrapper uses `mfence` instructions for proper synchronization between userspace
and kernel when accessing shared ring buffers.

## Usage Examples

### Kernel Internal API

```zig
const io = @import("io");

// Allocate request
const req = io.allocRequest(.socket_read) orelse return error.ENOMEM;
defer io.freeRequest(req);

// Configure
req.fd = socket_fd;
req.buf_ptr = @intFromPtr(buffer.ptr);
req.buf_len = buffer.len;

// Submit and get future
var future = io.submit(req);

// Option 1: Blocking wait
const result = future.wait();

// Option 2: Non-blocking poll
while (!future.isDone()) {
    // Do other work
}
const result = future.poll();
```

### Async Socket Accept

```zig
const socket = @import("net").transport.socket;

// Queue async accept
if (socket.acceptAsync(listen_fd, request)) |_| {
    // Request queued - will complete when connection arrives
} else |err| {
    // Error or completed immediately
}
```

### Timer with Reactor

```zig
const io = @import("io");

const req = io.allocRequest(.timer) orelse return error.ENOMEM;
_ = req.compareAndSwapState(.idle, .pending);

// Add 5 second timeout (5000 ticks at 1ms/tick)
io.getGlobal().addTimer(req, 5000);

// Wait for expiry
var future = io.Future{ .request = req };
_ = future.wait();
```

### Async Block I/O (AHCI)

```zig
const adapter = @import("ahci").adapter;
const io = @import("io");

// Allocate IoRequest for async operation
const req = io.allocRequest(.disk_read) orelse return error.ENOMEM;
defer io.freeRequest(req);

// Submit async read - allocates DMA buffer and returns its physical address
const buf_phys = try adapter.blockReadAsync(port_num, lba, sector_count, req);
defer adapter.freeDmaBuffer(buf_phys, sector_count * 512);

// Wait for IRQ-driven completion (thread blocks, no busy-wait)
var future = io.Future{ .request = req };
const result = future.wait();

switch (result) {
    .success => |bytes| {
        // Copy from DMA buffer to user buffer
        adapter.copyFromDmaBuffer(buf_phys, user_buffer[0..bytes]);
    },
    .err => |e| return e,
    .cancelled => return error.ECANCELED,
    .pending => unreachable,
}
```

### Userspace io_uring HTTP Server

The httpd example (`src/user/httpd/main.zig`) demonstrates the io_uring wrapper:

```zig
const syscall = @import("syscall");

// Initialize io_uring
var ring = syscall.IoUring.init(64) catch |err| {
    // Fallback to poll() mode
    return runPollMode(listener);
};
defer ring.deinit();

// Submit initial accept using atomic pattern (avoids TOCTOU race)
_ = ring.getSqeAtomicFn(&populateAccept, @ptrFromInt(@as(usize, @intCast(listener))));

// Event loop
while (true) {
    // Submit pending SQEs and wait for at least 1 completion
    // This properly blocks in kernel (no spin-polling)
    _ = ring.submit(1) catch continue;

    // Process all ready completions
    while (ring.peekCqe()) |cqe| {
        handleCompletion(&ring, listener, cqe);
        ring.advanceCq();
    }
}

fn populateAccept(sqe: *syscall.IoUringSqe, ctx: ?*anyopaque) void {
    const fd: i32 = @intCast(@intFromPtr(ctx));
    syscall.IoUring.prepAccept(sqe, fd, null, null, encodeUserData(.accept, fd));
}

fn handleCompletion(ring: *syscall.IoUring, listener: i32, cqe: *syscall.IoUringCqe) void {
    const op = decodeOp(cqe.user_data);
    const fd = decodeFd(cqe.user_data);

    switch (op) {
        .accept => {
            // Resubmit accept, handle new connection
            submitAccept(ring, listener);
            if (cqe.res >= 0) {
                if (allocClient(cqe.res)) |client| {
                    submitRecv(ring, client);
                }
            }
        },
        .recv => {
            // Got request, send response
            submitSend(ring, fd, http_response);
        },
        .send => {
            // Response sent, close connection
            submitClose(ring, fd);
        },
        .close => {},
    }
}
```

**Operation Encoding:**

The user_data field encodes both operation type and file descriptor:
- Bits 56-63: Operation type enum (accept, recv, send, close)
- Bits 0-55: File descriptor

## Integration Points

### Initialization

In `src/kernel/main.zig`:
```zig
// After sched.init()
io.initGlobal();
```

### Timer Tick

In `src/net/root.zig`:
```zig
pub fn tick() void {
    ipv4.arp.tick();
    transport.tcp.tick();
    io.timerTick();  // Process timer expirations
}
```

### IRQ Completion

Example from `src/drivers/input/keyboard.zig`:
```zig
// In handleIrq():
if (keyboard_state.pending_read) |pending_ptr| {
    const request: *io.IoRequest = @ptrCast(@alignCast(pending_ptr));
    if (keyboard_state.ascii_buffer.pop()) |c| {
        _ = request.complete(.{ .success = @as(usize, c) });
    }
}
```

### AHCI IRQ Handler Registration

In `src/drivers/storage/ahci/root.zig`:
```zig
pub fn registerIrqHandler(controller: *AhciController) void {
    hal.interrupts.registerHandler(
        controller.irq_line + 32,  // IRQ offset for PCI devices
        ahciIrqHandler,
        @ptrCast(controller),
    );
}

pub fn ahciIrqHandler(ctx: ?*anyopaque) void {
    const controller: *AhciController = @ptrCast(@alignCast(ctx));
    controller.handleInterrupt();
}
```

**AhciPort pending request tracking:**
```zig
// Added to AhciPort struct
pending_requests: [32]?*io.IoRequest,  // Per command slot
commands_issued: u32,                   // Bitmask of active slots
pending_lock: sync.Spinlock,            // Thread safety
```

## File Structure

```
src/kernel/io/
    types.zig       - IoRequest, Future, IoResult, IoOpType
    pool.zig        - IoRequestPool (256 requests)
    reactor.zig     - Global reactor singleton
    timer.zig       - Hierarchical timer wheel
    root.zig        - Module exports

src/uapi/
    io_ring.zig     - Linux-compatible SQE/CQE structures
    syscalls.zig    - Syscall numbers (425-427)

src/kernel/sys/syscall/
    io_uring.zig    - io_uring syscall implementations

src/net/transport/socket/
    tcp_api.zig     - acceptAsync, recvAsync, etc.
    types.zig       - Socket struct with pending_* fields

src/kernel/fs/
    pipe.zig        - readAsync, writeAsync

src/drivers/
    keyboard.zig    - getCharAsync

src/drivers/storage/ahci/
    root.zig        - AHCI controller with async methods:
                      readSectorsAsync, writeSectorsAsync,
                      handleInterrupt, handlePortInterrupt
    adapter.zig     - Block device adapter with:
                      blockReadAsync, blockWriteAsync,
                      copyFromDmaBuffer, copyToDmaBuffer, freeDmaBuffer

src/user/lib/
    syscall.zig     - Userspace syscall wrappers including:
                      IoUring struct (init, getSqeAtomicFn, submit, peekCqe)
                      io_uring_setup, io_uring_enter, io_uring_register

src/user/httpd/
    main.zig        - HTTP server using io_uring (with poll() fallback)
```

## Limitations

1. **Single pending request per resource** - Each socket/pipe/keyboard can have one pending async operation per type
2. **No SQPOLL** - Kernel polling thread not implemented
3. **No registered buffers** - IORING_REGISTER_BUFFERS not supported
4. **Fixed pool size** - 256 concurrent requests system-wide

## Future Enhancements

- Multiple pending requests per socket (queue)
- IORING_REGISTER_BUFFERS support for zero-copy I/O
- Linked operations (IOSQE_IO_LINK)
- SQPOLL mode for kernel-side SQ polling
- Vectored I/O (READV, WRITEV)
- NVMe async support (similar pattern to AHCI)
- Filesystem-level async operations (currently block layer only)

## Design Decisions: Shared Memory Ring Model

### Current Implementation: mmap Shared Rings (Linux-Compatible)

Our io_uring now uses Linux-compatible shared memory rings:
- Physical pages allocated for SQ ring, CQ ring, and SQE array
- Userspace maps these via `mmap()` on the io_uring fd
- Kernel and userspace share the same memory (true zero-copy)
- Standard mmap offsets: `IORING_OFF_SQ_RING`, `IORING_OFF_CQ_RING`, `IORING_OFF_SQES`

### Ring Structure

**SQ Ring (Submission Queue):**
```
| head | tail | ring_mask | ring_entries | flags | dropped | array[entries] |
```
- Userspace writes to `tail`, kernel reads and updates `head`
- `array[]` contains indices into the SQE array

**CQ Ring (Completion Queue):**
```
| head | tail | ring_mask | ring_entries | overflow | cqes[entries] |
```
- Kernel writes to `tail`, userspace reads and updates `head`
- `cqes[]` contains completion entries directly

**SQE Array:**
- Separate mmap region containing the actual SQE structures
- Indexed by values in SQ ring's array

### Memory Barriers

Shared memory requires proper synchronization:
- `lfence` before reading indices (load barrier)
- `sfence` after writing entries (store barrier)
- `mfence` around index updates (full barrier)

### Legacy Copy Mode (Still Supported)

For simple testing, the extended interface is still available:
- Pass non-zero `sqes_ptr` to copy SQEs from userspace
- Pass non-zero `cqes_ptr` to copy CQEs to userspace
- Useful for debugging or when mmap is not desired

### Implementation Details

Key changes in `src/kernel/sys/syscall/io_uring.zig`:
- `IoUringInstance` stores physical addresses for each ring region
- `allocInstance()` uses `pmm.allocZeroedPages()` for ring memory
- `ioUringMmap()` file operation returns physical addresses for mapping
- `submitFromSharedMemory()` reads SQEs directly from kernel virtual address (via HHDM)
- Ring headers initialized with proper `ring_mask` and `ring_entries`

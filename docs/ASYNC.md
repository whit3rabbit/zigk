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
+---+---+---+---+
|   |   |   |
Socket Pipe  Kbd  Timer
Async  Async Async Wheel
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

## io_uring Syscalls

### sys_io_uring_setup (425)

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

```c
int io_uring_enter(unsigned fd, unsigned to_submit,
                   unsigned min_complete, unsigned flags,
                   sigset_t *sig);
```

**Arguments:**
- `fd`: io_uring file descriptor
- `to_submit`: Number of SQEs to submit
- `min_complete`: Minimum CQEs to wait for (with IORING_ENTER_GETEVENTS)
- `flags`: IORING_ENTER_* flags
- `sig`: Signal mask (unused)

**Returns:** Number of SQEs submitted

### sys_io_uring_register (427)

Register resources with an io_uring instance.

```c
int io_uring_register(unsigned fd, unsigned opcode,
                      void *arg, unsigned nr_args);
```

**Status:** Stub implementation, returns ENOSYS

## Supported io_uring Operations

| Opcode | Value | Description |
|--------|-------|-------------|
| IORING_OP_NOP | 0 | No operation (completes immediately) |
| IORING_OP_READ | 22 | Read from fd (keyboard) |
| IORING_OP_WRITE | 23 | Write to fd |
| IORING_OP_ACCEPT | 13 | Accept TCP connection |
| IORING_OP_CONNECT | 16 | Connect TCP socket |
| IORING_OP_RECV | 27 | Receive from socket |
| IORING_OP_SEND | 26 | Send to socket |
| IORING_OP_TIMEOUT | 11 | Wait for timeout |

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

Example from `src/drivers/keyboard.zig`:
```zig
// In handleIrq():
if (keyboard_state.pending_read) |pending_ptr| {
    const request: *io.IoRequest = @ptrCast(@alignCast(pending_ptr));
    if (keyboard_state.ascii_buffer.pop()) |c| {
        _ = request.complete(.{ .success = @as(usize, c) });
    }
}
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

src/kernel/syscall/
    io_uring.zig    - io_uring syscall implementations

src/net/transport/socket/
    tcp_api.zig     - acceptAsync, recvAsync, etc.
    types.zig       - Socket struct with pending_* fields

src/kernel/
    pipe.zig        - readAsync, writeAsync

src/drivers/
    keyboard.zig    - getCharAsync
```

## Limitations

1. **Single pending request per resource** - Each socket/pipe/keyboard can have one pending async operation per type
2. **No SQPOLL** - Kernel polling thread not implemented
3. **No registered buffers** - IORING_REGISTER_BUFFERS not supported
4. **Fixed pool size** - 256 concurrent requests system-wide
5. **Simplified ring model** - SQEs copied to kernel, not true shared memory rings

## Future Enhancements

- Multiple pending requests per socket (queue)
- Proper shared memory rings with userspace
- IORING_REGISTER_BUFFERS support
- Linked operations (IOSQE_IO_LINK)
- Operation cancellation via IORING_OP_ASYNC_CANCEL

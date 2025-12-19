#!/usr/bin/env python3
"""
Async I/O Query Tool for zigk kernel.

Query async patterns: reactor, io_uring, ring buffers, timers.

Usage:
    python async_query.py reactor        # Kernel reactor pattern
    python async_query.py io_uring       # Userspace io_uring
    python async_query.py ring           # Ring buffer IPC
    python async_query.py timer          # Timer wheel
    python async_query.py future         # Future/promise pattern
    python async_query.py ahci           # AHCI async block I/O
"""

import sys

PATTERNS = {
    "reactor": """
## Kernel Reactor Pattern

Location: src/kernel/io/reactor.zig

### Request Lifecycle
```
1. Allocate request from pool
2. Configure request fields
3. Submit to reactor
4. Wait on future (blocks thread)
5. Free request back to pool
```

### Basic Pattern
```zig
const io = @import("io");

pub fn asyncRead(fd: usize, buf: []u8) !usize {
    // 1. Allocate from pool (O(1) free list)
    const req = io.allocRequest(.socket_read) orelse return error.ENOMEM;
    defer io.freeRequest(req);

    // 2. Configure
    req.fd = fd;
    req.buf_ptr = @intFromPtr(buf.ptr);
    req.buf_len = buf.len;

    // 3. Submit and get future
    var future = io.submit(req);

    // 4. Wait (blocks via sched.block(), not spin)
    const result = future.wait();

    // 5. Handle result
    return switch (result) {
        .success => |n| n,
        .err => |e| e,
        .cancelled => error.ECANCELED,
        .pending => error.EAGAIN,
    };
}
```

### IoOpType Enum
- socket_read, socket_write
- socket_accept, socket_connect
- pipe_read, pipe_write
- timer
- disk_read, disk_write
- keyboard_read

### Request Pool
- 256 pre-allocated requests
- O(1) alloc/free via free list
- No heap allocation during I/O
""",

    "io_uring": """
## Userspace io_uring

Location: src/user/lib/syscall.zig (IoUring wrapper)

### Syscalls
- 425: io_uring_setup
- 426: io_uring_enter
- 427: io_uring_register

### Setup
```zig
var ring = syscall.IoUring.init(64) catch return fallback();
defer ring.deinit();
```

### Submit Operations
```zig
// Get submission queue entry
if (ring.getSqe()) |sqe| {
    // Prepare operation
    syscall.IoUring.prepAccept(sqe, listener_fd, null, null, user_data);
    ring.submitSqe();
}

// Submit to kernel (blocks until min_complete done)
_ = ring.submit(1) catch continue;
```

### Process Completions
```zig
while (ring.peekCqe()) |cqe| {
    const user_data = cqe.user_data;
    const result = cqe.res;

    if (result < 0) {
        // Error: -errno
        handleError(-result);
    } else {
        handleSuccess(result);
    }

    ring.advanceCq();
}
```

### Prep Helpers
- prepAccept(sqe, fd, addr, len, user_data)
- prepRecv(sqe, fd, buf, len, flags, user_data)
- prepSend(sqe, fd, buf, len, flags, user_data)
- prepClose(sqe, fd, user_data)

### Current Status
io_uring syscalls defined but return ENOSYS (stub implementation).
Use poll() fallback for now.
""",

    "ring": """
## Ring Buffer IPC (Zero-Copy)

Location: src/kernel/syscall/ring.zig

### Syscalls
| # | Name | Purpose |
|---|------|---------|
| 1040 | ring_create | Create ring, specify consumer |
| 1041 | ring_attach | Attach as consumer |
| 1042 | ring_detach | Detach from ring |
| 1043 | ring_wait | Wait for entries (blocks) |
| 1044 | ring_notify | Wake consumer |
| 1045 | ring_wait_any | Wait on multiple rings |

### Ring Structure (Shared Memory)
```
+------------------+
| head (producer)  |  Write index
+------------------+
| tail (consumer)  |  Read index
+------------------+
| entry_size       |
| entry_count      |
+------------------+
| entries[0]       |
| entries[1]       |
| ...              |
+------------------+
```

### Producer Pattern
```zig
const ring_id = syscall.ring_create(1500, 256, driver_pid, name, len);

// Get write slot
const idx = ring.head;
const slot = ring.entries[idx % ring.entry_count];

// Write data
@memcpy(slot, packet_data);

// Commit (atomic increment)
@atomicStore(&ring.head, idx + 1, .release);

// Wake consumer
syscall.ring_notify(ring_id);
```

### Consumer Pattern
```zig
syscall.ring_attach(ring_id, &result);
const ring = @ptrFromInt(result.virt_addr);

while (true) {
    // Wait for entries
    const count = syscall.ring_wait(ring_id, 1, timeout_ns);

    // Process entries
    while (ring.tail != ring.head) {
        const slot = ring.entries[ring.tail % ring.entry_count];
        processEntry(slot);
        ring.tail += 1;
    }
}
```

### Multi-Ring Wait (MPSC)
```zig
const rings = [_]u32{ rx_ring, tx_ring, cmd_ring };
const ready = syscall.ring_wait_any(&rings, 3, 1, -1);
// ready = ring_id that has data
```

### Use Cases
- Network TX/RX rings
- Driver command queues
- Log buffers
""",

    "timer": """
## Timer Wheel

Location: src/kernel/io/timer.zig

### Hierarchical 3-Level Wheel
```
Level 0: 256 slots, ~1ms granularity
Level 1: 64 slots, ~256ms granularity
Level 2: 64 slots, ~16s granularity
```

### Adding Timer
```zig
const reactor = @import("reactor");

// Add timer for 100 ticks (~100ms)
reactor.addTimer(req, 100);

// Request will complete when timer fires
var future = io.Future{ .request = req };
_ = future.wait();
```

### Timer Callback
When timer fires, the request's completion is set:
```zig
req.result = .{ .success = 0 };
if (req.waiting_thread) |thread| {
    sched.unblock(thread);
}
```

### Syscall Integration
```zig
pub fn sys_nanosleep(req: *Timespec, rem: ?*Timespec) SyscallError!usize {
    const ticks = nsToTicks(req.tv_sec, req.tv_nsec);

    const timer_req = io.allocRequest(.timer) orelse return error.ENOMEM;
    defer io.freeRequest(timer_req);

    reactor.addTimer(timer_req, ticks);
    var future = io.Future{ .request = timer_req };
    _ = future.wait();

    return 0;
}
```
""",

    "future": """
## Future/Promise Pattern

Location: src/kernel/io/types.zig

### IoResult Union
```zig
pub const IoResult = union(enum) {
    success: usize,      // Bytes transferred, etc.
    err: SyscallError,   // Error code
    cancelled: void,     // Operation cancelled
    pending: void,       // Still in progress
};
```

### Future API
```zig
pub const Future = struct {
    request: *IoRequest,

    // Non-blocking check
    pub fn poll(self: *Future) ?IoResult {
        if (self.request.state == .completed) {
            return self.request.result;
        }
        return null;
    }

    // Check completion
    pub fn isDone(self: *Future) bool {
        return self.request.state == .completed;
    }

    // Blocking wait
    pub fn wait(self: *Future) IoResult {
        while (!self.isDone()) {
            self.request.waiting_thread = sched.currentThread();
            sched.block();  // Yield until unblocked
        }
        return self.request.result;
    }

    // Cancel operation
    pub fn cancelOp(self: *Future) void {
        self.request.cancelled = true;
        // ... notify driver
    }
};
```

### Request States
```
idle → pending → in_progress → completed
         ↑                         ↓
         └─────── cancelled ←──────┘
```
""",

    "ahci": """
## AHCI Async Block I/O

Location: src/drivers/storage/ahci/adapter.zig

### Async Read Pattern
```zig
const adapter = @import("ahci").adapter;

pub fn readSectorsAsync(port: u8, lba: u64, count: u16, request: *IoRequest) !u64 {
    // Allocate DMA buffer
    const buf_phys = try adapter.allocDmaBuffer(count * 512);

    // Setup command (FIS, PRD table)
    const slot = try adapter.findFreeSlot(port);
    adapter.setupReadCommand(port, slot, lba, count, buf_phys);

    // Issue command (non-blocking)
    adapter.issueCommand(port, slot);

    // Associate request for IRQ completion
    adapter.pending_requests[port][slot] = request;

    return buf_phys;
}
```

### Completion Handler (IRQ)
```zig
fn handleInterrupt(port: u8) void {
    const is = adapter.readPortReg(port, .IS);

    for (completed_slots) |slot| {
        if (adapter.pending_requests[port][slot]) |req| {
            req.result = .{ .success = req.buf_len };
            if (req.waiting_thread) |t| sched.unblock(t);
            adapter.pending_requests[port][slot] = null;
        }
    }
}
```

### Usage
```zig
const req = io.allocRequest(.disk_read) orelse return error.ENOMEM;
defer io.freeRequest(req);

const buf_phys = try adapter.readSectorsAsync(port, lba, sectors, req);
defer adapter.freeDmaBuffer(buf_phys, sectors * 512);

var future = io.Future{ .request = req };
_ = future.wait();  // Blocks until IRQ

adapter.copyFromDmaBuffer(buf_phys, dest_buf);
```
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

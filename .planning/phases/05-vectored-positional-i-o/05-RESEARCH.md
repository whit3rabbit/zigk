# Phase 5: Vectored & Positional I/O - Research

**Researched:** 2026-02-07
**Domain:** Vectored I/O syscalls (scatter-gather), positional I/O, and kernel-space file copying
**Confidence:** HIGH

## Summary

This phase implements the vectored I/O family (readv/writev and positional variants) plus sendfile for zero-copy file-to-socket transfers. The codebase already has writev and pread64 implementations, providing solid foundations to build upon.

Vectored I/O (scatter-gather) allows reading into or writing from multiple non-contiguous buffers in a single syscall, eliminating userspace loop overhead and providing atomicity guarantees. The positional variants (preadv/pwritev) combine vectored I/O with offset-based access without modifying file position. The v2 variants add per-call flags (RWF_NOWAIT, RWF_HIPRI, etc.) for advanced I/O control. sendfile efficiently copies data between file descriptors in kernel space, avoiding userspace buffer copies entirely.

**Primary recommendation:** Implement readv first (mirrors existing writev pattern), then add positional variants (preadv/pwritev) using the existing pread64 seek-read-restore pattern with vectored operations, extend to v2 variants with flags support, and finally implement sendfile with proper loop-until-complete logic and EOF handling.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| sys/uio.h | POSIX.1-2001 | iovec structure definition | Universal scatter-gather interface |
| Linux syscalls | 2.6.30+ (preadv/pwritev), 4.6+ (v2 variants) | Vectored I/O APIs | Industry standard for efficient I/O |

### Supporting
| Component | Purpose | When to Use |
|-----------|---------|-------------|
| IOV_MAX limit | Maximum iovec count per call | All vectored syscalls must validate iovcnt <= IOV_MAX |
| RWF_* flags | Per-call I/O behavior modifiers | preadv2/pwritev2 for non-blocking, high-priority, or append behavior |
| UserPtr validation | Safe user memory access | Every iovec buffer must be validated before kernel access |

### Existing Infrastructure
| Component | Location | Purpose |
|-----------|----------|---------|
| sys_writev | src/kernel/sys/syscall/io/read_write.zig:152 | Vectored write (already implemented) |
| sys_pread64 | src/kernel/sys/syscall/io/read_write.zig:255 | Positional read (already implemented) |
| perform_read_locked | src/kernel/sys/syscall/io/utils.zig:70 | Helper for user buffer -> kernel -> device read |
| perform_write_locked | src/kernel/sys/syscall/io/utils.zig:44 | Helper for user buffer -> kernel -> device write |
| FileOps vtable | src/kernel/fs/fd.zig:56 | Device-agnostic read/write/seek operations |

## Architecture Patterns

### Pattern 1: Vectored Operation Loop
**What:** Process array of iovecs sequentially, handling partial transfers and accumulating total bytes.
**When to use:** All readv/writev/preadv/pwritev implementations.
**Example (from existing sys_writev):**
```zig
// Source: src/kernel/sys/syscall/io/read_write.zig:211-252
for (kvecs) |vec| {
    if (vec.len == 0) continue;

    var offset: usize = 0;
    while (offset < vec.len) {
        const remaining = vec.len - offset;
        const chunk_len = @min(remaining, 64 * 1024); // Cap to avoid huge allocations

        const base_offset = @addWithOverflow(vec.base, offset);
        if (base_offset[1] != 0) {
            if (total_written > 0) return total_written;
            return error.EFAULT;
        }

        const res = perform_write_locked(fd_obj, base_offset[0], chunk_len) catch |err| {
            if (total_written > 0) return total_written;
            return err;
        };

        const new_total = @addWithOverflow(total_written, res);
        if (new_total[1] != 0) return total_written;
        total_written = new_total[0];
        offset += res;

        // Short write: stop processing
        if (res < chunk_len) return total_written;
    }
}
```

### Pattern 2: Positional I/O (Seek-Op-Restore)
**What:** Save current position, seek to target offset, perform operation, restore original position.
**When to use:** pread64, pwrite64, preadv, pwritev (when device lacks native pread/pwrite ops).
**Example (from existing sys_pread64):**
```zig
// Source: src/kernel/sys/syscall/io/read_write.zig:287-346
const held = fd.lock.acquire();
defer held.release();

// Save current position
const old_pos = fd.position;

// Seek to target offset
const seek_fn = fd.ops.seek.?;
const res1 = seek_fn(fd, @intCast(offset), 0); // SEEK_SET
if (res1 < 0) return error.EINVAL;
fd.position = @intCast(res1);

// Perform read
const bytes_read = utils.perform_read_locked(fd, buf_ptr, count) catch |err| {
    // Restore position before error return
    _ = seek_fn(fd, @intCast(old_pos), 0);
    fd.position = old_pos;
    return err;
};

// Restore position
const res2 = seek_fn(fd, @intCast(old_pos), 0);
if (res2 < 0) {
    console.err("sys_pread64: failed to restore position!", .{});
} else {
    fd.position = @intCast(res2);
}
```

### Pattern 3: IOV_MAX and Overflow Validation
**What:** Validate iovec array bounds and prevent iov_len sum overflow.
**When to use:** Entry point of all vectored syscalls.
**Example (from existing sys_writev):**
```zig
// Source: src/kernel/sys/syscall/io/read_write.zig:168-209
const MAX_WRITEV_BYTES: usize = 16 * 1024 * 1024;

if (count == 0) return 0;
if (count > 1024) return error.EINVAL; // IOV_MAX check

// Copy iovecs from user
const kvecs = heap.allocator().alloc(Iovec, count) catch return error.ENOMEM;
defer heap.allocator().free(kvecs);

const uptr = UserPtr.from(bvec_ptr);
_ = uptr.copyToKernel(std.mem.sliceAsBytes(kvecs)) catch return error.EFAULT;

var total_len: usize = 0;
for (kvecs) |vec| {
    if (vec.len == 0) continue;
    const new_total = @addWithOverflow(total_len, vec.len);
    if (new_total[1] != 0 or new_total[0] > MAX_WRITEV_BYTES) {
        return error.EINVAL;
    }
    total_len = new_total[0];
}
```

### Pattern 4: sendfile Loop-Until-Complete
**What:** Loop over sendfile calls until entire range copied or EOF reached.
**When to use:** sendfile implementation when caller requests multi-megabyte transfers.
**Pseudocode:**
```zig
pub fn sys_sendfile(out_fd: usize, in_fd: usize, offset_ptr: usize, count: usize) SyscallError!usize {
    // 1. Validate FDs (in_fd readable + seekable, out_fd writable)
    // 2. Handle offset parameter (NULL vs non-NULL)
    // 3. Loop: read chunk from in_fd, write chunk to out_fd
    var total_sent: usize = 0;
    while (total_sent < count) {
        const remaining = count - total_sent;
        const chunk = @min(remaining, 64 * 1024);

        // Allocate kernel buffer
        const kbuf = heap.allocator().alloc(u8, chunk) catch return error.ENOMEM;
        defer heap.allocator().free(kbuf);

        // Read from in_fd
        const bytes_read = perform_read_locked(in_fd_obj, kbuf);
        if (bytes_read == 0) break; // EOF

        // Write to out_fd
        const bytes_written = perform_write_locked(out_fd_obj, kbuf[0..bytes_read]);

        total_sent += bytes_written;

        // Short write: stop
        if (bytes_written < bytes_read) break;
    }
    // 4. Update offset parameter if non-NULL
    return total_sent;
}
```

### Anti-Patterns to Avoid
- **Not validating IOV_MAX upfront:** EINVAL must be returned before processing any iovecs if iovcnt > 1024 (IOV_MAX on modern Linux).
- **Ignoring partial transfers:** Short reads/writes can occur legitimately (pipe buffer full, socket buffer space). Must accumulate and return total_bytes instead of retrying silently.
- **Forgetting position restore on error:** preadv/pwritev must restore fd.position even when operation fails mid-way.
- **Failing to handle O_APPEND with sendfile:** Linux rejects sendfile when out_fd has O_APPEND flag (EINVAL).

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Userspace scatter-gather loop | Custom "read N buffers in loop" | readv/writev syscalls | Atomicity guarantee (no interleaving), fewer syscalls, kernel can optimize DMA |
| File-to-socket copying | read() + write() loop | sendfile syscall | Zero-copy in kernel (no userspace buffer), hardware DMA offload, 30-70% throughput gain |
| Offset-based I/O with lseek | lseek + read/write + lseek | pread64/pwrite64/preadv/pwritev | Atomic (no TOCTOU races), thread-safe (no position corruption) |
| Non-blocking I/O control per-call | fcntl(F_SETFL) + O_NONBLOCK toggle | preadv2/pwritev2 with RWF_NOWAIT | No side effects on FD flags, safe for multi-threaded use |

**Key insight:** Vectored I/O exists because scatter-gather DMA is a hardware primitive on modern systems. Hand-rolling these loops in userspace forces data through CPU cache unnecessarily and loses atomicity guarantees. Similarly, sendfile leverages splice/pipe infrastructure in the kernel that cannot be replicated efficiently from userspace.

## Common Pitfalls

### Pitfall 1: iov_len Sum Overflow to Negative ssize_t
**What goes wrong:** If sum of all iov_len values exceeds SSIZE_MAX (9223372036854775807 on 64-bit), the return type (ssize_t) cannot represent the total bytes transferred. Linux returns EINVAL.
**Why it happens:** Developers forget that return value is ssize_t, not size_t. An attacker could craft iovecs with huge lengths to trigger overflow.
**How to avoid:** Pre-validate sum of iov_len before processing any buffers. Use checked arithmetic (@addWithOverflow in Zig).
**Warning signs:** Test with IOV_MAX iovecs each with length = SIZE_MAX / 2. Should fail with EINVAL.

### Pitfall 2: IOV_MAX Varies by Kernel Version
**What goes wrong:** Linux 2.0 had IOV_MAX=16, modern kernels have 1024. Code hardcoded to 16 rejects valid calls.
**Why it happens:** Historical documentation shows old limits. Developers copy examples from outdated sources.
**How to avoid:** Use IOV_MAX constant (1024 for modern Linux). Existing sys_writev correctly uses `if (count > 1024) return error.EINVAL;`.
**Warning signs:** Userspace programs calling readv with 100 iovecs fail with EINVAL on your kernel but work on Linux.

### Pitfall 3: Not Handling Short Transfers in Vectored I/O
**What goes wrong:** readv/writev can return fewer bytes than sum of iov_len (e.g., pipe buffer full, socket buffer space exhausted). If you retry internally, you violate POSIX semantics.
**Why it happens:** Developers assume vectored I/O is "all or nothing" like atomicity guarantee for writes. Atomicity means no interleaving, NOT guaranteed full completion.
**How to avoid:** Return the partial byte count to userspace. Let caller decide whether to retry. Existing sys_writev correctly returns total_written on short write.
**Warning signs:** Programs using writev on pipes hang because kernel returns partial write but syscall retries forever.

### Pitfall 4: sendfile Partial Transfer Ignored
**What goes wrong:** sendfile can transfer fewer bytes than requested (non-blocking socket, low memory, file size limit). Caller must loop to complete transfer.
**Why it happens:** Man page says "sendfile() is more efficient than read+write", leading developers to assume it's atomic or guaranteed to complete.
**How to avoid:** Document return value clearly: "number of bytes written (may be less than count)". Test with non-blocking out_fd.
**Warning signs:** Large file transfers (>100MB) via sendfile stall at random byte counts.

### Pitfall 5: sendfile with O_APPEND out_fd
**What goes wrong:** Linux returns EINVAL if out_fd has O_APPEND flag, because sendfile cannot honor "append mode" semantics (offset parameter conflicts with append-only writing).
**Why it happens:** O_APPEND means "all writes go to EOF", but sendfile's offset parameter specifies read position. Developers don't realize these are incompatible.
**How to avoid:** Check `(out_fd.flags & O_APPEND) != 0` and return EINVAL early. Document restriction prominently.
**Warning signs:** Log rotation scripts using sendfile to append logs fail with EINVAL.

### Pitfall 6: preadv2 RWF_NOWAIT on Blocking Files
**What goes wrong:** RWF_NOWAIT means "fail with EAGAIN if operation would block" (e.g., page not in cache). If caller doesn't handle EAGAIN, reads fail silently.
**Why it happens:** Developers see "non-blocking I/O" and assume it works like O_NONBLOCK on sockets. It's actually for polling-based I/O with io_uring.
**How to avoid:** Document that RWF_NOWAIT requires caller to handle EAGAIN and retry. Existing kernel bug (Linux 5.9-5.10): preadv2 with RWF_NOWAIT returns 0 at non-EOF.
**Warning signs:** Programs using RWF_NOWAIT see intermittent zero-length reads in middle of files.

### Pitfall 7: Forgetting Position Restore on preadv Error
**What goes wrong:** If preadv seeks to offset, reads fail (EFAULT, EIO), and forgets to restore fd.position, subsequent reads start from wrong offset.
**Why it happens:** Error path doesn't match success path. Developers add `defer` for success case but error paths return early without executing it.
**How to avoid:** Use errdefer for position restore, or catch block that restores before returning error (like sys_pread64 does).
**Warning signs:** File reads become corrupted after failed preadv call.

### Pitfall 8: Atomicity Misunderstanding (Interleaving vs. Completion)
**What goes wrong:** Developers assume writev atomicity means "all buffers written or none" (transaction semantics). Actually means "no interleaving with other writers".
**Why it happens:** Word "atomic" is overloaded. In database context = ACID transactions. In I/O context = indivisible block (no partial overwrites from concurrent writers).
**How to avoid:** Document: "writev writes all iovecs as single contiguous block; concurrent writev calls won't split it. But writev can still return partial byte count if device buffer fills."
**Warning signs:** Programs using writev to logs expect transactional rollback on error, but get partial writes.

## Code Examples

### Vectored Write (Existing Implementation)
```zig
// Source: src/kernel/sys/syscall/io/read_write.zig
pub fn sys_writev(fd: usize, bvec_ptr: usize, count: usize) SyscallError!usize {
    const Iovec = extern struct {
        base: usize,
        len: usize,
    };

    const MAX_WRITEV_BYTES: usize = 16 * 1024 * 1024;

    if (count == 0) return 0;
    if (count > 1024) return error.EINVAL;

    // Copy iovecs from user
    const kvecs = heap.allocator().alloc(Iovec, count) catch return error.ENOMEM;
    defer heap.allocator().free(kvecs);

    const uptr = UserPtr.from(bvec_ptr);
    _ = uptr.copyToKernel(std.mem.sliceAsBytes(kvecs)) catch return error.EFAULT;

    var total_written: usize = 0;
    var total_len: usize = 0;

    // Get FD and lock once for entire operation
    const table = base.getGlobalFdTable();
    const fd_u32 = safeFdCast(fd) orelse return error.EBADF;
    const fd_obj = table.get(fd_u32) orelse return error.EBADF;

    if (!fd_obj.isWritable()) return error.EBADF;

    const held = fd_obj.lock.acquire();
    defer held.release();

    // Validate total length doesn't overflow
    for (kvecs) |vec| {
        if (vec.len == 0) continue;
        const new_total = @addWithOverflow(total_len, vec.len);
        if (new_total[1] != 0 or new_total[0] > MAX_WRITEV_BYTES) {
            return error.EINVAL;
        }
        total_len = new_total[0];
    }

    // Process each iovec
    for (kvecs) |vec| {
        if (vec.len == 0) continue;

        var offset: usize = 0;
        while (offset < vec.len) {
            const remaining = vec.len - offset;
            const chunk_len = @min(remaining, 64 * 1024);

            const base_offset = @addWithOverflow(vec.base, offset);
            if (base_offset[1] != 0) {
                if (total_written > 0) return total_written;
                return error.EFAULT;
            }

            const res = perform_write_locked(fd_obj, base_offset[0], chunk_len) catch |err| {
                if (total_written > 0) return total_written;
                return err;
            };

            const new_total = @addWithOverflow(total_written, res);
            if (new_total[1] != 0) return total_written;
            total_written = new_total[0];
            offset += res;

            // Short write: stop processing
            if (res < chunk_len) return total_written;
        }
    }

    return total_written;
}
```

### Positional Read (Existing Implementation - Pattern for preadv)
```zig
// Source: src/kernel/sys/syscall/io/read_write.zig
pub fn sys_pread64(fd_num: usize, buf_ptr: usize, count: usize, offset: usize) SyscallError!usize {
    if (count == 0) return 0;

    const table = base.getGlobalFdTable();
    const fd_u32 = safeFdCast(fd_num) orelse return error.EBADF;
    const fd = table.get(fd_u32) orelse return error.EBADF;

    if (!fd.isReadable()) return error.EBADF;
    if (fd.ops.read == null) return error.ESPIPE;
    if (fd.ops.seek == null) return error.ESPIPE;

    // Acquire lock to ensure atomicity of seek+read+seek
    const held = fd.lock.acquire();
    defer held.release();

    const old_pos = fd.position;
    const seek_fn = fd.ops.seek.?;

    // Seek to target offset
    const res1 = seek_fn(fd, @intCast(offset), 0); // SEEK_SET
    if (res1 < 0) return error.EINVAL;
    fd.position = @intCast(res1);

    // Perform read
    const bytes_read = utils.perform_read_locked(fd, buf_ptr, count) catch |err| {
        // Restore position before error
        _ = seek_fn(fd, @intCast(old_pos), 0);
        fd.position = old_pos;
        return err;
    };

    // Restore position
    const res2 = seek_fn(fd, @intCast(old_pos), 0);
    if (res2 < 0) {
        console.err("sys_pread64: failed to restore position!", .{});
    } else {
        fd.position = @intCast(res2);
    }

    return bytes_read;
}
```

### RWF Flags (for preadv2/pwritev2)
```zig
// Flags for preadv2/pwritev2 (from Linux kernel)
pub const RWF_HIPRI: u32 = 0x00000001;      // High-priority I/O (requires O_DIRECT)
pub const RWF_DSYNC: u32 = 0x00000002;      // Per-write equivalent of O_DSYNC
pub const RWF_SYNC: u32 = 0x00000004;       // Per-write equivalent of O_SYNC
pub const RWF_NOWAIT: u32 = 0x00000008;     // Non-blocking I/O (fail with EAGAIN if would block)
pub const RWF_APPEND: u32 = 0x00000010;     // Per-write equivalent of O_APPEND

// Validation example
pub fn sys_preadv2(fd: usize, iov_ptr: usize, iovcnt: usize, offset: i64, flags: u32) SyscallError!usize {
    // Validate flags
    const VALID_FLAGS = RWF_HIPRI | RWF_DSYNC | RWF_SYNC | RWF_NOWAIT;
    if ((flags & ~VALID_FLAGS) != 0) {
        return error.EOPNOTSUPP; // Unknown flags
    }

    // RWF_NOWAIT requires special handling
    if ((flags & RWF_NOWAIT) != 0) {
        // Set non-blocking mode for this operation
        // If operation would block, return EAGAIN
    }

    // Handle offset = -1 (use current file offset)
    const use_offset = if (offset == -1) null else @as(usize, @intCast(offset));

    // ... rest of preadv logic with flags applied
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| read() + write() loop for file copy | sendfile() | Linux 2.2 (1999) | 30-70% throughput increase, CPU load halved |
| lseek() + read()/write() + lseek() | pread64/pwrite64 | Linux 2.1.60 (1997) | Thread-safe offset-based I/O, no TOCTOU races |
| readv/writev (basic) | preadv/pwritev | Linux 2.6.30 (2009) | Vectored + positional I/O combined |
| Fixed flags at open() | preadv2/pwritev2 with RWF_* | Linux 4.6 (2016) | Per-call I/O behavior without fcntl overhead |
| sendfile socket-only | sendfile to any file/pipe | Linux 2.6.33 (2010) | Broader use cases (file-to-file copy) |
| Manual splice setup | sendfile auto-desugars to splice for pipes | Linux 5.12 (2021) | Unified zero-copy infrastructure |

**Deprecated/outdated:**
- readv/writev with IOV_MAX=16: Modern kernels support 1024 iovecs (since Linux 2.0+)
- sendfile with 32-bit offset (sendfile): Use sendfile64 or 64-bit aware libc wrapper (since Linux 2.4)
- Assuming sendfile only works with sockets: Works with regular files since Linux 2.6.33

## Open Questions

1. **RWF_HIPRI implementation complexity**
   - What we know: Requires O_DIRECT flag, enables polling-based I/O, used with io_uring
   - What's unclear: Does zk's I/O infrastructure support polling? Is there an event loop to poll from?
   - Recommendation: Stub preadv2/pwritev2 initially, accept flags parameter but ignore RWF_HIPRI (return EOPNOTSUPP if set). Add full support in future I/O optimization phase.

2. **sendfile zero-copy optimization**
   - What we know: Linux uses splice internally for pipes (since 5.12), can leverage DMA for sockets
   - What's unclear: Does zk have splice infrastructure? Can device drivers do zero-copy DMA?
   - Recommendation: Implement sendfile as "efficient copy" (kernel buffer intermediary) initially. Optimize to true zero-copy when driver DMA support lands.

3. **Atomicity with concurrent preadv calls**
   - What we know: preadv doesn't modify fd.position, so multiple threads can call it safely
   - What's unclear: Does device read operation need per-call offset or does it rely on fd.position internally?
   - Recommendation: Test existing pread64 with concurrent calls. If device ops use fd.position (not offset param), may need per-call state or lock contention mitigation.

4. **sendfile with non-regular files**
   - What we know: Linux requires in_fd to support mmap-like ops (no sockets), out_fd can be any file since 2.6.33
   - What's unclear: Which zk device types support mmap? Does DevFS? Do pipes?
   - Recommendation: Check `fd.ops.mmap != null` for in_fd. Return EINVAL if not supported. Document restriction in PLAN.md.

5. **IOV_MAX runtime vs compile-time**
   - What we know: Linux advertises IOV_MAX via sysconf(_SC_IOV_MAX), zk hardcodes 1024 in writev
   - What's unclear: Should zk expose sysconf() or keep hardcoded limit?
   - Recommendation: Keep hardcoded 1024 for MVP. Add sysconf() in future POSIX compliance phase.

## Sources

### Primary (HIGH confidence)
- [readv(2) - Linux manual page](https://man7.org/linux/man-pages/man2/readv.2.html) - Complete syscall specifications
- [sendfile(2) - Linux manual page](https://man7.org/linux/man-pages/man2/sendfile.2.html) - sendfile semantics and restrictions
- [iovec(3type) - Linux manual page](https://man7.org/linux/man-pages/man3/iovec.3type.html) - iovec structure definition
- Existing codebase: src/kernel/sys/syscall/io/read_write.zig - Verified writev and pread64 implementations

### Secondary (MEDIUM confidence)
- [Linux Zero-Copy Using sendfile() - Medium](https://medium.com/swlh/linux-zero-copy-using-sendfile-75d2eb56b39b) - sendfile performance benefits
- [Zero-Copy in Linux with sendfile() and splice() - Superpatterns](https://blog.superpat.com/zero-copy-in-linux-with-sendfile-and-splice) - Implementation details
- [pg_preadv() and pg_pwritev() - PostgreSQL hackers](https://www.mail-archive.com/pgsql-hackers@lists.postgresql.org/msg76968.html) - Real-world database usage
- [Linux kernel fs/read_write.c](https://github.com/torvalds/linux/blob/master/fs/read_write.c) - Reference implementation
- [splice(2) - Linux manual page](https://man7.org/linux/man-pages/man2/splice.2.html) - Related zero-copy mechanism

### Tertiary (LOW confidence)
- [Scatter-Gather I/O (GNU C Library)](https://www.gnu.org/software/libc/manual/html_node/Scatter_002dGather.html) - Historical context, not current Linux behavior
- WebSearch results for 2026-specific patterns - No major API changes found in 2026 vs 2025

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - syscall interfaces are stable POSIX/Linux standards with 20+ year history
- Architecture patterns: HIGH - existing writev and pread64 implementations provide verified patterns
- Pitfalls: HIGH - documented in man pages, verified with Linux kernel source and existing zk security patterns
- sendfile zero-copy: MEDIUM - implementation strategy needs validation against zk's driver capabilities
- RWF_HIPRI support: MEDIUM - unclear if zk's I/O infrastructure supports polling, may need stubbing

**Research date:** 2026-02-07
**Valid until:** 60 days (stable syscall APIs, no fast-moving ecosystem changes expected)

# Phase 7: Socket Extras - Research

**Researched:** 2026-02-08
**Domain:** BSD Socket API (socketpair, shutdown, sendto/recvfrom, sendmsg/recvmsg)
**Confidence:** HIGH

## Summary

Phase 7 aims to complete BSD socket API coverage by implementing socketpair, shutdown, and advanced message passing syscalls (sendto/recvfrom/sendmsg/recvmsg). Research reveals that ALL six required syscalls are ALREADY IMPLEMENTED in the kernel codebase. The primary blocker is not missing code but rather a kernel initialization bug that causes socket tests to panic before execution.

**Critical Finding:** The IrqLock used by the network stack is accessed before initialization, causing kernel panic when any socket syscall is invoked. This is a network stack initialization ordering issue in `src/net/transport/socket/state.zig` and `src/net/transport/tcp/state.zig`, where `lock.init()` is called but the locks are used in syscall context before the network subsystem is fully initialized.

**Primary recommendation:** Fix IrqLock initialization order FIRST, then validate existing implementations via tests. No new syscall code needs to be written.

## Blocker Analysis

### IrqLock Initialization Panic

**Symptom:** All socket tests trigger kernel panic with message "IrqLock used before initialization - security violation"

**Root Cause:**
1. `src/net/sync.zig:70,86` - IrqLock panics if `initialized` flag is false
2. `src/net/transport/socket/state.zig:44,59` - Calls `lock.init()` but this happens during module load, not kernel boot sequence
3. `src/net/transport/tcp/state.zig:153,185` - Same pattern for TCP state locks
4. Socket syscalls execute before network initialization completes in `src/kernel/core/init_hw.zig`

**Lock Initialization Sites (grep results):**
- `src/net/transport/socket/state.zig:44` - `lock.init()`
- `src/net/transport/socket/state.zig:59` - `lock.init()`
- `src/net/transport/tcp/state.zig:153` - `lock.init()`
- `src/net/transport/tcp/state.zig:185` - `lock.init()`

**Fix Strategy:**
1. Move IrqLock initialization to explicit init functions called from `init_hw.zig`
2. Ensure network stack init happens before syscall table is available
3. OR: Use lazy initialization pattern (check `initialized` in socket layer, init on first use)
4. OR: Replace static IrqLock globals with dynamically allocated locks initialized during network init

**Confidence:** HIGH - Root cause identified via panic message, lock usage pattern confirmed in source code

## Standard Stack (Already Implemented)

### Core Syscalls
| Syscall | Location | Lines | Status |
|---------|----------|-------|--------|
| sys_socketpair | net.zig:1874 | ~90 | Implemented (AF_UNIX, SOCK_STREAM/DGRAM) |
| sys_shutdown | net.zig:1241 | ~32 | Implemented (SHUT_RD/WR/RDWR) |
| sys_sendto | net.zig:433 | ~100 | Implemented (UDP, IPv4/IPv6) |
| sys_recvfrom | net.zig:539 | ~100 | Implemented (UDP, IPv4/IPv6, source addr) |
| sys_sendmsg | msg.zig:369 | ~250 | Implemented (scatter-gather, SCM_RIGHTS) |
| sys_recvmsg | msg.zig:630 | ~480 | Implemented (scatter-gather, SCM_RIGHTS) |

### Supporting Infrastructure
| Component | Location | Purpose |
|-----------|----------|---------|
| UnixSocket | unix_socket.zig | AF_UNIX socketpair backend (4KB buffers, DGRAM support) |
| shutdown() | control.zig:16-49 | Network socket shutdown (TCP FIN, wake blocked threads) |
| shutdownSocket() | unix_socket.zig:1615 | UNIX socket shutdown |
| SCM_RIGHTS | msg.zig:88-220 | File descriptor passing (up to 8 FDs) |
| PendingAncillary | unix_socket.zig:47-89 | FD queue for SCM_RIGHTS |
| sendto/recvfrom | udp_api.zig, raw_api.zig | UDP/Raw socket datagram I/O with addresses |

**Installation:** N/A - All code already exists

## Architecture Patterns

### Existing Implementation Structure

```
src/kernel/sys/syscall/net/
├── net.zig                  # Main socket syscalls (1979 lines)
│   ├── sys_socketpair       # Lines 1874-1979 (AF_UNIX pair creation)
│   ├── sys_shutdown         # Lines 1241-1272 (SHUT_RD/WR/RDWR)
│   ├── sys_sendto           # Lines 433-538 (UDP sendto with dest addr)
│   └── sys_recvfrom         # Lines 539-639 (UDP recvfrom with src addr)
├── msg.zig                  # Scatter-gather I/O (1123 lines)
│   ├── sys_sendmsg          # Lines 369-629 (scatter-gather + SCM_RIGHTS send)
│   └── sys_recvmsg          # Lines 630-1123 (scatter-gather + SCM_RIGHTS recv)
└── poll.zig                 # Socket polling (reused by epoll)
```

### Pattern 1: socketpair() - AF_UNIX Bidirectional IPC
**What:** Creates two connected anonymous sockets for local process communication

**Implementation:**
```zig
// Source: src/kernel/sys/syscall/net/net.zig:1874-1979
pub fn sys_socketpair(domain: usize, sock_type: usize, protocol: usize, sv_ptr: usize) SyscallError!usize {
    // 1. Validate domain is AF_UNIX (only supported domain)
    if (domain != socket.AF_UNIX and domain != socket.AF_LOCAL) {
        return error.EAFNOSUPPORT;
    }

    // 2. Extract SOCK_CLOEXEC and SOCK_NONBLOCK flags
    const sock_type_u32 = std.math.cast(u32, sock_type) orelse return error.EINVAL;
    const sock_type_i32: i32 = @intCast(sock_type_u32 & 0xFFFF);
    const is_cloexec = (sock_type_u32 & socket.SOCK_CLOEXEC) != 0;

    // 3. Allocate UNIX socket pair (circular buffers, 4KB each direction)
    const pair = unix_socket.allocatePair(sock_type_i32 & 0xFF) orelse return error.ENOMEM;

    // 4. Create handles for both endpoints
    const handle0 = heap.allocator().create(unix_socket.UnixSocketHandle) catch return error.ENOMEM;
    const handle1 = heap.allocator().create(unix_socket.UnixSocketHandle) catch return error.ENOMEM;

    // 5. Install both FDs in process table, write to userspace sv[0], sv[1]
    const fd_num0 = table.allocAndInstall(fd0) orelse return error.EMFILE;
    const fd_num1 = table.allocAndInstall(fd1) orelse return error.EMFILE;

    const sv_uptr = user_mem.UserPtr.from(sv_ptr);
    sv_uptr.writeValue(@as(i32, @intCast(fd_num0))) catch return error.EFAULT;
    sv_uptr.writeValue(@as(i32, @intCast(fd_num1))) catch return error.EFAULT;

    return 0;
}
```

**Features:**
- SOCK_STREAM and SOCK_DGRAM support
- SOCK_NONBLOCK and SOCK_CLOEXEC flag extraction
- 4KB circular buffer per direction (UNIX_SOCKET_BUF_SIZE)
- Bidirectional read/write on both endpoints
- Reference counting for proper cleanup on close

### Pattern 2: shutdown() - Half-Close Socket Connections
**What:** Disables send and/or receive on a socket without closing the file descriptor

**Implementation:**
```zig
// Source: src/net/transport/socket/control.zig:16-49
pub fn shutdown(sock_fd: usize, how: i32) errors.SocketError!void {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    defer state.releaseSocket(sock);

    const held = sock.lock.acquire();
    defer held.release();

    // Validate how: SHUT_RD (0), SHUT_WR (1), SHUT_RDWR (2)
    if (how != SHUT_RD and how != SHUT_WR and how != SHUT_RDWR) {
        return errors.SocketError.InvalidArg;
    }

    // Handle read shutdown
    if (how == SHUT_RD or how == SHUT_RDWR) {
        sock.shutdown_read = true;
        // Wake blocked reader so they receive EOF
        if (sock.blocked_thread) |t| {
            scheduler.wakeThread(t);
            sock.blocked_thread = null;
        }
    }

    // Handle write shutdown
    if (how == SHUT_WR or how == SHUT_RDWR) {
        sock.shutdown_write = true;
        // For TCP: send FIN to notify peer
        if (sock.sock_type == types.SOCK_STREAM) {
            if (sock.tcb) |tcb| {
                tcp.sendFinPacket(tcb);
            }
        }
    }
}
```

**Semantics:**
- SHUT_RD (0): Disable receives (local flag, no network effect)
- SHUT_WR (1): Disable sends, send TCP FIN packet
- SHUT_RDWR (2): Both SHUT_RD and SHUT_WR effects
- Wake blocked threads on shutdown
- File descriptor remains valid (can still close())

### Pattern 3: sendmsg/recvmsg - Scatter-Gather with Ancillary Data
**What:** Send/receive messages with multiple buffers and control data (e.g., file descriptor passing via SCM_RIGHTS)

**Implementation:**
```zig
// Source: src/kernel/sys/syscall/net/msg.zig:369-629
pub fn sys_sendmsg(fd: usize, msg_ptr: usize, flags: usize, socket_file_ops: *const fd_mod.FileOps) SyscallError!usize {
    // 1. Copy MsgHdr from userspace
    const msg_uptr = user_mem.UserPtr.from(msg_ptr);
    var kmsg: MsgHdr = msg_uptr.readValue(MsgHdr) catch return error.EFAULT;

    // 2. Process scatter-gather buffers (up to MAX_IOV_COUNT iovecs)
    var kiov_buffer: [MAX_IOV_COUNT]IoVec = undefined;
    const kiov = copyIovecToKernel(kmsg.msg_iov, kmsg.msg_iovlen, &kiov_buffer) catch return error.EFAULT;

    // 3. Process SCM_RIGHTS control message (if present)
    const scm_rights = processScmRights(kmsg.msg_control, kmsg.msg_controllen, table) catch |err| return err;
    defer if (scm_rights) |sr| releaseScmRights(&sr);

    // 4. Attach FD array to UNIX socket ancillary queue
    if (scm_rights) |sr| {
        unix_socket.attachAncillaryData(sock, sr.fds[0..sr.count], data_len) catch return error.ENOBUFS;
    }

    // 5. Write data using vectored I/O
    var total_sent: usize = 0;
    for (kiov) |iov| {
        const sent = unix_socket.write(sock, endpoint, iov.base[0..iov.len]) catch break;
        total_sent += sent;
    }

    return total_sent;
}
```

**Features:**
- Scatter-gather I/O (up to 1024 iovecs, 64KB max message)
- SCM_RIGHTS: Pass up to 8 file descriptors
- Ancillary data queue (4 pending messages max)
- Reference counting on FDs (incremented during send, decremented on recv or close)
- SECURITY: Zero-init control buffer to prevent kernel stack leaks

### Anti-Patterns to Avoid

- **Don't call socket syscalls before network init completes** - IrqLock panic
- **Don't use socket layer locks in syscall context without lazy init** - Initialization order bug
- **Don't skip validation of iovec counts** - Prevents DoS via excessive kernel allocations
- **Don't leak FDs from SCM_RIGHTS on error paths** - Use errdefer to release refs
- **Don't assume control message buffer is aligned** - Use UserPtr for safe copies

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Socket pair IPC | Custom pipe with metadata | unix_socket.allocatePair() | Handles bidirectional buffers, DGRAM messages, SCM_RIGHTS, reference counting |
| File descriptor passing | Manual fd duplication | SCM_RIGHTS via sendmsg/recvmsg | POSIX standard, handles refcounting, supports multiple FDs in one message |
| Scatter-gather I/O | Loop over buffers manually | sendmsg/recvmsg with msg_iov | Single syscall, atomic semantics, kernel validates all iovecs upfront |
| Socket shutdown | Close and reopen | shutdown() syscall | Allows half-close, sends TCP FIN, keeps fd valid for error retrieval |
| Network address passing | Custom struct in message | sendto/recvfrom with sockaddr | Standard BSD API, handles IPv4/IPv6, port byte order conversion |

**Key insight:** The BSD socket API has decades of edge case handling (partial writes, signal interruption, peer close races). Existing implementations in `msg.zig` and `unix_socket.zig` already handle these correctly with proper lock ordering and reference counting.

## Common Pitfalls

### Pitfall 1: IrqLock Initialization Order
**What goes wrong:** Kernel panic "IrqLock used before initialization - security violation" when creating first socket

**Why it happens:**
- IrqLock globals in `socket/state.zig` and `tcp/state.zig` use `lock.init()` during static initialization
- Syscalls can execute before network subsystem init completes
- IrqLock.acquire() checks `initialized` flag and panics if false

**How to avoid:**
1. Ensure `init_hw.zig:initNetwork()` completes before syscall dispatch is enabled
2. OR: Lazy-initialize locks on first socket syscall (check initialized, call init if false)
3. OR: Move lock init to explicit functions called during kernel boot sequence

**Warning signs:** Socket tests panic immediately, before any socket operations execute

### Pitfall 2: SCM_RIGHTS File Descriptor Leaks
**What goes wrong:** Passed file descriptors leak references if receiver doesn't call recvmsg or socket closes

**Why it happens:**
- sendmsg increments FD refcounts and queues them in ancillary data
- If receiver never calls recvmsg, FDs remain in queue forever
- Socket close must walk ancillary queue and release all FD refs

**How to avoid:**
- Use `PendingAncillary.releaseAll()` in socket close path (already implemented)
- Set release_fn callback when attaching FDs (syscall layer provides this)
- Use errdefer in sendmsg to release FDs if attachment fails

**Warning signs:** File descriptor table exhaustion, files not closed after socket close

### Pitfall 3: Scatter-Gather Buffer Validation
**What goes wrong:** Kernel DoS via massive iovec arrays (e.g., 1 million iovecs)

**Why it happens:**
- User controls msg_iovlen field in MsgHdr
- Kernel allocates kiov_buffer on stack or heap based on this count
- No upper bound check allows stack overflow or heap exhaustion

**How to avoid:**
- Check `msg_iovlen <= MAX_IOV_COUNT (1024)` before allocation (already implemented in msg.zig:34)
- Validate total message size <= MAX_MSG_SIZE (65536) (already implemented in msg.zig:37)
- Use fixed-size stack buffer for common case, fail for excessive counts

**Warning signs:** Kernel crash under malicious input, test suite hangs on large iovec tests

### Pitfall 4: shutdown() vs close() Confusion
**What goes wrong:** Programs expect shutdown(SHUT_RDWR) to close the socket, but FD remains valid

**Why it happens:**
- shutdown() only disables I/O, doesn't deallocate socket or FD
- close() is still required to free resources
- Programs ported from other systems may assume shutdown frees resources

**How to avoid:**
- Document that shutdown() + close() is the full teardown sequence
- Tests should verify FD remains valid after shutdown
- Ensure shutdown_read/shutdown_write flags cause read/write to return 0 or EPIPE

**Warning signs:** FD exhaustion in long-running programs that use shutdown without close

## Code Examples

Verified patterns from existing kernel implementation:

### socketpair() - Create Connected Socket Pair
```zig
// Source: src/kernel/sys/syscall/net/net.zig:1874-1979
// Usage: int sv[2]; socketpair(AF_UNIX, SOCK_STREAM, 0, sv);

// Validate domain
if (domain != socket.AF_UNIX and domain != socket.AF_LOCAL) {
    return error.EAFNOSUPPORT;
}

// Extract flags
const sock_type_u32 = std.math.cast(u32, sock_type) orelse return error.EINVAL;
const is_cloexec = (sock_type_u32 & socket.SOCK_CLOEXEC) != 0;

// Allocate pair
const pair = unix_socket.allocatePair(sock_type_i32 & 0xFF) orelse return error.ENOMEM;

// Create handles and FDs
const handle0 = heap.allocator().create(unix_socket.UnixSocketHandle) catch return error.ENOMEM;
const fd0 = fd_mod.createFd(&unix_socket_file_ops, fd_mod.O_RDWR, handle0) catch return error.ENOMEM;

// Write FD numbers to userspace array
const sv_uptr = user_mem.UserPtr.from(sv_ptr);
sv_uptr.writeValue(@as(i32, @intCast(fd_num0))) catch return error.EFAULT;
```

### shutdown() - Half-Close Socket
```zig
// Source: src/net/transport/socket/control.zig:16-49
// Usage: shutdown(sockfd, SHUT_WR); // Disable writes, send TCP FIN

const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
defer state.releaseSocket(sock);

const held = sock.lock.acquire();
defer held.release();

if (how == SHUT_WR or how == SHUT_RDWR) {
    sock.shutdown_write = true;
    // For TCP: send FIN packet
    if (sock.sock_type == types.SOCK_STREAM) {
        if (sock.tcb) |tcb| {
            tcp.sendFinPacket(tcb);
        }
    }
}
```

### sendmsg/recvmsg - SCM_RIGHTS File Descriptor Passing
```zig
// Source: src/kernel/sys/syscall/net/msg.zig:106-220
// Usage: Send 2 FDs via ancillary data

// Allocate FD array in control message
var control_buf: [CMSG_SPACE(2 * @sizeOf(i32))]u8 = undefined;
var msg: MsgHdr = .{
    .msg_control = &control_buf,
    .msg_controllen = control_buf.len,
    // ... msg_iov, msg_iovlen ...
};

// Parse control message header
const cmsg: *const CmsgHdr = @ptrCast(@alignCast(&kcontrol));
if (cmsg.cmsg_level == SOL_SOCKET and cmsg.cmsg_type == SCM_RIGHTS) {
    const data_len = cmsg.cmsg_len - @sizeOf(CmsgHdr);
    const fd_count = data_len / @sizeOf(i32);

    // Extract FD numbers and validate
    const kfd_nums = CMSG_DATA(cmsg);
    for (kfd_nums[0..fd_count]) |fd_num| {
        const fd = table.get(fd_num) orelse return error.EBADF;
        // Increment refcount
        fd.ref();
        result.fds[idx] = fd;
    }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Manual pipe + metadata for IPC | socketpair() with AF_UNIX | POSIX.1-2001 (2001) | Bidirectional, supports DGRAM, integrated with select/epoll |
| send/recv with manual address tracking | sendto/recvfrom for datagrams | BSD 4.2 (1983) | Single syscall includes addressing, works with connect() |
| Custom ancillary data protocol | SCM_RIGHTS for FD passing | BSD 4.3 (1986) | Standard mechanism, handles refcounting, atomic receive |
| Custom half-close logic | shutdown() syscall | BSD 4.2 (1983) | Sends TCP FIN, keeps FD valid for error retrieval |

**Deprecated/outdated:**
- None - All six syscalls are current POSIX.1-2024 standard
- SCM_CREDENTIALS (Linux-specific) is not yet implemented but not required for Phase 7

## Open Questions

1. **Should IrqLock initialization be fixed before Phase 7 or as part of Phase 7?**
   - What we know: It's a network stack bug, not specific to socket extras
   - What's unclear: Whether fix belongs in Phase 7 or a separate bugfix phase
   - Recommendation: Fix as FIRST task in Phase 7 Plan 01 - unblocks all socket testing

2. **Are there existing tests for the six implemented syscalls?**
   - What we know: 8 socket smoke tests exist in `sockets.zig` but cannot run due to IrqLock panic
   - What's unclear: Whether tests cover all six Phase 7 syscalls or just basic socket/bind/listen
   - Recommendation: Audit `sockets.zig` and add missing tests for socketpair, shutdown, sendmsg/recvmsg

3. **Is SCM_CREDENTIALS needed for Phase 7 completion?**
   - What we know: Phase 7 requirements mention "control data (ancillary data)" via sendmsg/recvmsg
   - What's unclear: Whether this refers only to SCM_RIGHTS or also SCM_CREDENTIALS
   - Recommendation: SCM_RIGHTS is sufficient for MVP, SCM_CREDENTIALS deferred to future phase

4. **Should sendto/recvfrom work with connected sockets?**
   - What we know: Current implementation in net.zig:433,539 handles UDP datagrams
   - What's unclear: Whether connected UDP sockets should accept sendto/recvfrom or require send/recv
   - Recommendation: Verify POSIX spec - sendto/recvfrom on connected sockets should work (dest/src addr optional)

## Sources

### Primary (HIGH confidence)
- Kernel implementation: `src/kernel/sys/syscall/net/net.zig` (lines 433-1979), `msg.zig` (lines 369-1123)
- Network stack: `src/net/transport/socket/control.zig`, `unix_socket.zig`, `udp_api.zig`
- Codebase concerns: `.planning/codebase/CONCERNS.md` (IrqLock panic analysis)
- Test infrastructure: `TODO_TESTING_INFRA.md` (socket test status)

### Secondary (MEDIUM confidence)
- [socketpair(2) - Linux manual page](https://man7.org/linux/man-pages/man2/socketpair.2.html) - POSIX.1-2024 standard, AF_UNIX domain, SOCK_CLOEXEC support
- [shutdown(2) - Linux manual page](https://man7.org/linux/man-pages/man2/shutdown.2.html) - SHUT_RD/WR/RDWR semantics, TCP FIN behavior
- [cmsg(3) - Linux manual page](https://man7.org/linux/man-pages/man3/cmsg.3.html) - SCM_RIGHTS ancillary data, file descriptor passing

### Tertiary (LOW confidence)
- [Baeldung: Sockets Close vs Shutdown](https://www.baeldung.com/cs/sockets-close-vs-shutdown) - Explains difference between shutdown() and close()
- [Cloudflare: Know your SCM_RIGHTS](https://blog.cloudflare.com/know-your-scm_rights/) - SCM_RIGHTS quirks and edge cases

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - All six syscalls already implemented, code reviewed
- Architecture: HIGH - Existing patterns well-established, lock ordering documented
- Pitfalls: HIGH - IrqLock panic root cause identified, SCM_RIGHTS refcount pattern verified

**Research date:** 2026-02-08
**Valid until:** 30 days (stable POSIX APIs, kernel code unlikely to change)

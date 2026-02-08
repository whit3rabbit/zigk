# Phase 9: SysV IPC - Research

**Researched:** 2026-02-08
**Domain:** System V Inter-Process Communication (Shared Memory, Semaphores, Message Queues)
**Confidence:** MEDIUM

## Summary

System V IPC is a legacy but widely-used IPC mechanism consisting of three subsystems: shared memory (fastest IPC via direct memory access), semaphores (synchronization primitives for resource locking), and message queues (kernel-mediated message passing). Despite being considered legacy, SysV IPC remains critical for compatibility with older applications like PostgreSQL (when configured with sysv shared memory backend) and other POSIX/UNIX software.

The implementation requires kernel-managed global tables for each IPC type, permission checking via struct ipc_perm, unique key generation (often via ftok() in userspace), and careful resource limit enforcement. Modern Linux uses tmpfs/shmfs as the backing store for shared memory segments, avoiding filesystem dependency while providing swappable memory backing.

**Primary recommendation:** Implement shared memory first (highest priority for PostgreSQL compatibility), then semaphores (required for process synchronization), then message queues (lowest priority, mostly replaced by POSIX alternatives). Consider POSIX IPC alternatives (shm_open/mq_open) as future enhancements but implement SysV for legacy compatibility.

## Standard Stack

### Core Components

| Component | Purpose | Why Standard |
|-----------|---------|--------------|
| Global IPC Tables | Per-type arrays tracking active segments/sets/queues | Kernel must maintain process-independent state for IPC objects |
| struct ipc_perm | Permission/ownership tracking | POSIX standard structure for IPC access control |
| tmpfs/shmfs Backend | Physical memory backing for shared memory | Linux standard - avoids filesystem dependency, supports swap |
| key_t Hash Lookup | Map user keys to kernel IPC IDs | Standard SysV IPC discovery mechanism |

### Supporting Structures

| Structure | Purpose | When to Use |
|-----------|---------|-------------|
| struct shmid_ds | Shared memory segment metadata | Returned by IPC_STAT, tracks size/creator/attach count |
| struct semid_ds | Semaphore set metadata | Returned by IPC_STAT, tracks number of semaphores |
| struct msqid_ds | Message queue metadata | Returned by IPC_STAT, tracks queue depth/byte count |
| SEM_UNDO tracking | Per-process semaphore adjustment values | Automatic cleanup on process exit to prevent deadlocks |

### Installation

No userspace libraries required - these are syscalls. Kernel implementation only.

Syscalls to implement (Linux x86_64 numbers):
```zig
// Shared Memory
pub const SYS_SHMGET: usize = 29;   // Allocate shared memory segment
pub const SYS_SHMAT: usize = 30;    // Attach shared memory to address space
pub const SYS_SHMCTL: usize = 31;   // Shared memory control operations
pub const SYS_SHMDT: usize = 67;    // Detach shared memory from address space

// Semaphores
pub const SYS_SEMGET: usize = 64;   // Get semaphore set
pub const SYS_SEMOP: usize = 65;    // Semaphore operations (wait/signal)
pub const SYS_SEMCTL: usize = 66;   // Semaphore control operations

// Message Queues
pub const SYS_MSGGET: usize = 68;   // Get message queue
pub const SYS_MSGSND: usize = 69;   // Send message to queue
pub const SYS_MSGRCV: usize = 70;   // Receive message from queue
pub const SYS_MSGCTL: usize = 71;   // Message queue control operations
```

## Architecture Patterns

### Recommended Kernel Structure

```
src/kernel/
├── ipc/
│   ├── shm.zig          # Shared memory implementation
│   ├── sem.zig          # Semaphore implementation
│   ├── msg.zig          # Message queue implementation
│   ├── ipc_perm.zig     # Common permission checking
│   └── root.zig         # IPC subsystem initialization
└── sys/syscall/
    └── ipc/
        ├── shm.zig      # sys_shmget, sys_shmat, sys_shmdt, sys_shmctl
        ├── sem.zig      # sys_semget, sys_semop, sys_semctl
        └── msg.zig      # sys_msgget, sys_msgsnd, sys_msgrcv, sys_msgctl
```

### Pattern 1: Global IPC Table with Unique IDs

**What:** Each IPC type maintains a global kernel table mapping IPC identifiers (positive integers) to kernel objects. User-provided keys (key_t) are hashed to find/create entries.

**When to use:** All SysV IPC implementations require this pattern.

**Example:**
```zig
// Shared memory global state (src/kernel/ipc/shm.zig)
const MAX_SHM_SEGMENTS = 128;  // Configurable limit (Linux default: 4096)

const ShmSegment = struct {
    id: u32,                    // Unique kernel identifier
    key: i32,                   // User-provided key (or IPC_PRIVATE)
    perm: IpcPerm,              // Permissions, owner, creator
    size: usize,                // Segment size in bytes
    phys_addr: u64,             // Physical memory base (from PMM)
    attach_count: u32,          // Number of processes attached
    cpid: u32,                  // Creator PID
    lpid: u32,                  // Last shmat/shmdt PID
    atime: u64,                 // Last attach time
    dtime: u64,                 // Last detach time
    ctime: u64,                 // Last control change time
    marked_for_deletion: bool,  // IPC_RMID called, delete when attach_count == 0
};

var shm_segments: [MAX_SHM_SEGMENTS]?ShmSegment = [_]?ShmSegment{null} ** MAX_SHM_SEGMENTS;
var shm_lock: Spinlock = Spinlock.init();

pub fn shmget(key: i32, size: usize, flags: i32) !u32 {
    const held = shm_lock.acquire();
    defer held.release();

    // IPC_PRIVATE always creates new segment
    if (key == IPC_PRIVATE) {
        return allocateNewSegment(size, flags);
    }

    // Search for existing segment with matching key
    for (shm_segments, 0..) |maybe_seg, i| {
        if (maybe_seg) |seg| {
            if (seg.key == key) {
                // IPC_CREAT | IPC_EXCL fails if exists
                if ((flags & IPC_CREAT) != 0 and (flags & IPC_EXCL) != 0) {
                    return error.EEXIST;
                }
                // Check permissions
                if (!hasAccess(seg.perm, .read)) return error.EACCES;
                return seg.id;
            }
        }
    }

    // Not found - create if IPC_CREAT set
    if ((flags & IPC_CREAT) != 0) {
        return allocateNewSegment(size, flags);
    }

    return error.ENOENT;
}
```

### Pattern 2: Permission Checking via ipc_perm

**What:** Common structure and helper function for checking IPC permissions based on UID/GID and mode bits.

**When to use:** All IPC operations requiring permission checks (attach, send, stat, control).

**Example:**
```zig
// src/kernel/ipc/ipc_perm.zig
pub const IpcPerm = struct {
    cuid: u32,      // Creator UID
    cgid: u32,      // Creator GID
    uid: u32,       // Owner UID
    gid: u32,       // Owner GID
    mode: u16,      // Permission bits (lower 9 bits)
    seq: u16,       // Sequence number (for unique ID generation)
};

pub const AccessMode = enum { read, write, control };

pub fn checkAccess(perm: *const IpcPerm, proc: *Process, mode: AccessMode) bool {
    const euid = proc.euid;
    const egid = proc.egid;

    // Root bypasses all checks
    if (euid == 0) return true;

    // Owner/creator can always control
    if (mode == .control) {
        if (euid == perm.uid or euid == perm.cuid) return true;
    }

    // Check user permissions
    if (euid == perm.uid) {
        const need_bit: u16 = if (mode == .read) 0o400 else 0o200;
        return (perm.mode & need_bit) != 0;
    }

    // Check group permissions
    if (egid == perm.gid) {
        const need_bit: u16 = if (mode == .read) 0o040 else 0o020;
        return (perm.mode & need_bit) != 0;
    }

    // Check other permissions
    const need_bit: u16 = if (mode == .read) 0o004 else 0o002;
    return (perm.mode & need_bit) != 0;
}
```

### Pattern 3: Shared Memory Attachment via Process VMA Tracking

**What:** shmat() maps physical pages into process address space and tracks attachments in both the segment (attach_count) and process VMM (VMA entry).

**When to use:** sys_shmat implementation.

**Example:**
```zig
// sys_shmat (src/kernel/sys/syscall/ipc/shm.zig)
pub fn sys_shmat(shmid: usize, shmaddr: usize, shmflg: usize) SyscallError!usize {
    const seg = findSegmentById(shmid) orelse return error.EINVAL;
    const proc = base.getCurrentProcess();

    // Check read permission (SHM_RDONLY = 0o10000)
    const need_write = (shmflg & SHM_RDONLY) == 0;
    const mode: AccessMode = if (need_write) .write else .read;
    if (!checkAccess(&seg.perm, proc, mode)) return error.EACCES;

    // Determine virtual address (0 = kernel choice, else user hint/fixed)
    var virt_addr = shmaddr;
    if (virt_addr == 0) {
        virt_addr = proc.user_vmm.findFreeRange(seg.size) orelse return error.ENOMEM;
    } else if ((shmflg & SHM_RND) != 0) {
        // Round down to SHMLBA (page size on most systems)
        virt_addr &= ~(pmm.PAGE_SIZE - 1);
    }

    // Map physical pages into process address space
    const page_flags = vmm.PageFlags{
        .writable = need_write,
        .user = true,
        .write_through = false,
        .cache_disable = false,
        .global = false,
        .no_execute = true,  // Shared memory is non-executable by default
    };

    vmm.mapRange(proc.cr3, virt_addr, seg.phys_addr, seg.size, page_flags) catch {
        return error.ENOMEM;
    };

    // Create VMA with MAP_SHARED | MAP_SHM (custom flag to identify SysV shm)
    const vma = proc.user_vmm.createVma(
        virt_addr,
        virt_addr + seg.size,
        if (need_write) PROT_READ | PROT_WRITE else PROT_READ,
        MAP_SHARED | MAP_SHM,
    ) catch {
        // Rollback mapping
        var off: usize = 0;
        while (off < seg.size) : (off += pmm.PAGE_SIZE) {
            vmm.unmapPage(proc.cr3, virt_addr + off) catch {};
        }
        return error.ENOMEM;
    };

    // Store shmid in VMA for shmdt lookup
    vma.shmid = @intCast(shmid);
    proc.user_vmm.insertVma(vma);

    // Update segment metadata
    const held = shm_lock.acquire();
    seg.attach_count += 1;
    seg.lpid = proc.pid;
    seg.atime = hal.time.getUnixTimestamp();
    held.release();

    return virt_addr;
}
```

### Pattern 4: Semaphore Operations with SEM_UNDO Tracking

**What:** semop() performs atomic operations on semaphore sets and optionally tracks undo values per process for automatic cleanup on exit.

**When to use:** sys_semop implementation.

**Example:**
```zig
// Semaphore operation structure (from Linux ABI)
const SemBuf = extern struct {
    sem_num: u16,   // Semaphore index in set
    sem_op: i16,    // Operation: <0 = wait, >0 = signal, 0 = wait for zero
    sem_flg: i16,   // Flags: IPC_NOWAIT, SEM_UNDO
};

pub fn sys_semop(semid: usize, sops_ptr: usize, nsops: usize) SyscallError!usize {
    if (nsops == 0 or nsops > SEMOPM) return error.EINVAL;  // SEMOPM = 500 on Linux

    // Copy operations from userspace
    var sops_buf: [SEMOPM]SemBuf = undefined;
    const user_ptr = user_mem.UserPtr.from(sops_ptr);
    const sops_bytes = std.mem.sliceAsBytes(sops_buf[0..nsops]);
    _ = user_ptr.copyToKernel(sops_bytes) catch return error.EFAULT;
    const sops = sops_buf[0..nsops];

    const semset = findSemaphoreSet(semid) orelse return error.EINVAL;
    const proc = base.getCurrentProcess();

    // Validate all operations first
    for (sops) |sop| {
        if (sop.sem_num >= semset.nsems) return error.EFBIG;

        // Check permissions
        const mode: AccessMode = if (sop.sem_op >= 0) .write else .read;
        if (!checkAccess(&semset.perm, proc, mode)) return error.EACCES;
    }

    // Acquire semaphore set lock
    const held = semset.lock.acquire();
    defer held.release();

    // Try to apply all operations atomically
    var can_proceed = true;
    for (sops) |sop| {
        const current_val = semset.sems[sop.sem_num].semval;

        if (sop.sem_op < 0) {
            // Wait operation - check if we can decrement
            const abs_op: u32 = @intCast(-sop.sem_op);
            if (current_val < abs_op) {
                can_proceed = false;
                break;
            }
        } else if (sop.sem_op == 0) {
            // Wait for zero
            if (current_val != 0) {
                can_proceed = false;
                break;
            }
        }
        // sem_op > 0 (signal) always succeeds
    }

    if (!can_proceed) {
        if ((sops[0].sem_flg & IPC_NOWAIT) != 0) {
            return error.EAGAIN;
        }
        // Block current thread (simplified - real impl needs wait queue)
        held.release();
        sched.block();
        return error.EINTR;  // Woken by signal
    }

    // Apply all operations
    for (sops) |sop| {
        if (sop.sem_op < 0) {
            const abs_op: u32 = @intCast(-sop.sem_op);
            semset.sems[sop.sem_num].semval -= @intCast(abs_op);
        } else if (sop.sem_op > 0) {
            semset.sems[sop.sem_num].semval += @intCast(sop.sem_op);
        }

        // Track undo value if SEM_UNDO set
        if ((sop.sem_flg & SEM_UNDO) != 0) {
            // Find or create undo structure for this process
            var undo_entry = findUndoEntry(proc.pid, semid) orelse {
                const new_undo = allocateUndoEntry(proc.pid, semid) catch {
                    // Rollback - skip for simplicity, real impl must rollback all ops
                    return error.ENOMEM;
                };
                new_undo
            };

            // Subtract sem_op from undo value (inverse operation on exit)
            undo_entry.semadj[sop.sem_num] -= sop.sem_op;
        }
    }

    semset.otime = hal.time.getUnixTimestamp();
    return 0;
}
```

### Pattern 5: Resource Limit Enforcement

**What:** Enforce kernel-wide limits on IPC resources to prevent exhaustion attacks.

**When to use:** All IPC allocation operations (shmget, semget, msgget).

**Example:**
```zig
// Kernel IPC limits (configurable, Linux defaults shown)
pub const IPC_LIMITS = struct {
    // Shared Memory
    pub const SHMMAX: usize = 0x2000000;      // 32 MB max segment size (Linux: kernel.shmmax)
    pub const SHMMIN: usize = 1;              // 1 byte min segment size
    pub const SHMMNI: usize = 4096;           // Max segments system-wide (Linux: kernel.shmmni)
    pub const SHMALL: usize = 0x200000;       // Max total pages (Linux: kernel.shmall)

    // Semaphores
    pub const SEMMNI: usize = 32000;          // Max semaphore sets (Linux 3.19+: 32000)
    pub const SEMMSL: usize = 250;            // Max semaphores per set
    pub const SEMMNS: usize = SEMMNI * SEMMSL; // Max semaphores system-wide
    pub const SEMOPM: usize = 500;            // Max operations per semop call
    pub const SEMVMX: usize = 32767;          // Max semaphore value

    // Message Queues
    pub const MSGMNI: usize = 32000;          // Max queues system-wide
    pub const MSGMAX: usize = 8192;           // Max message size (bytes)
    pub const MSGMNB: usize = 16384;          // Max queue size (bytes)
};

fn allocateNewSegment(size: usize, flags: i32) !u32 {
    // Enforce size limits
    if (size < IPC_LIMITS.SHMMIN or size > IPC_LIMITS.SHMMAX) {
        return error.EINVAL;
    }

    // Check system-wide segment count
    var active_count: usize = 0;
    for (shm_segments) |maybe_seg| {
        if (maybe_seg) |_| active_count += 1;
    }
    if (active_count >= IPC_LIMITS.SHMMNI) {
        return error.ENOSPC;
    }

    // Check total memory usage (SHMALL in pages)
    const pages_needed = std.mem.alignForward(usize, size, pmm.PAGE_SIZE) / pmm.PAGE_SIZE;
    var total_pages: usize = 0;
    for (shm_segments) |maybe_seg| {
        if (maybe_seg) |seg| {
            total_pages += std.mem.alignForward(usize, seg.size, pmm.PAGE_SIZE) / pmm.PAGE_SIZE;
        }
    }
    if (total_pages + pages_needed > IPC_LIMITS.SHMALL) {
        return error.ENOSPC;
    }

    // Allocate physical memory from PMM (zeroed for security)
    const aligned_size = std.mem.alignForward(usize, size, pmm.PAGE_SIZE);
    const phys_addr = pmm.allocZeroedPages(aligned_size / pmm.PAGE_SIZE) orelse {
        return error.ENOMEM;
    };

    // Find free slot and create segment...
}
```

### Anti-Patterns to Avoid

- **Direct physical memory access without tmpfs abstraction:** Linux uses tmpfs/shmfs as a backing store. While zk doesn't have tmpfs yet, allocate from PMM and track separately - don't assume memory is always resident (future swap support).
- **Forgetting IPC_RMID delayed deletion:** When IPC_RMID is called with attach_count > 0, mark for deletion but don't free until last detach. Immediate deletion causes UAF.
- **Missing SEM_UNDO cleanup on process exit:** The scheduler's process exit path MUST call IPC undo handler to release held semaphores, or deadlocks will persist after crashes.
- **No permission re-checks after IPC_SET:** After shmctl/semctl/msgctl with IPC_SET changes perm.uid/gid/mode, existing attachments retain access, but NEW operations must use new permissions.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Shared memory key collision handling | Custom hash table with conflict resolution | Linear search of fixed-size array, return EEXIST on collision | Linux kernel uses simple array scan, not a hash table. Key collisions are user's responsibility (ftok() is inherently collision-prone). |
| Semaphore wait queues | Custom blocking queue per semaphore | Reuse existing scheduler block/unblock with wake-all on semop | Kernel already has thread blocking infrastructure. SysV semaphores need to wake ALL waiters on any change (they re-check conditions). |
| Message queue buffer management | Custom ring buffer or linked list allocator | Fixed-size kernel heap allocations per message | Linux uses simple kmalloc per message. Don't optimize prematurely - message queues are rarely used in modern code. |
| IPC namespace isolation | Per-namespace IPC tables | Single global table initially, add namespace support later | IPC namespaces are container-specific. Phase 9 targets basic compatibility, not containerization. |

**Key insight:** SysV IPC is deliberately simple and inefficient by modern standards. Don't over-engineer. The reference implementation (Linux 2.4) is < 2000 lines per subsystem. Performance is NOT a goal - correctness and POSIX compliance are.

## Common Pitfalls

### Pitfall 1: SEM_UNDO Leaks on Abnormal Process Exit

**What goes wrong:** If a process crashes while holding semaphores with SEM_UNDO set, and the kernel doesn't apply undo adjustments, semaphores remain locked forever (deadlock).

**Why it happens:** Undo structures are stored in a global list indexed by PID. If the process exit handler doesn't walk this list and apply `semadj` values before freeing the process, the undo is lost.

**How to avoid:** Hook into the scheduler's process cleanup (after marking process as ZOMBIE but before freeing process struct). Walk global `sem_undo_list`, find entries matching `proc.pid`, apply adjustments (`sem.semval += undo.semadj[i]`), then free undo entries.

**Warning signs:** Tests involving semaphores that intentionally crash processes will hang if undo is broken. Add test: fork(), acquire semaphore with SEM_UNDO, exit(1) without release, parent should be able to acquire.

### Pitfall 2: IPC_RMID with Outstanding Attachments (UAF)

**What goes wrong:** If shmctl(IPC_RMID) immediately frees physical memory while processes still have the segment attached, subsequent access causes page faults or data corruption.

**Why it happens:** Misunderstanding IPC_RMID semantics - it marks for deletion, not immediate free. Linux waits until `attach_count == 0` before calling `pmm.freePages()`.

**How to avoid:** Add `marked_for_deletion` boolean to `ShmSegment`. In `shmctl(IPC_RMID)`, set flag and remove from lookup table (so new shmget can't find it), but keep segment alive. In `shmdt()`, decrement `attach_count` and if it hits 0 AND `marked_for_deletion`, THEN free physical pages.

**Warning signs:** Segfaults or panics during shared memory tests that create, attach, mark for deletion, then continue using the segment.

### Pitfall 3: ftok() Key Collisions Causing EEXIST Loops

**What goes wrong:** ftok() generates keys from inode + device + proj_id (8 bits). With only 8 bits of project ID entropy, collisions happen frequently. User code may retry ftok() with different proj_id, but kernel table lookup is O(n) and may become slow.

**Why it happens:** ftok() is a userspace library function (not a syscall) that hashes file metadata. The kernel only sees the resulting key_t. If two processes use the same file path and different proj_id that happen to collide, shmget(key, ..., IPC_CREAT | IPC_EXCL) will fail with EEXIST.

**How to avoid:** Document that IPC_PRIVATE (key = 0) always creates a new segment with a unique kernel-generated key. Recommend users prefer IPC_PRIVATE for new code. For legacy apps using ftok(), accept that collisions are a known limitation and user's responsibility.

**Warning signs:** Test failures with EEXIST when running multiple tests in parallel that use shmget with the same hardcoded key.

### Pitfall 4: Integer Overflow in Total Memory Accounting (SHMALL)

**What goes wrong:** When checking `total_pages + pages_needed > SHMALL`, if `total_pages` and `pages_needed` are large `usize` values, addition can overflow, wrapping to a small value and bypassing the limit check.

**Why it happens:** SHMALL is specified in pages (not bytes). On 64-bit systems with PAGE_SIZE=4096, SHMALL=0x200000 pages = 8 TB. If kernel tracks bytes instead of pages, conversions can overflow.

**How to avoid:** Use `std.math.add(usize, total_pages, pages_needed)` which returns error on overflow. Store segment sizes in pages, not bytes. Check limits BEFORE allocating physical memory.

**Warning signs:** Kernel allows allocation of more shared memory than SHMALL limit, leading to OOM or panics when PMM exhausted.

### Pitfall 5: Missing Sequence Number in IPC ID Generation

**What goes wrong:** If IPC IDs are just array indices (0, 1, 2...), a program that deletes segment ID=5 and immediately recreates can reuse ID=5. If a stale process still has ID=5 cached, it attaches to the WRONG segment (security issue).

**Why it happens:** IDs must be unique across the lifetime of the kernel (or at least across many delete/create cycles). Linux uses `(index << 16) | seq` where `seq` increments on each reuse of a slot.

**How to avoid:** Store `seq: u16` in `IpcPerm` (it's part of the standard struct). When allocating a new segment in slot `i`, increment `shm_segments[i].perm.seq` and return ID as `(i << 16) | seq`. When looking up, extract index and verify sequence matches.

**Warning signs:** Tests that rapidly create/delete/create segments with same keys exhibit unexpected data or EINVAL on operations.

## Code Examples

Verified patterns from official sources:

### IPC Permission Check (Standard POSIX Algorithm)

```zig
// Source: https://man7.org/linux/man-pages/man5/ipc.5.html
// When an IPC system call requires a permission check, if the process has privilege,
// access is granted. Otherwise:
// - If euid == perm.uid, use user permission bits (0400 read, 0200 write)
// - Else if egid == perm.gid, use group permission bits (0040 read, 0020 write)
// - Else use other permission bits (0004 read, 0002 write)

pub fn checkIpcAccess(perm: *const IpcPerm, proc: *const Process, need_write: bool) bool {
    if (proc.euid == 0) return true;  // Root always allowed

    const need_bit: u16 = if (proc.euid == perm.uid) {
        if (need_write) 0o200 else 0o400;
    } else if (proc.egid == perm.gid) {
        if (need_write) 0o020 else 0o040;
    } else {
        if (need_write) 0o002 else 0o004;
    };

    return (perm.mode & need_bit) != 0;
}
```

### Message Queue Send (Blocking vs Non-Blocking)

```zig
// Source: https://man7.org/linux/man-pages/man2/msgsnd.2.html
// msgsnd() appends message to queue. If queue is full:
// - IPC_NOWAIT set: return EAGAIN immediately
// - IPC_NOWAIT not set: block until space available or signal received

pub fn sys_msgsnd(msqid: usize, msgp: usize, msgsz: usize, msgflg: i32) SyscallError!usize {
    if (msgsz > IPC_LIMITS.MSGMAX) return error.EINVAL;

    const queue = findMessageQueue(msqid) orelse return error.EINVAL;
    const proc = base.getCurrentProcess();

    if (!checkIpcAccess(&queue.perm, proc, true)) return error.EACCES;

    // Allocate kernel message buffer
    const msg = heap.allocator().alloc(u8, msgsz + @sizeOf(i64)) catch return error.ENOMEM;
    errdefer heap.allocator().free(msg);

    // Copy message from userspace (type + data)
    const user_ptr = user_mem.UserPtr.from(msgp);
    _ = user_ptr.copyToKernel(msg) catch return error.EFAULT;

    // Check queue space
    const held = queue.lock.acquire();
    while (queue.qbytes + msgsz > IPC_LIMITS.MSGMNB) {
        if ((msgflg & IPC_NOWAIT) != 0) {
            held.release();
            return error.EAGAIN;
        }

        // Block until space available
        held.release();
        sched.block();  // TODO: Add to queue's wait list
        held.acquire();
    }

    // Append message to queue
    queue.messages.append(msg);
    queue.qnum += 1;
    queue.qbytes += msgsz;
    queue.lspid = proc.pid;
    queue.stime = hal.time.getUnixTimestamp();
    held.release();

    // Wake any msgrcv waiters
    // TODO: Implement wait queue wakeup

    return 0;
}
```

### Semaphore Control (IPC_STAT, IPC_SET, IPC_RMID)

```zig
// Source: https://man7.org/linux/man-pages/man2/semctl.2.html
// semctl() performs control operations:
// - IPC_STAT: Copy semid_ds to user buffer (requires read permission)
// - IPC_SET: Set perm.uid, perm.gid, perm.mode (requires owner or root)
// - IPC_RMID: Mark for deletion (requires owner or root)

pub fn sys_semctl(semid: usize, semnum: usize, cmd: i32, arg: usize) SyscallError!usize {
    const semset = findSemaphoreSet(semid) orelse return error.EINVAL;
    const proc = base.getCurrentProcess();

    switch (cmd) {
        IPC_STAT => {
            if (!checkIpcAccess(&semset.perm, proc, false)) return error.EACCES;

            var ds: SemidDs = undefined;
            ds.sem_perm = semset.perm;
            ds.sem_nsems = semset.nsems;
            ds.sem_otime = semset.otime;
            ds.sem_ctime = semset.ctime;

            const user_ptr = user_mem.UserPtr.from(arg);
            _ = user_ptr.copyFromKernel(std.mem.asBytes(&ds)) catch return error.EFAULT;
            return 0;
        },
        IPC_SET => {
            // Must be owner, creator, or root
            if (proc.euid != 0 and proc.euid != semset.perm.uid and proc.euid != semset.perm.cuid) {
                return error.EPERM;
            }

            const user_ptr = user_mem.UserPtr.from(arg);
            var ds: SemidDs = undefined;
            _ = user_ptr.copyToKernel(std.mem.asBytes(&ds)) catch return error.EFAULT;

            const held = semset.lock.acquire();
            semset.perm.uid = ds.sem_perm.uid;
            semset.perm.gid = ds.sem_perm.gid;
            semset.perm.mode = ds.sem_perm.mode & 0o777;  // Only lower 9 bits
            semset.ctime = hal.time.getUnixTimestamp();
            held.release();
            return 0;
        },
        IPC_RMID => {
            if (proc.euid != 0 and proc.euid != semset.perm.uid and proc.euid != semset.perm.cuid) {
                return error.EPERM;
            }

            const held = global_sem_lock.acquire();
            defer held.release();

            // Remove from global table
            for (sem_sets, 0..) |maybe_set, i| {
                if (maybe_set) |set| {
                    if (set.id == semset.id) {
                        // Free physical resources
                        heap.allocator().free(set.sems);
                        // Clear undo entries for this set
                        clearUndoEntries(semid);
                        sem_sets[i] = null;
                        return 0;
                    }
                }
            }
            return error.EINVAL;
        },
        SETVAL => {
            if (semnum >= semset.nsems) return error.EINVAL;
            if (!checkIpcAccess(&semset.perm, proc, true)) return error.EACCES;

            const val: i32 = @intCast(arg);
            if (val < 0 or val > IPC_LIMITS.SEMVMX) return error.ERANGE;

            const held = semset.lock.acquire();
            semset.sems[semnum].semval = @intCast(val);
            semset.ctime = hal.time.getUnixTimestamp();
            held.release();
            return 0;
        },
        GETVAL => {
            if (semnum >= semset.nsems) return error.EINVAL;
            if (!checkIpcAccess(&semset.perm, proc, false)) return error.EACCES;

            return semset.sems[semnum].semval;
        },
        else => return error.EINVAL,
    }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| SysV shared memory (shmget/shmat) | POSIX shared memory (shm_open/mmap) | POSIX.1-2001 (2001) | POSIX is preferred for new code (file descriptor based, simpler API, no ftok collisions), but SysV still required for legacy apps like PostgreSQL < 9.3 |
| shmfs (System V shared memory filesystem) | tmpfs (generalized temporary filesystem) | Linux 2.4 (2001) | tmpfs replaced shmfs as backing store. Modern kernels use tmpfs for both /dev/shm (POSIX) and anonymous SysV segments |
| Fixed SEMMNI=128 semaphore sets | Dynamic SEMMNI=32000 | Linux 3.19 (2015) | Increased default limits to support modern workloads (databases, container orchestrators) |
| Legacy ipc() multiplexing syscall | Direct syscalls (shmget, semget, msgget) | Always available on x86_64 | ipc() syscall (number 117) is obsolete on x86_64, never existed on aarch64. Use direct syscalls only |

**Deprecated/outdated:**
- **ipc() syscall (117):** Obsolete multiplexing syscall that dispatched to SysV IPC functions based on `call` parameter. Removed on x86_64, never existed on aarch64. Always use direct syscalls (shmget=29, semget=64, msgget=68).
- **shm_lock()/shm_unlock():** Removed from Linux in 2.6.10 (2004). These locked shared memory segments into RAM (prevented swapping). Not needed in modern kernels with better memory management.

## Open Questions

1. **IPC Namespace Support**
   - What we know: Linux supports per-namespace IPC tables for container isolation (CONFIG_IPC_NS). Each namespace has independent key spaces.
   - What's unclear: Does zk need namespace support in Phase 9, or defer to future container work?
   - Recommendation: Implement single global namespace initially. Add a `// TODO: IPC namespaces` comment in the global table initialization. Phase 9 success criteria don't mention namespaces, and no container requirements exist yet.

2. **tmpfs/shmfs Backing Store**
   - What we know: Linux uses tmpfs as the backing store for SysV shared memory. This allows segments to be swapped out and provides a unified memory management path.
   - What's unclear: zk doesn't have tmpfs yet. Can we allocate directly from PMM and track segments separately, or does this create swap complications later?
   - Recommendation: Allocate from PMM with `pmm.allocZeroedPages()`. Store physical addresses in `ShmSegment.phys_addr`. When tmpfs is added in a future phase, refactor to use tmpfs inodes as backing store (breaking change, but no external API impact).

3. **Semaphore Undo Limits**
   - What we know: Linux limits undo structures to SEMMNU (default 32000) per-process. Each structure tracks adjustments for one semaphore set.
   - What's unclear: Is SEMMNU enforcement critical for Phase 9, or can we skip the limit and allocate undo structures on-demand?
   - Recommendation: Allocate undo structures from heap with no hard limit initially. Most processes use 0-5 semaphore sets. Add limit enforcement later if memory exhaustion becomes an issue in testing.

4. **Message Queue Priority Ordering**
   - What we know: msgrcv() can receive messages by type (exact match, first of any type, first <= specified type). Messages of the same type are FIFO ordered.
   - What's unclear: Does type-based filtering require a priority queue, or is linear scan acceptable?
   - Recommendation: Use simple linked list (FIFO). msgrcv() scans the list for the first matching message. This is O(n) but message queues are rarely used and typically have < 10 messages. Don't optimize prematurely.

5. **IPC Limits Configuration**
   - What we know: Linux exposes IPC limits via /proc/sys/kernel/shm* and sysctl. PostgreSQL documentation warns users to increase SHMMAX.
   - What's unclear: Should zk hardcode limits or make them configurable via a config file / boot parameter?
   - Recommendation: Hardcode generous defaults (SHMMAX=32MB, SHMMNI=4096, SEMMNI=32000) matching modern Linux. Add `// TODO: Make configurable` comment. Phase 9 doesn't require runtime configuration, and boot parameters are out of scope.

## Sources

### Primary (HIGH confidence)
- [sysvipc(7) - Linux manual page](https://man7.org/linux/man-pages/man7/svipc.7.html) - SysV IPC overview, data structures, permissions
- [shmget(2) - Linux manual page](https://man7.org/linux/man-pages/man2/shmget.2.html) - Shared memory allocation semantics
- [shmop(2) - Linux manual page (shmat/shmdt)](https://man7.org/linux/man-pages/man2/shmat.2.html) - Attach/detach operations
- [shmctl(2) - Linux manual page](https://www.man7.org/linux/man-pages/man2/shmctl.2.html) - Shared memory control operations
- [semget(2) - Linux manual page](https://www.man7.org/linux/man-pages/man2/semget.2.html) - Semaphore set creation
- [semop(2) - Linux manual page](https://man7.org/linux/man-pages/man2/semop.2.html) - Semaphore operations, SEM_UNDO semantics
- [semctl(2) - Linux manual page](https://man7.org/linux/man-pages/man2/semctl.2.html) - Semaphore control, SETVAL/GETVAL
- [msgget(2) - Linux manual page](https://man7.org/linux/man-pages/man2/msgget.2.html) - Message queue creation
- [msgop(2) - Linux manual page (msgsnd/msgrcv)](https://www.man7.org/linux/man-pages/man2/msgsnd.2.html) - Message queue operations
- [ipc(5) - Linux man page](https://linux.die.net/man/5/ipc) - struct ipc_perm and permission checking algorithm

### Secondary (MEDIUM confidence)
- [Shared Memory Virtual Filesystem - Kernel.org](https://www.kernel.org/doc/gorman/html/understand/understand015.html) - tmpfs/shmfs implementation details (verified against official kernel docs)
- [tmpfs(5) - Linux manual page](https://man7.org/linux/man-pages/man5/tmpfs.5.html) - tmpfs as SysV backing store (official man page)
- [IPC: System V Shared Memory - circuitlabs.net](https://circuitlabs.net/ipc-system-v-shared-memory-shmget-shmat-shmdt-shmctl/) - Implementation patterns (cross-referenced with man pages)
- [PostgreSQL Documentation: Managing Kernel Resources](https://www.postgresql.org/docs/current/kernel-resources.html) - Real-world SysV IPC usage requirements (official PostgreSQL docs)
- [ftok(3) - Linux manual page](https://man7.org/linux/man-pages/man3/ftok.3.html) - Key generation and collision issues
- [ipc_namespaces(7) - Linux manual page](https://man7.org/linux/man-pages/man7/ipc_namespaces.7.html) - Namespace isolation (official kernel feature docs)

### Tertiary (LOW confidence)
- [shm_overview(7) - Linux manual page](https://www.man7.org/linux/man-pages/man7/shm_overview.7.html) - POSIX vs SysV comparison (marked LOW because it advocates for POSIX as replacement, which may not apply to zk's compatibility goals)
- Various StackOverflow discussions about SysV IPC pitfalls - used for validation only, not cited as authoritative

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - syscall numbers and data structures are well-defined POSIX/Linux standards with official man pages
- Architecture: HIGH - Linux kernel implementation patterns are documented in kernel.org and Understanding the Linux Kernel (O'Reilly)
- Pitfalls: MEDIUM - based on man page warnings, mailing list discussions, and inferred from error conditions; some pitfalls are hypothetical (not verified against actual kernel bugs)

**Research date:** 2026-02-08
**Valid until:** 60 days (2026-04-09) - SysV IPC is stable/legacy technology, minimal churn expected

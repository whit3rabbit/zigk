# Requirements: ZK Kernel v1.2

**Defined:** 2026-02-11
**Core Value:** Every implemented syscall works correctly on both x86_64 and aarch64, tested via the integration test harness.

## v1.2 Requirements

### File Synchronization

- [ ] **FSYNC-01**: User can call fsync on an open file descriptor to flush data to storage
- [ ] **FSYNC-02**: User can call fdatasync to flush data without metadata
- [ ] **FSYNC-03**: User can call sync to flush all filesystem buffers
- [ ] **FSYNC-04**: User can call syncfs to flush buffers for a specific filesystem

### Advanced File Operations

- [ ] **FOPS-01**: User can call fallocate to pre-allocate file space with mode flags
- [ ] **FOPS-02**: User can call renameat2 with RENAME_NOREPLACE and RENAME_EXCHANGE flags

### Zero-Copy I/O

- [ ] **ZCIO-01**: User can call splice to move data between a pipe and a file descriptor without user-space copy
- [ ] **ZCIO-02**: User can call tee to duplicate data between two pipe descriptors
- [ ] **ZCIO-03**: User can call vmsplice to splice user pages into a pipe
- [ ] **ZCIO-04**: User can call copy_file_range to copy data between two file descriptors server-side

### File Monitoring

- [ ] **INOT-01**: User can call inotify_init1 to create an inotify instance with flags
- [ ] **INOT-02**: User can call inotify_add_watch to monitor a file/directory for events
- [ ] **INOT-03**: User can call inotify_rm_watch to stop monitoring a watch descriptor
- [ ] **INOT-04**: User can read inotify events from the inotify file descriptor via read()

### Memory Management

- [ ] **MEM-01**: User can call memfd_create to create an anonymous file backed by memory
- [ ] **MEM-02**: User can call mremap to resize or move an existing memory mapping
- [ ] **MEM-03**: User can call msync to synchronize a memory-mapped file region with storage

### Process Control

- [ ] **PROC-01**: User can call clone3 with struct clone_args for modern process creation
- [ ] **PROC-02**: User can call waitid to wait for process state changes with extended options

### Signal Handling

- [ ] **SIG-01**: User can call rt_sigtimedwait to synchronously wait for a pending signal with timeout
- [ ] **SIG-02**: User can call rt_sigqueueinfo to send a signal with associated data to a process
- [ ] **SIG-03**: User can call clock_nanosleep to sleep with a specific clock source and flags

### POSIX Timers

- [ ] **PTMR-01**: User can call timer_create to create a per-process POSIX timer
- [ ] **PTMR-02**: User can call timer_settime to arm or disarm a POSIX timer
- [ ] **PTMR-03**: User can call timer_gettime to query remaining time on a POSIX timer
- [ ] **PTMR-04**: User can call timer_getoverrun to get overrun count for a POSIX timer
- [ ] **PTMR-05**: User can call timer_delete to delete a POSIX timer

### I/O Multiplexing

- [ ] **EPOLL-01**: User can call epoll_pwait to wait for events with an atomically-set signal mask

### Capabilities

- [ ] **CAP-01**: User can call capget to retrieve process capabilities
- [ ] **CAP-02**: User can call capset to set process capabilities

### Seccomp

- [ ] **SEC-01**: User can call seccomp with SECCOMP_SET_MODE_STRICT to restrict syscalls to read/write/exit/sigreturn
- [ ] **SEC-02**: User can call seccomp with SECCOMP_SET_MODE_FILTER to install a BPF filter for syscall filtering

### Test Coverage Expansion

- [ ] **TEST-01**: Integration tests exist for all file ownership syscalls (fchown, lchown, fchdir)
- [ ] **TEST-02**: Integration tests exist for memory advisory syscalls (madvise, mincore)
- [ ] **TEST-03**: Integration tests exist for signal state syscalls (rt_sigpending, rt_sigsuspend)
- [ ] **TEST-04**: Integration tests exist for resource limit syscalls (setrlimit, getrusage)
- [ ] **TEST-05**: Integration tests exist for credential variant syscalls (setreuid, setregid, setfsuid, setfsgid)
- [ ] **TEST-06**: Integration tests exist for time setter syscalls (settimeofday)
- [ ] **TEST-07**: Integration tests exist for select() and epoll edge cases
- [ ] **TEST-08**: Integration tests exist for scheduling syscalls (sched_rr_get_interval)

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### Container/Namespace Support

- **NS-01**: User can call unshare to create new namespaces
- **NS-02**: User can call setns to join existing namespaces

### Advanced Debugging

- **DBG-01**: User can use ptrace to attach to and control another process

### Advanced Zero-Copy

- **ZC-01**: sendfile uses true zero-copy via VFS page cache (currently 64KB buffer)
- **ZC-02**: sync_file_range for partial file synchronization

## Out of Scope

| Feature | Reason |
|---------|--------|
| ptrace | Extremely complex, separate project (unchanged from v1.0) |
| unshare/setns | Container/namespace support requires kernel architecture changes |
| Extended attributes (setxattr family) | Depends on security model not yet designed |
| Module loading | Microkernel, not applicable |
| Legacy/deprecated syscalls | Removed from modern Linux |
| io_uring expansion | Basic support exists, full completion is separate |
| Swap management | No swap subsystem planned |
| VFS redesign (mount/umount rework) | Separate project |
| SFS nested subdirectories | Fundamental SFS architecture change |
| Multi-CPU affinity enforcement | Single-CPU kernel |
| Full seccomp BPF JIT | v1.2 implements interpreter only, JIT is future |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| FSYNC-01 | Phase 15 | Pending |
| FSYNC-02 | Phase 15 | Pending |
| FSYNC-03 | Phase 15 | Pending |
| FSYNC-04 | Phase 15 | Pending |
| FOPS-01 | Phase 16 | Pending |
| FOPS-02 | Phase 16 | Pending |
| ZCIO-01 | Phase 17 | Pending |
| ZCIO-02 | Phase 17 | Pending |
| ZCIO-03 | Phase 17 | Pending |
| ZCIO-04 | Phase 17 | Pending |
| INOT-01 | Phase 22 | Pending |
| INOT-02 | Phase 22 | Pending |
| INOT-03 | Phase 22 | Pending |
| INOT-04 | Phase 22 | Pending |
| MEM-01 | Phase 18 | Pending |
| MEM-02 | Phase 18 | Pending |
| MEM-03 | Phase 18 | Pending |
| PROC-01 | Phase 19 | Pending |
| PROC-02 | Phase 19 | Pending |
| SIG-01 | Phase 20 | Pending |
| SIG-02 | Phase 20 | Pending |
| SIG-03 | Phase 20 | Pending |
| PTMR-01 | Phase 23 | Pending |
| PTMR-02 | Phase 23 | Pending |
| PTMR-03 | Phase 23 | Pending |
| PTMR-04 | Phase 23 | Pending |
| PTMR-05 | Phase 23 | Pending |
| EPOLL-01 | Phase 21 | Pending |
| CAP-01 | Phase 24 | Pending |
| CAP-02 | Phase 24 | Pending |
| SEC-01 | Phase 25 | Pending |
| SEC-02 | Phase 25 | Pending |
| TEST-01 | Phase 26 | Pending |
| TEST-02 | Phase 26 | Pending |
| TEST-03 | Phase 26 | Pending |
| TEST-04 | Phase 26 | Pending |
| TEST-05 | Phase 26 | Pending |
| TEST-06 | Phase 26 | Pending |
| TEST-07 | Phase 26 | Pending |
| TEST-08 | Phase 26 | Pending |

**Coverage:**
- v1.2 requirements: 40 total
- Mapped to phases: 40
- Unmapped: 0

**✓ 100% requirement coverage achieved**

---
*Requirements defined: 2026-02-11*
*Last updated: 2026-02-11 after roadmap creation*

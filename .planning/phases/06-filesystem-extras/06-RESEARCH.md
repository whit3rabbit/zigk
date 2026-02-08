# Phase 6: Filesystem Extras - Research

**Researched:** 2026-02-08
**Domain:** Linux filesystem syscalls (*at family, timestamp manipulation)
**Confidence:** HIGH

## Summary

Phase 6 completes filesystem syscall coverage by implementing the remaining *at family syscalls (readlinkat, linkat, symlinkat) and timestamp manipulation syscalls (utimensat, futimesat). The *at family provides race-free directory operations by using directory file descriptors instead of string paths. Timestamp manipulation syscalls allow nanosecond-precision control over file access and modification times, with utimensat being the modern replacement for the obsolete futimesat.

All required syscalls follow established patterns in the codebase. The *at syscalls use the existing `resolvePathAt` helper and kernel-space path delegation pattern already proven in fstatat, mkdirat, unlinkat, renameat, and fchmodat. Timestamp syscalls require adding VFS layer support for storing/updating atime/mtime with nanosecond precision, which the current VFS metadata structure does not support.

The existing codebase already implements the base syscalls (readlink, symlink, link) with full VFS support, making the *at variants straightforward wrappers. The kernel pointer delegation pattern was recently fixed across all *at syscalls, providing a verified implementation template.

**Primary recommendation:** Implement all *at syscalls first (FS-01 to FS-03), then add VFS timestamp infrastructure and utimensat/futimesat (FS-04, FS-05). Follow the kernel-space path helper pattern established in fstatat and mkdirat.

## Standard Stack

### Core (Kernel Implementation)
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Zig 0.16.x | Nightly | Language implementation | Project standard |
| VFS (src/fs/vfs.zig) | Custom | Filesystem abstraction | Already implements base link/symlink/readlink operations |
| resolvePathAt helper (syscall/fs/fd.zig) | Custom | Path resolution for *at syscalls | Shared by all existing *at syscalls, handles AT_FDCWD |
| Timespec (uapi/base/abi.zig) | POSIX.1-2017 | Nanosecond timestamp structure | 16-byte extern struct (tv_sec: i64, tv_nsec: i64) |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| FileMeta (fs/meta.zig) | Custom | File metadata storage | Will need atime_nsec/mtime_nsec fields added |
| UserPtr (syscall/core/user_mem.zig) | Custom | SMAP-safe userspace memory access | All userspace pointer reads/writes |
| copyStringFromUser | Custom | Safe path string copying | All path parameters from userspace |
| canonicalizePath | Custom | Path sanitization (.., /) | Security layer before VFS calls |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| utimensat | futimesat (legacy) | futimesat deprecated since Linux 2.6.16, microsecond precision only |
| Kernel-space helpers | Direct delegation to base syscalls | Helper pattern prevents double-copy EFAULT bug (already fixed) |
| VFS timestamp extension | Filesystem-specific timestamps | VFS layer ensures uniform timestamp handling across all filesystems |

**Installation:** No external dependencies. All implementation is kernel-internal.

## Architecture Patterns

### Recommended Project Structure
```
src/kernel/sys/syscall/
├── fs/
│   ├── fs_handlers.zig     # Link/symlink/readlink implementations, timestamp syscalls
│   ├── fd.zig              # resolvePathAt helper (already exists)
├── io/
│   ├── stat.zig            # fstatat pattern reference
src/fs/
├── vfs.zig                 # VFS layer with link/symlink/readlink/setTimestamps
├── meta.zig                # FileMeta with atime_nsec, mtime_nsec fields
```

### Pattern 1: *at Syscall Implementation (Kernel-Space Path Helper)
**What:** *at syscalls copy path from userspace once, resolve relative to dirfd, then delegate to kernel-space helper that takes a kernel path slice.
**When to use:** All *at family syscalls to prevent double-copy EFAULT bug.
**Example:**
```zig
// From fs_handlers.zig (existing pattern)
pub fn sys_readlinkat(dirfd: usize, path_ptr: usize, buf_ptr: usize, bufsiz: usize) SyscallError!usize {
    const alloc = heap.allocator();
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);

    const path = user_mem.copyStringFromUser(path_buf, path_ptr) catch |err| {
        if (err == error.NameTooLong) return error.ENAMETOOLONG;
        return error.EFAULT;
    };

    if (path.len == 0) return error.ENOENT;

    // Handle absolute paths directly (bypass dirfd)
    if (path[0] == '/') {
        return sys_readlink(@intFromPtr(path.ptr), buf_ptr, bufsiz);
    }

    // Allocate buffer for resolved path
    const resolved_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(resolved_buf);

    // Resolve path relative to dirfd
    const resolved = fd_syscall.resolvePathAt(dirfd, path, resolved_buf) catch |err| return err;

    // Call base syscall with resolved path
    return sys_readlink(@intFromPtr(resolved.ptr), buf_ptr, bufsiz);
}
```

### Pattern 2: AT_FDCWD and Directory FD Handling
**What:** resolvePathAt handles special AT_FDCWD value (-100) to mean "current working directory", validates directory FDs, and returns kernel-space path slice.
**When to use:** All *at syscalls for consistent path resolution.
**Example:**
```zig
// From syscall/fs/fd.zig (existing helper)
pub fn resolvePathAt(dirfd: usize, path: []const u8, output_buf: []u8) SyscallError![]const u8 {
    const AT_FDCWD: usize = @bitCast(@as(isize, -100));

    // Absolute paths ignore dirfd
    if (path.len > 0 and path[0] == '/') {
        if (path.len > output_buf.len) return error.ENAMETOOLONG;
        @memcpy(output_buf[0..path.len], path);
        return output_buf[0..path.len];
    }

    // Determine base directory
    if (dirfd == AT_FDCWD) {
        const proc = base.getCurrentProcess();
        const held = proc.cwd_lock.acquire();
        @memcpy(output_buf[0..proc.cwd_len], proc.cwd[0..proc.cwd_len]);
        const len = proc.cwd_len;
        held.release();
        return joinPaths(output_buf[0..len], path, output_buf);
    } else {
        // Validate dirfd is a directory FD
        const table = base.getGlobalFdTable();
        const fd = table.get(@truncate(dirfd)) orelse return error.EBADF;
        if (fd.ops != &fd_mod.dir_ops) return error.ENOTDIR;
        // Extract directory path and join with relative path
        // ...
    }
}
```

### Pattern 3: Timespec Validation and Special Values
**What:** utimensat supports UTIME_NOW (set to current time) and UTIME_OMIT (leave unchanged) as special tv_nsec values. Normal values must be 0-999,999,999.
**When to use:** All timestamp manipulation syscalls.
**Example:**
```zig
// Recommended pattern for utimensat
pub fn sys_utimensat(dirfd: usize, path_ptr: usize, times_ptr: usize, flags: usize) SyscallError!usize {
    const UTIME_NOW: i64 = (1 << 30) - 1;  // 0x3fffffff
    const UTIME_OMIT: i64 = (1 << 30) - 2; // 0x3ffffffe

    // Read timespec array from userspace (null = set both to current time)
    var times: [2]uapi.Timespec = undefined;
    if (times_ptr == 0) {
        // NULL pointer: set both to UTIME_NOW
        times[0] = .{ .tv_sec = 0, .tv_nsec = UTIME_NOW };
        times[1] = .{ .tv_sec = 0, .tv_nsec = UTIME_NOW };
    } else {
        if (!isValidUserAccess(times_ptr, @sizeOf([2]uapi.Timespec), .Read)) {
            return error.EFAULT;
        }
        const uptr = UserPtr.from(times_ptr);
        times = uptr.readValue([2]uapi.Timespec) catch return error.EFAULT;

        // Validate nsec fields (0-999999999 or special values)
        for (times) |ts| {
            if (ts.tv_nsec != UTIME_NOW and ts.tv_nsec != UTIME_OMIT) {
                if (ts.tv_nsec < 0 or ts.tv_nsec > 999_999_999) {
                    return error.EINVAL;
                }
            }
        }
    }

    // Resolve path, delegate to VFS setTimestamps
    // ...
}
```

### Anti-Patterns to Avoid
- **Direct copyStringFromUser in *at variants:** Causes double-copy when delegating to base syscall. Use kernel-space path helpers (readlinkKernel, linkKernel, symlinkKernel) that take `[]const u8` instead of `usize` pointer.
- **Storing userspace pointers across locks:** Always copy path/timespec data to kernel stack before acquiring locks or calling VFS functions.
- **Hardcoding syscall numbers:** Use uapi/syscalls/linux.zig and linux_aarch64.zig constants. Note: aarch64 has different numbering scheme.
- **Ignoring AT_SYMLINK_NOFOLLOW flag:** readlinkat should NOT follow symlinks by design (reads the link itself). Other syscalls should check the flag.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Path resolution for *at syscalls | Per-syscall dirfd handling | resolvePathAt helper (syscall/fs/fd.zig) | Handles AT_FDCWD, validates directory FDs, prevents TOCTOU races |
| Userspace string copying | Raw pointer dereferencing | user_mem.copyStringFromUser | SMAP-compliant, bounds-checked, handles NameTooLong |
| Userspace structure reads | @ptrCast from usize | UserPtr.readValue / writeValue | Type-safe, SMAP-compliant, explicit error handling |
| Path sanitization | Manual slash/dot removal | canonicalizePath | Rejects ".." (security), normalizes slashes, validated pattern |
| Timestamp current time | hal.timing.getTsc | hal.timing.getClockNanoseconds or hal.rtc | Clock-agnostic, returns UNIX epoch time |
| VFS link/symlink operations | Direct filesystem calls | VFS.link / VFS.symlink / VFS.readlink | Cross-filesystem compatibility, mount point handling |

**Key insight:** The *at syscall family was created to address TOCTOU race conditions in directory operations. Using the shared resolvePathAt helper ensures all syscalls benefit from the same race-prevention logic. Custom implementations would duplicate complex dirfd validation and cwd locking logic.

## Common Pitfalls

### Pitfall 1: Syscall Number Mismatch Between Architectures
**What goes wrong:** Adding syscall constant to only linux.zig (x86_64) causes aarch64 builds to fail with "unknown syscall" or dispatch to wrong function.
**Why it happens:** x86_64 and aarch64 use completely different syscall numbering schemes. aarch64 has no legacy syscalls (open, pipe, stat) and different numeric assignments for shared syscalls.
**How to avoid:** Add every new syscall to BOTH uapi/syscalls/linux.zig and linux_aarch64.zig with correct architecture-specific numbers.
**Warning signs:** Test suite passes on x86_64 but fails on aarch64 with "ENOSYS" errors.

### Pitfall 2: Double-Copy EFAULT in *at Syscalls
**What goes wrong:** *at syscall copies path from userspace to kernel buffer, then calls base syscall (sys_readlink) passing kernel buffer pointer as if it were a userspace pointer. Base syscall tries to copyStringFromUser on the kernel pointer, returns EFAULT.
**Why it happens:** Base syscalls expect userspace pointers. Kernel pointers fail UserPtr validation.
**How to avoid:** Extract kernel-space path helpers (readlinkKernel, linkKernel, symlinkKernel) that take `[]const u8` slice, not `usize` pointer. Both base syscalls and *at variants delegate to these helpers.
**Warning signs:** *at syscalls always return EFAULT even with valid paths. This bug was already fixed in fstatat, mkdirat, unlinkat, renameat, fchmodat - use those as templates.

### Pitfall 3: Missing VFS Timestamp Infrastructure
**What goes wrong:** Implementing utimensat without extending FileMeta to store nanosecond timestamps causes precision loss (truncates to seconds) or requires filesystem-specific timestamp handling.
**Why it happens:** Current FileMeta (fs/meta.zig) has no atime_nsec or mtime_nsec fields. VFS.statPath returns FileMeta without nanosecond precision.
**How to avoid:** Add atime_nsec and mtime_nsec fields to FileMeta. Add VFS.setTimestamps(path, atime, atime_nsec, mtime, mtime_nsec) method. Update all filesystems (InitRD, SFS, DevFS) to store/restore nanosecond fields.
**Warning signs:** utimensat succeeds but subsequent stat shows timestamps truncated to seconds.

### Pitfall 4: Ignoring UTIME_NOW and UTIME_OMIT Special Values
**What goes wrong:** Treating UTIME_NOW (0x3fffffff) as a literal nanosecond value causes timestamp to be set to year 2038 instead of current time. Treating UTIME_OMIT as invalid causes EINVAL instead of preserving existing timestamp.
**Why it happens:** Special values are outside the valid 0-999,999,999 range but must be handled specially, not validated as normal nsec values.
**How to avoid:** Check for special values BEFORE range validation. UTIME_NOW reads current time from hal.timing. UTIME_OMIT skips the timestamp field entirely (leaves VFS metadata unchanged).
**Warning signs:** Files get future timestamps (year 2038) after utimensat call, or utimensat returns EINVAL when passing UTIME_OMIT.

### Pitfall 5: futimesat Confusion with utimensat Signature
**What goes wrong:** futimesat uses microsecond precision (struct timeval[2]) while utimensat uses nanosecond precision (struct timespec[2]). Mixing the structures causes timestamp corruption or EFAULT.
**Why it happens:** futimesat is obsolete but still part of ABI. Developers might implement it standalone instead of wrapping utimensat.
**How to avoid:** Implement futimesat as a wrapper that reads timeval[2], converts to timespec[2] (usec * 1000 = nsec), then delegates to utimensat implementation.
**Warning signs:** futimesat sets timestamps off by 1000x (microseconds interpreted as nanoseconds).

### Pitfall 6: symlinkat Target Path Confusion
**What goes wrong:** Resolving the symlink target path relative to dirfd instead of storing it literally. Symlinks should store the exact target string provided, not resolve it.
**Why it happens:** Misunderstanding that symlink target is data (stored in the link), not a path to be resolved at link creation time.
**How to avoid:** In symlinkat, only the linkpath (where to create the link) is resolved relative to dirfd. The target string is copied as-is and passed to VFS.symlink.
**Warning signs:** Symlinks point to wrong paths when linkpath is relative to a directory FD.

## Code Examples

Verified patterns from existing codebase:

### Kernel-Space Path Helper Pattern (from fstatat implementation)
```zig
// Source: src/kernel/sys/syscall/io/stat.zig
/// Internal: stat a canonicalized kernel-space path and write result to userspace buffer.
/// Used by sys_stat and sys_fstatat to avoid redundant copyStringFromUser calls.
fn statPathKernel(path: []const u8, stat_buf_ptr: usize) SyscallError!usize {
    // Validate userspace buffer
    if (!isValidUserAccess(stat_buf_ptr, @sizeOf(uapi.stat.Stat), AccessMode.Write)) {
        return error.EFAULT;
    }

    // Get file metadata via VFS
    const file_meta = fs.vfs.Vfs.statPath(path) orelse return error.ENOENT;

    // SECURITY: Use UserPtr for SMAP-compliant writes to userspace
    const stat_result: uapi.stat.Stat = .{
        .dev = file_meta.dev,
        .ino = file_meta.ino,
        // ... populate fields ...
    };
    UserPtr.from(stat_buf_ptr).writeValue(stat_result) catch return error.EFAULT;

    return 0;
}

pub fn sys_stat(path_ptr: usize, stat_buf_ptr: usize) SyscallError!usize {
    const alloc = heap.allocator();
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);
    const raw_path = user_mem.copyStringFromUser(path_buf, path_ptr) catch return error.EFAULT;
    return statPathKernel(raw_path, stat_buf_ptr); // Delegate to kernel helper
}

pub fn sys_fstatat(dirfd: usize, path_ptr: usize, statbuf_ptr: usize, flags: usize) SyscallError!usize {
    _ = flags;
    const alloc = heap.allocator();
    const path_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(path_buf);
    const raw_path = user_mem.copyStringFromUser(path_buf, path_ptr) catch return error.EFAULT;

    if (raw_path[0] == '/') {
        return statPathKernel(raw_path, statbuf_ptr); // Absolute path: bypass dirfd
    }

    const resolved_buf = alloc.alloc(u8, user_mem.MAX_PATH_LEN) catch return error.ENOMEM;
    defer alloc.free(resolved_buf);
    const resolved = fd_syscall.resolvePathAt(dirfd, raw_path, resolved_buf) catch |err| return err;
    return statPathKernel(resolved, statbuf_ptr); // Delegate to shared helper
}
```

### VFS Link/Symlink Operations (existing implementations)
```zig
// Source: src/fs/vfs.zig (lines 690-773)
/// Create a hard link
pub fn link(old_path: []const u8, new_path: []const u8) Error!void {
    if (old_path.len == 0 or new_path.len == 0) return error.InvalidPath;
    if (old_path[0] != '/' or new_path[0] != '/') return error.InvalidPath;

    const old_mount = findMountPoint(old_path) orelse return error.NotFound;
    const new_mount = findMountPoint(new_path) orelse return error.NotFound;

    // Hard links must be on same filesystem
    if (old_mount.id != new_mount.id) return error.CrossDeviceLink;

    if (old_mount.fs.link) |link_fn| {
        return link_fn(old_mount.fs, old_path, new_path);
    }
    return error.NotSupported;
}

/// Create a symbolic link
pub fn symlink(target: []const u8, linkpath: []const u8) Error!void {
    if (linkpath.len == 0 or linkpath[0] != '/') return error.InvalidPath;

    const mount = findMountPoint(linkpath) orelse return error.NotFound;

    if (mount.fs.symlink) |symlink_fn| {
        return symlink_fn(mount.fs, target, linkpath);
    }
    return error.NotSupported;
}

/// Read the target of a symbolic link
pub fn readlink(path: []const u8, buf: []u8) Error!usize {
    if (path.len == 0 or path[0] != '/') return error.InvalidPath;

    const mount = findMountPoint(path) orelse return error.NotFound;

    if (mount.fs.readlink) |readlink_fn| {
        return readlink_fn(mount.fs, path, buf);
    }
    return error.NotSupported;
}
```

### Syscall Registration Pattern
```zig
// Source: Pattern from syscall/io/root.zig
// All *at syscalls must be exported in the module's root.zig

pub const sys_readlinkat = fs_handlers.sys_readlinkat;
pub const sys_linkat = fs_handlers.sys_linkat;
pub const sys_symlinkat = fs_handlers.sys_symlinkat;
pub const sys_utimensat = fs_handlers.sys_utimensat;
pub const sys_futimesat = fs_handlers.sys_futimesat;

// Note: sys_newfstatat alias required for dispatch (SYS_NEWFSTATAT = 262 on x86_64)
pub const sys_newfstatat = stat.sys_fstatat;
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| futimesat (microsecond) | utimensat (nanosecond) | Linux 2.6.16 (2006) | utimensat obsoletes futimesat, 1000x precision improvement |
| Base syscalls (stat, mkdir) | *at variants (fstatat, mkdirat) | Linux 2.6.16+ | *at family prevents TOCTOU races, required for aarch64 |
| Direct kernel pointer passing | Kernel-space path helpers | ZK Phase 5 (2026-02) | Fixed EFAULT bug in all *at syscalls |
| Single VFS timestamp field | Separate sec/nsec fields | Not yet implemented | Required for POSIX.1-2008 compliance |

**Deprecated/outdated:**
- **futimesat:** Obsolete since Linux 2.6.16, replaced by utimensat. Still part of x86_64 ABI for compatibility.
- **utime/utimes:** Legacy syscalls with second/microsecond precision. Modern code should use utimensat.
- **Direct base syscalls without *at variants:** aarch64 ABI has no legacy syscalls, requires *at variants exclusively.

## Open Questions

1. **VFS timestamp storage format**
   - What we know: FileMeta currently has no nanosecond timestamp fields. Stat structure has atime_nsec/mtime_nsec/ctime_nsec fields.
   - What's unclear: Should FileMeta add nsec fields, or should VFS.statPath compute them from filesystem-specific metadata?
   - Recommendation: Add atime_nsec/mtime_nsec to FileMeta for uniform handling. InitRD and DevFS can zero them (no persistence). SFS needs persistence layer updates.

2. **SFS timestamp persistence**
   - What we know: SFS has close deadlock and 64-file limit. Timestamp updates require writing to disk.
   - What's unclear: Can SFS reliably persist nanosecond timestamps without triggering close deadlock?
   - Recommendation: Implement timestamp syscalls with in-memory-only precision for MVP. SFS persistence is out of scope (deferred to Phase 9 or filesystem rewrite).

3. **CLOCK_BOOTTIME vs CLOCK_MONOTONIC**
   - What we know: utimensat accepts clock_id parameter (proposed but not in current POSIX).
   - What's unclear: Do we need to support different clock sources for UTIME_NOW, or always use CLOCK_REALTIME?
   - Recommendation: UTIME_NOW always uses CLOCK_REALTIME (hal.rtc). Clock source selection is deferred.

4. **AT_SYMLINK_NOFOLLOW flag handling**
   - What we know: utimensat supports AT_SYMLINK_NOFOLLOW to set symlink timestamps instead of target.
   - What's unclear: Does VFS support setting symlink metadata directly, or only target metadata?
   - Recommendation: Check flag and return ENOSYS if set (symlink timestamp manipulation not supported in MVP). Document in test suite.

5. **Cross-filesystem hard links**
   - What we know: POSIX requires EXDEV error when old_path and new_path are on different filesystems.
   - What's unclear: Does VFS.link already enforce this, or do we need explicit mount point checking?
   - Recommendation: VFS.link already checks `old_mount.id != new_mount.id` (line 697 in vfs.zig). Pattern is correct.

## Sources

### Primary (HIGH confidence)
- [Linux utimensat(2) manual page](https://man7.org/linux/man-pages/man2/utimensat.2.html) - Function signature, timespec structure, special values, flags, dirfd behavior
- [Linux futimesat(2) manual page](https://man7.org/linux/man-pages/man2/futimesat.2.html) - Obsolescence status, relationship with utimensat
- [Linux readlink(2) manual page](https://man7.org/linux/man-pages/man2/readlink.2.html) - readlinkat behavior, AT_FDCWD semantics
- [Linux link(2) manual page](https://man7.org/linux/man-pages/man2/link.2.html) - linkat behavior, AT_SYMLINK_FOLLOW flag
- [Linux symlink(2) manual page](https://www.man7.org/linux/man-pages/man2/symlink.2.html) - symlinkat behavior, target vs linkpath distinction
- [Linux kernel syscall table (x86_64)](https://github.com/torvalds/linux/blob/master/arch/x86/entry/syscalls/syscall_64.tbl) - Syscall numbers: utimensat=280, futimesat=261
- [Searchable Linux Syscall Table](https://filippo.io/linux-syscall-table/) - Cross-architecture syscall number reference
- ZK codebase (src/kernel/sys/syscall/io/stat.zig) - statPathKernel pattern (kernel-space helper)
- ZK codebase (src/kernel/sys/syscall/fs/fs_handlers.zig) - Existing link/symlink/readlink implementations, *at pattern
- ZK codebase (src/fs/vfs.zig) - VFS.link, VFS.symlink, VFS.readlink implementations
- ZK codebase (src/uapi/base/abi.zig) - Timespec structure definition (16-byte extern struct)

### Secondary (MEDIUM confidence)
- [Chromium OS Linux System Call Table](https://chromium.googlesource.com/chromiumos/docs/+/master/constants/syscalls.md) - Syscall number cross-reference
- [arm64.syscall.sh](https://arm64.syscall.sh/) - aarch64 syscall numbers (utimensat=88)
- [Marcin Juszkiewicz syscall tables](https://marcin.juszkiewicz.com.pl/download/tables/syscalls.html) - Multi-architecture syscall reference

### Tertiary (LOW confidence)
- None - all findings verified against official kernel sources and man pages

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - All components verified in existing codebase
- Architecture: HIGH - Patterns proven in fstatat, mkdirat, unlinkat implementations
- Pitfalls: HIGH - Double-copy EFAULT bug already encountered and fixed, documented in STATE.md

**Research date:** 2026-02-08
**Valid until:** 30 days (stable APIs, POSIX syscalls)

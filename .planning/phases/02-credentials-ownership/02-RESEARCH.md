# Phase 2: Credentials & Ownership - Research

**Researched:** 2026-02-06
**Domain:** OS kernel credential management (POSIX UID/GID syscalls, permission checking, file ownership)
**Confidence:** HIGH

## Summary

Phase 2 completes the UID/GID syscall surface by implementing 8 missing syscalls: setreuid, setregid, getgroups, setgroups, setfsuid, setfsgid, and the chown family (chown, fchown, lchown already have VFS infrastructure; fchownat needs implementation). The kernel has robust credential infrastructure already in place from Phase 1:

- **Process struct** (src/kernel/proc/process/types.zig) already has all credential fields including uid/gid/euid/egid/suid/sgid, supplementary_groups array (16 slots), and cred_lock spinlock
- **Existing implementations** of setuid/setgid/setresuid/setresgid provide the exact pattern to follow for permission checks and atomic credential updates
- **Capability system** (hasSetUidCapability/hasSetGidCapability) is wired in and ready to use
- **VFS chown interface** exists but currently takes only uid/gid parameters (no flags for nofollow/empty_path)
- **SFS chown** (src/fs/sfs/ops.zig:948-1012) implements the 3-phase TOCTOU prevention pattern

**Primary recommendation:** Add fsuid/fsgid fields to Process struct, implement 8 missing syscalls following existing setresuid/setresgid patterns, extend VFS chown to accept flags parameter, add FileOps.chown method for fchown.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
**fsuid/fsgid Scope:**
- Add real fsuid/fsgid fields to the Process struct (not aliases to euid/egid)
- Match Linux return semantics exactly: setfsuid/setfsgid return the PREVIOUS fsuid/fsgid value, not 0/-errno
- fsuid/fsgid replace euid/egid in filesystem permission checks ONLY (open, access, stat, chown). Signal delivery, ptrace, and other non-FS operations continue using euid/egid
- Auto-sync: when setuid/setreuid/setresuid changes euid, fsuid automatically tracks to the new euid. Same for fsgid tracking egid. Only diverge when setfsuid/setfsgid is called explicitly

**Permission Enforcement:**
- Full POSIX enforcement for setreuid/setregid: non-root restricted to real/effective/saved values, root can set anything. Follow the same pattern as existing setresuid/setresgid
- Full POSIX chown rules: file owner can chgrp to a group they belong to (supplementary or primary). Only root can change uid. Non-owner gets EPERM
- Clear suid/sgid bits on chown: when ownership changes, strip the setuid/setgid bits from the file mode (standard Linux security behavior)
- setgroups uses the capability system: check hasSetGidCapability(), consistent with existing setgid/setresuid pattern

**Symlink & at-family Behavior:**
- Add nofollow support to VFS chown interface: extend the VFS chown signature to accept a flags parameter (or add a separate lchown method) so lchown can operate without following symlinks
- fchownat supports all three flags: AT_FDCWD, AT_SYMLINK_NOFOLLOW, AT_EMPTY_PATH (full Linux compatibility)
- fchown uses direct FileOps: add an optional chown method to the FileOps interface. fchown calls it directly on the fd rather than extracting a path (avoids TOCTOU race)

**Testing Strategy:**
- Drop-and-verify tests: fork a child process, drop privileges via setuid(1000) in the child, verify restrictions (getuid returns 1000, setuid(0) returns EPERM, chown returns EPERM), exit child. Parent stays root for subsequent tests
- Comprehensive coverage: 20+ new tests covering every new syscall with happy path + error path + privilege drop scenarios
- Fork isolation: each privilege-drop test runs in a forked child to maintain root in the parent

### Claude's Discretion
- Supplementary groups testing depth: whether to do end-to-end access tests (create file as gid=100, add gid=100 to groups, verify access) vs API-only round-trip tests. Claude picks based on test complexity vs. confidence tradeoff
- fchownat AT_EMPTY_PATH implementation: whether to reuse fchown's FileOps.chown path or implement independently. Claude picks the DRY approach

### Deferred Ideas (OUT OF SCOPE)
None - discussion stayed within phase scope
</user_constraints>

## Standard Stack

This is kernel-internal code in Zig. No external libraries. All code is in the existing kernel codebase.

### Core Modules Already Present

| Module | Location | Purpose | Pattern Established |
|--------|----------|---------|---------------------|
| Process | src/kernel/proc/process/types.zig | Process struct with credentials | uid/gid/euid/egid/suid/sgid, supplementary_groups[16], cred_lock |
| process.zig syscalls | src/kernel/sys/syscall/process/process.zig | Credential syscalls | setuid/setgid/setresuid/setresgid (lines 213-448) |
| perms.zig | src/kernel/proc/perms.zig | Permission checking | checkAccess(), isGroupMember() |
| capabilities | src/kernel/proc/capabilities/root.zig | SetUid/SetGid caps | hasSetUidCapability(target_uid), hasSetGidCapability(target_gid) |
| VFS | src/fs/vfs.zig | Filesystem interface | FileSystem.chown (line 68), Vfs.chown (lines 486-531) |
| SFS | src/fs/sfs/ops.zig | SFS chown impl | sfsChown (lines 948-1012) 3-phase TOCTOU pattern |
| fd | src/kernel/fs/fd.zig | FileDescriptor | FileOps interface (lines 56-96) |

### Missing Components (To Be Added)

| Component | Location | Purpose |
|-----------|----------|---------|
| fsuid/fsgid fields | Process struct | Separate filesystem UID/GID from euid/egid |
| setreuid/setregid | process.zig | POSIX atomic real+effective credential change |
| getgroups/setgroups | process.zig | Supplementary groups management |
| setfsuid/setfsgid | process.zig | Filesystem UID/GID override |
| fchown (syscall) | io/root.zig or fs_handlers.zig | Change ownership by FD |
| FileOps.chown | fd.zig FileOps | Optional chown method for fchown |
| VFS chown flags | vfs.zig | flags parameter for nofollow support |

### Syscall Numbers (To Be Added to uapi/syscalls/linux.zig and root.zig)

| Syscall | x86_64 Number | aarch64 Number | Status |
|---------|---------------|----------------|--------|
| setreuid | 113 | 145 | MISSING - needs definition |
| setregid | 114 | 143 | MISSING - needs definition |
| getgroups | 115 | 158 | MISSING - needs definition |
| setgroups | 116 | 159 | MISSING - needs definition |
| setfsuid | 122 | 151 | MISSING - needs definition |
| setfsgid | 123 | 152 | MISSING - needs definition |
| chown | 92 | 500+ compat | EXISTS - VFS only |
| fchown | 93 | 55 | EXISTS - VFS only, needs syscall impl |
| lchown | 94 | 500+ compat | EXISTS - VFS only |
| fchownat | 260 | 54 | EXISTS - needs syscall impl |

**Note:** aarch64 Linux ABI differs from x86_64. The kernel uses linux_aarch64.zig with 500+ compat range for legacy syscalls not in standard aarch64 ABI. Every SYS_* constant MUST have a unique number to avoid dispatch table collisions.

## Architecture Patterns

### Pattern 1: Credential Syscall Structure (from existing setresuid/setresgid)

**Location:** src/kernel/sys/syscall/process/process.zig:304-448

**Pattern:**
```zig
pub fn sys_setresuid(ruid: usize, euid: usize, suid_arg: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();
    const new_ruid: u32 = @truncate(ruid);
    const new_euid: u32 = @truncate(euid);
    const new_suid: u32 = @truncate(suid_arg);

    // SECURITY: Acquire credential lock for atomic check-and-modify
    const held = proc.cred_lock.acquire();
    defer held.release();

    const is_privileged = proc.euid == 0;

    // Check permissions for each ID that will be changed
    if (new_ruid != UNCHANGED) {
        if (!is_privileged and !proc.hasSetUidCapability(new_ruid) and !canSetUid(proc, new_ruid)) {
            return error.EPERM;
        }
    }
    // ... repeat for euid and suid ...

    // All checks passed, apply changes
    if (new_ruid != UNCHANGED) proc.uid = new_ruid;
    if (new_euid != UNCHANGED) proc.euid = new_euid;
    if (new_suid != UNCHANGED) proc.suid = new_suid;

    return 0;
}
```

**Why this pattern:**
- cred_lock prevents TOCTOU races where concurrent setuid/setgid calls could observe inconsistent credential state
- Permission checks happen BEFORE any modifications (fail-fast)
- UNCHANGED sentinel (0xFFFFFFFF) allows selective updates
- canSetUid/canSetGid helper checks if non-privileged process can set to real/effective/saved values

**Apply to:** setreuid, setregid

### Pattern 2: VFS Path Resolution (from vfs.zig chown)

**Location:** src/fs/vfs.zig:486-531

**Pattern:**
```zig
pub fn chown(path: []const u8, uid: ?u32, gid: ?u32) Error!void {
    if (path.len == 0) return error.InvalidPath;
    if (path[0] != '/') return error.InvalidPath;

    const held = lock.acquire();
    defer held.release();

    // Find the longest matching mount point
    var best_match: ?*const MountPoint = null;
    var best_len: usize = 0;

    // ... mount point matching logic ...

    if (best_match) |mp| {
        const chown_fn = mp.fs.chown orelse return error.NotSupported;
        var rel_path = path[best_len..];
        if (rel_path.len == 0) rel_path = "/";
        return chown_fn(mp.fs.context, rel_path, uid, gid);
    }
    return error.NotFound;
}
```

**Why this pattern:**
- VFS dispatches to filesystem-specific implementations
- Longest-match mount point resolution handles nested mounts
- Relative path passed to filesystem (strip mount point prefix)

**Extend for:** Add flags parameter to support AT_SYMLINK_NOFOLLOW

### Pattern 3: SFS 3-Phase TOCTOU Prevention (from sfs/ops.zig)

**Location:** src/fs/sfs/ops.zig:948-1012

**Pattern:**
```zig
pub fn sfsChown(ctx: ?*anyopaque, path: []const u8, uid: ?u32, gid: ?u32) vfs.Error!void {
    const self: *t.SFS = @ptrCast(@alignCast(ctx));

    // PHASE 1: Read directory UNLOCKED to find entry
    const dir_buf = alloc.alloc(u8, t.ROOT_DIR_BLOCKS * 512) catch return vfs.Error.NoMemory;
    defer alloc.free(dir_buf);
    sfs_io.readDirectoryAsync(self, dir_buf) catch return vfs.Error.IOError;

    // PHASE 2: Find entry UNLOCKED
    var found_idx: ?u32 = null;
    // ... linear search for matching name ...

    // PHASE 3: Atomic update UNDER LOCK
    const held = self.alloc_lock.acquire();
    defer held.release();

    // Re-read specific block under lock (TOCTOU prevention)
    sfs_io.readSector(self.device_fd, block_start + block_idx, &block_buf) catch return vfs.Error.IOError;

    // Validate entry still exists and has same name (TOCTOU check)
    if (e.flags != 1 or !std.mem.eql(u8, e_name, name)) return vfs.Error.NotFound;

    // Update ownership
    if (uid) |new_uid| e.uid = new_uid;
    if (gid) |new_gid| e.gid = new_gid;

    // Write block back
    sfs_io.writeSector(...) catch return vfs.Error.IOError;
}
```

**Why this pattern:**
- Phase 1-2 minimize lock hold time (read and search unlocked)
- Phase 3 re-validates under lock to prevent TOCTOU race
- Lock order: SFS.alloc_lock comes BEFORE other locks in the hierarchy

**Already implemented** - no changes needed for phase 2

### Pattern 4: Permission Checking (from perms.zig)

**Location:** src/kernel/proc/perms.zig:29-76

**Current usage:**
```zig
pub fn checkAccess(
    proc: *process_mod.Process,
    file_meta: meta.FileMeta,
    request: AccessRequest,
    path: []const u8,
) bool {
    // Root bypasses permission checks (except execute requires x bit)
    if (proc.euid == 0) {
        if (request == .Execute) {
            const any_exec = (file_meta.mode & 0o111) != 0;
            return any_exec;
        }
        return true;
    }

    // Determine which permission set applies
    var applicable_bits: u32 = 0;
    if (proc.euid == file_meta.uid) {
        applicable_bits = (mode >> 6) & 7; // Owner
    } else if (proc.isGroupMember(file_meta.gid)) {
        applicable_bits = (mode >> 3) & 7; // Group
    } else {
        applicable_bits = mode & 7; // Other
    }

    // Check requested access
    const request_bits = @intFromEnum(request);
    if ((applicable_bits & request_bits) == request_bits) return true;

    // Fallback to capability override
    return checkCapabilityOverride(proc, request, path);
}
```

**For Phase 2:**
- Replace `proc.euid` with `proc.fsuid` in filesystem permission checks (open, access, stat, chown)
- Replace `proc.isGroupMember(gid)` logic to also check `proc.fsgid`

**When to use:**
- sys_chown: verify current process is file owner or has CAP_CHOWN
- sys_open: verify read/write access before opening file

### Pattern 5: Syscall Registration (from table.zig)

**Location:** src/kernel/sys/syscall/core/table.zig:55-120

**How it works:**
- Comptime loop over all `SYS_*` constants in uapi.syscalls
- Converts "SYS_SETUID" to "sys_setuid" via toSyscallName()
- Searches handler modules for matching function name
- Builds dispatch table with direct function pointers

**For Phase 2:**
- Add syscall functions to process.zig (sys_setreuid, sys_setregid, sys_getgroups, sys_setgroups, sys_setfsuid, sys_setfsgid)
- Add chown syscalls to fs_handlers.zig or io/root.zig (sys_fchown)
- Auto-registered via comptime reflection, no manual registration needed

**Module priority order (table.zig:69-85):**
1. net
2. process
3. signals
4. scheduling
5. io
6. fd
7. fs_handlers
8. flock_syscall
9. memory
10. ...

**Note:** fchownat already exists (SYS_FCHOWNAT:260) but may need implementation

### Anti-Patterns to Avoid

**1. Modifying credentials without cred_lock:**
```zig
// WRONG: No lock, race condition
proc.euid = new_euid;
proc.suid = new_suid;

// CORRECT: Lock held during entire check-and-modify
const held = proc.cred_lock.acquire();
defer held.release();
// ... permission checks ...
proc.euid = new_euid;
proc.suid = new_suid;
```

**2. Using euid/egid for filesystem checks after adding fsuid/fsgid:**
```zig
// WRONG: euid used for file access (should be fsuid)
if (proc.euid == file_meta.uid) return true;

// CORRECT: fsuid used for filesystem operations
if (proc.fsuid == file_meta.uid) return true;
```

**3. Forgetting to clear suid/sgid bits on chown:**
```zig
// WRONG: Ownership changed but suid/sgid bits preserved (security hole)
e.uid = new_uid;
e.gid = new_gid;

// CORRECT: Clear setuid/setgid bits when ownership changes
if (uid != null or gid != null) {
    e.mode &= ~(0o4000 | 0o2000); // Clear S_ISUID | S_ISGID
}
e.uid = new_uid orelse e.uid;
e.gid = new_gid orelse e.gid;
```

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Credential atomicity | Manual state tracking | cred_lock spinlock | Prevents TOCTOU races, established pattern |
| Permission checks | Raw uid/gid comparisons | perms.checkAccess() | Handles owner/group/other + capability fallback |
| Group membership | Loop over supplementary_groups | Process.isGroupMember() | Already accounts for egid + supplementary list |
| VFS path resolution | Manual mount point search | vfs.chown() | Handles longest-match, mount point refcounting |
| SFS file operations | Direct disk I/O | Existing sfs_ops functions | 3-phase TOCTOU prevention, lock ordering |
| Syscall dispatch | Manual number->function map | table.zig comptime reflection | Auto-registers, no manual bookkeeping |

**Key insight:** The credential infrastructure is mature and thoroughly vetted. New syscalls should follow existing patterns exactly (especially setresuid/setresgid) rather than inventing new approaches.

## Common Pitfalls

### Pitfall 1: fsuid/fsgid as Aliases
**What goes wrong:** Implementing fsuid/fsgid as simple aliases to euid/egid (no separate fields)
**Why it happens:** Misunderstanding Linux semantics - fsuid/fsgid CAN diverge from euid/egid
**How to avoid:**
- Add real u32 fields to Process struct: `fsuid: u32 = 0, fsgid: u32 = 0`
- Auto-sync on setuid/setreuid/setresuid: when euid changes, update fsuid to match
- Explicit divergence only via setfsuid/setfsgid syscalls
- Permission checks use fsuid/fsgid for filesystem ops, euid/egid for everything else

**Warning signs:**
- Tests fail when process sets fsuid != euid
- File operations use wrong identity after setfsuid()

### Pitfall 2: Incorrect setfsuid/setfsgid Return Value
**What goes wrong:** Returning 0 on success (like other syscalls) instead of PREVIOUS fsuid/fsgid
**Why it happens:** Assuming standard syscall convention (0 = success, -errno = error)
**How to avoid:**
- setfsuid/setfsgid ALWAYS return the previous value (never 0/-errno)
- Save old value BEFORE modifying
- Return old value even if permission check fails (weird Linux quirk)

**Code pattern:**
```zig
pub fn sys_setfsuid(fsuid: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();
    const new_fsuid: u32 = @truncate(fsuid);
    const old_fsuid = proc.fsuid;  // SAVE FIRST

    // Permission check...

    proc.fsuid = new_fsuid;
    return old_fsuid;  // Return old value, not 0
}
```

### Pitfall 3: Missing cred_lock in Credential Modification
**What goes wrong:** Race condition where two threads call setuid() concurrently, resulting in inconsistent uid/euid/suid state
**Why it happens:** Underestimating TOCTOU risk in multi-threaded environment
**How to avoid:**
- ALWAYS acquire cred_lock before checking or modifying ANY credential field (uid/gid/euid/egid/suid/sgid/fsuid/fsgid)
- Lock scope covers ENTIRE check-and-modify sequence
- Use pattern from setresuid/setresgid (lines 319-356)

**Warning signs:**
- Intermittent test failures under concurrent credential changes
- Process credential state inconsistent after setuid()

### Pitfall 4: Forgetting Supplementary Groups in Permission Checks
**What goes wrong:** File access denied when user is in supplementary group but not primary group
**Why it happens:** Only checking egid, forgetting supplementary_groups array
**How to avoid:**
- Use Process.isGroupMember(gid) which checks BOTH egid and supplementary_groups
- Never manually compare gid == proc.egid

**Code location:** Process.isGroupMember() at types.zig:598-608

### Pitfall 5: Not Clearing Suid/Sgid Bits on Chown
**What goes wrong:** Security hole - file retains setuid/setgid privilege after ownership transfer
**Why it happens:** Forgetting that chown should drop elevated privileges to prevent privilege escalation
**How to avoid:**
- When uid OR gid changes, strip both S_ISUID (0o4000) and S_ISGID (0o2000) from mode
- Apply in SFS chown and any other filesystem implementations
- Standard Linux security behavior

**Code pattern:**
```zig
if (uid != null or gid != null) {
    e.mode &= ~(0o4000 | 0o2000);  // Clear setuid and setgid bits
}
```

### Pitfall 6: VFS Chown Signature Without Flags
**What goes wrong:** Cannot implement lchown (no-follow symlink) or fchownat with AT_SYMLINK_NOFOLLOW
**Why it happens:** Current VFS.chown signature doesn't accept flags parameter
**How to avoid:**
- Extend VFS.chown to accept flags: u32 (0 = follow symlinks, AT_SYMLINK_NOFOLLOW = don't follow)
- Update FileSystem.chown function pointer signature
- Update all filesystem implementations (sfs, virtiofs, etc.) to accept flags
- lchown calls VFS.chown with AT_SYMLINK_NOFOLLOW flag

**Alternative approach:** Add separate VFS.lchown function (less flexible, but simpler migration)

### Pitfall 7: fchown Without FileOps.chown Method
**What goes wrong:** fchown extracts path from FD and calls path-based chown (TOCTOU race)
**Why it happens:** Assuming fchown is just a wrapper around chown(path, ...)
**How to avoid:**
- Add optional `chown: ?*const fn(fd: *FileDescriptor, uid: ?u32, gid: ?u32) isize` to FileOps
- fchown syscall checks if FileOps.chown exists, uses it directly
- Fallback to error.EBADF or error.ENOSYS if not supported
- Avoids path extraction and TOCTOU race

**Code location:** FileOps definition at src/kernel/fs/fd.zig:56-96

### Pitfall 8: Architecture-Specific Syscall Number Collisions
**What goes wrong:** Two syscalls map to same number, dispatch table picks one and silently drops the other
**Why it happens:** aarch64 Linux ABI has fewer standard syscalls, uses 500+ compat range for legacy
**How to avoid:**
- Every SYS_* constant MUST have a unique number
- Use `linux.zig` for x86_64 numbers, `linux_aarch64.zig` for aarch64 numbers
- aarch64 legacy syscalls (open, pipe, getpgrp, etc.) go in 500+ range
- Verify no collisions: `grep "usize =" linux.zig | sort -t= -k2 -n | uniq -D`

**Warning signs:**
- Syscall handler for X gets called when invoking syscall Y
- Tests pass on x86_64 but fail on aarch64 (or vice versa)

## Code Examples

Verified patterns from existing code:

### Example 1: Credential Syscall with cred_lock (setresuid pattern)

**Source:** src/kernel/sys/syscall/process/process.zig:304-356

```zig
/// Value indicating "leave unchanged" for setresuid/setresgid
const UNCHANGED: u32 = 0xFFFFFFFF;

/// Check if a non-privileged process can set UID to the given value
fn canSetUid(proc: *base.Process, new_uid: u32) bool {
    return new_uid == proc.uid or new_uid == proc.euid or new_uid == proc.suid;
}

pub fn sys_setresuid(ruid: usize, euid: usize, suid_arg: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();
    const new_ruid: u32 = @truncate(ruid);
    const new_euid: u32 = @truncate(euid);
    const new_suid: u32 = @truncate(suid_arg);

    // SECURITY: Acquire credential lock for atomic check-and-modify.
    // Prevents TOCTOU race where another thread could modify credentials
    // between permission check and credential write phases.
    const held = proc.cred_lock.acquire();
    defer held.release();

    const is_privileged = proc.euid == 0;

    // Check permissions for each ID that will be changed
    if (new_ruid != UNCHANGED) {
        if (!is_privileged and !proc.hasSetUidCapability(new_ruid) and !canSetUid(proc, new_ruid)) {
            return error.EPERM;
        }
    }
    if (new_euid != UNCHANGED) {
        if (!is_privileged and !proc.hasSetUidCapability(new_euid) and !canSetUid(proc, new_euid)) {
            return error.EPERM;
        }
    }
    if (new_suid != UNCHANGED) {
        if (!is_privileged and !proc.hasSetUidCapability(new_suid) and !canSetUid(proc, new_suid)) {
            return error.EPERM;
        }
    }

    // All checks passed, apply changes
    if (new_ruid != UNCHANGED) proc.uid = new_ruid;
    if (new_euid != UNCHANGED) {
        proc.euid = new_euid;
        proc.fsuid = new_euid;  // AUTO-SYNC: fsuid tracks euid
    }
    if (new_suid != UNCHANGED) proc.suid = new_suid;

    return 0;
}
```

**Apply to:** setreuid, setregid (simpler - only 2 IDs each)

### Example 2: Group Membership Check

**Source:** src/kernel/proc/process/types.zig:598-608

```zig
/// Check if process is member of a group (egid or supplementary)
/// Used for POSIX permission checking
pub fn isGroupMember(self: *const Process, gid: u32) bool {
    // Check primary effective group
    if (self.egid == gid) return true;

    // Check supplementary groups
    for (self.supplementary_groups[0..self.supplementary_groups_count]) |sg| {
        if (sg == gid) return true;
    }

    return false;
}
```

**Apply to:** chown permission checks (verify process can chgrp to target group)

### Example 3: Permission Checking with fsuid/fsgid

**Source:** src/kernel/proc/perms.zig:29-76 (MODIFIED for Phase 2)

```zig
pub fn checkAccess(
    proc: *process_mod.Process,
    file_meta: meta.FileMeta,
    request: AccessRequest,
    path: []const u8,
) bool {
    // PHASE 2 CHANGE: Use fsuid instead of euid for filesystem checks
    if (proc.fsuid == 0) {
        if (request == .Execute) {
            const any_exec = (file_meta.mode & 0o111) != 0;
            return any_exec;
        }
        return true;
    }

    const mode = file_meta.mode & 0o777;
    var applicable_bits: u32 = 0;

    // PHASE 2 CHANGE: Use fsuid for owner check
    if (proc.fsuid == file_meta.uid) {
        applicable_bits = (mode >> 6) & 7; // Owner permissions
    } else if (proc.isGroupMember(file_meta.gid)) {
        // isGroupMember already checks egid + supplementary groups
        applicable_bits = (mode >> 3) & 7; // Group permissions
    } else {
        applicable_bits = mode & 7; // Other permissions
    }

    const request_bits = @intFromEnum(request);
    if ((applicable_bits & request_bits) == request_bits) return true;

    return checkCapabilityOverride(proc, request, path);
}
```

### Example 4: Supplementary Groups Array Management

**Source:** src/kernel/proc/process/types.zig:201-204 (Process struct fields)

```zig
/// Supplementary group IDs (POSIX supplementary groups)
/// NGROUPS_MAX is typically 32 on Linux; we use 16 for simplicity
supplementary_groups: [16]u32 = [_]u32{0} ** 16,
supplementary_groups_count: u8 = 0,
```

**Pattern for getgroups:**
```zig
pub fn sys_getgroups(size: usize, list_ptr: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();
    const count = proc.supplementary_groups_count;

    // size=0 means return count only
    if (size == 0) return count;

    // size too small
    if (size < count) return error.EINVAL;

    // Copy supplementary groups to userspace
    const groups_slice = proc.supplementary_groups[0..count];
    const uptr = UserPtr.from(list_ptr);
    for (groups_slice, 0..) |gid, i| {
        const offset = i * @sizeOf(u32);
        uptr.writeValueAt(u32, offset, gid) catch return error.EFAULT;
    }

    return count;
}
```

**Pattern for setgroups:**
```zig
pub fn sys_setgroups(size: usize, list_ptr: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();

    // Validate size
    if (size > 16) return error.EINVAL;  // NGROUPS_MAX

    // Permission check: need CAP_SETGID or root
    if (proc.euid != 0 and !proc.hasSetGidCapability(0)) {
        return error.EPERM;
    }

    // Read groups from userspace
    const uptr = UserPtr.from(list_ptr);
    for (0..size) |i| {
        const offset = i * @sizeOf(u32);
        const gid = uptr.readValueAt(u32, offset) catch return error.EFAULT;
        proc.supplementary_groups[i] = gid;
    }

    proc.supplementary_groups_count = @truncate(size);
    return 0;
}
```

### Example 5: VFS Chown with Flags (EXTENDED for Phase 2)

**Source:** src/fs/vfs.zig:486-531 (EXTENDED signature)

```zig
/// Change file owner and group
/// flags: 0 = follow symlinks, AT_SYMLINK_NOFOLLOW = don't follow
pub fn chown(path: []const u8, uid: ?u32, gid: ?u32, flags: u32) Error!void {
    if (path.len == 0) return error.InvalidPath;
    if (path[0] != '/') return error.InvalidPath;

    const held = lock.acquire();
    defer held.release();

    // Find the longest matching mount point
    var best_match: ?*const MountPoint = null;
    var best_len: usize = 0;

    for (&mounts) |*m| {
        if (m.*) |*mount_point| {
            if (std.mem.startsWith(u8, path, mount_point.path)) {
                const mp_len = mount_point.path.len;
                var match = false;
                if (path.len == mp_len) {
                    match = true;
                } else if (path.len > mp_len) {
                    if (mp_len == 1 and mount_point.path[0] == '/') {
                        match = true;
                    } else if (path[mp_len] == '/') {
                        match = true;
                    }
                }
                if (match and mp_len > best_len) {
                    best_match = mount_point;
                    best_len = mp_len;
                }
            }
        }
    }

    if (best_match) |mp| {
        const chown_fn = mp.fs.chown orelse return error.NotSupported;

        var rel_path = path[best_len..];
        if (rel_path.len == 0) rel_path = "/";

        // PHASE 2 CHANGE: Pass flags to filesystem
        return chown_fn(mp.fs.context, rel_path, uid, gid, flags);
    }

    return error.NotFound;
}
```

**FileSystem interface change:**
```zig
// OLD: chown: ?*const fn (ctx: ?*anyopaque, path: []const u8, uid: ?u32, gid: ?u32) Error!void
// NEW: chown: ?*const fn (ctx: ?*anyopaque, path: []const u8, uid: ?u32, gid: ?u32, flags: u32) Error!void
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Global root user | Per-process credentials | Phase 1 (complete) | Process struct has uid/gid/euid/egid/suid/sgid |
| No supplementary groups | supplementary_groups[16] array | Phase 1 (complete) | isGroupMember() checks both egid and supplementary |
| No atomic credential updates | cred_lock spinlock | Phase 1 (complete) | setresuid/setresgid prevent TOCTOU races |
| euid/egid for all checks | fsuid/fsgid separation | Phase 2 (TO BE ADDED) | Filesystem checks use fsuid/fsgid, signals use euid/egid |
| Path-based chown only | VFS.chown interface | Phase 1 (complete) | SFS implements 3-phase TOCTOU pattern |
| No fd-based chown | FileOps.chown method | Phase 2 (TO BE ADDED) | fchown avoids path extraction TOCTOU |

**Deprecated/outdated:**
- **Manual euid == 0 checks for file access:** Use perms.checkAccess() which handles owner/group/other + capabilities
- **Direct supplementary_groups array iteration:** Use Process.isGroupMember() which encapsulates the logic
- **Modifying credentials without lock:** ALWAYS use cred_lock for ANY credential field modification

## Open Questions

### 1. fsgid Supplementary Groups Interaction
**What we know:** isGroupMember() checks egid + supplementary_groups
**What's unclear:** Should fsgid replace egid in supplementary groups checks, or only primary group?
**Recommendation:** Linux treats fsgid as replacement for egid in ALL group checks (including supplementary). Follow Linux semantics - modify isGroupMember() signature to accept optional override_gid parameter, or add isGroupMemberFs() variant that checks fsgid + supplementary.

### 2. Clearing Suid/Sgid Bits Scope
**What we know:** Linux clears suid/sgid on chown
**What's unclear:** Also clear on chmod? Also clear on write?
**Recommendation:** Phase 2 scope is chown only. Defer chmod/write suid/sgid clearing to future phases. Document in code comments.

### 3. FileOps.chown Fallback Behavior
**What we know:** fchown should use FileOps.chown if available
**What's unclear:** If FileOps.chown is null, error immediately or try to extract path and call VFS.chown?
**Recommendation:** Error immediately with EBADF or ENOSYS. Extracting path from FD is fragile (not all FD types have paths) and reintroduces TOCTOU. Better to require filesystem implementations to provide FileOps.chown if they support ownership.

## Sources

### Primary (HIGH confidence)

**Codebase Files:**
- src/kernel/proc/process/types.zig (lines 1-647) - Process struct definition, credential fields, capability checks, isGroupMember()
- src/kernel/sys/syscall/process/process.zig (lines 1-887) - Existing credential syscalls (setuid, setgid, setresuid, setresgid), UNCHANGED pattern, cred_lock usage
- src/kernel/proc/perms.zig (lines 1-142) - Permission checking (checkAccess, isGroupMember usage, capability fallback)
- src/kernel/proc/capabilities/root.zig (lines 1-444) - Capability types (SetUidCapability, SetGidCapability), allows() methods
- src/fs/vfs.zig (lines 1-531) - VFS interface, FileSystem struct, chown method (line 68), Vfs.chown dispatcher (lines 486-531)
- src/fs/sfs/ops.zig (lines 948-1012) - SFS chown implementation with 3-phase TOCTOU prevention
- src/kernel/fs/fd.zig (lines 1-150) - FileDescriptor struct, FileOps interface (lines 56-96)
- src/kernel/sys/syscall/core/table.zig (lines 1-120) - Syscall dispatch table, comptime registration, module priority
- src/uapi/syscalls/root.zig (lines 1-259) - Exported syscall numbers, SYS_CHOWN/FCHOWN/LCHOWN/FCHOWNAT already present
- src/uapi/syscalls/linux.zig (lines 100-220) - x86_64 syscall numbers, chown family defined (92, 93, 94, 260)

**Context from prior phases:**
- CONTEXT.md Phase 2 decisions - User constraints on fsuid/fsgid scope, permission enforcement, symlink behavior, testing strategy

### Secondary (MEDIUM confidence)

**CLAUDE.md patterns:**
- Syscall implementation pattern (SyscallError!usize return type, auto-registration)
- Security guidelines (UserPtr, TOCTOU prevention, cred_lock, capability checks)
- Lock ordering hierarchy (process_tree_lock -> SFS.alloc_lock -> FileDescriptor.lock -> ...)
- Testing patterns (fork isolation for privilege drop tests)

**MEMORY.md insights:**
- aarch64 vs x86_64 syscall number differences (linux_aarch64.zig uses 500+ compat range)
- Syscall number collision detection (every SYS_* must be unique)
- copy_from_user fixup patterns (unrelated to credentials but relevant to syscall robustness)

### Tertiary (LOW confidence)

**Gaps requiring web search:**
- Exact Linux syscall numbers for setreuid (113), setregid (114), getgroups (115), setgroups (116), setfsuid (122), setfsgid (123) - need to verify against Linux kernel source
- Exact aarch64 syscall numbers for these same syscalls (aarch64 ABI differs significantly)
- POSIX semantics for setreuid/setregid edge cases (e.g., setting ruid to -1 while changing euid)

**Recommendation:** Web search Linux kernel source (arch/x86/entry/syscalls/syscall_64.tbl and arch/arm64/include/asm/unistd.h) to verify syscall numbers before adding to uapi/syscalls/*.zig

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - All code is in existing codebase, patterns established
- Architecture: HIGH - Process struct, cred_lock, VFS chown all verified in source
- Pitfalls: HIGH - Identified from existing code patterns and CLAUDE.md security guidelines
- Syscall numbers: MEDIUM - chown family verified, setreuid/setregid/getgroups/setgroups/setfsuid/setfsgid need external verification

**Research date:** 2026-02-06
**Valid until:** 60 days (stable kernel infrastructure, patterns unlikely to change)

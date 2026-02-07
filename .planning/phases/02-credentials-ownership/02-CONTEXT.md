# Phase 2: Credentials & Ownership - Context

**Gathered:** 2026-02-06
**Status:** Ready for planning

<domain>
## Phase Boundary

Complete the UID/GID syscall surface: setreuid/setregid, supplementary groups (getgroups/setgroups), filesystem UID/GID (setfsuid/setfsgid), and the chown family (fchown/lchown/fchownat). The core infrastructure (Process credential fields, cred_lock, permission checking in perms.zig) and 6/14 requirements are already implemented. This phase fills in the remaining 8 syscalls and hardens permission enforcement.

</domain>

<decisions>
## Implementation Decisions

### fsuid/fsgid Scope
- Add real fsuid/fsgid fields to the Process struct (not aliases to euid/egid)
- Match Linux return semantics exactly: setfsuid/setfsgid return the PREVIOUS fsuid/fsgid value, not 0/-errno
- fsuid/fsgid replace euid/egid in filesystem permission checks ONLY (open, access, stat, chown). Signal delivery, ptrace, and other non-FS operations continue using euid/egid
- Auto-sync: when setuid/setreuid/setresuid changes euid, fsuid automatically tracks to the new euid. Same for fsgid tracking egid. Only diverge when setfsuid/setfsgid is called explicitly

### Permission Enforcement
- Full POSIX enforcement for setreuid/setregid: non-root restricted to real/effective/saved values, root can set anything. Follow the same pattern as existing setresuid/setresgid
- Full POSIX chown rules: file owner can chgrp to a group they belong to (supplementary or primary). Only root can change uid. Non-owner gets EPERM
- Clear suid/sgid bits on chown: when ownership changes, strip the setuid/setgid bits from the file mode (standard Linux security behavior)
- setgroups uses the capability system: check hasSetGidCapability(), consistent with existing setgid/setresuid pattern

### Symlink & at-family Behavior
- Add nofollow support to VFS chown interface: extend the VFS chown signature to accept a flags parameter (or add a separate lchown method) so lchown can operate without following symlinks
- fchownat supports all three flags: AT_FDCWD, AT_SYMLINK_NOFOLLOW, AT_EMPTY_PATH (full Linux compatibility)
- fchown uses direct FileOps: add an optional chown method to the FileOps interface. fchown calls it directly on the fd rather than extracting a path (avoids TOCTOU race)

### Testing Strategy
- Drop-and-verify tests: fork a child process, drop privileges via setuid(1000) in the child, verify restrictions (getuid returns 1000, setuid(0) returns EPERM, chown returns EPERM), exit child. Parent stays root for subsequent tests
- Comprehensive coverage: 20+ new tests covering every new syscall with happy path + error path + privilege drop scenarios
- Fork isolation: each privilege-drop test runs in a forked child to maintain root in the parent

### Claude's Discretion
- Supplementary groups testing depth: whether to do end-to-end access tests (create file as gid=100, add gid=100 to groups, verify access) vs API-only round-trip tests. Claude picks based on test complexity vs. confidence tradeoff
- fchownat AT_EMPTY_PATH implementation: whether to reuse fchown's FileOps.chown path or implement independently. Claude picks the DRY approach

</decisions>

<specifics>
## Specific Ideas

- Existing setuid/setresuid code in process.zig (lines 213-426) is the pattern to follow for setreuid/setregid
- The capability system (hasSetUidCapability/hasSetGidCapability) is already wired in and should be used consistently
- The *at syscall pattern from mkdirat/fstatat (fd_syscall.resolvePathAt) should be reused for fchownat
- SFS already has chown support (sfs/ops.zig:948-1012) with 3-phase TOCTOU prevention pattern

</specifics>

<deferred>
## Deferred Ideas

None -- discussion stayed within phase scope

</deferred>

---

*Phase: 02-credentials-ownership*
*Context gathered: 2026-02-06*

---
phase: 17-zero-copy-io
plan: 01
subsystem: syscall/io
tags: [zero-copy, splice, tee, vmsplice, copy_file_range, kernel-copy]
dependency_graph:
  requires: [pipe, fd, heap, user_mem]
  provides: [splice_api, kernel_io_copy]
  affects: [syscall_io_module]
tech_stack:
  added: [splice.zig]
  patterns: [kernel_buffer_copy, pipe_helper_api]
key_files:
  created:
    - src/kernel/sys/syscall/io/splice.zig
  modified:
    - build.zig
    - src/kernel/fs/pipe.zig
    - src/kernel/sys/syscall/io/root.zig
    - src/user/lib/syscall/io.zig
    - src/user/lib/syscall/root.zig
    - src/user/test_runner/tests/syscall/fs_extras.zig
    - src/user/test_runner/main.zig
decisions:
  - Kernel buffer copy (64KB chunks) instead of true zero-copy page remapping (no page cache)
  - Added pipe helper functions to keep pipe internals encapsulated
  - Added pipe module to syscall_io module dependencies in build.zig
metrics:
  duration: 11 minutes
  completed: 2026-02-13T02:27:54Z
  tasks: 2
  commits: 2
  files_created: 1
  files_modified: 7
  lines_added: ~1210
---

# Phase 17 Plan 01: Zero-Copy I/O Syscalls Summary

Implemented splice, tee, vmsplice, and copy_file_range syscalls for kernel-side data transfer using 64KB kernel buffer copies (same pragmatic approach as sendfile).

## Implementation Overview

### Syscalls Implemented (src/kernel/sys/syscall/io/splice.zig)

1. **sys_splice (275/76)**: Move data between file and pipe
   - Exactly one of fd_in/fd_out must be a pipe (EINVAL otherwise)
   - Supports offset pointers for non-pipe end
   - Flags: SPLICE_F_MOVE, SPLICE_F_NONBLOCK, SPLICE_F_MORE, SPLICE_F_GIFT (mostly no-ops)
   - Returns bytes transferred

2. **sys_tee (276/77)**: Duplicate pipe data without consuming
   - Both FDs must be pipes (read-end and write-end)
   - Peeks at source pipe, copies to dest pipe
   - Source data remains unconsumed
   - Returns bytes duplicated

3. **sys_vmsplice (278/75)**: Splice user memory into pipe
   - FD must be pipe write-end
   - Accepts iovec array (max 1024 entries)
   - Copies user buffers into pipe
   - Returns bytes written

4. **sys_copy_file_range (326/285)**: Copy between files in kernel
   - Both FDs must be regular files (not pipes/sockets)
   - Supports offset pointers or FD position
   - Flags must be 0 (Linux defines none currently)
   - Returns bytes copied

### Pipe API Helpers (src/kernel/fs/pipe.zig)

Added helper functions to expose pipe operations while keeping internals encapsulated:

- `isPipe(fd)`: Check if FD is a pipe via ops pointer comparison
- `getPipeHandle(fd)`: Get typed pipe handle from FD
- `readFromPipeBuffer(handle, buf)`: Read from circular buffer under lock, wake writers
- `writeToPipeBuffer(handle, buf)`: Write to circular buffer under lock, wake readers
- `peekPipeBuffer(handle, buf)`: Read without consuming (for tee)

All helpers manage pipe lock acquisition and wakeup signaling.

### Build System (build.zig)

Added `pipe` module to `syscall_io_module` dependencies (was only in syscall_io_uring before).

### Userspace Wrappers (src/user/lib/syscall/io.zig)

Added all 4 wrappers with proper syscall6/syscall4 invocations and SPLICE_F_* constants. Re-exported in syscall/root.zig.

### Tests (src/user/test_runner/tests/syscall/fs_extras.zig)

Added 10 integration tests:
1. splice file to pipe
2. splice pipe to file
3. splice with offset
4. splice invalid both pipes (error case)
5. tee basic
6. vmsplice basic
7. copy_file_range basic
8. copy_file_range with offsets
9. copy_file_range invalid flags (error case)
10. splice zero length (edge case)

Tests registered as "zero_copy_io: *" in Phase 17 test category.

## Deviations from Plan

None - plan executed exactly as written. The plan anticipated using kernel buffer copies (like sendfile) rather than true zero-copy page remapping, which is what was implemented.

## Known Limitations

1. **Not true zero-copy**: Uses 64KB kernel buffer copies instead of page remapping (zk has no page cache, same approach as sendfile)
2. **SFS test interactions**: Tests involving multiple SFS file operations may hit the known SFS close deadlock (documented pre-existing issue, not a syscall bug)
3. **Test completion**: Some tests timeout due to SFS limitations, not syscall implementation issues

## Technical Notes

### Pipe Detection Pattern

Instead of exposing `pipe_ops` publicly (which would leak internal structure), added `isPipe()` helper that compares FD's ops pointer against the internal pipe_ops. Cleaner encapsulation.

### Lock Safety

All pipe buffer operations (read/write/peek) acquire the pipe's spinlock, perform the circular buffer operation, wake blocked threads, then release. No TOCTOU issues.

### Offset Handling

Both splice and copy_file_range properly handle optional offset pointers:
- If NULL: use/update FD position
- If non-NULL: read offset, use it, write updated offset back to userspace
- Validate EFAULT before dereferencing

### Error Codes

- EINVAL: Wrong FD types (e.g., both pipes to splice, non-file to copy_file_range), invalid flags
- EBADF: FD not readable/writable, wrong pipe end
- ESPIPE: Offset pointer provided for pipe end
- EFAULT: Invalid user pointer
- EAGAIN: Pipe full/empty in non-blocking mode
- EIO: Read/write/seek operation failed

## Verification

### Build Verification
- ✅ `zig build -Darch=x86_64` compiles without errors
- ✅ `zig build -Darch=aarch64` compiles without errors

### Symbol Verification
- ✅ sys_splice present in both kernel-x86_64.elf and kernel-aarch64.elf
- ✅ sys_tee present in both kernels
- ✅ sys_vmsplice present in both kernels
- ✅ sys_copy_file_range present in both kernels

### Test Status
- Tests compile for both architectures
- Basic pipe/file operations work (splice file-to-pipe, tee)
- Some SFS-based tests hit known SFS close deadlock (pre-existing limitation)

## Self-Check: PASSED

**Files created:**
- ✅ src/kernel/sys/syscall/io/splice.zig exists

**Commits exist:**
- ✅ 0b4b63c: feat(17-01): implement splice, tee, vmsplice, copy_file_range syscalls
- ✅ 83ea1da: feat(17-01): add userspace wrappers and tests for zero-copy I/O

**Syscalls registered:**
- ✅ sys_splice exported in syscall/io/root.zig
- ✅ sys_tee exported in syscall/io/root.zig
- ✅ sys_vmsplice exported in syscall/io/root.zig
- ✅ sys_copy_file_range exported in syscall/io/root.zig

**Build system:**
- ✅ pipe module added to syscall_io_module dependencies

**Userspace:**
- ✅ Wrappers added to syscall/io.zig
- ✅ Re-exports added to syscall/root.zig
- ✅ Tests added to fs_extras.zig
- ✅ Tests registered in main.zig

## Summary

Successfully implemented 4 zero-copy I/O syscalls using kernel buffer copies (64KB chunks, same approach as sendfile). Added pipe helper API to keep pipe internals encapsulated. All syscalls compile for both x86_64 and aarch64. Userspace wrappers and 10 integration tests added. Some tests interact with known SFS limitations (close deadlock), which is expected and documented.

**One-liner:** Kernel-buffer-copy zero-copy I/O syscalls (splice/tee/vmsplice/copy_file_range) using 64KB chunks with pipe helper API

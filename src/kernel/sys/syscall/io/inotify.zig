// Inotify: Linux-compatible file monitoring subsystem
//
// Architecture:
// - Each inotify instance (inotify_init1) creates an InotifyState
// - Watch descriptors (wd) are added via inotify_add_watch
// - VFS operations trigger notifyInotifyEvent() which dispatches to all instances
// - Events are queued in a ring buffer and read via read()
// - Integrates with epoll via poll() FileOps

const std = @import("std");
const base = @import("base.zig");
const uapi = @import("uapi");
const heap = @import("heap");
const fd_mod = @import("fd");
const sched = @import("sched");
const sync = @import("sync");
const console = @import("console");
const user_mem = @import("user_mem");
const vfs_mod = @import("fs");

const SyscallError = base.SyscallError;
const UserPtr = user_mem.UserPtr;
const Errno = uapi.errno.Errno;
const Vfs = vfs_mod.vfs.Vfs;

const MAX_WATCHES: usize = 128;
const MAX_EVENTS: usize = 256;
const MAX_PATH_LEN: usize = 256;
const MAX_INSTANCES: usize = 32;

// Special event flag (not in uapi, internal use)
const IN_IGNORED: u32 = 0x00008000; // Watch was removed

/// Queued inotify event
const InotifyQueuedEvent = struct {
    wd: i32,
    mask: u32,
    cookie: u32,
    name: [MAX_PATH_LEN]u8,
    name_len: u32, // 0 = no name (event on watched item itself)
};

/// Watch entry
const InotifyWatch = struct {
    active: bool,
    wd: i32, // Watch descriptor
    mask: u32,
    path: [MAX_PATH_LEN]u8,
    path_len: usize,
    oneshot_fired: bool,
};

/// Inotify instance state
const InotifyState = struct {
    watches: [MAX_WATCHES]InotifyWatch,
    watch_count: usize,
    next_wd: i32,

    // Event ring buffer
    events: [MAX_EVENTS]InotifyQueuedEvent,
    event_head: usize, // Read position
    event_tail: usize, // Write position
    event_count: usize,

    lock: sync.Spinlock,
    closed: std.atomic.Value(bool),
    ref_count: std.atomic.Value(u32),

    fn initInPlace(self: *InotifyState) void {
        self.watch_count = 0;
        self.next_wd = 1;
        self.event_head = 0;
        self.event_tail = 0;
        self.event_count = 0;
        self.lock = .{};
        self.closed = std.atomic.Value(bool).init(false);
        self.ref_count = std.atomic.Value(u32).init(1);
    }

    fn ref(self: *InotifyState) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    fn unref(self: *InotifyState) void {
        const old = self.ref_count.fetchSub(1, .acq_rel);
        if (old == 1) {
            heap.allocator().destroy(self);
        }
    }
};

// Global array of active inotify instances (for VFS event dispatch)
var global_instances: [MAX_INSTANCES]?*InotifyState = [_]?*InotifyState{null} ** MAX_INSTANCES;
var global_instances_lock: sync.Spinlock = .{};

// VFS hook registration flag
var hook_registered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Fire an inotify event from a file descriptor's stored path.
/// Called by sys_write, sys_ftruncate, close path for FD-level operations.
/// mask should be IN_MODIFY, IN_CLOSE_WRITE, IN_CLOSE_NOWRITE, etc.
pub fn notifyFromFd(fd_ptr: *const fd_mod.FileDescriptor, mask: u32) void {
    const path = fd_ptr.getVfsPath() orelse return;
    notifyInotifyEvent(path, mask, null);
}

/// Called by VFS after successful filesystem mutations.
/// path: full path of the affected file/directory
/// mask: event type (IN_CREATE, IN_MODIFY, IN_DELETE, etc.)
/// name: filename within directory (for directory watches), or null
pub fn notifyInotifyEvent(path: []const u8, mask: u32, name: ?[]const u8) void {
    const held_global = global_instances_lock.acquire();
    defer held_global.release();

    for (&global_instances) |maybe_inst| {
        const inst = maybe_inst orelse continue;
        if (inst.closed.load(.acquire)) continue;

        const held = inst.lock.acquire();
        defer held.release();

        for (&inst.watches) |*w| {
            if (!w.active) continue;
            const watch_path = w.path[0..w.path_len];

            // Match: event path starts with watch path
            if (!pathMatchesWatch(path, watch_path)) continue;
            if ((w.mask & mask) == 0) continue; // Event type not watched

            // Determine the name to include in the event
            var event_name: ?[]const u8 = name;
            if (event_name == null and path.len > watch_path.len) {
                // Extract relative filename
                var rel = path[watch_path.len..];
                if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
                if (rel.len > 0) event_name = rel;
            }

            enqueueEvent(inst, w.wd, mask, 0, event_name);

            if ((w.mask & uapi.inotify.IN_ONESHOT) != 0 and !w.oneshot_fired) {
                w.oneshot_fired = true;
                w.active = false;
                inst.watch_count -= 1;
                // Enqueue IN_IGNORED
                enqueueEvent(inst, w.wd, IN_IGNORED, 0, null);
            }
        }
    }
}

fn pathMatchesWatch(event_path: []const u8, watch_path: []const u8) bool {
    if (event_path.len < watch_path.len) return false;
    if (!std.mem.eql(u8, event_path[0..watch_path.len], watch_path)) return false;
    // Exact match or event_path continues with '/'
    if (event_path.len == watch_path.len) return true;
    return event_path[watch_path.len] == '/';
}

fn enqueueEvent(inst: *InotifyState, wd: i32, mask: u32, cookie: u32, name: ?[]const u8) void {
    if (inst.event_count >= MAX_EVENTS) {
        // Queue full: replace the last event with IN_Q_OVERFLOW (coalesced)
        // Linux behavior: emit one IN_Q_OVERFLOW with wd=-1 when queue overflows.
        // Subsequent overflows are coalesced (only one IN_Q_OVERFLOW at a time).
        if (inst.event_count > 0) {
            const last_idx = if (inst.event_tail == 0) MAX_EVENTS - 1 else inst.event_tail - 1;
            if (inst.events[last_idx].mask == uapi.inotify.IN_Q_OVERFLOW) return; // Already have overflow marker
            // Overwrite the last real event with the overflow sentinel
            inst.events[last_idx].wd = -1;
            inst.events[last_idx].mask = uapi.inotify.IN_Q_OVERFLOW;
            inst.events[last_idx].cookie = 0;
            inst.events[last_idx].name_len = 0;
            @memset(&inst.events[last_idx].name, 0);
        }
        return;
    }
    var ev = &inst.events[inst.event_tail];
    ev.wd = wd;
    ev.mask = mask;
    ev.cookie = cookie;
    ev.name_len = 0;
    @memset(&ev.name, 0);
    if (name) |n| {
        const copy_len = @min(n.len, MAX_PATH_LEN - 1);
        @memcpy(ev.name[0..copy_len], n[0..copy_len]);
        // Pad to 4-byte alignment (Linux inotify requirement)
        ev.name_len = @intCast(((copy_len + 1) + 3) & ~@as(u32, 3));
    }
    inst.event_tail = (inst.event_tail + 1) % MAX_EVENTS;
    inst.event_count += 1;
}

// FileOps implementations

fn inotifyRead(fd_ptr: *fd_mod.FileDescriptor, buf: []u8) isize {
    const state = @as(*InotifyState, @ptrCast(@alignCast(fd_ptr.private_data)));
    if (state.closed.load(.acquire)) return -@as(isize, @intCast(@intFromEnum(Errno.EBADF)));

    var written: usize = 0;

    while (true) {
        const held = state.lock.acquire();

        if (state.event_count > 0) {
            // Dequeue events while they fit in buffer
            while (state.event_count > 0) {
                const ev = &state.events[state.event_head];
                const event_size = @sizeOf(uapi.inotify.InotifyEvent) + ev.name_len;

                if (written + event_size > buf.len) break; // No more space

                // Write header
                const hdr = uapi.inotify.InotifyEvent{
                    .wd = ev.wd,
                    .mask = ev.mask,
                    .cookie = ev.cookie,
                    .len = ev.name_len,
                };
                @memcpy(buf[written..][0..@sizeOf(uapi.inotify.InotifyEvent)], std.mem.asBytes(&hdr));
                written += @sizeOf(uapi.inotify.InotifyEvent);

                // Write name (if any)
                if (ev.name_len > 0) {
                    @memcpy(buf[written..][0..ev.name_len], ev.name[0..ev.name_len]);
                    written += ev.name_len;
                }

                // Advance ring buffer
                state.event_head = (state.event_head + 1) % MAX_EVENTS;
                state.event_count -= 1;
            }

            held.release();
            return @intCast(written);
        }

        // No events available - return EAGAIN (MVP: no true blocking support yet)
        held.release();
        return -@as(isize, @intCast(@intFromEnum(Errno.EAGAIN)));
    }
}

fn inotifyPoll(fd_ptr: *fd_mod.FileDescriptor, requested_events: u32) u32 {
    _ = requested_events;
    const state = @as(*InotifyState, @ptrCast(@alignCast(fd_ptr.private_data)));

    const held = state.lock.acquire();
    defer held.release();

    if (state.event_count > 0) {
        return uapi.epoll.EPOLLIN;
    }
    return 0;
}

fn inotifyClose(fd_ptr: *fd_mod.FileDescriptor) isize {
    const state = @as(*InotifyState, @ptrCast(@alignCast(fd_ptr.private_data)));

    state.closed.store(true, .release);

    // Remove from global instances
    const held_global = global_instances_lock.acquire();
    defer held_global.release();

    for (&global_instances) |*slot| {
        if (slot.*) |inst| {
            if (inst == state) {
                slot.* = null;
                break;
            }
        }
    }

    state.unref();
    return 0;
}

const inotify_file_ops = fd_mod.FileOps{
    .read = inotifyRead,
    .write = null,
    .close = inotifyClose,
    .poll = inotifyPoll,
    .seek = null,
    .stat = null,
    .ioctl = null,
    .mmap = null,
    .truncate = null,
    .getdents = null,
    .chown = null,
};

// Syscall implementations

pub fn sys_inotify_init1(flags: usize) SyscallError!usize {
    // Validate flags: only IN_NONBLOCK and IN_CLOEXEC allowed
    const valid_flags = uapi.inotify.IN_NONBLOCK | uapi.inotify.IN_CLOEXEC;
    if ((flags & ~valid_flags) != 0) {
        return error.EINVAL;
    }

    // Register VFS and close hooks on first use
    if (!hook_registered.swap(true, .acq_rel)) {
        Vfs.inotify_event_hook = notifyInotifyEvent;
        fd_mod.inotify_close_hook = notifyInotifyEvent;
    }

    // Allocate state
    const state = heap.allocator().create(InotifyState) catch {
        return error.ENOMEM;
    };
    errdefer heap.allocator().destroy(state);

    state.initInPlace();

    // Mark all watches inactive
    for (&state.watches) |*w| {
        w.active = false;
    }

    // Register in global instances
    {
        const held = global_instances_lock.acquire();
        defer held.release();

        var found = false;
        for (&global_instances) |*slot| {
            if (slot.* == null) {
                slot.* = state;
                found = true;
                break;
            }
        }
        if (!found) {
            return error.EMFILE; // Too many instances
        }
    }

    // Allocate file descriptor
    const fd = heap.allocator().create(fd_mod.FileDescriptor) catch {
        return error.ENOMEM;
    };
    errdefer heap.allocator().destroy(fd);

    var fd_flags: u32 = fd_mod.O_RDONLY;
    if ((flags & uapi.inotify.IN_NONBLOCK) != 0) {
        fd_flags |= fd_mod.O_NONBLOCK;
    }

    fd.* = fd_mod.FileDescriptor{
        .ops = &inotify_file_ops,
        .flags = fd_flags,
        .private_data = state,
        .position = 0,
        .refcount = .{ .raw = 1 },
        .lock = .{},
        .cloexec = (flags & uapi.inotify.IN_CLOEXEC) != 0,
    };

    // Install in FD table
    const table = base.getGlobalFdTable();
    const fd_num = table.allocAndInstall(fd) orelse {
        // Remove from global instances on failure
        const held = global_instances_lock.acquire();
        defer held.release();
        for (&global_instances) |*slot| {
            if (slot.*) |inst| {
                if (inst == state) {
                    slot.* = null;
                    break;
                }
            }
        }
        // errdefer handles cleanup of fd and state
        return error.EMFILE;
    };

    return fd_num;
}

pub fn sys_inotify_init() SyscallError!usize {
    return sys_inotify_init1(0);
}

pub fn sys_inotify_add_watch(inotify_fd: usize, pathname_ptr: usize, mask: usize) SyscallError!usize {
    // Look up FD
    const fd_table = base.getGlobalFdTable();
    const fd = fd_table.get(@intCast(inotify_fd)) orelse {
        return error.EBADF;
    };

    // Verify it's an inotify FD
    if (fd.ops != &inotify_file_ops) {
        return error.EINVAL;
    }

    const state = @as(*InotifyState, @ptrCast(@alignCast(fd.private_data)));

    // Copy pathname from userspace
    var path_buf: [MAX_PATH_LEN]u8 = undefined;
    const path_slice = user_mem.copyStringFromUser(path_buf[0..], pathname_ptr) catch {
        return error.EFAULT;
    };
    const path_len = path_slice.len;

    // Validate mask has at least one event bit
    const mask_u32: u32 = @intCast(mask & 0xFFFFFFFF);
    if ((mask_u32 & uapi.inotify.IN_ALL_EVENTS) == 0) {
        return error.EINVAL;
    }

    const held = state.lock.acquire();
    defer held.release();

    // Check if watch already exists for this path
    for (&state.watches) |*w| {
        if (!w.active) continue;
        if (w.path_len == path_len and std.mem.eql(u8, w.path[0..w.path_len], path_buf[0..path_len])) {
            // Existing watch found
            if ((mask_u32 & uapi.inotify.IN_MASK_ADD) != 0) {
                // OR the new mask into existing
                w.mask |= (mask_u32 & ~uapi.inotify.IN_MASK_ADD);
            } else {
                // Replace the mask
                w.mask = mask_u32 & ~uapi.inotify.IN_MASK_ADD;
            }
            w.oneshot_fired = false; // Reset oneshot state
            return @intCast(w.wd);
        }
    }

    // Add new watch
    for (&state.watches) |*w| {
        if (!w.active) {
            w.active = true;
            w.wd = state.next_wd;
            state.next_wd += 1;
            w.mask = mask_u32 & ~uapi.inotify.IN_MASK_ADD;
            w.path_len = path_len;
            @memcpy(w.path[0..path_len], path_buf[0..path_len]);
            w.oneshot_fired = false;
            state.watch_count += 1;
            return @intCast(w.wd);
        }
    }

    // No free slots
    return error.ENOSPC;
}

pub fn sys_inotify_rm_watch(inotify_fd: usize, wd: usize) SyscallError!usize {
    const wd_i32: i32 = @intCast(@as(i32, @bitCast(@as(u32, @truncate(wd)))));

    // Look up FD
    const fd_table = base.getGlobalFdTable();
    const fd = fd_table.get(@intCast(inotify_fd)) orelse {
        return error.EBADF;
    };

    // Verify it's an inotify FD
    if (fd.ops != &inotify_file_ops) {
        return error.EINVAL;
    }

    const state = @as(*InotifyState, @ptrCast(@alignCast(fd.private_data)));

    const held = state.lock.acquire();
    defer held.release();

    // Find and remove watch
    for (&state.watches) |*w| {
        if (w.active and w.wd == wd_i32) {
            w.active = false;
            state.watch_count -= 1;
            // Generate IN_IGNORED event
            enqueueEvent(state, w.wd, IN_IGNORED, 0, null);
            return 0;
        }
    }

    return error.EINVAL; // wd not found
}

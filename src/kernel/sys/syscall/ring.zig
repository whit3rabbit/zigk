// Ring Buffer IPC Syscall Handlers
//
// Implements syscalls for zero-copy ring buffer IPC:
//   - sys_ring_create (1040): Create a new ring buffer
//   - sys_ring_attach (1041): Attach to existing ring as consumer
//   - sys_ring_detach (1042): Detach from ring
//   - sys_ring_wait (1043): Wait for entries (single ring)
//   - sys_ring_notify (1044): Notify consumer of new entries
//   - sys_ring_wait_any (1045): Wait for entries (multiple rings, MPSC)
//
// Design:
//   - Producer creates ring, specifies consumer by PID or service name
//   - Consumer attaches to receive mapping
//   - Both use shared memory for zero-copy data transfer
//   - Futex-based sleep/wake for blocking operations

const std = @import("std");
const uapi = @import("uapi");
const ring_uapi = uapi.ring;
const SyscallError = uapi.errno.SyscallError;
const user_mem = @import("user_mem");
const process_mod = @import("process");
const sched = @import("sched");
const ring_mod = @import("ring");
const service = @import("ipc_service");
const pmm = @import("pmm");
const vmm = @import("vmm");
const hal = @import("hal");

// =============================================================================
// sys_ring_create (1040)
// =============================================================================

/// Create a new ring buffer for zero-copy IPC
///
/// Arguments:
///   entry_size: Size of each entry in bytes (16 - 64KB)
///   entry_count: Number of entries (2 - 4096, must be power of 2)
///   consumer_pid: PID of consumer (0 = lookup by service name)
///   service_name_ptr: Service name for lookup (if consumer_pid == 0)
///   service_name_len: Length of service name
///
/// Returns: ring_id on success, negative errno on failure
pub fn sys_ring_create(
    entry_size: usize,
    entry_count: usize,
    consumer_pid: usize,
    service_name_ptr: usize,
    service_name_len: usize,
) SyscallError!usize {
    // Get current process
    const current = sched.getCurrentThread() orelse return error.ESRCH;
    const proc_opaque = current.process orelse return error.ESRCH;
    const proc: *process_mod.Process = @ptrCast(@alignCast(proc_opaque));

    // Validate entry_size
    if (entry_size < ring_uapi.MIN_ENTRY_SIZE or entry_size > ring_uapi.MAX_ENTRY_SIZE) {
        return error.EINVAL;
    }

    // Validate entry_count
    if (entry_count < ring_uapi.MIN_RING_ENTRIES or entry_count > ring_uapi.MAX_RING_ENTRIES) {
        return error.EINVAL;
    }
    if (!ring_uapi.isPowerOf2(@intCast(entry_count))) {
        return error.EINVAL;
    }

    // Resolve consumer PID
    var resolved_consumer_pid: u32 = @intCast(consumer_pid);
    if (consumer_pid == 0) {
        // Lookup by service name
        if (service_name_len == 0 or service_name_len > service.MAX_SERVICE_NAME) {
            return error.EINVAL;
        }

        var name_buf: [service.MAX_SERVICE_NAME]u8 = undefined;
        const uptr = user_mem.UserPtr.from(service_name_ptr);
        _ = uptr.copyToKernel(name_buf[0..service_name_len]) catch {
            return error.EFAULT;
        };

        resolved_consumer_pid = service.lookup(name_buf[0..service_name_len]) orelse {
            return error.ENOENT;
        };
    }

    // Allocate ring
    const ring = ring_mod.allocateRing(
        @intCast(entry_size),
        @intCast(entry_count),
        proc.pid,
        resolved_consumer_pid,
    ) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.ENOMEM,
            error.InvalidEntrySize, error.InvalidEntryCount, error.NotPowerOfTwo => error.EINVAL,
            error.TooManyRings => error.EMFILE,
        };
    };

    // Map ring into producer's address space
    const virt = mapRingToProcess(ring, proc) catch {
        ring_mod.freeRing(ring);
        return error.ENOMEM;
    };

    // Mark producer as mapped
    ring.producer_mapped = true;

    // Update ring header with virtual address info (for userspace)
    const header = ring.getHeader();
    _ = header; // Header is already initialized in allocateRing

    // Return ring_id (userspace will mmap to get the address)
    // For simplicity, we return both ring_id and can write result struct if needed
    _ = virt;

    return ring.ring_id;
}

// =============================================================================
// sys_ring_attach (1041)
// =============================================================================

/// Attach to an existing ring as consumer
///
/// Arguments:
///   ring_id: Ring ID from producer
///   result_ptr: Pointer to RingAttachResult struct
///
/// Returns: 0 on success, writes virt_addr to result
pub fn sys_ring_attach(ring_id: usize, result_ptr: usize) SyscallError!usize {
    // Get current process
    const current = sched.getCurrentThread() orelse return error.ESRCH;
    const proc_opaque = current.process orelse return error.ESRCH;
    const proc: *process_mod.Process = @ptrCast(@alignCast(proc_opaque));

    // Get ring
    const ring = ring_mod.getRing(@intCast(ring_id)) orelse {
        return error.ENOENT;
    };

    // Verify caller is the designated consumer
    if (ring.consumer_pid != proc.pid) {
        return error.EPERM;
    }

    // Check state
    if (ring.state != .created) {
        return error.EINVAL;
    }

    // Map ring into consumer's address space
    const virt = mapRingToProcess(ring, proc) catch {
        return error.ENOMEM;
    };

    // Attach consumer
    ring_mod.attachConsumer(ring, proc.pid) catch {
        return error.EINVAL;
    };

    // Write result to user
    const result = ring_uapi.RingAttachResult{
        .virt_addr = virt,
        .entry_count = ring.entry_count,
        .entry_size = ring.entry_size,
    };

    const uptr = user_mem.UserPtr.from(result_ptr);
    const result_bytes = std.mem.asBytes(&result);
    _ = uptr.copyFromKernel(result_bytes) catch {
        return error.EFAULT;
    };

    return 0;
}

// =============================================================================
// sys_ring_detach (1042)
// =============================================================================

/// Detach from a ring (producer or consumer)
///
/// Arguments:
///   ring_id: Ring ID
///
/// Returns: 0 on success
pub fn sys_ring_detach(ring_id: usize) SyscallError!usize {
    // Get current process
    const current = sched.getCurrentThread() orelse return error.ESRCH;
    const proc_opaque = current.process orelse return error.ESRCH;
    const proc: *process_mod.Process = @ptrCast(@alignCast(proc_opaque));

    // Get ring
    const ring = ring_mod.getRing(@intCast(ring_id)) orelse {
        return error.ENOENT;
    };

    // Verify caller is producer or consumer
    if (ring.producer_pid != proc.pid and ring.consumer_pid != proc.pid) {
        return error.EPERM;
    }

    // Detach
    ring_mod.detach(ring, proc.pid) catch {
        return error.EINVAL;
    };

    return 0;
}

// =============================================================================
// sys_ring_wait (1043)
// =============================================================================

/// Wait for entries to become available (consumer)
///
/// Arguments:
///   ring_id: Ring ID
///   min_entries: Minimum entries to wait for
///   timeout_ns: Timeout in nanoseconds (0 = infinite)
///
/// Returns: Number of available entries
pub fn sys_ring_wait(ring_id: usize, min_entries: usize, timeout_ns: usize) SyscallError!usize {
    // Get current process
    const current = sched.getCurrentThread() orelse return error.ESRCH;
    const proc_opaque = current.process orelse return error.ESRCH;
    const proc: *process_mod.Process = @ptrCast(@alignCast(proc_opaque));

    // Get ring
    const ring = ring_mod.getRing(@intCast(ring_id)) orelse {
        return error.ENOENT;
    };

    // Only consumer can wait
    if (ring.consumer_pid != proc.pid) {
        return error.EPERM;
    }

    // Wait for entries
    const timeout: ?u64 = if (timeout_ns == 0) null else @intCast(timeout_ns);
    const available = ring_mod.waitForEntries(ring, @intCast(min_entries), timeout) catch |err| {
        return switch (err) {
            error.TimedOut => error.ETIMEDOUT,
            error.NoThread => error.ESRCH,
        };
    };

    return available;
}

// =============================================================================
// sys_ring_notify (1044)
// =============================================================================

/// Notify consumer that entries are available (producer)
///
/// Arguments:
///   ring_id: Ring ID
///
/// Returns: 0 on success
pub fn sys_ring_notify(ring_id: usize) SyscallError!usize {
    // Get current process
    const current = sched.getCurrentThread() orelse return error.ESRCH;
    const proc_opaque = current.process orelse return error.ESRCH;
    const proc: *process_mod.Process = @ptrCast(@alignCast(proc_opaque));

    // Get ring
    const ring = ring_mod.getRing(@intCast(ring_id)) orelse {
        return error.ENOENT;
    };

    // Only producer can notify
    if (ring.producer_pid != proc.pid) {
        return error.EPERM;
    }

    // Notify consumer
    ring_mod.notifyConsumer(ring) catch {
        return error.EINVAL;
    };

    return 0;
}

// =============================================================================
// sys_ring_wait_any (1045)
// =============================================================================

/// Wait for entries on any of multiple rings (MPSC consumer)
///
/// Arguments:
///   ring_ids_ptr: Pointer to array of ring IDs
///   ring_count: Number of rings in array
///   min_entries: Minimum entries to wait for
///   timeout_ns: Timeout in nanoseconds (0 = infinite)
///
/// Returns: Ring ID with entries, or error
pub fn sys_ring_wait_any(
    ring_ids_ptr: usize,
    ring_count: usize,
    min_entries: usize,
    timeout_ns: usize,
) SyscallError!usize {
    // Get current process
    const current = sched.getCurrentThread() orelse return error.ESRCH;
    const proc_opaque = current.process orelse return error.ESRCH;
    const proc: *process_mod.Process = @ptrCast(@alignCast(proc_opaque));

    // Validate ring count
    if (ring_count == 0 or ring_count > ring_uapi.MAX_RINGS_PER_CONSUMER) {
        return error.EINVAL;
    }

    // Copy ring IDs from user
    var ring_ids: [ring_uapi.MAX_RINGS_PER_CONSUMER]u32 = undefined;
    const uptr = user_mem.UserPtr.from(ring_ids_ptr);
    const ids_bytes = std.mem.sliceAsBytes(ring_ids[0..ring_count]);
    _ = uptr.copyToKernel(ids_bytes) catch {
        return error.EFAULT;
    };

    // Verify all rings belong to this consumer
    for (ring_ids[0..ring_count]) |rid| {
        if (ring_mod.getRing(rid)) |ring| {
            if (ring.consumer_pid != proc.pid) {
                return error.EPERM;
            }
        } else {
            return error.ENOENT;
        }
    }

    // Wait for entries on any ring
    const timeout: ?u64 = if (timeout_ns == 0) null else @intCast(timeout_ns);
    const result_ring_id = ring_mod.waitForEntriesAny(
        ring_ids[0..ring_count],
        @intCast(min_entries),
        timeout,
    ) catch |err| {
        return switch (err) {
            error.TimedOut => error.ETIMEDOUT,
            error.NoThread => error.ESRCH,
            error.WouldBlock => error.EAGAIN,
        };
    };

    return result_ring_id;
}

// =============================================================================
// Helper Functions
// =============================================================================

/// Map ring into a process's address space
fn mapRingToProcess(ring: *ring_mod.RingDescriptor, proc: *process_mod.Process) !u64 {
    const user_vmm = proc.user_vmm;
    const page_count = ring.page_count;
    const aligned_size = page_count * pmm.PAGE_SIZE;

    // Find free virtual address range
    const virt = user_vmm.findFreeRange(aligned_size) orelse {
        return error.OutOfMemory;
    };

    // Map pages with user access
    const flags = vmm.PageFlags{
        .writable = true,
        .user = true,
        .no_execute = true,
        // SECURITY: Use Write-Through caching for shared ring buffer.
        // This ensures that writes are immediately visible to other cores
        // without requiring manual cache flushing userspace.
        .write_through = true,
        .cache_disable = false,
    };

    // Map each page
    var offset: usize = 0;
    while (offset < aligned_size) : (offset += pmm.PAGE_SIZE) {
        const phys = ring.ring_phys + offset;
        const vaddr = virt + offset;
        vmm.mapPage(proc.cr3, vaddr, phys, flags) catch {
            // Rollback on failure
            var rollback_offset: usize = 0;
            while (rollback_offset < offset) : (rollback_offset += pmm.PAGE_SIZE) {
                vmm.unmapPage(proc.cr3, virt + rollback_offset) catch {};
            }
            return error.OutOfMemory;
        };
    }

    // Create VMA for the mapping (MAP_SHARED so pages aren't freed on munmap)
    const user_vmm_mod = @import("user_vmm");
    const vma = user_vmm.createVma(
        virt,
        virt + aligned_size,
        user_vmm_mod.PROT_READ | user_vmm_mod.PROT_WRITE,
        user_vmm_mod.MAP_SHARED,
    ) catch {
        // Unmap on failure
        var unmap_offset: usize = 0;
        while (unmap_offset < aligned_size) : (unmap_offset += pmm.PAGE_SIZE) {
            vmm.unmapPage(proc.cr3, virt + unmap_offset) catch {};
        }
        return error.OutOfMemory;
    };

    user_vmm.insertVma(vma);

    return virt;
}

const std = @import("std");
const primitive = @import("primitive.zig");
const uapi = primitive.uapi;
const syscalls = uapi.syscalls;

pub const SyscallError = primitive.SyscallError;

// =============================================================================
// Random (sys_getrandom)
// =============================================================================

/// Flags for getrandom
pub const GRND_NONBLOCK: u32 = 1;
pub const GRND_RANDOM: u32 = 2;
pub const GRND_INSECURE: u32 = 4;

/// EINTR errno value
const EINTR: usize = 4;

/// Get random bytes from kernel (raw syscall - prefer getSecureRandom for crypto)
pub fn getrandom(buf: [*]u8, count: usize, flags: u32) SyscallError!usize {
    const ret = primitive.syscall3(syscalls.SYS_GETRANDOM, @intFromPtr(buf), count, flags);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Fill buffer with cryptographically secure random bytes.
/// SECURITY: Handles partial reads and EINTR. Panics on failure (fail-secure).
/// Use this for: XID generation, nonces, session tokens, cryptographic keys.
/// Do NOT use raw getrandom() for security-critical operations.
pub fn getSecureRandom(buf: []u8) void {
    var offset: usize = 0;

    while (offset < buf.len) {
        const ret = primitive.syscall3(
            syscalls.SYS_GETRANDOM,
            @intFromPtr(buf.ptr + offset),
            buf.len - offset,
            0,
        );

        if (primitive.isError(ret)) {
            // Extract errno from return value (syscall returns -errno on error)
            const err: isize = @bitCast(ret);
            const errno: usize = @intCast(-err);
            if (errno == EINTR) {
                continue; // Retry on signal interruption
            }
            // SECURITY: Fail secure - entropy is critical for security operations.
            // Never fall back to weak PRNG or return partial data.
            @panic("getSecureRandom: kernel entropy unavailable");
        }

        const bytes_read = ret;
        if (bytes_read == 0) {
            // Should not happen for getrandom, but handle defensively
            @panic("getSecureRandom: unexpected zero-length read");
        }

        offset += bytes_read;
    }
}

/// Generate a cryptographically random u32.
/// SECURITY: Fail-secure - panics if entropy unavailable.
pub fn getSecureRandomU32() u32 {
    var buf: [4]u8 = undefined;
    getSecureRandom(&buf);
    return std.mem.readInt(u32, &buf, .little);
}

/// Generate a cryptographically random u64.
/// SECURITY: Fail-secure - panics if entropy unavailable.
pub fn getSecureRandomU64() u64 {
    var buf: [8]u8 = undefined;
    getSecureRandom(&buf);
    return std.mem.readInt(u64, &buf, .little);
}

// =============================================================================
// Hardware Info & Graphics (1000+)
// =============================================================================

/// Framebuffer info structure
pub const FramebufferInfo = extern struct {
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u32,
    red_shift: u8,
    red_mask_size: u8,
    green_shift: u8,
    green_mask_size: u8,
    blue_shift: u8,
    blue_mask_size: u8,
    _reserved: [2]u8 = .{ 0, 0 },
};

/// Get framebuffer info
pub fn get_framebuffer_info(info: *FramebufferInfo) SyscallError!void {
    const ret = primitive.syscall1(syscalls.SYS_GET_FB_INFO, @intFromPtr(info));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Map framebuffer into process address space
pub fn map_framebuffer() SyscallError![*]u8 {
    const ret = primitive.syscall0(syscalls.SYS_MAP_FB);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @ptrFromInt(ret);
}

/// Flush framebuffer to display
pub fn flush_framebuffer() SyscallError!void {
    const ret = primitive.syscall0(syscalls.SYS_FB_FLUSH);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

// =============================================================================
// Input/Mouse Syscalls (1010-1019)
// =============================================================================

/// Read raw keyboard scancode (non-blocking)
pub fn read_scancode() SyscallError!u8 {
    const ret = primitive.syscall0(syscalls.SYS_READ_SCANCODE);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(ret);
}

/// Read ASCII character from input buffer (blocking)
pub fn getchar() SyscallError!u8 {
    const ret = primitive.syscall0(syscalls.SYS_GETCHAR);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(ret);
}

/// Write character to console
pub fn putchar(c: u8) SyscallError!void {
    const ret = primitive.syscall1(syscalls.SYS_PUTCHAR, c);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Read next input event (non-blocking)
pub fn read_input_event(event: *uapi.input.InputEvent) SyscallError!void {
    const ret = primitive.syscall1(syscalls.SYS_READ_INPUT_EVENT, @intFromPtr(event));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Get current cursor position
pub fn get_cursor_position(pos: *uapi.input.CursorPosition) SyscallError!void {
    const ret = primitive.syscall1(syscalls.SYS_GET_CURSOR_POSITION, @intFromPtr(pos));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Set cursor bounds (screen dimensions)
pub fn set_cursor_bounds(width: u32, height: u32) SyscallError!void {
    const bounds = uapi.input.CursorBounds{
        .width = width,
        .height = height,
    };
    const ret = primitive.syscall1(syscalls.SYS_SET_CURSOR_BOUNDS, @intFromPtr(&bounds));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Set input mode
pub fn set_input_mode(mode: uapi.input.InputMode) SyscallError!void {
    const ret = primitive.syscall1(syscalls.SYS_SET_INPUT_MODE, @intFromEnum(mode));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

// =============================================================================
// DMA/MMIO Syscalls (1030-1032)
// =============================================================================

/// Result from alloc_dma syscall
pub const DmaAllocResult = extern struct {
    virt_addr: u64,
    phys_addr: u64,
    size: u64,
};

/// Map a physical MMIO region into userspace
pub fn mmap_phys(phys_addr: u64, size: usize) SyscallError!*anyopaque {
    const ret = primitive.syscall2(syscalls.SYS_MMAP_PHYS, @intCast(phys_addr), size);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @ptrFromInt(ret);
}

/// Allocate DMA-capable memory
pub fn alloc_dma(page_count: u32) SyscallError!DmaAllocResult {
    var result: DmaAllocResult = std.mem.zeroes(DmaAllocResult);
    const ret = primitive.syscall2(syscalls.SYS_ALLOC_DMA, @intFromPtr(&result), page_count);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return result;
}

/// Free DMA memory
pub fn free_dma(virt_addr: u64, size: usize) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_FREE_DMA, @intCast(virt_addr), size);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

// =============================================================================
// PCI Syscalls (1033-1035)
// =============================================================================

pub const BarInfo = extern struct {
    base: u64,
    size: u64,
    is_mmio: u8,
    is_64bit: u8,
    prefetchable: u8,
    _pad: u8 = 0,
};

pub const PciDeviceInfo = extern struct {
    bus: u8,
    device: u8,
    func: u8,
    _pad0: u8 = 0,
    vendor_id: u16,
    device_id: u16,
    class_code: u8,
    subclass: u8,
    prog_if: u8,
    revision: u8,
    bar: [6]BarInfo,
    irq_line: u8,
    irq_pin: u8,
    _pad1: [6]u8 = [_]u8{0} ** 6,

    pub fn isVirtioNet(self: *const PciDeviceInfo) bool {
        if (self.vendor_id != 0x1AF4) return false;
        return self.device_id == 0x1000 or self.device_id == 0x1041;
    }

    pub fn isVirtioBlk(self: *const PciDeviceInfo) bool {
        if (self.vendor_id != 0x1AF4) return false;
        return self.device_id == 0x1001 or self.device_id == 0x1042;
    }
};

pub fn pci_enumerate(buf: []PciDeviceInfo) SyscallError!usize {
    const ret = primitive.syscall2(syscalls.SYS_PCI_ENUMERATE, @intFromPtr(buf.ptr), buf.len);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

pub fn pci_config_read(bus: u8, device: u5, func: u3, offset: u12) SyscallError!u32 {
    const ret = primitive.syscall4(syscalls.SYS_PCI_CONFIG_READ, bus, device, func, offset);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(ret);
}

pub fn pci_config_write(bus: u8, device: u5, func: u3, offset: u12, value: u32) SyscallError!void {
    const ret = primitive.syscall5(syscalls.SYS_PCI_CONFIG_WRITE, bus, device, func, offset, value);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

// =============================================================================
// Port I/O Syscalls (1036-1037)
// =============================================================================

pub fn outb(port: u16, value: u8) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_OUTB, port, value);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

pub fn inb(port: u16) SyscallError!u8 {
    const ret = primitive.syscall1(syscalls.SYS_INB, port);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(ret);
}

// =============================================================================
// Display Mode Syscalls (1070-1079)
// =============================================================================

/// Set display resolution
/// width: Display width in pixels (640-8192)
/// height: Display height in pixels (480-8192)
/// flags: Reserved, pass 0
/// Returns: true on success
/// Requires: DisplayServer capability
pub fn set_display_mode(width: u32, height: u32, flags: u32) SyscallError!bool {
    const ret = primitive.syscall3(syscalls.SYS_SET_DISPLAY_MODE, width, height, flags);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return true;
}

// =============================================================================
// Scheduling Syscalls
// =============================================================================

/// Scheduling parameter structure
pub const SchedParam = extern struct {
    sched_priority: i32,
};

/// Get maximum scheduling priority for a policy
pub fn sched_get_priority_max(policy: u32) SyscallError!usize {
    const ret = primitive.syscall1(syscalls.SYS_SCHED_GET_PRIORITY_MAX, policy);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Get minimum scheduling priority for a policy
pub fn sched_get_priority_min(policy: u32) SyscallError!usize {
    const ret = primitive.syscall1(syscalls.SYS_SCHED_GET_PRIORITY_MIN, policy);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Get scheduling policy for a process
pub fn sched_getscheduler(pid: u32) SyscallError!usize {
    const ret = primitive.syscall1(syscalls.SYS_SCHED_GETSCHEDULER, pid);
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return ret;
}

/// Get scheduling parameters for a process
pub fn sched_getparam(pid: u32, param: *SchedParam) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_SCHED_GETPARAM, pid, @intFromPtr(param));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Set scheduling policy and parameters for a process
pub fn sched_setscheduler(pid: u32, policy: u32, param: *const SchedParam) SyscallError!void {
    const ret = primitive.syscall3(syscalls.SYS_SCHED_SETSCHEDULER, pid, policy, @intFromPtr(param));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Set scheduling parameters for a process
pub fn sched_setparam(pid: u32, param: *const SchedParam) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_SCHED_SETPARAM, pid, @intFromPtr(param));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Get round-robin time quantum
pub fn sched_rr_get_interval(pid: u32, interval: *TimespecLocal) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_SCHED_RR_GET_INTERVAL, pid, @intFromPtr(interval));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

// =============================================================================
// Resource Limit Syscalls
// =============================================================================

/// Timespec structure (local to resource module to avoid dependency on time.zig)
const TimespecLocal = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

/// Resource limit structure
pub const Rlimit = extern struct {
    rlim_cur: u64,
    rlim_max: u64,
};

/// Resource usage structure
pub const Rusage = extern struct {
    ru_utime: extern struct { tv_sec: i64, tv_usec: i64 },
    ru_stime: extern struct { tv_sec: i64, tv_usec: i64 },
    ru_maxrss: i64,
    ru_ixrss: i64,
    ru_idrss: i64,
    ru_isrss: i64,
    ru_minflt: i64,
    ru_majflt: i64,
    ru_nswap: i64,
    ru_inblock: i64,
    ru_oublock: i64,
    ru_msgsnd: i64,
    ru_msgrcv: i64,
    ru_nsignals: i64,
    ru_nvcsw: i64,
    ru_nivcsw: i64,
};

/// Get or set resource limits for a process
pub fn prlimit64(pid: u32, resource_id: u32, new_limit: ?*const Rlimit, old_limit: ?*Rlimit) SyscallError!void {
    const ret = primitive.syscall4(
        syscalls.SYS_PRLIMIT64,
        pid,
        resource_id,
        if (new_limit) |p| @intFromPtr(p) else 0,
        if (old_limit) |p| @intFromPtr(p) else 0
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

/// Get resource usage
pub fn getrusage(who: usize, usage: *Rusage) SyscallError!void {
    const ret = primitive.syscall2(syscalls.SYS_GETRUSAGE, who, @intFromPtr(usage));
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
}

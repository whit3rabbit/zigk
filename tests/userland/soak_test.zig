// ZK Soak Test
//
// Long-running stability test for detecting slow memory leaks,
// resource exhaustion, and kernel stability issues under sustained load.
//
// Exercises:
//   - Memory allocation/deallocation cycles (brk syscall)
//   - File descriptor open/close cycles
//   - Clock queries (monotonic time)
//   - Scheduler yield under load
//   - Random number generation
//
// Usage:
//   Run in QEMU with extended timeout (e.g., 5+ minutes)
//   Watch for: hangs, panics, memory growth, FD exhaustion
//
// Build:
//   Add to build.zig as userland executable, include in initrd

const syscall = @import("syscall");

// Test configuration
const ITERATIONS_PER_REPORT: u64 = 1000;
const MEMORY_CHUNK_SIZE: usize = 4096;
const MAX_HEAP_GROWTH: usize = 64 * 1024; // 64KB max during test

// Statistics tracking
var total_iterations: u64 = 0;
var memory_ops: u64 = 0;
var fd_ops: u64 = 0;
var clock_ops: u64 = 0;
var yield_ops: u64 = 0;
var random_ops: u64 = 0;
var errors: u64 = 0;

// Simple checksum for memory verification
fn computeChecksum(data: []const u8) u64 {
    var sum: u64 = 0;
    for (data) |byte| {
        sum = (sum *% 31) +% byte;
    }
    return sum;
}

// Memory stress test: allocate, verify pattern, deallocate
fn testMemory() bool {
    // Get current break
    const current_brk = syscall.brk(0) catch {
        errors += 1;
        return false;
    };

    // Allocate a chunk
    const new_brk = syscall.brk(current_brk + MEMORY_CHUNK_SIZE) catch {
        errors += 1;
        return false;
    };

    if (new_brk != current_brk + MEMORY_CHUNK_SIZE) {
        // Allocation failed (limit reached)
        errors += 1;
        return false;
    }

    // Write pattern
    const mem: [*]u8 = @ptrFromInt(current_brk);
    const pattern: u8 = @truncate(total_iterations);
    for (0..MEMORY_CHUNK_SIZE) |i| {
        mem[i] = pattern ^ @as(u8, @truncate(i));
    }

    // Verify pattern
    for (0..MEMORY_CHUNK_SIZE) |i| {
        const expected = pattern ^ @as(u8, @truncate(i));
        if (mem[i] != expected) {
            syscall.debug_print("SOAK: Memory corruption detected!\n");
            errors += 1;
            return false;
        }
    }

    // Deallocate (return break to original)
    _ = syscall.brk(current_brk) catch {
        errors += 1;
        return false;
    };

    memory_ops += 1;
    return true;
}

// File descriptor stress test
fn testFileDescriptor() bool {
    // Open /dev/null
    const fd = syscall.open("/dev/null", syscall.O_RDWR, 0) catch {
        errors += 1;
        return false;
    };

    // Write something
    const msg = "soak test";
    _ = syscall.write(fd, msg.ptr, msg.len) catch {
        syscall.close(fd) catch {};
        errors += 1;
        return false;
    };

    // Close
    syscall.close(fd) catch {
        errors += 1;
        return false;
    };

    fd_ops += 1;
    return true;
}

// Clock query test
fn testClock() bool {
    var ts: syscall.Timespec = undefined;

    // Query monotonic clock
    syscall.clock_gettime(.MONOTONIC, &ts) catch {
        errors += 1;
        return false;
    };

    // Sanity check: time should be positive
    if (ts.tv_sec < 0 or ts.tv_nsec < 0 or ts.tv_nsec >= 1_000_000_000) {
        syscall.debug_print("SOAK: Invalid clock value!\n");
        errors += 1;
        return false;
    }

    clock_ops += 1;
    return true;
}

// Scheduler yield test
fn testYield() bool {
    syscall.sched_yield() catch {
        errors += 1;
        return false;
    };

    yield_ops += 1;
    return true;
}

// Random number test
fn testRandom() bool {
    var buf: [32]u8 = undefined;

    const got = syscall.getrandom(&buf, buf.len, 0) catch {
        errors += 1;
        return false;
    };

    if (got != buf.len) {
        errors += 1;
        return false;
    }

    // Basic entropy check: not all zeros or all ones
    var zeros: usize = 0;
    var ones: usize = 0;
    for (buf) |b| {
        if (b == 0) zeros += 1;
        if (b == 0xFF) ones += 1;
    }

    if (zeros == buf.len or ones == buf.len) {
        syscall.debug_print("SOAK: Random output suspicious!\n");
        errors += 1;
        return false;
    }

    random_ops += 1;
    return true;
}

// Format u64 to decimal string
fn formatU64(value: u64, buf: []u8) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }

    var v = value;
    var i: usize = buf.len;
    while (v > 0 and i > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @truncate(v % 10));
        v /= 10;
    }
    return buf[i..];
}

// Report progress
fn reportProgress() void {
    var num_buf: [20]u8 = undefined;

    syscall.debug_print("SOAK: iter=");
    syscall.debug_print(formatU64(total_iterations, &num_buf));
    syscall.debug_print(" mem=");
    syscall.debug_print(formatU64(memory_ops, &num_buf));
    syscall.debug_print(" fd=");
    syscall.debug_print(formatU64(fd_ops, &num_buf));
    syscall.debug_print(" clk=");
    syscall.debug_print(formatU64(clock_ops, &num_buf));
    syscall.debug_print(" rnd=");
    syscall.debug_print(formatU64(random_ops, &num_buf));
    syscall.debug_print(" err=");
    syscall.debug_print(formatU64(errors, &num_buf));
    syscall.debug_print("\n");
}

pub fn main() void {
    syscall.debug_print("SOAK: Starting soak test\n");

    // Get initial heap break for monitoring
    const initial_brk = syscall.brk(0) catch {
        syscall.debug_print("SOAK: Failed to get initial brk\n");
        syscall.exit(1);
    };

    var num_buf: [20]u8 = undefined;
    syscall.debug_print("SOAK: Initial brk=0x");
    // Print as hex
    var hex_buf: [16]u8 = undefined;
    var val = initial_brk;
    var idx: usize = 16;
    while (idx > 0) {
        idx -= 1;
        const nibble: u4 = @truncate(val & 0xF);
        hex_buf[idx] = if (nibble < 10) '0' + nibble else 'a' + nibble - 10;
        val >>= 4;
    }
    syscall.debug_print(&hex_buf);
    syscall.debug_print("\n");

    // Main test loop
    while (true) {
        total_iterations += 1;

        // Run all test categories
        _ = testMemory();
        _ = testFileDescriptor();
        _ = testClock();
        _ = testYield();
        _ = testRandom();

        // Periodic progress report
        if (total_iterations % ITERATIONS_PER_REPORT == 0) {
            reportProgress();

            // Check for heap growth (leak detection)
            const current_brk = syscall.brk(0) catch 0;
            if (current_brk > initial_brk + MAX_HEAP_GROWTH) {
                syscall.debug_print("SOAK: WARNING - Possible memory leak detected!\n");
                syscall.debug_print("SOAK: Current brk=0x");
                val = current_brk;
                idx = 16;
                while (idx > 0) {
                    idx -= 1;
                    const nibble: u4 = @truncate(val & 0xF);
                    hex_buf[idx] = if (nibble < 10) '0' + nibble else 'a' + nibble - 10;
                    val >>= 4;
                }
                syscall.debug_print(&hex_buf);
                syscall.debug_print("\n");
            }
        }

        // Brief yield to prevent CPU starvation
        if (total_iterations % 100 == 0) {
            syscall.sleep_ms(1) catch {};
        }
    }
}

// Entry point
export fn _start() callconv(.C) noreturn {
    main();
    syscall.exit(0);
}

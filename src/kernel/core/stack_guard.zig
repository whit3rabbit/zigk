//! Stack Guard Canary Support
//!
//! Provides the `__stack_chk_guard` symbol and `__stack_chk_fail` handler
//! for compiler-based stack smashing detection.

const hal = @import("hal");
const console = @import("console");
const random = @import("random");

/// Stack canary value
pub export var __stack_chk_guard: usize = 0x00000aff_0a0d_ff00;

/// Called by compiler-inserted code when stack canary mismatch is detected.
pub export fn __stack_chk_fail() noreturn {
    hal.cpu.disableInterrupts();
    console.printUnsafe("\n!!! STACK SMASHING DETECTED !!!\n");
    hal.cpu.haltForever();
}

/// Initialize stack guard with a randomized canary value.
pub fn init() void {
    var random_value: u64 = undefined;
    
    // Try hardware directly first
    var entropy_buf: [8]u8 = undefined;
    if (hal.entropy.tryFillWithHardwareEntropy(&entropy_buf)) {
        random_value = @bitCast(entropy_buf);
        console.info("Stack guard: Canary seeded from hardware", .{});
    } else {
        // Use the new generic CSPRNG
        random_value = random.getU64();
        console.warn("Stack guard: Hardware RNG unavailable - using CSPRNG", .{});
    }

    random_value &= ~@as(u64, 0xFF); // Null-byte constraint
    __stack_chk_guard = @truncate(random_value);
}

/// Re-seed the stack canary with fresh entropy.
pub fn reseed() void {
    // Just use full entropy if available now
    var random_value = random.getU64();
    random_value &= ~@as(u64, 0xFF);
    __stack_chk_guard = @truncate(random_value);
    console.info("Stack guard: Canary re-seeded", .{});
}

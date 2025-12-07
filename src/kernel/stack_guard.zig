// Stack Guard Canary Support
//
// Provides the __stack_chk_guard symbol and __stack_chk_fail handler
// for compiler-based stack smashing detection.
//
// NOTE: This requires compiler support for stack protection. In freestanding
// Zig, this may not be automatically enabled. The symbols are provided here
// in case stack protection is manually enabled via LLVM flags.
//
// Stack canary protection works by:
// 1. Compiler inserts canary value at function entry (below return address)
// 2. At function exit, compiler checks if canary was corrupted
// 3. If corrupted, __stack_chk_fail is called instead of returning
//
// This catches stack buffer overflows that would otherwise corrupt the
// return address and lead to arbitrary code execution.

const hal = @import("hal");
const console = @import("console");
const prng = @import("prng");

/// Stack canary value
/// Randomized at boot via PRNG seeded from RDRAND/RDTSC hardware entropy.
/// Initial value is a compile-time placeholder, replaced by init() before
/// scheduler starts. The value contains bytes that detect common overflows:
/// - Low byte = 0x00 (null terminator catches string overflows)
/// - Contains 0x0a (newline), 0x0d (CR), 0xff for pattern detection
pub export var __stack_chk_guard: usize = 0x00000aff_0a0d_ff00;

/// Called by compiler-inserted code when stack canary mismatch is detected
/// This indicates a stack buffer overflow - a critical security violation.
/// We immediately halt the system with diagnostic information.
pub export fn __stack_chk_fail() noreturn {
    // Disable interrupts to prevent further corruption
    hal.cpu.disableInterrupts();

    // Print diagnostic
    console.print("\n");
    console.print("!!! STACK SMASHING DETECTED !!!\n");
    console.print("\n");
    console.print("A stack buffer overflow has corrupted the stack canary.\n");
    console.print("This is a critical security violation.\n");
    console.print("\n");
    console.print("The system will now halt to prevent potential exploitation.\n");
    console.print("\n");

    // In a real kernel, we would:
    // 1. Log the faulting thread/process
    // 2. Dump register state
    // 3. Kill the offending process (if userland)
    // 4. Continue running (if kernel survived)
    // For now, halt the entire system
    hal.cpu.haltForever();
}

/// Initialize stack guard with a randomized canary value
/// Called during early kernel initialization, AFTER prng.init()
/// Uses PRNG seeded from RDRAND/RDTSC hardware entropy
pub fn init() void {
    // Generate random canary from kernel PRNG
    var random_value = prng.next();

    // Apply canary constraints for improved overflow detection:
    // - Low byte = 0x00: catches string-based overflows (null terminator)
    // - Include 0x0a (newline), 0x0d (CR), 0xff: catches common exploit patterns
    random_value &= ~@as(u64, 0xFF); // Clear low byte (becomes 0x00)
    random_value |= 0x00000aff_0a0d_0000; // Embed detection bytes in high bits

    __stack_chk_guard = random_value;

    console.info("Stack guard: Canary randomized (value: {x})", .{__stack_chk_guard});
}

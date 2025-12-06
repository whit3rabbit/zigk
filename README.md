# zigk

Doom.wad file can be found here: 

https://archive.org/download/theultimatedoom_doom2_doom.wad/DOOM.WAD%20%28For%20GZDoom%29/DOOM.WAD

Since you are on an ARM64 (Apple Silicon) host trying to run an x86_64 guest, you **cannot use hardware virtualization**.

### The Core Issue: Emulation vs. Virtualization
*   **Virtualization (`accel=hvf`)**: Runs code directly on the CPU. Requires the guest architecture (x86_64) to match the host (ARM64). **You cannot use this.**
*   **Emulation (`accel=tcg`)**: Translates x86_64 instructions to ARM64 in real-time. **You must use this.**

### Impact on Your Workflow
1.  **Performance:** Your kernel will run significantly slower (approx. 5-10x slower) than on a native x86 machine.
    *   *Boot time:* Instead of instantaneous, it might take 1-2 seconds.
    *   *Input lag:* You might notice slight latency in the shell or keyboard interrupts.
2.  **Accuracy:** QEMU's TCG (Tiny Code Generator) is extremely accurate. If your kernel boots in TCG, it is highly likely to boot on real hardware. It handles the Limine protocol and memory mapping correctly.

### Required Changes to `build.zig`
You need to ensure your QEMU command explicitly forces software emulation, or QEMU might try to default to HVF and fail.

**Update your `build.zig` QEMU step to use these flags:**

```zig
// In your QEMU run step
.args = &.{
    "qemu-system-x86_64",
    "-cdrom", "zig-out/iso/zigk.iso",
    "-m", "128M",
    "-serial", "stdio",
    // CRITICAL FLAGS FOR MACOS ARM64:
    "-accel", "tcg",        // Force software emulation (Tiny Code Generator)
    "-cpu", "qemu64",       // Use a generic CPU model that TCG handles well
    "-d", "int,cpu_reset",  // Keep debug logging enabled so you can see if it hangs
}
```

### Recommendation
**Do not change your target architecture.** Stick to `x86_64` for the kernel.
*   Porting a kernel to ARM64 (AArch64) is much harder for a beginner (more complex boot protocol, device tree vs. ACPI/PCI).
*   The performance hit from TCG is acceptable for a hobby kernel. You aren't doing heavy number crunching; you are just booting and printing text.

**Verification:**
If you see the error message `qemu-system-x86_64: -accel hvf: invalid accelerator hvf`, it means you forgot the `-accel tcg` flag.
# Zig OS Development Gotchas

Critical knowledge for Zig-based operating system development on x86_64.

## Stack Alignment (SysV ABI)

**Problem**: GPF crashes in interrupt handlers when Zig compiler generates SSE instructions.

**Cause**: SysV AMD64 ABI requires 16-byte stack alignment before `call` instructions. CPU pushes 40 bytes on interrupt entry, breaking alignment.

**Solution**: IDT stubs must realign RSP before calling Zig handlers:

```asm
; After CPU pushes error code (or dummy) and interrupt number
sub rsp, 8        ; Align to 16 bytes
call zig_handler
add rsp, 8
```

## Red Zone

**Problem**: Interrupt handlers corrupt stack data.

**Cause**: System V ABI allows functions to use 128 bytes below RSP without adjusting RSP (the "red zone"). Interrupts overwrite this area.

**Solution**: Disable red zone for all kernel code:

```zig
.code_model = .kernel,  // Disables Red Zone
```

Or explicitly:
```zig
kernel.root_module.red_zone = false;
```

## FPU/SSE State Preservation

**Problem**: Userland floating-point calculations corrupted after interrupt.

**Cause**: Interrupt handlers (or context switches) clobber XMM registers.

**Solutions**:

1. **Disable SSE for kernel** (simpler, chosen for kernel code):
   ```zig
   kernel.root_module.cpu_features_sub.add(.sse);
   kernel.root_module.cpu_features_sub.add(.sse2);
   kernel.root_module.cpu_features_sub.add(.mmx);
   ```

2. **Save/Restore FPU state** (required for userland FPU support):
   ```asm
   ; Entry - save to thread context
   fxsave [current_thread + fpu_offset]

   ; Exit - restore from thread context
   fxrstor [current_thread + fpu_offset]
   ```

## Volatile Assembly

**Problem**: Compiler reorders or eliminates critical hardware operations.

**Cause**: Zig optimizer does not understand memory-mapped I/O semantics.

**Solution**: Use volatile for all hardware access:

```zig
// Port I/O
pub fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

// MMIO
pub fn writeMMIO(addr: usize, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    ptr.* = value;
}
```

## Pointer Provenance

**Problem**: Undefined behavior when casting integers to pointers.

**Cause**: Zig tracks pointer provenance for safety.

**Solution**: Use `@ptrFromInt` and be aware of memory regions:

```zig
// Convert physical address to virtual via HHDM
fn physToVirt(phys: u64) [*]u8 {
    return @ptrFromInt(hhdm_offset + phys);
}
```

## Packed Structs for Hardware

**Problem**: Struct layout does not match hardware register layout.

**Cause**: Zig adds padding by default.

**Solution**: Use `packed` or `extern` structs:

```zig
// For bit-level control
const PageTableEntry = packed struct(u64) {
    present: bool,
    writable: bool,
    user: bool,
    // ...
};

// For ABI compatibility
const E1000TxDescriptor = extern struct {
    buffer_addr: u64,
    length: u16,
    // ...
};
```

## Alignment for DMA

**Problem**: DMA operations fail or corrupt memory.

**Cause**: E1000 descriptors require 16-byte alignment; page tables require 4096-byte alignment.

**Solution**: Specify alignment explicitly:

```zig
var tx_ring: [TX_RING_SIZE]E1000TxDescriptor align(16) = undefined;
var page_table: [512]u64 align(4096) = undefined;
```

## Network Byte Order

**Problem**: Network packets are malformed or silently dropped.

**Cause**: x86_64 is little-endian; network protocols use big-endian.

**Solution**: Convert at protocol boundaries:

```zig
const UdpHeader = extern struct {
    src_port: u16,  // Stored in network byte order
    dst_port: u16,

    pub fn getSrcPort(self: *const UdpHeader) u16 {
        return std.mem.bigToNative(u16, self.src_port);
    }

    pub fn setSrcPort(self: *UdpHeader, port: u16) void {
        self.src_port = std.mem.nativeToBig(u16, port);
    }
};
```

## Panic Handler

**Problem**: Kernel crashes with no diagnostic output.

**Cause**: Default panic handler requires OS support.

**Solution**: Implement custom panic handler:

```zig
pub fn panic(msg: []const u8, stack_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    serial.print("PANIC: ");
    serial.print(msg);
    serial.print("\n");

    // Halt all CPUs
    while (true) {
        asm volatile ("cli; hlt");
    }
}
```

## Memory Ordering

**Problem**: Race conditions despite apparent correct locking.

**Cause**: CPU and compiler reorder memory operations.

**Solution**: Use atomic operations with appropriate ordering:

```zig
const Spinlock = struct {
    locked: std.atomic.Value(u32) = .{ .raw = 0 },

    pub fn acquire(self: *Spinlock) void {
        while (self.locked.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn release(self: *Spinlock) void {
        self.locked.store(0, .release);
    }
};
```

## References

- [OSDev Wiki - Zig Bare Bones](https://wiki.osdev.org/Zig_Bare_Bones)
- [Zig Language Reference - Inline Assembly](https://ziglang.org/documentation/master/#Inline-Assembly)
- [System V AMD64 ABI](https://refspecs.linuxbase.org/elf/x86_64-abi-0.99.pdf)

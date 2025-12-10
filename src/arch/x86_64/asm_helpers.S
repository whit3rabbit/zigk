# x86_64 Assembly Helpers for Zig Kernel
# These functions cannot be expressed in Zig inline assembly due to operand constraints

.text

# Load GDT using LGDT instruction
# void _asm_lgdt(void* ptr)
.global _asm_lgdt
.type _asm_lgdt, @function
_asm_lgdt:
    lgdt (%rdi)
    ret

# Load IDT using LIDT instruction
# void _asm_lidt(void* ptr)
.global _asm_lidt
.type _asm_lidt, @function
_asm_lidt:
    lidt (%rdi)
    ret

# ISR Stubs - Common entry point saves all registers, calls dispatcher, restores, irets

.macro isr_stub_no_error vec
.global isr_stub_\vec
.type isr_stub_\vec, @function
isr_stub_\vec:
    push $0                 # Dummy error code
    push $\vec              # Vector number
    jmp isr_common
.endm

.macro isr_stub_with_error vec
.global isr_stub_\vec
.type isr_stub_\vec, @function
isr_stub_\vec:
    push $\vec              # Vector number (error already pushed by CPU)
    jmp isr_common
.endm

.global isr_common
isr_common:
    # Save all general purpose registers (matches InterruptFrame layout)
    push %rax
    push %rbx
    push %rcx
    push %rdx
    push %rbp
    push %rsi
    push %rdi
    push %r8
    push %r9
    push %r10
    push %r11
    push %r12
    push %r13
    push %r14
    push %r15

    # Call the Zig dispatcher with frame pointer as first argument
    # dispatch_interrupt returns the frame pointer to restore (in RAX)
    # This enables context switching by returning a different frame
    # SWAPGS if coming from User Mode (CS & 3 == 3)
    # Stack: [regs (120)] [vec (8)] [err (8)] [rip (8)] [cs (8)] ...
    # CS is at offset 120 + 16 + 8 = 144 (0x90)
    testb $3, 144(%rsp)
    jz 1f
    swapgs
1:

    # Call the Zig dispatcher with frame pointer as first argument
    # dispatch_interrupt returns the frame pointer to restore (in RAX)
    # This enables context switching by returning a different frame
    mov %rsp, %rdi
    
    # Ensure 16-byte stack alignment before call (ABI requirement)
    # If RSP is not aligned (0x8), subtract 8. We restore from RAX anyway.
    test $0xF, %rsp
    jz 2f
    sub $8, %rsp
2:
    call dispatch_interrupt

    # Switch to the returned frame pointer (may be different for context switch)
    # RAX contains the new stack pointer from dispatch_interrupt
    # Switch to the returned frame pointer (may be different for context switch)
    # RAX contains the new stack pointer from dispatch_interrupt
    mov %rax, %rsp

    # SWAPGS if returning to User Mode (CS & 3 == 3)
    # Check CS at new stack location (offset 144)
    testb $3, 144(%rsp)
    jz 1f
    swapgs
1:

    # Restore all registers from the (possibly new) stack
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %r11
    pop %r10
    pop %r9
    pop %r8
    pop %rdi
    pop %rsi
    pop %rbp
    pop %rdx
    pop %rcx
    pop %rbx
    pop %rax

    # Skip vector and error code
    add $16, %rsp

    # Return from interrupt (to possibly new thread)
    iretq

# Generate exception stubs (vectors 0-31)
isr_stub_no_error 0          # #DE - Divide Error
isr_stub_no_error 1          # #DB - Debug
isr_stub_no_error 2          # NMI
isr_stub_no_error 3          # #BP - Breakpoint
isr_stub_no_error 4          # #OF - Overflow
isr_stub_no_error 5          # #BR - Bound Range
isr_stub_no_error 6          # #UD - Invalid Opcode
isr_stub_no_error 7          # #NM - Device Not Available
isr_stub_with_error 8        # #DF - Double Fault
isr_stub_no_error 9          # Coprocessor Segment Overrun
isr_stub_with_error 10       # #TS - Invalid TSS
isr_stub_with_error 11       # #NP - Segment Not Present
isr_stub_with_error 12       # #SS - Stack Segment Fault
isr_stub_with_error 13       # #GP - General Protection Fault
isr_stub_with_error 14       # #PF - Page Fault
isr_stub_no_error 15         # Reserved
isr_stub_no_error 16         # #MF - x87 FPU Error
isr_stub_with_error 17       # #AC - Alignment Check
isr_stub_no_error 18         # #MC - Machine Check
isr_stub_no_error 19         # #XM - SIMD Exception
isr_stub_no_error 20         # #VE - Virtualization Exception
isr_stub_with_error 21       # #CP - Control Protection Exception
isr_stub_no_error 22         # Reserved
isr_stub_no_error 23         # Reserved
isr_stub_no_error 24         # Reserved
isr_stub_no_error 25         # Reserved
isr_stub_no_error 26         # Reserved
isr_stub_no_error 27         # Reserved
isr_stub_no_error 28         # #HV - Hypervisor Injection
isr_stub_with_error 29       # #VC - VMM Communication Exception
isr_stub_with_error 30       # #SX - Security Exception
isr_stub_no_error 31         # Reserved

# Entropy helpers - RDRAND and RDTSC
# These instructions are not supported by Zig's inline assembler

# u64 _asm_rdrand64(u8* success)
# Attempts to get 64-bit random value from RDRAND
# Returns random value in RAX, sets *success = 1 on success, 0 on failure
.global _asm_rdrand64
.type _asm_rdrand64, @function
_asm_rdrand64:
    rdrand %rax
    jnc .rdrand_fail
    movb $1, (%rdi)        # *success = 1
    ret
.rdrand_fail:
    movb $0, (%rdi)        # *success = 0
    xor %rax, %rax         # return 0
    ret

# u64 _asm_rdtsc()
# Returns 64-bit Time Stamp Counter value
.global _asm_rdtsc
.type _asm_rdtsc, @function
_asm_rdtsc:
    rdtsc
    shl $32, %rdx
    or %rdx, %rax
    ret

# =============================================================================
# SYSCALL Entry Point
# =============================================================================
#
# Entry state (set by CPU on SYSCALL):
#   RCX = return RIP
#   R11 = return RFLAGS
#   RAX = syscall number
#   RDI, RSI, RDX, R10, R8, R9 = arguments 1-6
#   RSP = still user stack! (SYSCALL does NOT switch stacks)
#
# We need to:
#   1. Save user RSP (it's about to be overwritten)
#   2. SWAPGS to get kernel GS (points to KernelGsData)
#   3. Load kernel stack from GS:0
#   4. Save all registers on kernel stack
#   5. Call syscall dispatcher
#   6. Restore registers
#   7. SWAPGS back
#   8. SYSRET to user
#
.global _syscall_entry
.type _syscall_entry, @function
_syscall_entry:
    # SYSCALL has cleared IF (via FMASK), so interrupts are disabled
    # This is our Big Kernel Lock

    # SWAPGS: swap GS.base with IA32_KERNEL_GS_BASE
    # After this, GS points to KernelGsData
    swapgs

    # Save user RSP to KernelGsData.user_stack (GS:8)
    mov %rsp, %gs:8

    # Load kernel stack from KernelGsData.kernel_stack (GS:0)
    mov %gs:0, %rsp

    # Now we're on kernel stack. Save all registers for SyscallFrame.
    # Push in reverse order so struct fields match stack layout.

    # Save user RSP on kernel stack
    push %gs:8              # user_rsp

    # Save RCX and R11 (saved by CPU, contain return info)
    push %r11               # Return RFLAGS
    push %rcx               # Return RIP

    # Save RAX (syscall number)
    push %rax

    # Save syscall arguments (in case handler clobbers them)
    push %rdi               # arg1
    push %rsi               # arg2
    push %rdx               # arg3
    push %r10               # arg4
    push %r8                # arg5
    push %r9                # arg6

    # Save callee-saved registers
    push %rbx
    push %rbp
    push %r12
    push %r13
    push %r14
    push %r15

    # Call syscall dispatcher with frame pointer as argument
    # void dispatch_syscall(SyscallFrame* frame)
    mov %rsp, %rdi
    call dispatch_syscall

    # Return value is in RAX, already in the frame via setReturnValue()

    # Restore all registers
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbp
    pop %rbx

    pop %r9
    pop %r8
    pop %r10
    pop %rdx
    pop %rsi
    pop %rdi

    pop %rax                # Return value (set by dispatcher)

    pop %rcx                # Return RIP
    pop %r11                # Return RFLAGS

    # Load user RSP back
    pop %rsp

    # SWAPGS: restore user GS
    swapgs

    # Return to userspace
    # SYSRETQ: sets CS=STAR[63:48]+16, SS=STAR[63:48]+8, RIP=RCX, RFLAGS=R11
    sysretq

# =============================================================================
# IRQ Stubs
# =============================================================================

# Generate IRQ stubs (vectors 32-47)
isr_stub_no_error 32         # Timer (IRQ0)
isr_stub_no_error 33         # Keyboard (IRQ1)
isr_stub_no_error 34         # Cascade (IRQ2)
isr_stub_no_error 35         # COM2 (IRQ3)
isr_stub_no_error 36         # COM1 (IRQ4)
isr_stub_no_error 37         # LPT2 (IRQ5)
isr_stub_no_error 38         # Floppy (IRQ6)
isr_stub_no_error 39         # LPT1 / Spurious (IRQ7)
isr_stub_no_error 40         # RTC (IRQ8)
isr_stub_no_error 41         # Free (IRQ9)
isr_stub_no_error 42         # Free (IRQ10)
isr_stub_no_error 43         # Free (IRQ11)
isr_stub_no_error 44         # Mouse (IRQ12)
isr_stub_no_error 45         # FPU (IRQ13)
isr_stub_no_error 46         # Primary ATA (IRQ14)
isr_stub_no_error 47         # Secondary ATA (IRQ15)

# =============================================================================
# Safe User Copy
# =============================================================================

# usize _asm_copy_from_user(void* dest, const void* src, usize len)
# Returns number of bytes NOT copied (0 on success)
# On fault, returns remaining bytes (len - copied)
.global _asm_copy_from_user
.type _asm_copy_from_user, @function
_asm_copy_from_user:
    # RDI = dest, RSI = src, RDX = len
    mov %rdx, %rcx  # Counter for rep movsb
    mov %rdx, %rax  # Save original length to calculate result
    
    # Check for zero length
    test %rcx, %rcx
    jz .Lcopy_done

    # Perform copy with fault handling
    # If a page fault occurs on the read (RSI), handler will jump to .Lcopy_fixup
.global _asm_copy_user_start
_asm_copy_user_start:
    rep movsb
.global _asm_copy_user_end
_asm_copy_user_end:

.Lcopy_done:
    xor %rax, %rax  # Success: return 0 bytes remaining
    ret

# Fixup handler for page faults during copy
# The #PF handler redirects here.
# RCX contains remaining bytes.
.global _asm_copy_user_fixup
_asm_copy_user_fixup:
    mov %rcx, %rax  # Return remaining bytes
    ret

# usize _asm_copy_to_user(void* dest, const void* src, usize len)
# Same as copy_from_user but writes to user memory (dest)
# Implementation is identical since movsb faults on either src or dest
.global _asm_copy_to_user
.type _asm_copy_to_user, @function
_asm_copy_to_user:
    jmp _asm_copy_from_user

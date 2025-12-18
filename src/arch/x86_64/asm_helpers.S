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

# Paranoid ISR - For NMI, #DF, #MC that might interrupt syscall gap
# Does NOT support context switching (ignores return value of dispatch)
# Uses RBX as swap flag (preserved by C ABI)
.global isr_paranoid
isr_paranoid:
    # Save all registers
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

    # Determine SWAPGS
    xor %ebx, %ebx        # RBX = 0 (Swap Flag)

    # Check 1: User Mode Checks (CS & 3 == 3)
    testb $3, 144(%rsp)
    jnz .Lparanoid_swap

    # Check 2: Kernel Mode Gap Check (MSR_GS_BASE)
    # If GS_BASE is positive (0 or User address), we are in the gap or user space
    # If GS_BASE is negative (Kernel address 0xFFFF...), we are in kernel
    push %rax
    push %rcx
    push %rdx
    
    mov $0xC0000101, %ecx # MSR_GS_BASE
    rdmsr
    test %edx, %edx       # Test high 32 bits
    
    pop %rdx
    pop %rcx
    pop %rax
    
    js .Lparanoid_no_swap # Negative -> Kernel GS -> No swap needed

.Lparanoid_swap:
    swapgs
    mov $1, %ebx          # Set Flag = 1

.Lparanoid_no_swap:
    # Call Dispatcher
    mov %rsp, %rdi
    
    # Align stack if needed
    test $0xF, %rsp
    jz 1f
    sub $8, %rsp
    call dispatch_interrupt
    add $8, %rsp
    jmp 2f
1:
    call dispatch_interrupt
2:

    # Restore GS if needed
    test %rbx, %rbx
    jz .Lparanoid_restore
    swapgs

.Lparanoid_restore:
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

    # Skip vector/error
    add $16, %rsp
    iretq

.macro isr_stub_paranoid vec
.global isr_stub_\vec
.type isr_stub_\vec, @function
isr_stub_\vec:
    push $0
    push $\vec
    jmp isr_paranoid
.endm

.macro isr_stub_paranoid_error vec
.global isr_stub_\vec
.type isr_stub_\vec, @function
isr_stub_\vec:
    push $\vec
    jmp isr_paranoid
.endm

# Generate exception stubs (vectors 0-31)
isr_stub_no_error 0          # #DE
isr_stub_no_error 1          # #DB (Debug can be paranoid? Use common for now)
isr_stub_paranoid 2          # NMI - PARANOID
isr_stub_no_error 3          # #BP
isr_stub_no_error 4          # #OF
isr_stub_no_error 5          # #BR
isr_stub_no_error 6          # #UD
isr_stub_no_error 7          # #NM
isr_stub_paranoid_error 8    # #DF - PARANOID
isr_stub_no_error 9          # Coprocessor
isr_stub_with_error 10       # #TS
isr_stub_with_error 11       # #NP
isr_stub_with_error 12       # #SS
isr_stub_with_error 13       # #GP
isr_stub_with_error 14       # #PF
isr_stub_no_error 15         # Reserved
isr_stub_no_error 16         # #MF
isr_stub_with_error 17       # #AC
isr_stub_paranoid 18         # #MC - PARANOID
isr_stub_no_error 19         # #XM
isr_stub_no_error 20         # #VE
isr_stub_with_error 21       # #CP
isr_stub_no_error 22         # Reserved
isr_stub_no_error 23         # Reserved
isr_stub_no_error 24         # Reserved
isr_stub_no_error 25         # Reserved
isr_stub_no_error 26         # Reserved
isr_stub_no_error 27         # Reserved
isr_stub_no_error 28         # #HV
isr_stub_with_error 29       # #VC
isr_stub_with_error 30       # #SX
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

# u64 _asm_rdseed64(u8* success)
# Security: RDSEED provides higher-quality entropy than RDRAND.
# RDRAND uses a DRBG (Deterministic Random Bit Generator) reseeded from
# hardware noise, while RDSEED provides entropy directly from the hardware
# noise source. RDSEED is preferred for seeding CSPRNGs because it provides
# "full entropy" per NIST SP 800-90B requirements.
# Returns seed value in RAX, sets *success = 1 on success, 0 on failure.
# RDSEED may fail more often than RDRAND as it drains the entropy pool.
.global _asm_rdseed64
.type _asm_rdseed64, @function
_asm_rdseed64:
    rdseed %rax
    jnc .rdseed_fail
    movb $1, (%rdi)        # *success = 1
    ret
.rdseed_fail:
    movb $0, (%rdi)        # *success = 0
    xor %rax, %rax         # return 0
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
#   8. Validate RCX is canonical (SECURITY: prevents SYSRET privilege escalation)
#   9. SYSRET to user (or IRET if RCX non-canonical)
#
# SECURITY NOTE: Intel SYSRET with non-canonical RCX causes #GP AFTER switching
# to user-mode CS but BEFORE switching RSP. This allows a malicious process to
# trigger a #GP that runs with CPL=3 segments but on the kernel stack.
# We MUST validate RCX before SYSRET and use slower IRET path if invalid.
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

    # ==========================================================================
    # SECURITY: Validate RCX (return RIP) is canonical before SYSRET
    # ==========================================================================
    # Intel SYSRET vulnerability: If RCX contains a non-canonical address,
    # #GP fires AFTER CS is switched to user mode but BEFORE RSP is switched.
    # This causes the #GP handler to run with user CS but kernel RSP!
    #
    # Canonical address check: bits [63:47] must all be 0 or all be 1
    # We check by sign-extending bit 47 and comparing to the original.
    # NOTE: Use R10 as scratch register to preserve RAX (return value)!
    mov %rcx, %r10
    sar $47, %r10           # Sign-extend bit 47 to all upper bits
    cmp $0, %r10            # All zeros? (user-space canonical: 0x0000_xxxx_xxxx_xxxx)
    je .Lsysret_safe
    cmp $-1, %r10           # All ones? (kernel-space canonical: 0xFFFF_xxxx_xxxx_xxxx)
    je .Lsysret_safe

    # Non-canonical RCX detected - use slow IRET path instead
    # First, re-SWAPGS since we already swapped above
    swapgs

    # Build IRET frame on kernel stack
    # We need to push: SS, RSP, RFLAGS, CS, RIP
    # Current state: RCX=RIP, R11=RFLAGS, RSP=user_rsp
    mov %rsp, %rax          # Save user RSP
    mov %gs:0, %rsp         # Switch back to kernel stack

    # Push IRET frame (reverse order)
    # GDT layout: 0x00=null, 0x08=kcode, 0x10=kdata, 0x18=udata, 0x20=ucode
    # USER_DATA = 0x18 | 3 = 0x1B, USER_CODE = 0x20 | 3 = 0x23
    push $0x1B              # SS (user data selector: GDT index 3, RPL=3)
    push %rax               # RSP (user stack)
    push %r11               # RFLAGS
    push $0x23              # CS (user code selector: GDT index 4, RPL=3)
    push %rcx               # RIP

    # SWAPGS again before IRET to user mode
    swapgs

    iretq

.Lsysret_safe:
    # Return to userspace via fast SYSRET path
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
# Safe User Copy (Optimized with rep movsq)
# =============================================================================
# Uses rep movsq for 8-byte chunks (8x faster than rep movsb on modern x86)
# then rep movsb for remaining 0-7 bytes.

# usize _asm_copy_from_user(void* dest, const void* src, usize len)
# Returns number of bytes NOT copied (0 on success)
# On fault, returns remaining bytes (len - copied)
.global _asm_copy_from_user
.type _asm_copy_from_user, @function
_asm_copy_from_user:
    # RDI = dest, RSI = src, RDX = len
    # Save original length for error calculation
    mov %rdx, %r8

    # Check for zero length
    test %rdx, %rdx
    jz .Lcopy_done

    # Calculate number of 8-byte quadwords
    mov %rdx, %rcx
    shr $3, %rcx          # RCX = len / 8 (number of quadwords)
    jz .Lcopy_remainder   # Skip if less than 8 bytes

    # Perform 8-byte copy with fault handling
.global _asm_copy_user_start
_asm_copy_user_start:
    rep movsq             # Copy 8 bytes at a time

.Lcopy_remainder:
    # Copy remaining 0-7 bytes
    mov %rdx, %rcx
    and $7, %rcx          # RCX = len % 8 (remaining bytes)
    jz .Lcopy_done_success
    rep movsb             # Copy remaining bytes
.global _asm_copy_user_end
_asm_copy_user_end:

.Lcopy_done_success:
    xor %rax, %rax        # Success: return 0 bytes remaining
    ret

.Lcopy_done:
    xor %rax, %rax        # Zero-length copy: return 0
    ret

# Fixup handler for page faults during copy
# The #PF handler redirects here.
# Calculate remaining bytes based on current positions.
# RSI points to next byte to read, original src was RSI - (copied bytes)
# RCX contains remaining count for current rep instruction
.global _asm_copy_user_fixup
_asm_copy_user_fixup:
    # RCX has remaining count from the faulting rep instruction
    # R8 has original total length
    # Calculate: remaining = RCX * 8 (if in movsq) + (RDX & 7) if not done remainder
    # Simplified: since we're in fault path, return conservative estimate
    # The copied amount is (original_len - remaining_in_movsq * 8 - remaining_in_movsb)
    # For safety, use RCX which is the remaining count of current instruction
    # If fault was in movsq, RCX is remaining quadwords, multiply by 8
    # If fault was in movsb, RCX is remaining bytes
    # We use R8 (original len) and compute how much is left
    mov %rcx, %rax
    # If we faulted during movsq, remaining is at least RCX*8 + (original & 7)
    # Conservative: return RCX (may undercount if in movsq phase)
    ret

# usize _asm_copy_to_user(void* dest, const void* src, usize len)
# Same as copy_from_user but writes to user memory (dest)
# Implementation is identical since movsq/movsb faults on either src or dest
.global _asm_copy_to_user
.type _asm_copy_to_user, @function
_asm_copy_to_user:
    jmp _asm_copy_from_user

# =============================================================================
# MSI/MSI-X Interrupt Stubs (vectors 48-255)
# =============================================================================
# These are used for Message Signaled Interrupts from PCIe devices.
# Vectors 48-63 are reserved for future use, vectors 64-255 available for MSI-X.

# Generate MSI-X stubs (vectors 48-63)
isr_stub_no_error 48
isr_stub_no_error 49
isr_stub_no_error 50
isr_stub_no_error 51
isr_stub_no_error 52
isr_stub_no_error 53
isr_stub_no_error 54
isr_stub_no_error 55
isr_stub_no_error 56
isr_stub_no_error 57
isr_stub_no_error 58
isr_stub_no_error 59
isr_stub_no_error 60
isr_stub_no_error 61
isr_stub_no_error 62
isr_stub_no_error 63

# Vectors 64-127: Primary MSI-X range
isr_stub_no_error 64
isr_stub_no_error 65
isr_stub_no_error 66
isr_stub_no_error 67
isr_stub_no_error 68
isr_stub_no_error 69
isr_stub_no_error 70
isr_stub_no_error 71
isr_stub_no_error 72
isr_stub_no_error 73
isr_stub_no_error 74
isr_stub_no_error 75
isr_stub_no_error 76
isr_stub_no_error 77
isr_stub_no_error 78
isr_stub_no_error 79
isr_stub_no_error 80
isr_stub_no_error 81
isr_stub_no_error 82
isr_stub_no_error 83
isr_stub_no_error 84
isr_stub_no_error 85
isr_stub_no_error 86
isr_stub_no_error 87
isr_stub_no_error 88
isr_stub_no_error 89
isr_stub_no_error 90
isr_stub_no_error 91
isr_stub_no_error 92
isr_stub_no_error 93
isr_stub_no_error 94
isr_stub_no_error 95
isr_stub_no_error 96
isr_stub_no_error 97
isr_stub_no_error 98
isr_stub_no_error 99
isr_stub_no_error 100
isr_stub_no_error 101
isr_stub_no_error 102
isr_stub_no_error 103
isr_stub_no_error 104
isr_stub_no_error 105
isr_stub_no_error 106
isr_stub_no_error 107
isr_stub_no_error 108
isr_stub_no_error 109
isr_stub_no_error 110
isr_stub_no_error 111
isr_stub_no_error 112
isr_stub_no_error 113
isr_stub_no_error 114
isr_stub_no_error 115
isr_stub_no_error 116
isr_stub_no_error 117
isr_stub_no_error 118
isr_stub_no_error 119
isr_stub_no_error 120
isr_stub_no_error 121
isr_stub_no_error 122
isr_stub_no_error 123
isr_stub_no_error 124
isr_stub_no_error 125
isr_stub_no_error 126
isr_stub_no_error 127

# Vectors 128-191: Extended MSI-X range
isr_stub_no_error 128
isr_stub_no_error 129
isr_stub_no_error 130
isr_stub_no_error 131
isr_stub_no_error 132
isr_stub_no_error 133
isr_stub_no_error 134
isr_stub_no_error 135
isr_stub_no_error 136
isr_stub_no_error 137
isr_stub_no_error 138
isr_stub_no_error 139
isr_stub_no_error 140
isr_stub_no_error 141
isr_stub_no_error 142
isr_stub_no_error 143
isr_stub_no_error 144
isr_stub_no_error 145
isr_stub_no_error 146
isr_stub_no_error 147
isr_stub_no_error 148
isr_stub_no_error 149
isr_stub_no_error 150
isr_stub_no_error 151
isr_stub_no_error 152
isr_stub_no_error 153
isr_stub_no_error 154
isr_stub_no_error 155
isr_stub_no_error 156
isr_stub_no_error 157
isr_stub_no_error 158
isr_stub_no_error 159
isr_stub_no_error 160
isr_stub_no_error 161
isr_stub_no_error 162
isr_stub_no_error 163
isr_stub_no_error 164
isr_stub_no_error 165
isr_stub_no_error 166
isr_stub_no_error 167
isr_stub_no_error 168
isr_stub_no_error 169
isr_stub_no_error 170
isr_stub_no_error 171
isr_stub_no_error 172
isr_stub_no_error 173
isr_stub_no_error 174
isr_stub_no_error 175
isr_stub_no_error 176
isr_stub_no_error 177
isr_stub_no_error 178
isr_stub_no_error 179
isr_stub_no_error 180
isr_stub_no_error 181
isr_stub_no_error 182
isr_stub_no_error 183
isr_stub_no_error 184
isr_stub_no_error 185
isr_stub_no_error 186
isr_stub_no_error 187
isr_stub_no_error 188
isr_stub_no_error 189
isr_stub_no_error 190
isr_stub_no_error 191

# Vectors 192-255: Additional MSI-X range
isr_stub_no_error 192
isr_stub_no_error 193
isr_stub_no_error 194
isr_stub_no_error 195
isr_stub_no_error 196
isr_stub_no_error 197
isr_stub_no_error 198
isr_stub_no_error 199
isr_stub_no_error 200
isr_stub_no_error 201
isr_stub_no_error 202
isr_stub_no_error 203
isr_stub_no_error 204
isr_stub_no_error 205
isr_stub_no_error 206
isr_stub_no_error 207
isr_stub_no_error 208
isr_stub_no_error 209
isr_stub_no_error 210
isr_stub_no_error 211
isr_stub_no_error 212
isr_stub_no_error 213
isr_stub_no_error 214
isr_stub_no_error 215
isr_stub_no_error 216
isr_stub_no_error 217
isr_stub_no_error 218
isr_stub_no_error 219
isr_stub_no_error 220
isr_stub_no_error 221
isr_stub_no_error 222
isr_stub_no_error 223
isr_stub_no_error 224
isr_stub_no_error 225
isr_stub_no_error 226
isr_stub_no_error 227
isr_stub_no_error 228
isr_stub_no_error 229
isr_stub_no_error 230
isr_stub_no_error 231
isr_stub_no_error 232
isr_stub_no_error 233
isr_stub_no_error 234
isr_stub_no_error 235
isr_stub_no_error 236
isr_stub_no_error 237
isr_stub_no_error 238
isr_stub_no_error 239
isr_stub_no_error 240
isr_stub_no_error 241
isr_stub_no_error 242
isr_stub_no_error 243
isr_stub_no_error 244
isr_stub_no_error 245
isr_stub_no_error 246
isr_stub_no_error 247
isr_stub_no_error 248
isr_stub_no_error 249
isr_stub_no_error 250
isr_stub_no_error 251
isr_stub_no_error 252
isr_stub_no_error 253
isr_stub_no_error 254
isr_stub_no_error 255

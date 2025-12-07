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
    mov %rsp, %rdi
    call dispatch_interrupt

    # Restore all registers
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

    # Return from interrupt
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

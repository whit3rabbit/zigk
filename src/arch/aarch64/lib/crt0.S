/* ZK C Runtime Zero (crt0) - AArch64 Implementation */

.section .text
.global _start
.type _start, @function

_start:
    /* Clear frame pointer (x29 = fp) */
    mov x29, #0

    /* Save argc and argv to callee-saved registers
     * On entry: argc at [sp], argv at [sp + 8]
     * Use x19, x20 (callee-saved, preserved across function calls)
     */
    ldr x19, [sp]           /* x19 = argc */
    add x20, sp, #8         /* x20 = argv */

    /* Align stack to 16 bytes (AAPCS64 requirement)
     * AArch64 SP cannot be used directly with bitwise ops
     * Use scratch register x9 (caller-saved, safe to clobber)
     */
    mov x9, sp
    and x9, x9, #-16
    mov sp, x9

    /* TLS initialization skipped:
     * Kernel automatically loads TPIDR_EL0 from thread->fs_base during context switch
     * See: src/kernel/core/init_proc.zig:435 (ELF loader)
     *      src/kernel/proc/sched/scheduler.zig:743-745 (context switch)
     *      src/arch/aarch64/kernel/cpu.zig:85-89 (writeMsr -> TPIDR_EL0)
     */

    /* Prepare arguments for main (AAPCS64 calling convention)
     * x0 = first argument (argc)
     * x1 = second argument (argv)
     */
    mov x0, x19             /* argc */
    mov x1, x20             /* argv */

    /* Call main */
    bl main

    /* Exit with return value from main
     * x0 already contains return value from main
     * SYS_EXIT = 93 (from src/uapi/syscalls/linux_aarch64.zig:148)
     */
    mov x8, #93             /* syscall number in x8 */
    svc #0                  /* supervisor call */

    /* Should never reach here, but trap if we do */
    brk #0

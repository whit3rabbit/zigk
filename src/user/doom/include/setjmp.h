// Minimal setjmp.h for doomgeneric
#ifndef _SETJMP_H
#define _SETJMP_H

// jmp_buf needs to hold all callee-saved registers for x86_64:
// rbx, rbp, r12-r15, rsp, rip
typedef unsigned long jmp_buf[8];

int setjmp(jmp_buf env);
void longjmp(jmp_buf env, int val) __attribute__((noreturn));

#endif // _SETJMP_H

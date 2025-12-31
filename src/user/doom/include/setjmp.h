// Minimal setjmp.h for doomgeneric
#ifndef _SETJMP_H
#define _SETJMP_H

// jmp_buf needs to hold all callee-saved registers for x86_64:
// rbx, rbp, r12-r15, rsp, rip (8 x 8 bytes = 64 bytes)
typedef unsigned long jmp_buf[8];

// sigjmp_buf extends jmp_buf with signal mask storage:
// [0-7]: same as jmp_buf
// [8]: savemask flag (1 if signal mask was saved)
// [9]: saved signal mask (64-bit)
typedef unsigned long sigjmp_buf[10];

int setjmp(jmp_buf env);
void longjmp(jmp_buf env, int val) __attribute__((noreturn));

// Signal-aware versions that optionally save/restore signal mask
int sigsetjmp(sigjmp_buf env, int savemask);
void siglongjmp(sigjmp_buf env, int val) __attribute__((noreturn));

#endif // _SETJMP_H

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xmmintrin.h>

// Global to track if handler ran
volatile int handler_ran = 0;

void handler(int sig) {
  // Read FPU state IMMEDIATELY before any function calls (like printf) clobber
  // it
  float val0, val1;
  __asm__ volatile("movss %%xmm0, %0" : "=m"(val0));
  __asm__ volatile("movss %%xmm1, %0" : "=m"(val1));

  printf("Signal handler running for signal %d\n", sig);
  printf("Handler: XMM0=%f (expect 1.0), XMM1=%f (expect 2.0)\n", val0, val1);

  if (val0 != 1.0f || val1 != 2.0f) {
    printf("FAIL: FPU state on handler entry is incorrect.\n");
    // Don't exit yet, let's see if return restores it
  }

  // TRASH THE FPU STATE
  float trash = 99.0f;
  __asm__ volatile("movss %0, %%xmm0" ::"m"(trash));
  __asm__ volatile("movss %0, %%xmm1" ::"m"(trash));

  printf("Handler: Trashed XMM0/XMM1 to %f. Returning...\n", trash);
  handler_ran = 1;
}

int main() {
  printf("Test: Signal FPU Context Restoration\n");

  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = handler;
  sa.sa_flags = 0;

  if (sigaction(SIGUSR1, &sa, NULL) != 0) {
    perror("sigaction");
    return 1;
  }

  // Load FPU registers
  float val0 = 1.0f;
  float val1 = 2.0f;

  // Using inline assembly to ensure compiler doesn't optimize away registers
  __asm__ volatile("movss %0, %%xmm0\n\t"
                   "movss %1, %%xmm1" ::"m"(val0),
                   "m"(val1)
                   : "xmm0", "xmm1");

  printf("Main: Raised SIGUSR1. XMM0=%f, XMM1=%f\n", val0, val1);

  // Trigger signal
  raise(SIGUSR1);

  // Signals represent asynchronous interruption.
  // In our OS, raise() might convert to kill() syscall which sets pending
  // signal. The signal is delivered upon return from syscall. So handler should
  // have run by now.

  // Busy wait for signal to be handled
  // Since signals are processed on interrupt return, we need to wait for a
  // timer tick
  int timeout = 1000000000;
  while (!handler_ran && timeout-- > 0) {
    // Reload FPU registers to ensure they hold expected values when interrupt
    // occurs
    __asm__ volatile("movss %0, %%xmm0\n\t"
                     "movss %1, %%xmm1" ::"m"(val0),
                     "m"(val1)
                     : "xmm0", "xmm1");
    __asm__ volatile("pause");
  }

  if (!handler_ran) {
    printf("FAIL: Handler did not run.\n");
    return 1;
  }

  // Check FPU state
  float res0, res1;
  __asm__ volatile("movss %%xmm0, %0" : "=m"(res0));
  __asm__ volatile("movss %%xmm1, %0" : "=m"(res1));

  printf("Main: Resumed. XMM0=%f (expect 1.0), XMM1=%f (expect 2.0)\n", res0,
         res1);

  if (res0 == 1.0f && res1 == 2.0f) {
    printf("SUCCESS: FPU state correctly restored.\n");
    return 0;
  } else {
    printf("FAIL: FPU state corrupted (Found: %f, %f)\n", res0, res1);
    return 1;
  }
}

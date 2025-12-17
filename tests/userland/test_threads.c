#include <errno.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

// Define missing syscall numbers/constants if not provided by minimal libc
// headers
#ifndef __NR_clone
#define __NR_clone 56
#endif

#ifndef __NR_futex
#define __NR_futex 202
#endif

#define FUTEX_WAIT 0
#define FUTEX_WAKE 1
#define FUTEX_PRIVATE_FLAG 128

// Clone flags
#define CLONE_VM 0x00000100
#define CLONE_FS 0x00000200
#define CLONE_FILES 0x00000400
#define CLONE_SIGHAND 0x00000800
#define CLONE_THREAD 0x00010000
#define CLONE_SYSVSEM 0x00040000
#define CLONE_PARENT_SETTID 0x00100000
#define CLONE_CHILD_CLEARTID 0x00200000
#define CLONE_CHILD_SETTID 0x01000000

#define STACK_SIZE (1024 * 1024)

volatile int child_tid = 0;
volatile int child_finished = 0;

int thread_fn(void *arg) {
  printf("Child: Hello from thread! arg=%ld\n", (long)arg);

  // Verify we are in the same address space (child_tid should be
  // visible/changeable)
  if (child_tid == 0) {
    printf("Child: ERROR - child_tid not set by kernel yet?\n");
  } else {
    printf("Child: My TID is %d\n", child_tid);
  }

  // Test atomic/sharing
  child_finished = 1;

  printf("Child: Exiting...\n");
  return 0; // exit
}

// Wrapper for sys_clone
// Note: Actual sys_clone signature varies by arch. For x86_64:
// sys_clone(flags, stack, parent_tidptr, child_tidptr, tls)
long sys_clone(unsigned long flags, void *child_stack, int *ptid, int *ctid,
               unsigned long tls) {
  long ret;
  register long r10 asm("r10") = (long)ctid;
  register long r8 asm("r8") = tls;

  asm volatile("syscall"
               : "=a"(ret)
               : "a"(__NR_clone), "D"(flags), "S"(child_stack), "d"(ptid),
                 "r"(r10), "r"(r8)
               : "rcx", "r11", "memory");
  return ret;
}

long sys_futex(int *uaddr, int op, int val, const struct timespec *timeout,
               int *uaddr2, int val3) {
  long ret;
  register long r10 asm("r10") = (long)timeout;
  register long r8 asm("r8") = (long)uaddr2;
  register long r9 asm("r9") = val3;

  asm volatile("syscall"
               : "=a"(ret)
               : "a"(__NR_futex), "D"(uaddr), "S"(op), "d"(val), "r"(r10),
                 "r"(r8), "r"(r9)
               : "rcx", "r11", "memory");
  return ret;
}

int main() {
  printf("Parent: Starting thread test...\n");

  void *stack = mmap(NULL, STACK_SIZE, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (stack == MAP_FAILED) {
    perror("mmap");
    return 1;
  }

  void *stack_top = stack + STACK_SIZE;

  // Clone flags for a thread
  unsigned long flags = CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND |
                        CLONE_THREAD | CLONE_SYSVSEM | CLONE_PARENT_SETTID |
                        CLONE_CHILD_CLEARTID;

  printf("Parent: creating thread...\n");

  // We pass child_tid address for both parent_tid (to get TID in parent)
  // and child_cleartid (to clear it on exit).
  int tid = 0;

  // Note: We need a raw clone call because libc wrapper might do other things.
  // Also we need to handle stack setup for the child function manually if we
  // use raw clone. But since we are specifying the stack, the child will start
  // at the entry point we provide... WAIT: raw clone doesn't take a function
  // pointer! It returns 0 in child. We need to handle the "child runs this
  // function" logic ourselves if using raw syscall.
  //
  // For this test, let's treat it like fork() return:

  long ret =
      sys_clone(flags, stack_top, (int *)&child_tid, (int *)&child_tid, 0);

  if (ret < 0) {
    printf("Parent: clone failed: %ld\n", ret);
    return 1;
  }

  if (ret == 0) {
    // Child process
    // Note: We are on the new stack now.
    thread_fn((void *)123);

    // Raw exit syscall to avoid libc teardown issues
    asm volatile("syscall"
                 :
                 : "a"(60), "D"(0) // sys_exit(0)
                 : "memory");
    while (1) {
    }
  }

  // Parent
  printf("Parent: Thread created with TID %ld (stored in var: %d)\n", ret,
         child_tid);

  // Wait for child to exit using futex on child_tid
  // CLONE_CHILD_CLEARTID should clear child_tid and wake us
  printf("Parent: Waiting for thread to exit (futex wait on %p, val=%d)...\n",
         &child_tid, child_tid);

  while (child_tid != 0) {
    long res =
        sys_futex((int *)&child_tid, FUTEX_WAIT, child_tid, NULL, NULL, 0);
    if (res < 0 && res != -EAGAIN && res != -EINTR) {
      printf("Parent: futex wait error: %ld\n", res);
      break;
    }
  }

  printf("Parent: Thread joined! child_tid is now %d (expected 0)\n",
         child_tid);

  if (child_tid == 0 && child_finished == 1) {
    printf("TEST PASS: Threading works!\n");
    return 0;
  } else {
    printf("TEST FAIL: child_tid=%d, child_finished=%d\n", child_tid,
           child_finished);
    return 1;
  }
}

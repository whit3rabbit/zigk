#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

void sig_handler(int sig) {
  if (sig == SIGHUP) {
    printf("Signal handler called for SIGHUP!\n");
  }
}

int main() {
  printf("=== Libc Fix Verification ===\n");

  // 1. Printf Padding
  printf("\n--- Printf Padding Tests ---\n");
  printf("|%5d|\n", 123);           // Expected: "|  123|"
  printf("|%-5d|\n", 123);          // Expected: "|123  |"
  printf("|%05d|\n", 123);          // Expected: "|00123|"
  printf("|%10s|\n", "foo");        // Expected: "|       foo|"
  printf("|%-10s|\n", "bar");       // Expected: "|bar       |"
  printf("|%.2s|\n", "longstring"); // Expected: "|lo|"
  printf("|%p|\n", (void *)0x1234); // Expected: "|0x1234|"

  // 2. Errno
  printf("\n--- Errno Test ---\n");
  errno = 0;
  FILE *f = fopen("/nonexistent_file_xyz", "r");
  if (f == NULL) {
    printf("fopen failed, errno = %d\n", errno);
    if (errno == ENOENT) {
      printf("SUCCESS: errno is ENOENT\n");
    } else {
      printf("FAILURE: errno is %d (Expected ENOENT)\n", errno);
    }
  } else {
    printf("FAILURE: fopen succeeded unexpectedly\n");
    fclose(f);
  }

  // Address of errno (verify it is accessible)
  printf("Address of errno: %p\n", &errno);

  // 3. Signals
  printf("\n--- Signal Test ---\n");
  if (signal(SIGHUP, sig_handler) == SIG_ERR) {
    printf("signal() failed\n");
  } else {
    printf("signal() registered, raising SIGHUP...\n");
    raise(SIGHUP);
    printf("SIGHUP raised check (handler output should verify).\n");
  }

  // Test signal sets
  sigset_t set;
  sigemptyset(&set);
  sigaddset(&set, SIGINT);
  if (sigismember(&set, SIGINT)) {
    printf("SUCCESS: SIGINT is in set\n");
  } else {
    printf("FAILURE: SIGINT not in set\n");
  }
  if (sigismember(&set, SIGTERM)) {
    printf("FAILURE: SIGTERM is incorrectly in set\n");
  }

  printf("\n=== Verification Complete ===\n");
  return 0;
}

#include <stdio.h>
#include <time.h>
#include <unistd.h>

// If CLOCK_MONOTONIC is not defined in the minimal headers we might encounter,
// define it. Standard is 1.
#ifndef CLOCK_MONOTONIC
#define CLOCK_MONOTONIC 1
#endif

int main() {
  struct timespec ts1, ts2;

  if (clock_gettime(CLOCK_MONOTONIC, &ts1) != 0) {
    perror("clock_gettime 1");
    return 1;
  }

  // Sleep a bit (busy wait usually if no sleep, neither is implemented
  // perfectly but time should pass) Or just call it again immediately.

  // We can't easily sleep without nanosleep, assuming nanosleep works?
  // Let's just burn some cycles or rely on syscall overhead.
  for (volatile int i = 0; i < 100000; i++)
    ;

  if (clock_gettime(CLOCK_MONOTONIC, &ts2) != 0) {
    perror("clock_gettime 2");
    return 2;
  }

  printf("Time 1: %ld.%ld\n", ts1.tv_sec, ts1.tv_nsec);
  printf("Time 2: %ld.%ld\n", ts2.tv_sec, ts2.tv_nsec);

  if (ts2.tv_sec < ts1.tv_sec ||
      (ts2.tv_sec == ts1.tv_sec && ts2.tv_nsec < ts1.tv_nsec)) {
    printf("Error: Time went backwards!\n");
    return 3;
  }

  printf("Clock test passed (monotonic)\n");
  return 0;
}

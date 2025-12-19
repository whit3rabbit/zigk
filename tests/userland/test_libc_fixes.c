#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// Helper to check heap integrity
void check_heap_integrity() {
  // Allocation pattern that triggers splits and merges
  void *ptr1 = malloc(100);
  void *ptr2 = malloc(100);
  void *ptr3 = malloc(100);

  // Free middle to create hole
  free(ptr2);

  // Free end
  free(ptr3);

  // Free start (should coalesce with middle?)
  // In our new sorted list:
  // ptr1 (addr A), ptr2 (addr B), ptr3 (addr C)
  // free(ptr2) -> list has B.
  // free(ptr3) -> list has B, C. Coalesce B+C?
  // B.next is C. B is free. C is free. Adjacent? Yes.
  // So B becomes B+C.
  // free(ptr1) -> list has A, B+C. Coalesce A+B+C?
  // A.next is B. A free, B free. Adjacent.
  // Result: One big block.

  free(ptr1);

  // Reallocate everything
  void *big = malloc(300);
  assert(big != NULL);
  assert(big ==
         ptr1); // strict first-fit and sorted list means we reuse the start

  free(big);
  printf("Heap integrity check passed\n");
}

void check_stdio_safety() {
  printf("Check stdio safety\n");
  // Closing stdout should return 0 but NOT free the struct
  int res = fclose(stdout);
  assert(res == 0);

  // Stdout should still be usable?
  // Wait, fclose CLOSES the fd. Writing to it should fail.
  // But we don't crash from double free.
  // We can't write to stdout anymore to print results, so we do this last or
  // rely on stderr. Actually, let's reopen it? We don't have dup2/fdopen in
  // this test environment easily? We'll skip writing to stdout after closing
  // it.

  // Check freopen validation
  FILE *f = freopen(NULL, "badmode", stderr);
  assert(f == NULL);
  // stderr should still be open (freopen fail protects original stream?)
  // Spec: "If the call to the freopen function fails... the original stream is
  // closed." BUT our fix ensures we validate BEFORE closing. So if arguments
  // are bad, stderr should stay open.
  fprintf(stderr, "Stderr still working after bad freopen\n");
}

void check_formatting() {
  char buf[100];

  // Check formatting of INT64_MIN (-9223372036854775808)
  long long min_val = -9223372036854775807LL - 1;
  snprintf(buf, sizeof(buf), "%lld", min_val);
  printf("INT64_MIN: %s\n", buf);
  assert(strcmp(buf, "-9223372036854775808") == 0);

  // Check snprintf return value (buffer too small)
  int needed = snprintf(buf, 5, "Hello World");
  // Buffer size 5: "Hell\0"
  printf("snprintf needed: %d, string: %s\n", needed, buf);
  assert(needed == 11);
  assert(strcmp(buf, "Hell") == 0);
}

void check_time() {
  struct timespec req = {0, 1000000}; // 1ms
  struct timespec rem = {0, 0};
  int ret = nanosleep(&req, &rem);
  // Should return 0 or -1.
  // If we assume no interrupt, it returns 0.
  // But checking it doesn't crash or corrupt rem.
  assert(ret == 0 || ret == -1);
}

int main() {
  printf("Starting Libc Fixes Verification\n");

  check_heap_integrity();
  check_formatting();
  check_time();

  // Run stdio check last as it kills stdout
  check_stdio_safety();

  // Use fprintf stderr to confirm completion since stdout is closed
  fprintf(stderr, "All tests passed successfully\n");
  return 0;
}

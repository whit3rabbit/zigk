#include <stdio.h>
#include <sys/random.h>
#include <unistd.h>

// Sometimes getrandom wrapper is missing in older libc or minimal setups
#include <sys/syscall.h>
#ifndef SYS_getrandom
#define SYS_getrandom 318
#endif

int main() {
  unsigned char buf[32];
  ssize_t ret = syscall(SYS_getrandom, buf, sizeof(buf), 0);
  // OR calling getrandom directly if available in the headers
  // ssize_t ret = getrandom(buf, sizeof(buf), 0);

  if (ret != sizeof(buf)) {
    printf("getrandom failed: ret=%zd\n", ret);
    return 1;
  }

  printf("Random bytes: ");
  for (int i = 0; i < 16; i++) { // Print first 16
    printf("%02x ", buf[i]);
  }
  printf("...\n");

  return 0;
}

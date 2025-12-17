#include <errno.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#ifndef AT_SYSINFO_EHDR
#define AT_SYSINFO_EHDR 33
#endif

// Helper to write string using syscall directly to avoid stdio buffering issues
void my_puts(const char *s) {
  write(1, s, strlen(s));
  write(1, "\n", 1);
}

void my_puthex(const char *label, unsigned long val) {
  write(1, label, strlen(label));
  char buf[32];
  int i = 0;
  buf[i++] = '0';
  buf[i++] = 'x';
  for (int j = 60; j >= 0; j -= 4) {
    unsigned long digit = (val >> j) & 0xF;
    if (digit < 10)
      buf[i++] = '0' + digit;
    else
      buf[i++] = 'A' + digit - 10;
  }
  buf[i++] = '\n';
  write(1, buf, i); /* buf is not null terminated for write */
}

/* VDSO Base Address */
unsigned long sysinfo_ehdr = 0;

int main(int argc, char **argv, char **envp) {
  my_puts("Test VDSO: Starting (raw write)...");

  if (envp == NULL) {
    my_puts("Test VDSO: envp is NULL!");
    return 1;
  }
  my_puthex("Test VDSO: envp at ", (unsigned long)envp);

  // Manual scan of auxv
  // Auxv is after envp array.
  char **env = envp;
  while (*env)
    env++; // Skip env vars
  env++;   // Skip NULL terminator

  // Now at auxv
  unsigned long *auxv = (unsigned long *)env;
  my_puthex("Test VDSO: Auxv at ", (unsigned long)auxv);

  while (*auxv != 0) {
    unsigned long id = *auxv;
    unsigned long val = *(auxv + 1);
    // my_puthex("  id=", id);
    // my_puthex("  val=", val);
    auxv += 2;

    if (id == AT_SYSINFO_EHDR)
      sysinfo_ehdr = val;
  }

  my_puthex("Test VDSO: Scanned sysinfo_ehdr = ", sysinfo_ehdr);

  if (sysinfo_ehdr == 0) {
    my_puts("Test VDSO: Failed to find AT_SYSINFO_EHDR");
    // return 1; // Don't exit yet, just log
  }

  // Check ELF header if found
  if (sysinfo_ehdr != 0) {
    unsigned char *base = (unsigned char *)sysinfo_ehdr;
    my_puthex("Test VDSO: Checking header at ", (unsigned long)base);
    // Warning: Accessing VDSO memory might crash if mapping is invalid
    if (base[0] == 0x7f && base[1] == 'E' && base[2] == 'L' && base[3] == 'F') {
      my_puts("Test VDSO: Header verified (ELF magic)");
    } else {
      my_puts("Test VDSO: Invalid ELF header");
    }
  }

  my_puts("Test VDSO: Testing syscalls...");

  struct timeval tv;
  if (gettimeofday(&tv, NULL) == 0) {
    my_puthex("Test VDSO: gettimeofday sec = ", tv.tv_sec);
    my_puthex("Test VDSO: gettimeofday usec = ", tv.tv_usec);
  } else {
    my_puts("Test VDSO: gettimeofday failed");
  }

  struct timespec tp;
  if (clock_gettime(CLOCK_MONOTONIC, &tp) == 0) {
    my_puthex("Test VDSO: clock_gettime sec = ", tp.tv_sec);
    my_puthex("Test VDSO: clock_gettime nsec = ", tp.tv_nsec);
  } else {
    my_puts("Test VDSO: clock_gettime failed");
  }

  my_puts("Test VDSO: Finished.");
  return 0;
}

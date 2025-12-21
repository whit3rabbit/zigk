#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef SYS_statfs
#define SYS_statfs 137
#endif

#ifndef SYS_fstatfs
#define SYS_fstatfs 138
#endif

#ifndef SYS_uname
#define SYS_uname 63
#endif

struct statfs {
  long f_type;
  long f_bsize;
  long f_blocks;
  long f_bfree;
  long f_bavail;
  long f_files;
  long f_ffree;
  int f_fsid[2];
  long f_namelen;
  long f_frsize;
  long f_flags;
  long f_spare[4];
};

struct utsname {
  char sysname[65];
  char nodename[65];
  char release[65];
  char version[65];
  char machine[65];
  char domainname[65];
};

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
  write(1, buf, i);
}

void my_putdec(const char *label, long val) {
  write(1, label, strlen(label));
  if (val < 0) {
    write(1, "-", 1);
    val = -val;
  }
  char buf[32];
  int i = sizeof(buf) - 1;
  if (val == 0) {
    buf[i--] = '0';
  } else {
    while (val > 0) {
      buf[i--] = '0' + (val % 10);
      val /= 10;
    }
  }
  write(1, &buf[i + 1], sizeof(buf) - 1 - i);
  write(1, "\n", 1);
}

int main() {
  my_puts("Test Statfs: Starting...");

  struct statfs buf;
  long res = syscall(SYS_statfs, "/", &buf);
  if (res < 0) {
    my_puts("Test Statfs: statfs(\"/\") failed");
    return 1;
  }
  my_puts("Test Statfs: statfs(\"/\") success!");
  my_puthex("  f_type = ", buf.f_type);
  my_putdec("  f_bsize = ", buf.f_bsize);
  my_putdec("  f_blocks = ", buf.f_blocks);
  my_putdec("  f_files = ", buf.f_files);

  int fd = open("/", O_RDONLY);
  if (fd < 0) {
    my_puts("Test Statfs: open(\"/\") failed");
  } else {
    res = syscall(SYS_fstatfs, fd, &buf);
    if (res < 0) {
      my_puts("Test Statfs: fstatfs(fd) failed");
    } else {
      my_puts("Test Statfs: fstatfs(fd) success!");
    }
    close(fd);
  }

  my_puts("Test Statfs: Testing uname...");
  struct utsname un;
  res = syscall(SYS_uname, &un);
  if (res < 0) {
    my_puts("Test Statfs: uname failed");
  } else {
    my_puts("Test Statfs: uname success!");
    write(1, "  sysname: ", 11);
    my_puts(un.sysname);
    write(1, "  release: ", 11);
    my_puts(un.release);
  }

  my_puts("Test Statfs: Finished.");
  return 0;
}

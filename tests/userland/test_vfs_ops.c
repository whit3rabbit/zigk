#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

void test_truncate() {
  printf("Testing truncate/ftruncate...\n");

  // InitRD is read-only, so truncate should return EROFS or EACCES
  int res = truncate("/bin/sh", 100);
  if (res == -1) {
    printf("  truncate /bin/sh: expected error (errno=%d: %s)\n", errno,
           strerror(errno));
    if (errno != EROFS && errno != EACCES) {
      printf("  FAILED: unexpected errno for read-only filesystem\n");
    }
  } else {
    printf("  FAILED: truncate on read-only filesystem succeeded!\n");
  }

  int fd = open("/bin/sh", O_RDONLY);
  if (fd != -1) {
    res = ftruncate(fd, 100);
    if (res == -1) {
      printf("  ftruncate /bin/sh (fd=%d): expected error (errno=%d: %s)\n", fd,
             errno, strerror(errno));
      // ftruncate on read-only FD should return EBADF in Linux,
      // but here we check if writable.
    } else {
      printf("  FAILED: ftruncate on read-only FD succeeded!\n");
    }
    close(fd);
  }
}

void test_mkdir_rmdir() {
  printf("Testing mkdir/rmdir...\n");

  int res = mkdir("/test_dir", 0755);
  if (res == -1) {
    printf("  mkdir /test_dir: expected error (errno=%d: %s)\n", errno,
           strerror(errno));
  } else {
    printf("  FAILED: mkdir on read-only filesystem succeeded!\n");
  }

  res = rmdir("/test_dir");
  if (res == -1) {
    printf("  rmdir /test_dir: expected error (errno=%d: %s)\n", errno,
           strerror(errno));
  } else {
    // This might "succeed" if we didn't check existence first,
    // but it should fail on EROFS.
  }
}

void test_rename_link() {
  printf("Testing rename/link/symlink...\n");

  int res = rename("/bin/sh", "/bin/sh_renamed");
  if (res == -1) {
    printf("  rename /bin/sh: expected error (errno=%d: %s)\n", errno,
           strerror(errno));
  } else {
    printf("  FAILED: rename on read-only filesystem succeeded!\n");
  }

  res = link("/bin/sh", "/bin/sh_link");
  if (res == -1) {
    printf("  link /bin/sh: expected error (errno=%d: %s)\n", errno,
           strerror(errno));
  } else {
    printf("  FAILED: link on read-only filesystem succeeded!\n");
  }

  res = symlink("/bin/sh", "/bin/sh_symlink");
  if (res == -1) {
    printf("  symlink /bin/sh: expected error (errno=%d: %s)\n", errno,
           strerror(errno));
  } else {
    printf("  FAILED: symlink on read-only filesystem succeeded!\n");
  }
}

void test_readlink() {
  printf("Testing readlink...\n");
  char buf[256];

  // /dev/stdout might be a symlink or special file.
  // In our kernel it's likely a special file.
  // Readlink on non-symlink should return EINVAL.
  ssize_t n = readlink("/bin/sh", buf, sizeof(buf));
  if (n == -1) {
    printf("  readlink /bin/sh: expected error (errno=%d: %s)\n", errno,
           strerror(errno));
    if (errno != EINVAL) {
      printf("  FAILED: expected EINVAL for non-symlink\n");
    }
  } else {
    printf("  readlink /bin/sh returned %ld bytes\n", (long)n);
  }
}

int main() {
  printf("--- VFS Phase 2 Syscall Tests ---\n");
  test_truncate();
  test_mkdir_rmdir();
  test_rename_link();
  test_readlink();
  printf("--- VFS Tests Complete ---\n");
  return 0;
}

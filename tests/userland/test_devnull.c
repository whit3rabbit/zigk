#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main() {
  int fd = open("/dev/null", O_RDWR);
  if (fd < 0) {
    printf("Failed to open /dev/null: %d\n", errno);
    return 1;
  }

  const char *data = "Discard this";
  ssize_t written = write(fd, data, strlen(data));
  if (written != (ssize_t)strlen(data)) {
    printf("Write failed: expected %zu, got %zd\n", strlen(data), written);
    close(fd);
    return 2;
  }

  char buf[10];
  ssize_t n = read(fd, buf, sizeof(buf));
  if (n != 0) {
    printf("Read failed: expected 0 (EOF), got %zd\n", n);
    close(fd);
    return 3;
  }

  close(fd);
  printf("/dev/null test passed\n");
  return 0;
}

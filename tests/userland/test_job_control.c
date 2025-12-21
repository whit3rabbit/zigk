#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

void test_pgid_sid() {
  printf("Testing getpid, getpgid, getsid...\n");

  pid_t pid = getpid();
  pid_t pgid = getpgid(0);
  pid_t sid = getsid(0);

  printf("  PID: %d, PGID: %d, SID: %d\n", pid, pgid, sid);

  if (pgid <= 0 || sid <= 0) {
    printf("  FAILED: invalid PGID or SID\n");
  }
}

void test_setsid() {
  printf("Testing setsid...\n");

  // In our initrd, we are probably not a group leader yet, or we are the first
  // process. Actually, if we are PID 1, we ARE the leader. setsid() should fail
  // with EPERM.

  pid_t sid = setsid();
  if (sid == -1) {
    printf("  setsid: expected result or error (errno=%d: %s)\n", errno,
           strerror(errno));
  } else {
    printf("  setsid: SUCCESS, new SID: %d (PGID should also be %d)\n", sid,
           (int)getpgid(0));
  }
}

void test_setpgid() {
  printf("Testing setpgid...\n");

  // Create a child to test group membership
  pid_t child = fork();
  if (child == 0) {
    // Child process
    pid_t my_pid = getpid();
    pid_t my_pgid = getpgid(0);
    printf("  Child: PID=%d, PGID=%d\n", my_pid, my_pgid);

    // Try to become group leader
    if (setpgid(0, 0) == 0) {
      printf("  Child: setpgid(0, 0) SUCCESS, new PGID=%d\n", (int)getpgid(0));
    } else {
      printf("  Child: setpgid(0, 0) FAILED (errno=%d)\n", errno);
    }
    _exit(0);
  } else if (child > 0) {
    // Parent process
    int status;
    waitpid(child, &status, 0);
    printf("  Parent: Child %d reaped.\n", child);
  } else {
    printf("  Fork FAILED\n");
  }
}

int main() {
  printf("--- Job Control Syscall Tests ---\n");
  test_pgid_sid();
  test_setsid();
  test_setpgid();
  printf("--- Job Control Tests Complete ---\n");
  return 0;
}

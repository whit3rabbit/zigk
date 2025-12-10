#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

int main() {
  pid_t pid = fork();

  if (pid < 0) {
    perror("fork failed");
    return 1;
  }

  if (pid == 0) {
    // Child
    printf("Child running, exiting with 42\n");
    exit(42);
  } else {
    // Parent
    int status;
    printf("Parent waiting for child %d\n", pid);
    pid_t waited_pid = wait4(pid, &status, 0, NULL);

    if (waited_pid != pid) {
      printf("wait4 returned %d, expected %d\n", waited_pid, pid);
      return 2;
    }

    if (WIFEXITED(status)) {
      int exit_code = WEXITSTATUS(status);
      if (exit_code == 42) {
        printf("Child exited with correct code: 42\n");
        return 0;
      } else {
        printf("Child exited with wrong code: %d\n", exit_code);
        return 3;
      }
    } else {
      printf("Child did not exit normally. Status: %x\n", status);
      return 4;
    }
  }
}

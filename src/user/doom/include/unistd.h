// Minimal unistd.h for doomgeneric
#ifndef _UNISTD_H
#define _UNISTD_H

#include <stddef.h>
#include <sys/types.h>

#define STDIN_FILENO  0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2

#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

int close(int fd);
ssize_t read(int fd, void *buf, size_t count);
ssize_t write(int fd, const void *buf, size_t count);
off_t lseek(int fd, off_t offset, int whence);
int unlink(const char *path);
int rmdir(const char *path);
char *getcwd(char *buf, size_t size);
int chdir(const char *path);
int access(const char *path, int mode);
unsigned int sleep(unsigned int seconds);
int usleep(unsigned int usec);
int isatty(int fd);
int pipe(int pipefd[2]);
int dup(int oldfd);
int dup2(int oldfd, int newfd);

#define R_OK 4
#define W_OK 2
#define X_OK 1
#define F_OK 0

#endif // _UNISTD_H

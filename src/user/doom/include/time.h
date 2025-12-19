// Minimal time.h for doomgeneric
#ifndef _TIME_H
#define _TIME_H

#include <stddef.h>
#include <sys/types.h>

struct tm {
  int tm_sec;
  int tm_min;
  int tm_hour;
  int tm_mday;
  int tm_mon;
  int tm_year;
  int tm_wday;
  int tm_yday;
  int tm_isdst;
};

time_t time(time_t *t);
struct tm *localtime(const time_t *timep);
struct tm *gmtime(const time_t *timep);
char *ctime(const time_t *timep);
clock_t clock(void);

#define CLOCKS_PER_SEC 1000000

struct timespec {
  time_t tv_sec;
  long tv_nsec;
};

int nanosleep(const struct timespec *req, struct timespec *rem);

#endif // _TIME_H

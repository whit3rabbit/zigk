// Minimal time.h for doomgeneric
#ifndef _TIME_H
#define _TIME_H

#include <stddef.h>

typedef long time_t;
typedef long clock_t;

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

#endif // _TIME_H

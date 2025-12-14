// Zscapek libc Root Module
//
// Provides C-compatible standard library functions for userland programs.
// Re-exports all subsystem modules to maintain a stable public API.
//
// Modules:
//   - memory: malloc, free, realloc, calloc
//   - stdio: FILE, printf, fprintf, fopen, etc.
//   - string: memcpy, strlen, strcmp, etc.
//   - stdlib: exit, atoi, rand, qsort, etc.
//   - ctype: isspace, isdigit, toupper, etc.
//   - time: time, clock_gettime, nanosleep
//   - errno: errno global variable

const std = @import("std");

// =============================================================================
// Module imports
// =============================================================================

pub const memory = @import("memory/root.zig");
pub const stdio = @import("stdio/root.zig");
pub const string = @import("string/root.zig");
pub const stdlib = @import("stdlib/root.zig");
pub const ctype = @import("ctype.zig");
pub const time_mod = @import("time.zig");
pub const errno_mod = @import("errno.zig");
pub const internal = @import("internal.zig");
pub const stubs = @import("stubs.zig");

// =============================================================================
// errno
// =============================================================================

pub const errno = &errno_mod.errno;

// =============================================================================
// Memory Management
// =============================================================================

pub const malloc = memory.malloc;
pub const free = memory.free;
pub const realloc = memory.realloc;
pub const calloc = memory.calloc;
pub const aligned_alloc = memory.aligned_alloc;
pub const posix_memalign = memory.posix_memalign;

// =============================================================================
// String and Memory Operations
// =============================================================================

// Memory
pub const memcpy = string.memcpy;
pub const memset = string.memset;
pub const memmove = string.memmove;
pub const memcmp = string.memcmp;
pub const memchr = string.memchr;
pub const memrchr = string.memrchr;

// String basics
pub const strlen = string.strlen;
pub const strnlen = string.strnlen;
pub const strcmp = string.strcmp;
pub const strncmp = string.strncmp;
pub const strcpy = string.strcpy;
pub const strncpy = string.strncpy;
pub const strlcpy = string.strlcpy;

// String search
pub const strchr = string.strchr;
pub const strrchr = string.strrchr;
pub const strstr = string.strstr;
pub const strpbrk = string.strpbrk;
pub const strspn = string.strspn;
pub const strcspn = string.strcspn;

// String concatenation
pub const strcat = string.strcat;
pub const strncat = string.strncat;
pub const strlcat = string.strlcat;

// Case-insensitive comparison
pub const strcasecmp = string.strcasecmp;
pub const strncasecmp = string.strncasecmp;

// Tokenization
pub const strtok = string.strtok;
pub const strtok_r = string.strtok_r;
pub const strsep = string.strsep;

// Error strings
pub const strerror = string.strerror;
pub const strerror_r = string.strerror_r;

// strdup - depends on malloc
pub export fn strdup(s: ?[*:0]const u8) ?[*:0]u8 {
    if (s == null) return null;
    const str = s.?;
    const len = std.mem.len(str);

    const new_ptr = malloc(len + 1);
    if (new_ptr == null) return null;

    const new_str: [*]u8 = @ptrCast(new_ptr.?);
    @memcpy(new_str[0..len], str[0..len]);
    new_str[len] = 0;

    return @ptrCast(new_str);
}

// =============================================================================
// stdio
// =============================================================================

// Types
pub const FILE = stdio.FILE;
pub const fpos_t = stdio.fpos_t;

// Constants
pub const EOF = stdio.EOF;
pub const SEEK_SET = stdio.SEEK_SET;
pub const SEEK_CUR = stdio.SEEK_CUR;
pub const SEEK_END = stdio.SEEK_END;

// Standard streams (note: these point to the actual stream pointers)
pub const stdin = stdio.stdin;
pub const stdout = stdio.stdout;
pub const stderr = stdio.stderr;

// File operations
pub const fopen = stdio.fopen;
pub const fclose = stdio.fclose;
pub const fread = stdio.fread;
pub const fwrite = stdio.fwrite;
pub const fseek = stdio.fseek;
pub const ftell = stdio.ftell;
pub const rewind = stdio.rewind;
pub const fflush = stdio.fflush;
pub const fileno = stdio.fileno;
pub const fgetpos = stdio.fgetpos;
pub const fsetpos = stdio.fsetpos;
pub const freopen = stdio.freopen;

// Character I/O
pub const fputc = stdio.fputc;
pub const putchar = stdio.putchar;
pub const putc = stdio.putc;
pub const fgetc = stdio.fgetc;
pub const getchar = stdio.getchar;
pub const getc = stdio.getc;
pub const ungetc = stdio.ungetc;

// String I/O
pub const fputs = stdio.fputs;
pub const puts = stdio.puts;
pub const fgets = stdio.fgets;
pub const gets = stdio.gets;

// Status
pub const feof = stdio.feof;
pub const ferror = stdio.ferror;
pub const clearerr = stdio.clearerr;

// File management
pub const remove = stdio.remove;
pub const rename = stdio.rename;
pub const tmpfile = stdio.tmpfile;
pub const tmpnam = stdio.tmpnam;

// Error output
pub const perror = stdio.perror;

// Formatted output
pub const printf = stdio.printf;
pub const fprintf = stdio.fprintf;
pub const sprintf = stdio.sprintf;
pub const snprintf = stdio.snprintf;
pub const vprintf = stdio.vprintf;
pub const vfprintf = stdio.vfprintf;
pub const vsprintf = stdio.vsprintf;
pub const vsnprintf = stdio.vsnprintf;

// Formatted input
pub const sscanf = stdio.sscanf;
pub const fscanf = stdio.fscanf;
pub const scanf = stdio.scanf;

// =============================================================================
// stdlib
// =============================================================================

// Process control
pub const exit = stdlib.exit;
pub const abort = stdlib.abort;
pub const _Exit = stdlib._Exit;
pub const _exit = stdlib._exit;
pub const atexit = stdlib.atexit;
pub const system = stdlib.system;
pub const EXIT_SUCCESS = stdlib.EXIT_SUCCESS;
pub const EXIT_FAILURE = stdlib.EXIT_FAILURE;

// Math utilities
pub const abs = stdlib.abs;
pub const labs = stdlib.labs;
pub const llabs = stdlib.llabs;
pub const div = stdlib.div;
pub const ldiv = stdlib.ldiv;
pub const lldiv = stdlib.lldiv;

// String conversion
pub const atoi = stdlib.atoi;
pub const atol = stdlib.atol;
pub const atoll = stdlib.atoll;
pub const atof = stdlib.atof;
pub const strtol = stdlib.strtol;
pub const strtoul = stdlib.strtoul;
pub const strtoll = stdlib.strtoll;
pub const strtoull = stdlib.strtoull;
pub const strtod = stdlib.strtod;
pub const strtof = stdlib.strtof;

// Random numbers
pub const rand = stdlib.rand;
pub const srand = stdlib.srand;
pub const RAND_MAX = stdlib.RAND_MAX;

// Sorting and searching
pub const qsort = stdlib.qsort;
pub const bsearch = stdlib.bsearch;
pub const lfind = stdlib.lfind;

// Environment
pub const getenv = stdlib.getenv;
pub const setenv = stdlib.setenv;
pub const unsetenv = stdlib.unsetenv;
pub const putenv = stdlib.putenv;

// Filesystem stubs
pub const mkdir = stdlib.mkdir;
pub const rmdir = stdlib.rmdir;
pub const chdir = stdlib.chdir;
pub const getcwd = stdlib.getcwd;

// =============================================================================
// ctype
// =============================================================================

pub const isspace = ctype.isspace;
pub const isdigit = ctype.isdigit;
pub const isalpha = ctype.isalpha;
pub const isalnum = ctype.isalnum;
pub const isupper = ctype.isupper;
pub const islower = ctype.islower;
pub const isprint = ctype.isprint;
pub const isxdigit = ctype.isxdigit;
pub const iscntrl = ctype.iscntrl;
pub const isgraph = ctype.isgraph;
pub const ispunct = ctype.ispunct;
pub const isblank = ctype.isblank;
pub const isascii = ctype.isascii;
pub const toupper = ctype.toupper;
pub const tolower = ctype.tolower;
pub const toascii = ctype.toascii;

// =============================================================================
// time
// =============================================================================

pub const time_t = time_mod.time_t;
pub const timespec = time_mod.timespec;
pub const time = time_mod.time;
pub const clock_gettime = time_mod.clock_gettime;
pub const nanosleep = time_mod.nanosleep;
pub const sleep = time_mod.sleep;
pub const usleep = time_mod.usleep;
pub const CLOCK_REALTIME = time_mod.CLOCK_REALTIME;
pub const CLOCK_MONOTONIC = time_mod.CLOCK_MONOTONIC;

// =============================================================================
// Signal stubs
// =============================================================================

pub const signal = stubs.signal;
pub const raise = stubs.raise;
pub const sighandler_t = stubs.sighandler_t;
pub const SIG_DFL = stubs.SIG_DFL;
pub const SIG_IGN = stubs.SIG_IGN;
pub const SIG_ERR = stubs.SIG_ERR;

// =============================================================================
// setjmp/longjmp stubs
// =============================================================================

pub const jmp_buf = stubs.jmp_buf;
pub const setjmp = stubs.setjmp;
pub const longjmp = stubs.longjmp;
pub const sigsetjmp = stubs.sigsetjmp;
pub const siglongjmp = stubs.siglongjmp;

// =============================================================================
// Locale stubs
// =============================================================================

pub const setlocale = stubs.setlocale;
pub const LC_ALL = stubs.LC_ALL;
pub const LC_COLLATE = stubs.LC_COLLATE;
pub const LC_CTYPE = stubs.LC_CTYPE;
pub const LC_MESSAGES = stubs.LC_MESSAGES;
pub const LC_MONETARY = stubs.LC_MONETARY;
pub const LC_NUMERIC = stubs.LC_NUMERIC;
pub const LC_TIME = stubs.LC_TIME;

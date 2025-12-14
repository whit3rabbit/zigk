// String module aggregator
//
// Re-exports all string-related functions from submodules.

const mem = @import("mem.zig");
const str = @import("str.zig");
const search = @import("search.zig");
const concat = @import("concat.zig");
const case = @import("case.zig");
const tokenize = @import("tokenize.zig");
const error_mod = @import("error.zig");

// Memory operations
pub const memcpy = mem.memcpy;
pub const memset = mem.memset;
pub const memmove = mem.memmove;
pub const memcmp = mem.memcmp;
pub const memchr = mem.memchr;
pub const memrchr = mem.memrchr;
pub const copyBytes = mem.copyBytes;

// String basics
pub const strlen = str.strlen;
pub const strnlen = str.strnlen;
pub const strcmp = str.strcmp;
pub const strncmp = str.strncmp;
pub const strcpy = str.strcpy;
pub const strncpy = str.strncpy;
pub const strlcpy = str.strlcpy;

// String search
pub const strchr = search.strchr;
pub const strrchr = search.strrchr;
pub const strstr = search.strstr;
pub const strpbrk = search.strpbrk;
pub const strspn = search.strspn;
pub const strcspn = search.strcspn;

// String concatenation
pub const strcat = concat.strcat;
pub const strncat = concat.strncat;
pub const strlcat = concat.strlcat;

// Case-insensitive comparison
pub const strcasecmp = case.strcasecmp;
pub const strncasecmp = case.strncasecmp;
pub const stricmp = case.stricmp;
pub const strnicmp = case.strnicmp;

// Tokenization
pub const strtok = tokenize.strtok;
pub const strtok_r = tokenize.strtok_r;
pub const strsep = tokenize.strsep;

// Error strings
pub const strerror = error_mod.strerror;
pub const strerror_r = error_mod.strerror_r;
// perror is defined in stdio/streams.zig since it requires stderr access

// strdup is defined in main root.zig since it depends on malloc

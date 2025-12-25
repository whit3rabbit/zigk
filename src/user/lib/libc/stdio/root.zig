// stdio module aggregator
//
// Re-exports all stdio functions from submodules.

const file = @import("file.zig");
const streams = @import("streams.zig");
const printf_mod = @import("printf.zig");
const fprintf_mod = @import("fprintf.zig");
const vprintf_mod = @import("vprintf.zig");
const sscanf_mod = @import("sscanf.zig");

// Types
pub const FILE = file.FILE;
pub const fpos_t = file.fpos_t;
pub const va_list = vprintf_mod.va_list;

// Constants
pub const EOF = file.EOF;
pub const SEEK_SET = file.SEEK_SET;
pub const SEEK_CUR = file.SEEK_CUR;
pub const SEEK_END = file.SEEK_END;

// Standard streams
pub const stdin = &streams.stdin;
pub const stdout = &streams.stdout;
pub const stderr = &streams.stderr;

// File operations
pub const fopen = file.fopen;
pub const fclose = file.fclose;
pub const fread = file.fread;
pub const fwrite = file.fwrite;
pub const fseek = file.fseek;
pub const ftell = file.ftell;
pub const rewind = file.rewind;
pub const fflush = file.fflush;
pub const fileno = file.fileno;
pub const fgetpos = file.fgetpos;
pub const fsetpos = file.fsetpos;
pub const freopen = file.freopen;

// Character I/O
pub const fputc = streams.fputc;
pub const putchar = streams.putchar;
pub const putc = streams.putc;
pub const fgetc = streams.fgetc;
pub const getchar = streams.getchar;
pub const getc = streams.getc;
pub const ungetc = streams.ungetc;

// String I/O
pub const fputs = streams.fputs;
pub const puts = streams.puts;
pub const fgets = streams.fgets;
pub const gets = streams.gets;

// Status
pub const feof = streams.feof;
pub const ferror = streams.ferror;
pub const clearerr = streams.clearerr;

// File management
pub const remove = streams.remove;
pub const rename = streams.rename;
pub const tmpfile = streams.tmpfile;
pub const tmpnam = streams.tmpnam;

// Error output
pub const perror = streams.perror;

// Formatted output
// Note: On x86_64, these are exported via X86*Export structs.
// On aarch64, these are provided by the C shim.
// The _impl functions are always available.
pub const printf_impl = printf_mod.printf_impl;
pub const fprintf_impl = fprintf_mod.fprintf_impl;
pub const sprintf_impl = fprintf_mod.sprintf_impl;
pub const snprintf_impl = fprintf_mod.snprintf_impl;

// v* functions
pub const vprintf = vprintf_mod.vprintf;
pub const vfprintf = vprintf_mod.vfprintf;
pub const vsprintf = vprintf_mod.vsprintf;
pub const vsnprintf = vprintf_mod.vsnprintf;

// Force v* function exports to be included in binary (referenced by C code)
comptime {
    _ = &vprintf_mod.vprintf;
    _ = &vprintf_mod.vfprintf;
    _ = &vprintf_mod.vsprintf;
    _ = &vprintf_mod.vsnprintf;
}

// Formatted input
// Note: On x86_64, these are exported via X86*Export structs.
// On aarch64, these are provided by the C shim.
pub const sscanf_impl = sscanf_mod.sscanf_impl;
pub const fscanf_impl = sscanf_mod.fscanf_impl;
pub const scanf_impl = sscanf_mod.scanf_impl;

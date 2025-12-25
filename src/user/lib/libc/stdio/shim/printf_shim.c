// C shim for aarch64 varargs functions
//
// These shims use __builtin_va_start to properly initialize the va_list
// structure according to AAPCS64, then call Zig implementation functions.
// This works around LLVM's @cVaArg limitation on aarch64 (GitHub #14096).
//
// Only compiled for aarch64 targets.

#include <stdarg.h>
#include <stddef.h>

// Forward declarations of Zig implementation functions
extern int printf_impl(const char* fmt, void* ap);
extern int fprintf_impl(void* stream, const char* fmt, void* ap);
extern int sprintf_impl(char* dest, const char* fmt, void* ap);
extern int snprintf_impl(char* dest, size_t size, const char* fmt, void* ap);
extern int sscanf_impl(const char* str, const char* fmt, void* ap);
extern int fscanf_impl(void* stream, const char* fmt, void* ap);
extern int scanf_impl(const char* fmt, void* ap);

// printf - print formatted output to stdout
int printf(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int result = printf_impl(fmt, &ap);
    va_end(ap);
    return result;
}

// fprintf - print formatted output to file
int fprintf(void* stream, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int result = fprintf_impl(stream, fmt, &ap);
    va_end(ap);
    return result;
}

// sprintf - format to string (unsafe, use snprintf)
int sprintf(char* dest, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int result = sprintf_impl(dest, fmt, &ap);
    va_end(ap);
    return result;
}

// snprintf - format to string with size limit
int snprintf(char* dest, size_t size, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int result = snprintf_impl(dest, size, fmt, &ap);
    va_end(ap);
    return result;
}

// sscanf - parse formatted input from string
int sscanf(const char* str, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int result = sscanf_impl(str, fmt, &ap);
    va_end(ap);
    return result;
}

// fscanf - parse formatted input from file
int fscanf(void* stream, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int result = fscanf_impl(stream, fmt, &ap);
    va_end(ap);
    return result;
}

// scanf - parse formatted input from stdin
int scanf(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int result = scanf_impl(fmt, &ap);
    va_end(ap);
    return result;
}

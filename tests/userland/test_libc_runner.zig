const libc = @import("libc");

// Import main from C test
extern fn main() c_int;

// Entry point called by ELF loader
export fn _start() noreturn {
    // Call main and exit with return value
    const ret = main();
    
    // Force inclusions of used symbols
    // Note: printf/fprintf/snprintf are exported directly to C, use _impl for references
    _ = libc.printf_impl;
    _ = libc.fprintf_impl;
    _ = libc.sprintf_impl;
    _ = libc.snprintf_impl;
    _ = libc.sscanf_impl;
    _ = libc.fscanf_impl;
    _ = libc.scanf_impl;
    _ = libc.freopen;
    _ = libc.fclose;
    _ = libc.strcmp;
    _ = libc.nanosleep;
    _ = libc.stdout;
    _ = libc.stderr;
    // __assert_fail is in stubs, check if exported.
    // If root.zig exports stubs namespace or stubs struct.
    _ = libc.stubs.__assert_fail; 
    
    libc.exit(ret);
    
    // Should be unreachable
    while (true) {}
}

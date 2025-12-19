const libc = @import("libc");

// Import main from C test
extern fn main() c_int;

// Entry point called by ELF loader
export fn _start() noreturn {
    // Call main and exit with return value
    const ret = main();
    
    // Force inclusions of used symbols
    _ = libc.printf;
    _ = libc.fprintf;
    _ = libc.freopen;
    _ = libc.fclose;
    _ = libc.snprintf;
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

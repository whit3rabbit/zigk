pub fn syscall0(number: usize) usize {
    var ret: usize = undefined;
    asm volatile ("syscall"
        : [ret] "={rax}" (ret),
        : [number] "{rax}" (number),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
    return ret;
}

pub fn syscall1(number: usize, arg1: usize) usize {
    var ret: usize = undefined;
    asm volatile ("syscall"
        : [ret] "={rax}" (ret),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
    return ret;
}

pub fn syscall2(number: usize, arg1: usize, arg2: usize) usize {
    var ret: usize = undefined;
    asm volatile ("syscall"
        : [ret] "={rax}" (ret),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
    return ret;
}

pub fn syscall3(number: usize, arg1: usize, arg2: usize, arg3: usize) usize {
    var ret: usize = undefined;
    asm volatile ("syscall"
        : [ret] "={rax}" (ret),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
    return ret;
}

pub fn syscall4(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
    var ret: usize = undefined;
    asm volatile ("syscall"
        : [ret] "={rax}" (ret),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
          [arg4] "{r10}" (arg4),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
    return ret;
}

pub fn syscall5(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
    var ret: usize = undefined;
    asm volatile ("syscall"
        : [ret] "={rax}" (ret),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
          [arg4] "{r10}" (arg4),
          [arg5] "{r8}" (arg5),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
    return ret;
}

pub fn syscall6(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize, arg6: usize) usize {
    var ret: usize = undefined;
    asm volatile ("syscall"
        : [ret] "={rax}" (ret),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
          [arg4] "{r10}" (arg4),
          [arg5] "{r8}" (arg5),
          [arg6] "{r9}" (arg6),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
    return ret;
}

const syscall = @import("syscall");

// Test 1: getuid returns 0 (root)
pub fn testGetuidReturnsZero() !void {
    const uid = syscall.getuid();
    if (uid != 0) return error.TestFailed;
}

// Test 2: geteuid returns 0 (root)
pub fn testGeteuidReturnsZero() !void {
    const euid = syscall.geteuid();
    if (euid != 0) return error.TestFailed;
}

// Test 3: getgid returns 0 (root)
pub fn testGetgidReturnsZero() !void {
    const gid = syscall.getgid();
    if (gid != 0) return error.TestFailed;
}

// Test 4: getegid returns 0 (root)
pub fn testGetegidReturnsZero() !void {
    const egid = syscall.getegid();
    if (egid != 0) return error.TestFailed;
}

// Test 5: setuid(0) as root succeeds
pub fn testSetuidAsRootSucceeds() !void {
    try syscall.setuid(0);
    const uid = syscall.getuid();
    if (uid != 0) return error.TestFailed;
}

// Test 6: setgid(0) as root succeeds
pub fn testSetgidAsRootSucceeds() !void {
    try syscall.setgid(0);
    const gid = syscall.getgid();
    if (gid != 0) return error.TestFailed;
}

// Test 7: getresuid returns all zeros (root)
pub fn testGetresuidReturnsAllZeros() !void {
    var ruid: u32 = undefined;
    var euid: u32 = undefined;
    var suid: u32 = undefined;

    try syscall.getresuid(&ruid, &euid, &suid);

    if (ruid != 0 or euid != 0 or suid != 0) return error.TestFailed;
}

// Test 8: getresgid returns all zeros (root)
pub fn testGetresgidReturnsAllZeros() !void {
    var rgid: u32 = undefined;
    var egid: u32 = undefined;
    var sgid: u32 = undefined;

    try syscall.getresgid(&rgid, &egid, &sgid);

    if (rgid != 0 or egid != 0 or sgid != 0) return error.TestFailed;
}

const std = @import("std");
const syscall = @import("syscall");

// =============================================================================
// Capability Tests (capget, capset)
// =============================================================================

// Test 1: capget with v3 header returns capabilities for current process
pub fn testCapgetSelf() !void {
    var hdr = syscall.CapUserHeader{
        .version = syscall._LINUX_CAPABILITY_VERSION_3,
        .pid = 0, // current process
    };
    var data: [2]syscall.CapUserData = .{
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
    };

    try syscall.capget(&hdr, &data);

    // Root process should have full effective capabilities
    // Low 32 bits should all be set
    if (data[0].effective != 0xFFFFFFFF) return error.TestFailed;
    // Permitted should also be full
    if (data[0].permitted != 0xFFFFFFFF) return error.TestFailed;
}

// Test 2: capget with v1 header returns 32-bit capabilities
pub fn testCapgetV1() !void {
    var hdr = syscall.CapUserHeader{
        .version = syscall._LINUX_CAPABILITY_VERSION_1,
        .pid = 0,
    };
    var data: [1]syscall.CapUserData = .{
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
    };

    try syscall.capget(&hdr, &data);

    // v1 should have all low 32 bits set for effective
    if (data[0].effective != 0xFFFFFFFF) return error.TestFailed;
    if (data[0].permitted != 0xFFFFFFFF) return error.TestFailed;
    // Inheritable should be 0 by default
    if (data[0].inheritable != 0) return error.TestFailed;
}

// Test 3: capget version negotiation -- invalid version returns EINVAL and preferred version
pub fn testCapgetVersionNegotiation() !void {
    var hdr = syscall.CapUserHeader{
        .version = 0x12345678, // Invalid version
        .pid = 0,
    };

    const result = syscall.capget(&hdr, null);
    if (result) |_| {
        return error.TestFailed; // Should fail with EINVAL
    } else |err| {
        if (err != error.InvalidArgument) return error.TestFailed;
    }

    // After EINVAL, kernel should have written the preferred version
    if (hdr.version != syscall._LINUX_CAPABILITY_VERSION_3) return error.TestFailed;
}

// Test 4: capget with null datap is version query (returns success)
pub fn testCapgetVersionQuery() !void {
    var hdr = syscall.CapUserHeader{
        .version = syscall._LINUX_CAPABILITY_VERSION_3,
        .pid = 0,
    };

    // NULL datap = version query only
    try syscall.capget(&hdr, null);
    // Should succeed without error
}

// Test 5: capset can drop effective capabilities
pub fn testCapsetDropEffective() !void {
    // First, get current caps
    var hdr = syscall.CapUserHeader{
        .version = syscall._LINUX_CAPABILITY_VERSION_3,
        .pid = 0,
    };
    var data: [2]syscall.CapUserData = .{
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
    };
    try syscall.capget(&hdr, &data);

    // Drop CAP_SYS_ADMIN from effective (bit 21)
    data[0].effective &= ~(@as(u32, 1) << syscall.CAP_SYS_ADMIN);

    // Set new caps (keep permitted unchanged)
    const set_hdr = syscall.CapUserHeader{
        .version = syscall._LINUX_CAPABILITY_VERSION_3,
        .pid = 0,
    };
    try syscall.capset(&set_hdr, &data);

    // Verify the drop
    var verify_data: [2]syscall.CapUserData = .{
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
    };
    try syscall.capget(&hdr, &verify_data);

    // CAP_SYS_ADMIN should be cleared in effective
    if ((verify_data[0].effective & (@as(u32, 1) << syscall.CAP_SYS_ADMIN)) != 0) {
        return error.TestFailed;
    }
    // But still present in permitted
    if ((verify_data[0].permitted & (@as(u32, 1) << syscall.CAP_SYS_ADMIN)) == 0) {
        return error.TestFailed;
    }

    // Restore full effective caps for subsequent tests
    var restore_data: [2]syscall.CapUserData = .{
        .{ .effective = 0xFFFFFFFF, .permitted = 0xFFFFFFFF, .inheritable = 0 },
        .{ .effective = @truncate(syscall.CAP_FULL_SET >> 32), .permitted = @truncate(syscall.CAP_FULL_SET >> 32), .inheritable = 0 },
    };
    try syscall.capset(&set_hdr, &restore_data);
}

// Test 6: capset rejects adding capabilities beyond permitted
pub fn testCapsetCannotGainPermitted() !void {
    // First drop CAP_MKNOD from permitted
    var hdr = syscall.CapUserHeader{
        .version = syscall._LINUX_CAPABILITY_VERSION_3,
        .pid = 0,
    };
    var data: [2]syscall.CapUserData = .{
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
    };
    try syscall.capget(&hdr, &data);

    // Drop CAP_MKNOD (27) from permitted AND effective
    data[0].permitted &= ~(@as(u32, 1) << syscall.CAP_MKNOD);
    data[0].effective &= ~(@as(u32, 1) << syscall.CAP_MKNOD);

    const set_hdr = syscall.CapUserHeader{
        .version = syscall._LINUX_CAPABILITY_VERSION_3,
        .pid = 0,
    };
    try syscall.capset(&set_hdr, &data);

    // Now try to re-add CAP_MKNOD to permitted -- should fail with EPERM
    data[0].permitted |= (@as(u32, 1) << syscall.CAP_MKNOD);
    const result = syscall.capset(&set_hdr, &data);
    if (result) |_| {
        return error.TestFailed; // Should fail
    } else |err| {
        if (err != error.PermissionDenied) return error.TestFailed;
    }

    // Restore -- NOTE: Cannot restore CAP_MKNOD since permitted was dropped.
    // This is by design. Subsequent tests do not depend on CAP_MKNOD.
    // Re-read current caps and restore effective to match permitted
    try syscall.capget(&hdr, &data);
    data[0].effective = data[0].permitted;
    data[1].effective = data[1].permitted;
    _ = syscall.capset(&set_hdr, &data) catch {};
}

// Test 7: capset rejects effective bits not in permitted
pub fn testCapsetEffectiveSubsetOfPermitted() !void {
    var hdr = syscall.CapUserHeader{
        .version = syscall._LINUX_CAPABILITY_VERSION_3,
        .pid = 0,
    };
    var data: [2]syscall.CapUserData = .{
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
    };
    try syscall.capget(&hdr, &data);

    // Save original permitted for restore
    const orig_eff_lo = data[0].effective;
    const orig_eff_hi = data[1].effective;
    const orig_perm_lo = data[0].permitted;
    const orig_perm_hi = data[1].permitted;

    // Clear all permitted but try to set some effective -- should fail
    data[0].permitted = 0;
    data[1].permitted = 0;
    data[0].effective = 0x1; // Try to keep CAP_CHOWN effective with no permitted

    const set_hdr = syscall.CapUserHeader{
        .version = syscall._LINUX_CAPABILITY_VERSION_3,
        .pid = 0,
    };
    const result = syscall.capset(&set_hdr, &data);
    if (result) |_| {
        return error.TestFailed; // Should fail
    } else |err| {
        // Must be EPERM since either:
        // - new_perm is not subset of old_perm (we cleared all, but caps already dropped from test 6)
        // - OR new_eff has bit 0 while new_perm is 0
        if (err != error.PermissionDenied) return error.TestFailed;
    }

    // Restore (caps may be partially dropped from test 6, that is fine)
    data[0].permitted = orig_perm_lo;
    data[0].effective = orig_eff_lo;
    data[1].permitted = orig_perm_hi;
    data[1].effective = orig_eff_hi;
    _ = syscall.capset(&set_hdr, &data) catch {};
}

// Test 8: capset for different PID returns EPERM
pub fn testCapsetOtherPidFails() !void {
    var data: [2]syscall.CapUserData = .{
        .{ .effective = 0xFFFFFFFF, .permitted = 0xFFFFFFFF, .inheritable = 0 },
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
    };

    const hdr = syscall.CapUserHeader{
        .version = syscall._LINUX_CAPABILITY_VERSION_3,
        .pid = 9999, // Some other PID
    };

    const result = syscall.capset(&hdr, &data);
    if (result) |_| {
        return error.TestFailed;
    } else |err| {
        if (err != error.PermissionDenied) return error.TestFailed;
    }
}

// Test 9: capget with own PID works (same as pid=0)
pub fn testCapgetOwnPid() !void {
    const my_pid = syscall.getpid();

    var hdr = syscall.CapUserHeader{
        .version = syscall._LINUX_CAPABILITY_VERSION_3,
        .pid = @intCast(my_pid),
    };
    var data: [2]syscall.CapUserData = .{
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
    };

    try syscall.capget(&hdr, &data);

    // Should have capabilities (same as pid=0 query)
    // Note: some caps may have been dropped by earlier tests (test 6 drops CAP_MKNOD)
    // But most bits should still be set
    if (data[0].effective == 0) return error.TestFailed;
    if (data[0].permitted == 0) return error.TestFailed;
}

// Test 10: capset can set inheritable capabilities
pub fn testCapsetInheritable() !void {
    var hdr = syscall.CapUserHeader{
        .version = syscall._LINUX_CAPABILITY_VERSION_3,
        .pid = 0,
    };
    var data: [2]syscall.CapUserData = .{
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
    };
    try syscall.capget(&hdr, &data);

    // Set CAP_NET_RAW (13) as inheritable
    data[0].inheritable = @as(u32, 1) << syscall.CAP_NET_RAW;

    const set_hdr = syscall.CapUserHeader{
        .version = syscall._LINUX_CAPABILITY_VERSION_3,
        .pid = 0,
    };
    try syscall.capset(&set_hdr, &data);

    // Verify inheritable was set
    var verify_data: [2]syscall.CapUserData = .{
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
    };
    try syscall.capget(&hdr, &verify_data);

    if ((verify_data[0].inheritable & (@as(u32, 1) << syscall.CAP_NET_RAW)) == 0) {
        return error.TestFailed;
    }

    // Restore inheritable to 0
    data[0].inheritable = 0;
    _ = syscall.capset(&set_hdr, &data) catch {};
}

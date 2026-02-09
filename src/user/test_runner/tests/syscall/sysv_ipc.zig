const std = @import("std");
const syscall = @import("syscall");

// ========== Shared Memory Tests ==========

// Test 1: shmget creates segment
pub fn testShmgetCreatesSegment() !void {
    const id = syscall.shmget(syscall.IPC_PRIVATE, 4096, @as(i32, syscall.IPC_CREAT) | 0o666) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Verify we got a positive ID
    if (id == 0) return error.TestFailed;

    // Clean up
    _ = syscall.shmctl(id, syscall.IPC_RMID, null) catch {};
}

// Test 2: shmget with IPC_EXCL fails on duplicate
pub fn testShmgetExclFails() !void {
    // Create segment with specific key
    const key: i32 = 12345;
    const id1 = syscall.shmget(key, 4096, @as(i32, syscall.IPC_CREAT) | 0o666) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.shmctl(id1, syscall.IPC_RMID, null) catch {};

    // Try to create again with IPC_EXCL
    const result = syscall.shmget(key, 4096, @as(i32, syscall.IPC_CREAT) | @as(i32, syscall.IPC_EXCL) | 0o666);
    if (result) |_| {
        return error.TestFailed; // Should have failed
    } else |err| {
        if (err != error.FileExists) return error.TestFailed;
    }
}

// Test 3: shmat/write/read/shmdt roundtrip
pub fn testShmatWriteRead() !void {
    // Create segment
    const id = syscall.shmget(syscall.IPC_PRIVATE, 4096, @as(i32, syscall.IPC_CREAT) | 0o666) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.shmctl(id, syscall.IPC_RMID, null) catch {};

    // Attach
    const ptr = syscall.shmat(id, null, 0) catch return error.TestFailed;

    // Write data
    ptr[0] = 0xAB;
    ptr[1] = 0xCD;
    ptr[2] = 0xEF;

    // Read back and verify
    if (ptr[0] != 0xAB) return error.TestFailed;
    if (ptr[1] != 0xCD) return error.TestFailed;
    if (ptr[2] != 0xEF) return error.TestFailed;

    // Detach
    syscall.shmdt(ptr) catch return error.TestFailed;
}

// Test 4: shmctl IPC_STAT
pub fn testShmctlStat() !void {
    // Create segment
    const id = syscall.shmget(syscall.IPC_PRIVATE, 8192, @as(i32, syscall.IPC_CREAT) | 0o666) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.shmctl(id, syscall.IPC_RMID, null) catch {};

    // Attach to increment attach count
    const ptr = syscall.shmat(id, null, 0) catch return error.TestFailed;
    defer syscall.shmdt(ptr) catch {};

    // Get stats
    var ds: syscall.ShmidDs = undefined;
    _ = syscall.shmctl(id, syscall.IPC_STAT, &ds) catch return error.TestFailed;

    // Verify size (may be rounded up to page size)
    if (ds.shm_segsz < 8192) return error.TestFailed;

    // Verify attach count
    if (ds.shm_nattch != 1) return error.TestFailed;
}

// ========== Semaphore Tests ==========

// Test 5: semget creates set
pub fn testSemgetCreateSet() !void {
    const id = syscall.semget(syscall.IPC_PRIVATE, 3, @as(i32, syscall.IPC_CREAT) | 0o666) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Verify we got a positive ID
    if (id == 0) return error.TestFailed;

    // Clean up
    _ = syscall.semctl(id, 0, syscall.IPC_RMID, 0) catch {};
}

// Test 6: semctl SETVAL/GETVAL
pub fn testSemctlSetGetVal() !void {
    // Create semaphore set with 1 semaphore
    const id = syscall.semget(syscall.IPC_PRIVATE, 1, @as(i32, syscall.IPC_CREAT) | 0o666) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.semctl(id, 0, syscall.IPC_RMID, 0) catch {};

    // Set value to 42
    _ = syscall.semctl(id, 0, syscall.SETVAL, 42) catch return error.TestFailed;

    // Get value back
    const val = syscall.semctl(id, 0, syscall.GETVAL, 0) catch return error.TestFailed;
    if (val != 42) return error.TestFailed;
}

// Test 7: semop increment
pub fn testSemopIncrement() !void {
    // Create semaphore set
    const id = syscall.semget(syscall.IPC_PRIVATE, 1, @as(i32, syscall.IPC_CREAT) | 0o666) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.semctl(id, 0, syscall.IPC_RMID, 0) catch {};

    // Set initial value to 5
    _ = syscall.semctl(id, 0, syscall.SETVAL, 5) catch return error.TestFailed;

    // Increment by 3
    const sop = syscall.SemBuf{ .sem_num = 0, .sem_op = 3, .sem_flg = 0, ._pad = 0 };
    syscall.semop(id, &[_]syscall.SemBuf{sop}) catch return error.TestFailed;

    // Verify new value is 8
    const val = syscall.semctl(id, 0, syscall.GETVAL, 0) catch return error.TestFailed;
    if (val != 8) return error.TestFailed;
}

// Test 8: semop with IPC_NOWAIT returns EAGAIN when would block
pub fn testSemopNowaitEagain() !void {
    // Create semaphore set with initial value 0
    const id = syscall.semget(syscall.IPC_PRIVATE, 1, @as(i32, syscall.IPC_CREAT) | 0o666) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.semctl(id, 0, syscall.IPC_RMID, 0) catch {};

    // Semaphore is already 0 (default), try to decrement with IPC_NOWAIT
    const nowait_flag: i16 = @truncate(@as(i32, syscall.IPC_NOWAIT));
    const sop = syscall.SemBuf{ .sem_num = 0, .sem_op = -1, .sem_flg = nowait_flag, ._pad = 0 };
    const result = syscall.semop(id, &[_]syscall.SemBuf{sop});

    if (result) |_| {
        return error.TestFailed; // Should have failed with EAGAIN
    } else |err| {
        if (err != error.WouldBlock) return error.TestFailed;
    }
}

// ========== Message Queue Tests ==========

// Test 9: msgget creates queue
pub fn testMsggetCreateQueue() !void {
    const id = syscall.msgget(syscall.IPC_PRIVATE, @as(i32, syscall.IPC_CREAT) | 0o666) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Verify we got a positive ID
    if (id == 0) return error.TestFailed;

    // Clean up
    _ = syscall.msgctl(id, syscall.IPC_RMID, null) catch {};
}

// Test 10: msgsnd/msgrcv basic roundtrip
pub fn testMsgsndRecvBasic() !void {
    // Create queue
    const id = syscall.msgget(syscall.IPC_PRIVATE, @as(i32, syscall.IPC_CREAT) | 0o666) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.msgctl(id, syscall.IPC_RMID, null) catch {};

    // Build message: mtype (8 bytes) + "hello" (5 bytes)
    var send_buf: [8 + 16]u8 = undefined;
    @as(*align(1) i64, @ptrCast(&send_buf)).* = 1; // mtype = 1
    @memcpy(send_buf[8..][0..5], "hello");

    // Send message
    syscall.msgsnd(id, &send_buf, 5, 0) catch return error.TestFailed;

    // Receive message
    var recv_buf: [8 + 16]u8 = undefined;
    const n = syscall.msgrcv(id, &recv_buf, 16, 0, 0) catch return error.TestFailed;

    // Verify
    if (n != 5) return error.TestFailed;
    const recv_mtype = @as(*align(1) i64, @ptrCast(&recv_buf)).*;
    if (recv_mtype != 1) return error.TestFailed;
    if (!std.mem.eql(u8, recv_buf[8..][0..5], "hello")) return error.TestFailed;
}

// Test 11: msgrcv type filtering
pub fn testMsgrcvTypeFilter() !void {
    // Create queue
    const id = syscall.msgget(syscall.IPC_PRIVATE, @as(i32, syscall.IPC_CREAT) | 0o666) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.msgctl(id, syscall.IPC_RMID, null) catch {};

    // Send message with mtype=2
    var buf1: [8 + 16]u8 = undefined;
    @as(*align(1) i64, @ptrCast(&buf1)).* = 2;
    @memcpy(buf1[8..][0..5], "world");
    syscall.msgsnd(id, &buf1, 5, 0) catch return error.TestFailed;

    // Send message with mtype=1
    var buf2: [8 + 16]u8 = undefined;
    @as(*align(1) i64, @ptrCast(&buf2)).* = 1;
    @memcpy(buf2[8..][0..5], "hello");
    syscall.msgsnd(id, &buf2, 5, 0) catch return error.TestFailed;

    // Receive with msgtyp=1 (should get "hello", skip mtype=2)
    var recv_buf: [8 + 16]u8 = undefined;
    const n1 = syscall.msgrcv(id, &recv_buf, 16, 1, 0) catch return error.TestFailed;
    if (n1 != 5) return error.TestFailed;
    if (!std.mem.eql(u8, recv_buf[8..][0..5], "hello")) return error.TestFailed;

    // Receive with msgtyp=0 (should get "world", first remaining)
    const n2 = syscall.msgrcv(id, &recv_buf, 16, 0, 0) catch return error.TestFailed;
    if (n2 != 5) return error.TestFailed;
    if (!std.mem.eql(u8, recv_buf[8..][0..5], "world")) return error.TestFailed;
}

// Test 12: msgctl IPC_STAT
pub fn testMsgctlStat() !void {
    // Create queue
    const id = syscall.msgget(syscall.IPC_PRIVATE, @as(i32, syscall.IPC_CREAT) | 0o666) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.msgctl(id, syscall.IPC_RMID, null) catch {};

    // Send 2 messages
    var buf1: [8 + 8]u8 = undefined;
    @as(*align(1) i64, @ptrCast(&buf1)).* = 1;
    @memcpy(buf1[8..][0..3], "one");
    syscall.msgsnd(id, &buf1, 3, 0) catch return error.TestFailed;

    var buf2: [8 + 8]u8 = undefined;
    @as(*align(1) i64, @ptrCast(&buf2)).* = 2;
    @memcpy(buf2[8..][0..3], "two");
    syscall.msgsnd(id, &buf2, 3, 0) catch return error.TestFailed;

    // Get stats
    var ds: syscall.MsqidDs = undefined;
    _ = syscall.msgctl(id, syscall.IPC_STAT, &ds) catch return error.TestFailed;

    // Verify message count
    if (ds.msg_qnum != 2) return error.TestFailed;
}

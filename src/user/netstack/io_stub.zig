const std = @import("std");

pub const IoResult = union(enum) {
    success: usize,
    err: anyerror,
    cancelled: void,
    pending: void,
};

pub const IoRequest = struct {
    callback: *const fn (*anyopaque) void,
    ctx: *anyopaque,
    buf_ptr: usize = 0,
    buf_len: usize = 0,
    
    pub fn complete(self: *IoRequest, result: IoResult) bool {
        _ = self;
        _ = result;
        return true;
    }
};

pub fn timerTick() void {}

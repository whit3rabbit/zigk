// 9P Fid (File Identifier) Management
//
// The 9P protocol uses fids to identify files/directories across operations.
// Each fid represents a handle to a file system object on the server.
//
// Fid Lifecycle:
// 1. allocate() - Get a free fid number
// 2. attach/walk - Associate fid with a server object
// 3. open - Open fid for I/O operations
// 4. read/write - Perform I/O using the fid
// 5. clunk - Release the fid (server and client)
// 6. release() - Return fid to free pool

const std = @import("std");
const config = @import("config.zig");
const protocol = @import("protocol.zig");
const sync = @import("sync");

// ============================================================================
// Fid State
// ============================================================================

/// State of a fid in the local tracking table
pub const FidState = enum {
    /// Fid is not in use
    free,
    /// Fid number allocated but not yet attached/walked
    allocated,
    /// Fid is attached to root or walked to a path
    attached,
    /// Fid is opened for I/O
    opened,
};

// ============================================================================
// Fid Structure
// ============================================================================

/// A tracked fid with associated metadata
pub const Fid = struct {
    /// The 9P fid number sent over the wire
    fid_num: u32,
    /// Current state
    state: FidState,
    /// Qid from attach/walk/open (cached for stat optimization)
    qid: protocol.P9Qid,
    /// Open mode if state == opened
    open_mode: u8,
    /// Current read/write position (maintained client-side)
    position: u64,
    /// I/O unit size (from Ropen, 0 = use msize)
    iounit: u32,
    /// Cached path for debugging (not authoritative)
    path: [config.Limits.MAX_PATH_LEN]u8,
    path_len: usize,
    /// Reference count for concurrent operations
    refcount: u32,

    const Self = @This();

    /// Initialize a fid as free
    pub fn initFree(fid_num: u32) Self {
        return .{
            .fid_num = fid_num,
            .state = .free,
            .qid = std.mem.zeroes(protocol.P9Qid),
            .open_mode = 0,
            .position = 0,
            .iounit = 0,
            .path = undefined,
            .path_len = 0,
            .refcount = 0,
        };
    }

    /// Mark as allocated
    pub fn allocate(self: *Self) void {
        self.state = .allocated;
        self.qid = std.mem.zeroes(protocol.P9Qid);
        self.open_mode = 0;
        self.position = 0;
        self.iounit = 0;
        self.path_len = 0;
        self.refcount = 1;
    }

    /// Mark as attached with qid
    pub fn attach(self: *Self, qid: protocol.P9Qid) void {
        self.state = .attached;
        self.qid = qid;
    }

    /// Mark as opened with qid and iounit
    pub fn open(self: *Self, qid: protocol.P9Qid, iounit: u32, mode: u8) void {
        self.state = .opened;
        self.qid = qid;
        self.iounit = iounit;
        self.open_mode = mode;
        self.position = 0;
    }

    /// Set the cached path
    pub fn setPath(self: *Self, path: []const u8) void {
        const len = @min(path.len, config.Limits.MAX_PATH_LEN);
        @memcpy(self.path[0..len], path[0..len]);
        self.path_len = len;
    }

    /// Get the cached path
    pub fn getPath(self: *const Self) []const u8 {
        return self.path[0..self.path_len];
    }

    /// Check if fid is a directory
    pub fn isDir(self: *const Self) bool {
        return self.qid.isDir();
    }

    /// Increment reference count
    pub fn ref(self: *Self) void {
        self.refcount += 1;
    }

    /// Decrement reference count, returns true if now zero
    pub fn unref(self: *Self) bool {
        if (self.refcount == 0) return true;
        self.refcount -= 1;
        return self.refcount == 0;
    }

    /// Release fid back to free state
    pub fn release(self: *Self) void {
        self.state = .free;
        self.refcount = 0;
    }
};

// ============================================================================
// Fid Table
// ============================================================================

/// Table managing all fids for a 9P session
pub const FidTable = struct {
    /// Fid storage
    fids: [config.Limits.MAX_FIDS]Fid,
    /// Lock for concurrent access
    lock: sync.Spinlock,
    /// Next fid number to allocate (wraps around, skips in-use)
    next_fid_num: u32,
    /// Number of fids currently in use
    active_count: usize,
    /// Whether the table has been initialized
    initialized: bool,

    const Self = @This();

    /// Initialize a new fid table
    pub fn init() Self {
        var table = Self{
            .fids = undefined,
            .lock = .{},
            .next_fid_num = 1, // Start at 1, 0 is often reserved for root
            .active_count = 0,
            .initialized = true,
        };

        // Initialize all fids as free
        for (&table.fids, 0..) |*fid, i| {
            fid.* = Fid.initFree(@intCast(i));
        }

        return table;
    }

    /// Allocate a new fid, returns null if table is full
    pub fn allocate(self: *Self) ?*Fid {
        const held = self.lock.acquire();
        defer held.release();

        // Find a free slot
        for (&self.fids) |*fid| {
            if (fid.state == .free) {
                // Assign a unique fid number
                fid.fid_num = self.next_fid_num;
                self.next_fid_num +%= 1;
                if (self.next_fid_num == config.P9_NOFID) {
                    self.next_fid_num = 1;
                }

                fid.allocate();
                self.active_count += 1;
                return fid;
            }
        }

        return null; // Table full
    }

    /// Allocate a fid with a specific fid number (for root fid)
    pub fn allocateWithNum(self: *Self, fid_num: u32) ?*Fid {
        const held = self.lock.acquire();
        defer held.release();

        // Check if fid number is already in use
        for (&self.fids) |*fid| {
            if (fid.state != .free and fid.fid_num == fid_num) {
                return null; // Already in use
            }
        }

        // Find a free slot
        for (&self.fids) |*fid| {
            if (fid.state == .free) {
                fid.fid_num = fid_num;
                fid.allocate();
                self.active_count += 1;
                return fid;
            }
        }

        return null;
    }

    /// Look up a fid by its wire number
    pub fn lookup(self: *Self, fid_num: u32) ?*Fid {
        const held = self.lock.acquire();
        defer held.release();

        for (&self.fids) |*fid| {
            if (fid.state != .free and fid.fid_num == fid_num) {
                return fid;
            }
        }
        return null;
    }

    /// Look up a fid without locking (caller must hold lock)
    pub fn lookupUnlocked(self: *Self, fid_num: u32) ?*Fid {
        for (&self.fids) |*fid| {
            if (fid.state != .free and fid.fid_num == fid_num) {
                return fid;
            }
        }
        return null;
    }

    /// Release a fid back to the free pool
    pub fn release(self: *Self, fid: *Fid) void {
        const held = self.lock.acquire();
        defer held.release();

        if (fid.state != .free) {
            fid.release();
            if (self.active_count > 0) {
                self.active_count -= 1;
            }
        }
    }

    /// Release a fid by number
    pub fn releaseByNum(self: *Self, fid_num: u32) bool {
        const held = self.lock.acquire();
        defer held.release();

        for (&self.fids) |*fid| {
            if (fid.state != .free and fid.fid_num == fid_num) {
                fid.release();
                if (self.active_count > 0) {
                    self.active_count -= 1;
                }
                return true;
            }
        }
        return false;
    }

    /// Clone a fid to a new fid number (for walk with newfid)
    pub fn clone(self: *Self, src_fid_num: u32, dst_fid_num: u32) ?*Fid {
        const held = self.lock.acquire();
        defer held.release();

        // Find source fid
        var src_fid: ?*Fid = null;
        for (&self.fids) |*fid| {
            if (fid.state != .free and fid.fid_num == src_fid_num) {
                src_fid = fid;
                break;
            }
        }

        if (src_fid == null) return null;

        // Find free slot for destination
        for (&self.fids) |*fid| {
            if (fid.state == .free) {
                fid.fid_num = dst_fid_num;
                fid.state = src_fid.?.state;
                fid.qid = src_fid.?.qid;
                fid.open_mode = 0; // Clone is not opened
                fid.position = 0;
                fid.iounit = 0;
                fid.refcount = 1;
                @memcpy(fid.path[0..src_fid.?.path_len], src_fid.?.path[0..src_fid.?.path_len]);
                fid.path_len = src_fid.?.path_len;
                self.active_count += 1;
                return fid;
            }
        }

        return null;
    }

    /// Get the number of active fids
    pub fn getActiveCount(self: *Self) usize {
        const held = self.lock.acquire();
        defer held.release();
        return self.active_count;
    }

    /// Iterate over all active fids (for cleanup)
    pub fn forEachActive(self: *Self, callback: *const fn (*Fid) void) void {
        const held = self.lock.acquire();
        defer held.release();

        for (&self.fids) |*fid| {
            if (fid.state != .free) {
                callback(fid);
            }
        }
    }

    /// Release all fids (for unmount/disconnect)
    pub fn releaseAll(self: *Self) void {
        const held = self.lock.acquire();
        defer held.release();

        for (&self.fids) |*fid| {
            fid.release();
        }
        self.active_count = 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "FidTable allocate and release" {
    const testing = std.testing;

    var table = FidTable.init();

    // Allocate a fid
    const fid1 = table.allocate();
    try testing.expect(fid1 != null);
    try testing.expectEqual(FidState.allocated, fid1.?.state);
    try testing.expectEqual(@as(usize, 1), table.getActiveCount());

    // Allocate another
    const fid2 = table.allocate();
    try testing.expect(fid2 != null);
    try testing.expect(fid1.?.fid_num != fid2.?.fid_num);
    try testing.expectEqual(@as(usize, 2), table.getActiveCount());

    // Release first
    table.release(fid1.?);
    try testing.expectEqual(FidState.free, fid1.?.state);
    try testing.expectEqual(@as(usize, 1), table.getActiveCount());
}

test "FidTable lookup" {
    const testing = std.testing;

    var table = FidTable.init();

    const fid = table.allocate().?;
    const fid_num = fid.fid_num;

    // Should find the fid
    const found = table.lookup(fid_num);
    try testing.expect(found != null);
    try testing.expectEqual(fid_num, found.?.fid_num);

    // Should not find a non-existent fid
    try testing.expect(table.lookup(0xDEADBEEF) == null);
}

test "FidTable allocateWithNum" {
    const testing = std.testing;

    var table = FidTable.init();

    // Allocate root fid
    const root = table.allocateWithNum(config.P9_ROOT_FID);
    try testing.expect(root != null);
    try testing.expectEqual(config.P9_ROOT_FID, root.?.fid_num);

    // Should not be able to allocate same number again
    try testing.expect(table.allocateWithNum(config.P9_ROOT_FID) == null);
}

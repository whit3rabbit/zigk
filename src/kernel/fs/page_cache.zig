//! VFS Page Cache
//!
//! Stores file data in physical pages indexed by (file_id, page_offset).
//! This is the foundation for zero-copy data transfer between file descriptors,
//! replacing the 64KB heap-allocated kernel buffers used by splice/sendfile/tee/copy_file_range.
//!
//! Pages are reference counted: callers obtain references via getPages() and release
//! them via releasePages(). Pages with ref_count == 0 remain cached for future hits
//! until eviction is needed.
//!
//! Lock ordering: page_cache.lock is acquired AFTER FileDescriptor.lock
//! (higher number in the lock ordering hierarchy, between FD lock and scheduler lock).
//! When getPages needs to call read_fn, it must NOT hold page_cache.lock while calling
//! read_fn -- acquire fd.lock, do I/O, release fd.lock, then acquire page_cache.lock
//! to insert the page.

const std = @import("std");
const pmm = @import("pmm");
const hal = @import("hal");
const heap = @import("heap");
const sync = @import("sync");
const fd_mod = @import("fd");
const console = @import("console");

const FileDescriptor = fd_mod.FileDescriptor;

/// Page size constant (4KB)
const PAGE_SIZE: u64 = 4096;

/// Number of hash buckets for the page cache
const HASH_BUCKETS: usize = 256;

/// Maximum number of cached pages (4MB of cached data)
const MAX_CACHED_PAGES: usize = 1024;

/// Function type for reading file data to populate a cache page
pub const ReadFn = *const fn (fd: *FileDescriptor, buf: []u8) isize;

/// Function type for writing dirty page data back to a file
pub const WriteFn = *const fn (fd: *FileDescriptor, buf: []const u8) isize;

/// A reference to a range within a cached page.
/// Returned by getPages() to describe which portion of a page covers
/// the requested byte range.
pub const PageRef = struct {
    page: *CachedPage,
    offset_in_page: usize,
    len: usize,
};

/// A single cached page of file data.
/// Stored in a hash chain (linked list) within the page cache.
pub const CachedPage = struct {
    /// Physical address of the 4KB page
    phys_addr: u64,
    /// Identifies the file (uses FileDescriptor.file_identifier)
    file_id: u64,
    /// Page-aligned offset within the file (byte offset / PAGE_SIZE)
    page_offset: u64,
    /// Reference count, starts at 1 when inserted into the cache
    ref_count: std.atomic.Value(u32),
    /// True if page has been modified and needs write-back
    dirty: bool,
    /// True if page contains valid data (vs allocated but not yet populated)
    valid: bool,
    /// Next page in hash chain
    next: ?*CachedPage,
};

/// Global page cache singleton.
/// Uses a fixed-size hash table with chained buckets for O(1) average lookup.
pub const PageCache = struct {
    /// Hash table buckets, each is the head of a linked list of CachedPage entries
    buckets: [HASH_BUCKETS]?*CachedPage,
    /// Protects all hash table operations (lookup, insert, remove)
    lock: sync.Spinlock,
    /// Count of cached pages for statistics and eviction threshold
    total_pages: usize,

    /// Hash function: maps (file_id, page_offset) to a bucket index.
    /// Uses two large prime multipliers with wrapping multiply and XOR.
    fn hash(file_id: u64, page_offset: u64) usize {
        return @intCast(((file_id *% 0x9E3779B97F4A7C15) ^ (page_offset *% 0x517CC1B727220A95)) % HASH_BUCKETS);
    }

    /// Look up a cached page by file_id and page_offset.
    /// Caller MUST hold page_cache lock.
    fn lookupLocked(self: *PageCache, file_id: u64, page_offset: u64) ?*CachedPage {
        const bucket = hash(file_id, page_offset);
        var page = self.buckets[bucket];
        while (page) |p| {
            if (p.file_id == file_id and p.page_offset == page_offset) {
                return p;
            }
            page = p.next;
        }
        return null;
    }

    /// Insert a page into the hash table.
    /// Caller MUST hold page_cache lock.
    fn insertLocked(self: *PageCache, page: *CachedPage) void {
        const bucket = hash(page.file_id, page.page_offset);
        page.next = self.buckets[bucket];
        self.buckets[bucket] = page;
        self.total_pages += 1;
    }

    /// Remove a specific page from the hash table.
    /// Caller MUST hold page_cache lock.
    /// Returns true if the page was found and removed.
    fn removeLocked(self: *PageCache, page: *CachedPage) bool {
        const bucket = hash(page.file_id, page.page_offset);
        var prev: ?*CachedPage = null;
        var current = self.buckets[bucket];
        while (current) |c| {
            if (c == page) {
                if (prev) |p| {
                    p.next = c.next;
                } else {
                    self.buckets[bucket] = c.next;
                }
                c.next = null;
                self.total_pages -= 1;
                return true;
            }
            prev = c;
            current = c.next;
        }
        return false;
    }

    /// Evict a single unreferenced, non-dirty page to make room.
    /// Caller MUST hold page_cache lock.
    /// Returns true if a page was evicted.
    fn evictOneLocked(self: *PageCache) bool {
        // First pass: look for unreferenced, non-dirty pages
        for (&self.buckets) |*bucket_ptr| {
            var prev: ?*CachedPage = null;
            var current = bucket_ptr.*;
            while (current) |c| {
                if (c.ref_count.load(.acquire) == 0 and !c.dirty) {
                    // Remove from chain
                    if (prev) |p| {
                        p.next = c.next;
                    } else {
                        bucket_ptr.* = c.next;
                    }
                    self.total_pages -= 1;

                    // Free physical page and CachedPage struct
                    pmm.freePages(c.phys_addr, 1);
                    heap.allocator().destroy(c);
                    return true;
                }
                prev = c;
                current = c.next;
            }
        }
        return false;
    }

    /// Allocate a new CachedPage backed by a physical page.
    /// Does NOT hold page_cache lock (allocates from PMM and heap).
    fn allocatePage(file_id: u64, page_offset: u64) ?*CachedPage {
        // Allocate physical page (zero-initialized to prevent info leaks)
        const phys = pmm.allocZeroedPages(1) orelse {
            console.warn("page_cache: PMM allocation failed for file_id={d} offset={d}", .{ file_id, page_offset });
            return null;
        };

        // Allocate CachedPage metadata struct
        const page = heap.allocator().create(CachedPage) catch {
            // Failed to allocate metadata, free the physical page
            pmm.freePages(phys, 1);
            console.warn("page_cache: heap allocation failed for CachedPage metadata", .{});
            return null;
        };

        page.* = CachedPage{
            .phys_addr = phys,
            .file_id = file_id,
            .page_offset = page_offset,
            .ref_count = .{ .raw = 1 },
            .dirty = false,
            .valid = false,
            .next = null,
        };

        return page;
    }

    /// Populate a page with data from the backing store via read_fn.
    /// Acquires fd.lock, saves/restores fd.position, calls read_fn.
    /// Does NOT hold page_cache lock.
    fn populatePage(page: *CachedPage, read_fn: ReadFn, fd: *FileDescriptor) void {
        const virt = hal.paging.physToVirt(page.phys_addr);
        const buf = virt[0..PAGE_SIZE];

        // Calculate the byte offset for this page
        const byte_offset = std.math.mul(u64, page.page_offset, PAGE_SIZE) catch {
            console.warn("page_cache: offset overflow for page_offset={d}", .{page.page_offset});
            return;
        };

        // Acquire fd.lock to protect position manipulation
        const fd_held = fd.lock.acquire();

        // Save current position
        const saved_pos = fd.position;

        // Seek to the target page offset
        fd.position = byte_offset;

        // Read data into the page
        const bytes_read = read_fn(fd, buf);

        // Restore original position
        fd.position = saved_pos;

        fd_held.release();

        if (bytes_read > 0) {
            page.valid = true;
        } else {
            // Read returned 0 or error -- page stays zeroed (from allocZeroedPages)
            // but mark valid since we attempted the read (could be EOF)
            page.valid = true;
        }
    }
};

/// Global page cache instance
var global_cache: PageCache = undefined;

/// Initialize the global page cache.
/// Must be called during VFS initialization before any files are opened.
pub fn init() void {
    global_cache = PageCache{
        .buckets = [_]?*CachedPage{null} ** HASH_BUCKETS,
        .lock = .{},
        .total_pages = 0,
    };
    console.info("Page cache initialized ({d} buckets, max {d} pages / {d}KB)", .{
        HASH_BUCKETS,
        MAX_CACHED_PAGES,
        MAX_CACHED_PAGES * 4,
    });
}

/// Get cached pages covering the requested byte range of a file.
///
/// Returns a heap-allocated slice of PageRef structs. The caller is responsible
/// for releasing these via releasePages() when done.
///
/// For each page in the range:
/// - If cached: increments ref_count and returns existing page
/// - If not cached: allocates a physical page, optionally populates via read_fn,
///   and inserts into the cache
/// - Read-ahead: on cache miss, prefetches the NEXT page if within file bounds
///
/// Parameters:
/// - file_id: file identifier from FileDescriptor.file_identifier
/// - offset: byte offset into the file (need not be page-aligned)
/// - len: number of bytes requested
/// - read_fn: optional function to populate pages on miss
/// - fd: optional FileDescriptor for read_fn (required if read_fn is provided)
///
/// Returns error.ENOMEM if allocation fails.
pub fn getPages(file_id: u64, offset: u64, len: usize, read_fn: ?ReadFn, fd: ?*FileDescriptor) ![]PageRef {
    if (len == 0) {
        // Return empty slice
        return &[_]PageRef{};
    }

    // Calculate page range
    const start_page = offset / PAGE_SIZE;
    const end_byte = std.math.add(u64, offset, @as(u64, @intCast(len))) catch return error.ENOMEM;
    // end_page is inclusive: the last page that contains data
    const end_page = if (end_byte == 0) 0 else (end_byte - 1) / PAGE_SIZE;
    const num_pages_u64 = std.math.add(u64, end_page - start_page, 1) catch return error.ENOMEM;
    const num_pages: usize = std.math.cast(usize, num_pages_u64) orelse return error.ENOMEM;

    // Allocate PageRef array from heap
    const alloc = heap.allocator();
    const refs = alloc.alloc(PageRef, num_pages) catch return error.ENOMEM;
    errdefer alloc.free(refs);

    var pages_filled: usize = 0;
    var did_miss = false;

    for (0..num_pages) |i| {
        const page_idx = start_page + @as(u64, @intCast(i));

        // Try cache lookup first
        var page: ?*CachedPage = null;
        {
            const held = global_cache.lock.acquire();
            page = global_cache.lookupLocked(file_id, page_idx);
            if (page) |p| {
                _ = p.ref_count.fetchAdd(1, .monotonic);
            }
            held.release();
        }

        if (page == null) {
            // Cache miss -- allocate and optionally populate outside the lock
            did_miss = true;

            // Ensure we have room (evict if needed)
            {
                const held = global_cache.lock.acquire();
                while (global_cache.total_pages >= MAX_CACHED_PAGES) {
                    if (!global_cache.evictOneLocked()) {
                        held.release();
                        // Cannot evict -- free already-acquired pages and fail
                        for (refs[0..pages_filled]) |*r| {
                            _ = r.page.ref_count.fetchSub(1, .release);
                        }
                        alloc.free(refs);
                        return error.ENOMEM;
                    }
                }
                held.release();
            }

            const new_page = PageCache.allocatePage(file_id, page_idx) orelse {
                // Allocation failed -- release already-acquired refs
                for (refs[0..pages_filled]) |*r| {
                    _ = r.page.ref_count.fetchSub(1, .release);
                }
                alloc.free(refs);
                return error.ENOMEM;
            };

            // Populate the page if read_fn is provided
            if (read_fn) |rfn| {
                if (fd) |file_desc| {
                    PageCache.populatePage(new_page, rfn, file_desc);
                }
            } else {
                // No read_fn -- page is zeroed, mark valid
                new_page.valid = true;
            }

            // Insert into cache under lock
            // Check if another thread inserted the same page while we were reading
            {
                const held = global_cache.lock.acquire();
                const existing = global_cache.lookupLocked(file_id, page_idx);
                if (existing) |e| {
                    // Another thread beat us -- use theirs, free ours
                    _ = e.ref_count.fetchAdd(1, .monotonic);
                    held.release();

                    // Free our duplicate
                    pmm.freePages(new_page.phys_addr, 1);
                    alloc.destroy(new_page);

                    page = e;
                } else {
                    global_cache.insertLocked(new_page);
                    held.release();
                    page = new_page;
                }
            }
        }

        // Calculate the offset and length within this page
        const page_start_byte = std.math.mul(u64, page_idx, PAGE_SIZE) catch {
            // Overflow -- should not happen since we checked above
            for (refs[0..pages_filled]) |*r| {
                _ = r.page.ref_count.fetchSub(1, .release);
            }
            alloc.free(refs);
            return error.ENOMEM;
        };

        const offset_in_page: usize = if (offset > page_start_byte)
            @intCast(offset - page_start_byte)
        else
            0;

        const page_end_byte = std.math.add(u64, page_start_byte, PAGE_SIZE) catch PAGE_SIZE;
        const available_in_page = @as(usize, @intCast(@min(page_end_byte, end_byte) - @max(page_start_byte, offset)));

        refs[pages_filled] = PageRef{
            .page = page.?,
            .offset_in_page = offset_in_page,
            .len = available_in_page,
        };
        pages_filled += 1;
    }

    // Read-ahead: on cache miss, prefetch the next page
    if (did_miss and read_fn != null and fd != null) {
        const next_page_idx = end_page + 1;
        readAhead(file_id, next_page_idx, read_fn.?, fd.?);
    }

    return refs;
}

/// Prefetch a single page into the cache (read-ahead).
/// Best-effort: silently ignores allocation or I/O failures.
fn readAhead(file_id: u64, page_offset: u64, read_fn: ReadFn, fd: *FileDescriptor) void {
    // Check if already cached
    {
        const held = global_cache.lock.acquire();
        if (global_cache.lookupLocked(file_id, page_offset) != null) {
            held.release();
            return; // Already cached, no need to prefetch
        }
        // Check capacity
        if (global_cache.total_pages >= MAX_CACHED_PAGES) {
            held.release();
            return; // Cache full, skip read-ahead
        }
        held.release();
    }

    const new_page = PageCache.allocatePage(file_id, page_offset) orelse return;
    PageCache.populatePage(new_page, read_fn, fd);

    // Insert into cache
    {
        const held = global_cache.lock.acquire();
        const existing = global_cache.lookupLocked(file_id, page_offset);
        if (existing != null) {
            // Another thread inserted it -- free ours
            held.release();
            pmm.freePages(new_page.phys_addr, 1);
            heap.allocator().destroy(new_page);
            return;
        }
        // Decrease initial ref_count since read-ahead pages start unreferenced
        _ = new_page.ref_count.fetchSub(1, .release);
        global_cache.insertLocked(new_page);
        held.release();
    }
}

/// Release page references obtained from getPages().
/// Decrements ref_count on each page and frees the PageRef array.
/// Does NOT evict pages -- they stay cached with ref_count=0 for future hits.
pub fn releasePages(refs: []PageRef) void {
    for (refs) |*r| {
        const old = r.page.ref_count.fetchSub(1, .release);
        if (old == 0) {
            // Underflow -- should not happen but handle defensively
            console.warn("page_cache: releasePages ref_count underflow for file_id={d} offset={d}", .{
                r.page.file_id, r.page.page_offset,
            });
            r.page.ref_count.store(0, .monotonic);
        }
    }
    // Free the PageRef array
    if (refs.len > 0) {
        heap.allocator().free(refs);
    }
}

/// Mark a cached page as dirty (modified, needs write-back).
pub fn markDirty(page: *CachedPage) void {
    page.dirty = true;
}

/// Write back all dirty pages for a given file to the backing store.
/// Called on fsync or file close.
///
/// Iterates all buckets, finds pages matching file_id with dirty flag set,
/// writes them back via write_fn, and clears the dirty flag.
/// Acquires/releases page_cache lock per scan iteration to avoid holding
/// the lock during I/O.
pub fn writeback(file_id: u64, write_fn: WriteFn, fd: *FileDescriptor) void {
    // Collect dirty pages for this file under lock, then write them back outside lock.
    // We iterate buckets and process one dirty page at a time to minimize lock hold time.
    var bucket_idx: usize = 0;
    while (bucket_idx < HASH_BUCKETS) : (bucket_idx += 1) {
        while (true) {
            // Find next dirty page in this bucket
            var dirty_page: ?*CachedPage = null;
            {
                const held = global_cache.lock.acquire();
                var current = global_cache.buckets[bucket_idx];
                while (current) |c| {
                    if (c.file_id == file_id and c.dirty) {
                        dirty_page = c;
                        // Take a reference to prevent eviction while we write
                        _ = c.ref_count.fetchAdd(1, .monotonic);
                        break;
                    }
                    current = c.next;
                }
                held.release();
            }

            const dp = dirty_page orelse break; // No more dirty pages in this bucket

            // Write back outside the lock
            const virt = hal.paging.physToVirt(dp.phys_addr);
            const buf = virt[0..PAGE_SIZE];

            // Calculate byte offset for this page
            const byte_offset = std.math.mul(u64, dp.page_offset, PAGE_SIZE) catch {
                console.warn("page_cache: writeback offset overflow for page_offset={d}", .{dp.page_offset});
                _ = dp.ref_count.fetchSub(1, .release);
                break;
            };

            // Acquire fd.lock to protect position manipulation
            const fd_held = fd.lock.acquire();
            const saved_pos = fd.position;
            fd.position = byte_offset;
            _ = write_fn(fd, buf);
            fd.position = saved_pos;
            fd_held.release();

            // Clear dirty flag under lock
            {
                const held = global_cache.lock.acquire();
                dp.dirty = false;
                held.release();
            }

            // Release our reference
            _ = dp.ref_count.fetchSub(1, .release);
        }
    }
}

/// Invalidate all cached pages for a given file.
/// Removes pages from the cache and frees physical pages for entries with ref_count == 0.
/// Entries with ref_count > 0 are marked invalid (will be freed when released).
pub fn invalidate(file_id: u64) void {
    const alloc = heap.allocator();
    const held = global_cache.lock.acquire();
    defer held.release();

    for (&global_cache.buckets) |*bucket_ptr| {
        var prev: ?*CachedPage = null;
        var current = bucket_ptr.*;
        while (current) |c| {
            const next = c.next;
            if (c.file_id == file_id) {
                if (c.ref_count.load(.acquire) == 0) {
                    // Unreferenced -- remove and free
                    if (prev) |p| {
                        p.next = next;
                    } else {
                        bucket_ptr.* = next;
                    }
                    global_cache.total_pages -= 1;
                    c.next = null;

                    // Free physical page and metadata
                    pmm.freePages(c.phys_addr, 1);
                    alloc.destroy(c);

                    // prev stays the same, current advances to next
                    current = next;
                    continue;
                } else {
                    // Referenced -- mark invalid but leave in cache
                    c.valid = false;
                }
            }
            prev = c;
            current = next;
        }
    }
}

/// Get the kernel virtual address for a cached page's physical memory.
/// Uses the HHDM (Higher Half Direct Map) to convert physical to virtual.
pub fn getPageData(page: *CachedPage) [*]u8 {
    return hal.paging.physToVirt(page.phys_addr);
}

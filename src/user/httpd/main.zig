// Async HTTP Server using io_uring
//
// Demonstrates Zscapek's async I/O capabilities with proper kernel-level
// blocking (no spin-polling). Uses io_uring for accept, recv, send operations.
//
// Flow:
//   1. Setup io_uring ring
//   2. Submit accept SQE for listener
//   3. Wait for completions (properly blocks in kernel)
//   4. Handle completions: accept -> recv -> send -> close
//   5. Resubmit accept for next connection

const std = @import("std");
const syscall = @import("syscall");

const MAX_CLIENTS = 32;
const LISTEN_PORT = 80;
const RING_ENTRIES = 64;

// Operation types for user_data encoding
const OpType = enum(u8) {
    accept = 0,
    recv = 1,
    send = 2,
    close = 3,
};

// Encode operation type and fd into user_data
fn encodeUserData(op: OpType, fd: i32) u64 {
    return (@as(u64, @intFromEnum(op)) << 56) | @as(u64, @bitCast(@as(i64, fd)));
}

// Decode operation type from user_data
fn decodeOp(user_data: u64) OpType {
    return @enumFromInt(@as(u8, @truncate(user_data >> 56)));
}

// Decode fd from user_data
fn decodeFd(user_data: u64) i32 {
    return @truncate(@as(i64, @bitCast(user_data & 0x00FFFFFFFFFFFFFF)));
}

// Per-client state for managing buffers
const ClientState = struct {
    fd: i32 = -1,
    buf: [1024]u8 = undefined,
    in_use: bool = false,
};

var clients: [MAX_CLIENTS]ClientState = [_]ClientState{.{}} ** MAX_CLIENTS;

fn allocClient(fd: i32) ?*ClientState {
    for (&clients) |*c| {
        if (!c.in_use) {
            c.fd = fd;
            c.in_use = true;
            return c;
        }
    }
    return null;
}

fn freeClient(fd: i32) void {
    for (&clients) |*c| {
        if (c.in_use and c.fd == fd) {
            c.in_use = false;
            c.fd = -1;
            return;
        }
    }
}

fn getClient(fd: i32) ?*ClientState {
    for (&clients) |*c| {
        if (c.in_use and c.fd == fd) {
            return c;
        }
    }
    return null;
}

pub export fn _start() noreturn {
    if (main()) |_| {} else |_| {
        syscall.print("Httpd crashed\n");
        syscall.exit(1);
    }
    syscall.exit(0);
}

fn main() !void {
    syscall.print("Starting HTTP Server (io_uring) on port 80...\n");

    // Create listener socket
    const listener = try syscall.socket(syscall.AF_INET, syscall.SOCK_STREAM, 0);
    const addr = syscall.SockAddrIn.init(0, LISTEN_PORT);

    // Bind and listen
    try syscall.bind(listener, &addr);
    try syscall.listen(listener, 10);

    syscall.print("Listening...\n");

    // Initialize io_uring
    var ring = syscall.IoUring.init(RING_ENTRIES) catch |err| {
        syscall.print("Failed to init io_uring: ");
        printError(err);
        syscall.print("\nFalling back to poll mode...\n");
        return runPollMode(listener);
    };
    defer ring.deinit();

    syscall.print("io_uring initialized, using async I/O\n");

    // Submit initial accept
    submitAccept(&ring, listener);

    // Event loop
    while (true) {
        // Submit pending and wait for at least 1 completion
        // This properly blocks in kernel (no spin-polling)
        _ = ring.submit(1) catch |err| {
            syscall.print("io_uring_enter failed: ");
            printError(err);
            syscall.print("\n");
            continue;
        };

        // Process all ready completions
        while (ring.peekCqe()) |cqe| {
            handleCompletion(&ring, listener, cqe);
            ring.advanceCq();
        }
    }
}

fn submitAccept(ring: *syscall.IoUring, listener: i32) void {
    _ = ring.getSqeAtomicFn(&populateAccept, @ptrFromInt(@as(usize, @intCast(listener))));
}

fn populateAccept(sqe: *syscall.IoUringSqe, ctx: ?*anyopaque) void {
    const listener: i32 = @intCast(@intFromPtr(ctx));
    syscall.IoUring.prepAccept(sqe, listener, null, null, encodeUserData(.accept, listener));
}

fn submitRecv(ring: *syscall.IoUring, client: *ClientState) void {
    _ = ring.getSqeAtomicFn(&populateRecv, client);
}

fn populateRecv(sqe: *syscall.IoUringSqe, ctx: ?*anyopaque) void {
    const client: *ClientState = @ptrCast(@alignCast(ctx));
    syscall.IoUring.prepRecv(sqe, client.fd, &client.buf, encodeUserData(.recv, client.fd));
}

fn submitSend(ring: *syscall.IoUring, fd: i32, data: []const u8) void {
    // Pack fd and data pointer into a stack struct for the callback
    const SendCtx = struct { fd: i32, data: []const u8 };
    var send_ctx = SendCtx{ .fd = fd, .data = data };
    _ = ring.getSqeAtomicFn(&populateSend, @ptrCast(&send_ctx));
}

fn populateSend(sqe: *syscall.IoUringSqe, ctx: ?*anyopaque) void {
    const SendCtx = struct { fd: i32, data: []const u8 };
    const send_ctx: *SendCtx = @ptrCast(@alignCast(ctx));
    syscall.IoUring.prepSend(sqe, send_ctx.fd, send_ctx.data, encodeUserData(.send, send_ctx.fd));
}

fn submitClose(ring: *syscall.IoUring, fd: i32) void {
    _ = ring.getSqeAtomicFn(&populateClose, @ptrFromInt(@as(usize, @intCast(fd))));
}

fn populateClose(sqe: *syscall.IoUringSqe, ctx: ?*anyopaque) void {
    const fd: i32 = @intCast(@intFromPtr(ctx));
    syscall.IoUring.prepClose(sqe, fd, encodeUserData(.close, fd));
}

fn handleCompletion(ring: *syscall.IoUring, listener: i32, cqe: *syscall.IoUringCqe) void {
    const op = decodeOp(cqe.user_data);
    const fd = decodeFd(cqe.user_data);

    switch (op) {
        .accept => {
            // Always resubmit accept for next connection
            submitAccept(ring, listener);

            if (cqe.res < 0) {
                // Accept failed, just continue
                return;
            }

            const client_fd: i32 = cqe.res;

            // Allocate client state
            if (allocClient(client_fd)) |client| {
                submitRecv(ring, client);
            } else {
                // No client slots, close immediately
                syscall.print("Too many clients\n");
                submitClose(ring, client_fd);
            }
        },

        .recv => {
            if (cqe.res <= 0) {
                // Connection closed or error
                freeClient(fd);
                submitClose(ring, fd);
                return;
            }

            // Got request, send response
            const response =
                "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/html\r\n" ++
                "Connection: close\r\n" ++
                "\r\n" ++
                "<html><head><title>Zscapek HTTPD</title></head>" ++
                "<body><h1>Hello from Zscapek!</h1>" ++
                "<p>This is a microkernel running a userspace HTTP server.</p>" ++
                "<p>Powered by io_uring async I/O.</p>" ++
                "</body></html>";

            submitSend(ring, fd, response);
        },

        .send => {
            // Response sent, close connection
            freeClient(fd);
            submitClose(ring, fd);
        },

        .close => {
            // Close completed, nothing more to do
        },
    }
}

fn printError(err: syscall.SyscallError) void {
    const msg = switch (err) {
        error.PermissionDenied => "EPERM",
        error.NoSuchFileOrDirectory => "ENOENT",
        error.NoSuchProcess => "ESRCH",
        error.Interrupted => "EINTR",
        error.IoError => "EIO",
        error.NoSuchDevice => "ENXIO",
        error.ArgumentListTooLong => "E2BIG",
        error.ExecFormatError => "ENOEXEC",
        error.BadFileDescriptor => "EBADF",
        error.NoChildProcesses => "ECHILD",
        error.WouldBlock => "EAGAIN",
        error.OutOfMemory => "ENOMEM",
        error.AccessDenied => "EACCES",
        error.BadAddress => "EFAULT",
        error.DeviceBusy => "EBUSY",
        error.FileExists => "EEXIST",
        error.InvalidArgument => "EINVAL",
        error.TooManyOpenFiles => "EMFILE",
        error.NotImplemented => "ENOSYS",
        error.Unexpected => "UNKNOWN",
    };
    syscall.print(msg);
}

// Fallback poll-based implementation
fn runPollMode(listener: i32) !void {
    const POLLIN = syscall.POLLIN;

    var fds: [1 + MAX_CLIENTS]syscall.PollFd = undefined;

    // Setup listener
    fds[0] = .{
        .fd = listener,
        .events = POLLIN,
        .revents = 0,
    };

    // Initialize client slots
    for (1..fds.len) |i| {
        fds[i] = .{
            .fd = -1,
            .events = POLLIN,
            .revents = 0,
        };
    }

    while (true) {
        const count = try syscall.poll(&fds, -1);

        if (count == 0) continue;

        // Check listener
        if ((fds[0].revents & POLLIN) != 0) {
            acceptClientPoll(&fds, listener);
        }

        // Check clients
        for (1..fds.len) |i| {
            if (fds[i].fd == -1) continue;

            if ((fds[i].revents & POLLIN) != 0) {
                handleClientPoll(&fds[i]);
            } else if ((fds[i].revents & (syscall.POLLHUP | syscall.POLLERR)) != 0) {
                closeClientPoll(&fds[i]);
            }
        }
    }
}

fn acceptClientPoll(fds: []syscall.PollFd, listener: i32) void {
    const client_fd = syscall.accept(listener, null) catch {
        return;
    };

    for (1..fds.len) |i| {
        if (fds[i].fd == -1) {
            fds[i].fd = client_fd;
            fds[i].events = syscall.POLLIN;
            fds[i].revents = 0;
            return;
        }
    }

    syscall.print("Too many clients\n");
    syscall.close(client_fd) catch {};
}

fn closeClientPoll(pfd: *syscall.PollFd) void {
    if (pfd.fd != -1) {
        syscall.close(pfd.fd) catch {};
        pfd.fd = -1;
        pfd.revents = 0;
    }
}

fn handleClientPoll(pfd: *syscall.PollFd) void {
    var buf: [1024]u8 = undefined;
    const len = syscall.read(pfd.fd, &buf, buf.len) catch {
        closeClientPoll(pfd);
        return;
    };

    if (len == 0) {
        closeClientPoll(pfd);
        return;
    }

    const response =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/html\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "<html><head><title>Zscapek HTTPD</title></head>" ++
        "<body><h1>Hello from Zscapek!</h1>" ++
        "<p>This is a microkernel running a userspace HTTP server.</p>" ++
        "<p>Powered by poll() (fallback mode).</p>" ++
        "</body></html>";

    _ = syscall.write(pfd.fd, response, response.len) catch {};
    closeClientPoll(pfd);
}


const std = @import("std");
const syscall = @import("syscall");
const POLLIN = syscall.POLLIN;
const POLLOUT = syscall.POLLOUT;

const MAX_CLIENTS = 32;
const LISTEN_PORT = 80;

pub export fn _start() noreturn {
    if (main()) |_| {} else |_| {
        syscall.print("Httpd crashed\n");
        syscall.exit(1);
    }
    syscall.exit(0);
}

fn main() !void {
    syscall.print("Starting HTTP Server on port 80...\n");

    // Create listener socket
    const listener = try syscall.socket(syscall.AF_INET, syscall.SOCK_STREAM, 0);
    const addr = syscall.SockAddrIn.init(0, LISTEN_PORT);
    
    // Bind
    try syscall.bind(listener, &addr);
    
    // Listen
    try syscall.listen(listener, 10);
    
    syscall.print("Listening...\n");

    // Poll structure
    var fds: [1 + MAX_CLIENTS]syscall.PollFd = undefined;
    
    // Setup listener at index 0
    fds[0] = .{
        .fd = listener,
        .events = POLLIN,
        .revents = 0,
    };
    
    // Initialize clients
    for (1..fds.len) |i| {
        fds[i] = .{
            .fd = -1, // Unused
            .events = POLLIN,
            .revents = 0,
        };
    }
    
    while (true) {
        // Wait for events (blocks)
        const count = try syscall.poll(&fds, -1);
        
        if (count == 0) continue;
        
        // Check listener
        if ((fds[0].revents & POLLIN) != 0) {
            // Accept new connection
            acceptClient(&fds, listener);
        }
        
        // Check clients
        for (1..fds.len) |i| {
            if (fds[i].fd == -1) continue;
            
            if ((fds[i].revents & POLLIN) != 0) {
                // Read request
                handleClient(&fds[i]);
            } else if ((fds[i].revents & (syscall.POLLHUP | syscall.POLLERR)) != 0) {
                closeClient(&fds[i]);
            }
        }
    }
}

fn acceptClient(fds: []syscall.PollFd, listener: i32) void {
    const client_fd = syscall.accept(listener, null) catch {
        syscall.print("Accept failed\n");
        return;
    };
    
    // Find free slot
    for (1..fds.len) |i| {
        if (fds[i].fd == -1) {
            fds[i].fd = client_fd;
            fds[i].events = POLLIN;
            fds[i].revents = 0;
            // syscall.print("New client connected\n");
            return;
        }
    }
    
    // No slots
    syscall.print("Too many clients, closing\n");
    syscall.close(client_fd) catch {};
}

fn closeClient(pfd: *syscall.PollFd) void {
    if (pfd.fd != -1) {
        syscall.close(pfd.fd) catch {};
        pfd.fd = -1;
        pfd.revents = 0;
    }
}

fn handleClient(pfd: *syscall.PollFd) void {
    var buf: [1024]u8 = undefined;
    const len = syscall.read(pfd.fd, &buf, buf.len) catch {
        // Read error (connection reset etc)
        closeClient(pfd);
        return;
    };
    
    if (len == 0) {
        // EOF
        closeClient(pfd);
        return;
    }
    
    // Simple HTTP Response
    // We ignore the request content for now (just serve index)
    const response = 
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/html\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "<html><head><title>ZigK HTTPD</title></head>" ++
        "<body><h1>Hello from ZigK!</h1>" ++
        "<p>This is a microkernel running a userspace HTTP server.</p>" ++
        "<p>Powered by Zig poll() implementation.</p>" ++
        "</body></html>";

    _ = syscall.write(pfd.fd, response, response.len) catch {};
    
    // Close connection (short-lived)
    closeClient(pfd);
}

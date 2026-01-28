const std = @import("std");
const syscall = @import("syscall");
const uapi = syscall.uapi;

// Tokenize input string into space-separated tokens
// Returns number of tokens found (max 8)
fn tokenize(input: []const u8, tokens: *[8][]const u8) usize {
    var count: usize = 0;
    var i: usize = 0;

    while (i < input.len and count < 8) {
        // Skip leading spaces
        while (i < input.len and input[i] == ' ') : (i += 1) {}
        if (i >= input.len) break;

        // Mark start of token
        const start = i;

        // Find end of token (space or end of string)
        while (i < input.len and input[i] != ' ') : (i += 1) {}

        tokens[count] = input[start..i];
        count += 1;
    }

    return count;
}

// Print human-readable error message for syscall errors
fn printError(err: anyerror) void {
    const msg = switch (err) {
        error.ENOENT => "No such file or directory",
        error.ENOTDIR => "Not a directory",
        error.EISDIR => "Is a directory",
        error.EACCES => "Permission denied",
        error.EEXIST => "File exists",
        error.ENOTEMPTY => "Directory not empty",
        error.EBUSY => "Device or resource busy",
        error.ENOMEM => "Out of memory",
        error.ENOSPC => "No space left on device",
        error.EROFS => "Read-only file system",
        else => "Unknown error",
    };
    syscall.print(msg);
    syscall.print("\n");
}

// Print current working directory
fn cmd_pwd() void {
    var buf: [256]u8 = undefined;

    const len = syscall.getcwd(&buf, buf.len) catch |err| {
        syscall.print("pwd: ");
        printError(err);
        return;
    };

    const path = buf[0..len];
    syscall.print(path);
    syscall.print("\n");
}

// Change current working directory
fn cmd_cd(path: []const u8) void {
    const target = if (path.len == 0) "/" else path;

    // Null-terminate path for syscall
    var path_buf: [256]u8 = undefined;
    if (target.len >= path_buf.len) {
        syscall.print("cd: path too long\n");
        return;
    }
    @memcpy(path_buf[0..target.len], target);
    path_buf[target.len] = 0;

    const path_z: [*:0]const u8 = @ptrCast(&path_buf);
    syscall.chdir(path_z) catch |err| {
        syscall.print("cd: ");
        syscall.print(target);
        syscall.print(": ");
        printError(err);
        return;
    };
}

// List directory contents
fn cmd_ls(path: []const u8) void {
    const target = if (path.len == 0) "." else path;

    // Null-terminate path for syscall
    var path_buf: [256]u8 = undefined;
    if (target.len >= path_buf.len) {
        syscall.print("ls: path too long\n");
        return;
    }
    @memcpy(path_buf[0..target.len], target);
    path_buf[target.len] = 0;

    const path_z: [*:0]const u8 = @ptrCast(&path_buf);

    // Open directory
    const fd = syscall.open(path_z, syscall.O_RDONLY, 0) catch |err| {
        syscall.print("ls: cannot access '");
        syscall.print(target);
        syscall.print("': ");
        printError(err);
        return;
    };
    defer syscall.close(fd) catch {};

    // Buffer for getdents64 (2KB stack buffer)
    var buf: [2048]u8 = undefined;

    while (true) {
        const bytes_read = syscall.getdents64(fd, &buf, buf.len) catch |err| {
            syscall.print("ls: error reading directory: ");
            printError(err);
            return;
        };

        if (bytes_read == 0) break; // End of directory

        // Parse directory entries
        var offset: usize = 0;
        while (offset < bytes_read) {
            // Safety: Check we have at least the header size
            if (offset + @sizeOf(uapi.dirent.Dirent64) > bytes_read) break;

            const entry: *align(1) const uapi.dirent.Dirent64 = @ptrCast(&buf[offset]);

            // Validate d_reclen to prevent infinite loop
            if (entry.d_reclen == 0 or entry.d_reclen > bytes_read - offset) break;

            // Get null-terminated name
            const name_offset = offset + @offsetOf(uapi.dirent.Dirent64, "d_name");
            if (name_offset >= bytes_read) break;

            const name_ptr: [*:0]const u8 = @ptrCast(&buf[name_offset]);
            const name = std.mem.sliceTo(name_ptr, 0);

            // Skip . and .. entries
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
                offset += entry.d_reclen;
                continue;
            }

            // Print name with type indicator
            syscall.print(name);
            if (entry.d_type == uapi.dirent.DT_DIR) {
                syscall.print("/");
            }
            syscall.print("\n");

            offset += entry.d_reclen;
        }
    }
}

// Create a directory
fn cmd_mkdir(path: []const u8) void {
    if (path.len == 0) {
        syscall.print("mkdir: missing operand\n");
        return;
    }

    // Null-terminate path for syscall
    var path_buf: [256]u8 = undefined;
    if (path.len >= path_buf.len) {
        syscall.print("mkdir: path too long\n");
        return;
    }
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const path_z: [*:0]const u8 = @ptrCast(&path_buf);
    syscall.mkdir(path_z, 0o755) catch |err| {
        syscall.print("mkdir: cannot create directory '");
        syscall.print(path);
        syscall.print("': ");
        printError(err);
        return;
    };
}

// Remove an empty directory
fn cmd_rmdir(path: []const u8) void {
    if (path.len == 0) {
        syscall.print("rmdir: missing operand\n");
        return;
    }

    // Null-terminate path for syscall
    var path_buf: [256]u8 = undefined;
    if (path.len >= path_buf.len) {
        syscall.print("rmdir: path too long\n");
        return;
    }
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const path_z: [*:0]const u8 = @ptrCast(&path_buf);
    syscall.rmdir(path_z) catch |err| {
        syscall.print("rmdir: failed to remove '");
        syscall.print(path);
        syscall.print("': ");
        printError(err);
        return;
    };
}

pub fn main() void {
    syscall.print("\nZK Shell v0.1\n");
    syscall.print("Type 'help' for commands\n\n");

    var buffer: [256]u8 = undefined;

    while (true) {
        syscall.print("zk> ");

        // Read line
        var len: usize = 0;
        while (len < buffer.len) {
            const c = syscall.getchar() catch {
                syscall.print("Error reading input\n");
                continue;
            };

            // Echo back
            syscall.putchar(c) catch {};

            if (c == '\n') {
                break;
            } else if (c == 0x08 or c == 0x7F) { // Backspace
                if (len > 0) {
                    len -= 1;
                    // Backspace sequence for terminal
                    syscall.print("\x08 \x08"); 
                }
            } else {
                buffer[len] = c;
                len += 1;
            }
        }

        if (len == 0) continue;

        const input = buffer[0..len];

        // Tokenize input
        var tokens: [8][]const u8 = undefined;
        const token_count = tokenize(input, &tokens);
        if (token_count == 0) continue;

        const cmd = tokens[0];

        if (std.mem.eql(u8, cmd, "help")) {
            syscall.print("Available commands:\n");
            syscall.print("  help    - Show this help\n");
            syscall.print("  exit    - Exit shell\n");
            syscall.print("  clear   - Clear screen\n");
            syscall.print("  pwd     - Print working directory\n");
            syscall.print("  cd      - Change directory\n");
            syscall.print("  ls      - List directory contents\n");
            syscall.print("  mkdir   - Create directory\n");
            syscall.print("  rmdir   - Remove empty directory\n");
        } else if (std.mem.eql(u8, cmd, "exit")) {
            syscall.print("Exiting shell...\n");
            syscall.exit(0);
        } else if (std.mem.eql(u8, cmd, "clear")) {
            syscall.print("\x1b[2J\x1b[H");
        } else if (std.mem.eql(u8, cmd, "pwd")) {
            cmd_pwd();
        } else if (std.mem.eql(u8, cmd, "cd")) {
            const path = if (token_count > 1) tokens[1] else "";
            cmd_cd(path);
        } else if (std.mem.eql(u8, cmd, "ls")) {
            const path = if (token_count > 1) tokens[1] else "";
            cmd_ls(path);
        } else if (std.mem.eql(u8, cmd, "mkdir")) {
            const path = if (token_count > 1) tokens[1] else "";
            cmd_mkdir(path);
        } else if (std.mem.eql(u8, cmd, "rmdir")) {
            const path = if (token_count > 1) tokens[1] else "";
            cmd_rmdir(path);
        } else {
            syscall.print("Unknown command: ");
            syscall.print(cmd);
            syscall.print("\n");
        }
    }
}

// Entry point called by linker/crt0
export fn _start() noreturn {
    main();
    syscall.exit(0);
}

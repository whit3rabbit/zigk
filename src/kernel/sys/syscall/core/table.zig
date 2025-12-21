// Syscall Dispatch Table
//
// Dispatches syscalls to their handlers based on syscall number.
// All syscall numbers are imported from uapi.syscalls to ensure
// kernel/userland consistency (single source of truth).
//
// Syscall Convention (x86_64 Linux ABI):
//   RAX = syscall number
//   RDI, RSI, RDX, R10, R8, R9 = arguments 1-6
//   RAX = return value (or negative errno on error)

const std = @import("std");
const uapi = @import("uapi");
const console = @import("console");
const hal = @import("hal");
const signal = @import("signal");

// Handler modules (split from handlers.zig)
const process = @import("process");
const signals = @import("signals");
const scheduling = @import("scheduling");
const io = @import("io");
const fd = @import("fd");
const memory = @import("memory");
const execution = @import("execution");
const custom = @import("custom");
const net = @import("net");
const random = @import("random");
const input_handlers = @import("input");
const ipc = @import("ipc");
const interrupt = @import("interrupt");
const port_io = @import("port_io");
const mmio = @import("mmio");
const pci_syscall = @import("pci_syscall");
const ring = @import("ring");
const fs_handlers = @import("fs_handlers");

/// Syscall frame from arch-specific entry
pub const SyscallFrame = hal.syscall.SyscallFrame;

/// Dispatch a syscall and return the result
/// Called from the assembly syscall entry point
pub export fn dispatch_syscall(frame: *SyscallFrame) callconv(.c) void {
    const syscall_num = frame.getSyscallNumber();
    // Pre-calculate valid handlers at comptime to generate clean switch cases
    const handler_entries = comptime blk: {
        @setEvalBranchQuota(10000);
        const SyscallEntry = struct { value: usize, module: type, name: []const u8 };
        var entries: []const SyscallEntry = &.{};
        const decls = @typeInfo(uapi.syscalls).@"struct".decls;

        for (decls) |decl| {
            const val = @field(uapi.syscalls, decl.name);

            // Check if it's a usize constant (syscall number)
            if (@TypeOf(val) == usize) {
                const name = toSyscallName(decl.name);
                var mod: ?type = null;

                // Search handler modules in order of priority
                // net.zig owns socket syscalls
                if (@hasDecl(net, name)) {
                    mod = net;
                } else if (@hasDecl(process, name)) {
                    mod = process;
                } else if (@hasDecl(signals, name)) {
                    mod = signals;
                } else if (@hasDecl(scheduling, name)) {
                    mod = scheduling;
                } else if (@hasDecl(io, name)) {
                    mod = io;
                } else if (@hasDecl(fd, name)) {
                    mod = fd;
                } else if (@hasDecl(fs_handlers, name)) {
                    mod = fs_handlers;
                } else if (@hasDecl(memory, name)) {
                    mod = memory;
                } else if (@hasDecl(execution, name)) {
                    mod = execution;
                } else if (@hasDecl(custom, name)) {
                    mod = custom;
                } else if (@hasDecl(random, name)) {
                    mod = random;
                } else if (@hasDecl(input_handlers, name)) {
                    mod = input_handlers;
                } else if (@hasDecl(ipc, name)) {
                    mod = ipc;
                } else if (@hasDecl(interrupt, name)) {
                    mod = interrupt;
                } else if (@hasDecl(port_io, name)) {
                    mod = port_io;
                } else if (@hasDecl(mmio, name)) {
                    mod = mmio;
                } else if (@hasDecl(pci_syscall, name)) {
                    mod = pci_syscall;
                } else if (@hasDecl(ring, name)) {
                    mod = ring;
                }

                if (mod) |m| {
                    entries = entries ++ @as([]const SyscallEntry, &.{.{ .value = val, .module = m, .name = name }});
                }
                // Note: Syscalls without handlers will return ENOSYS at runtime.
                // This allows incremental syscall implementation during development.
            }
        }
        break :blk entries;
    };

    const args = frame.getArgs();

    // Syscall debug logging disabled - uncomment to enable
    // console.debug("Syscall: #{d} (args: {x} {x} {x})", .{ syscall_num, args[0], args[1], args[2] });

    // Use unrolled linear dispatch to avoid switch syntax limitations
    // LLVM will optimize this into a jump table/switch
    const result = blk: {
        inline for (handler_entries) |entry| {
            if (entry.value == syscall_num) {
                break :blk callHandler(@field(entry.module, entry.name), frame, args);
            }
        }

        // Default handler for unknown/unimplemented syscalls
        console.debug("Unknown or unimplemented syscall: {d}", .{syscall_num});
        break :blk uapi.errno.ENOSYS.toReturn();
    };

    // Set return value in frame
    frame.setReturnSigned(result);

    // Check for pending signals and deliver if necessary
    // This modifies the frame to jump to signal handler instead of returning normally
    signal.checkSignalsOnSyscallExit(frame);
}

/// Helper to call a handler with correct arguments
/// Automatically maps frame pointer and register arguments
/// Supports both legacy handlers (returning isize) and new error union handlers (returning SyscallError!usize)
inline fn callHandler(comptime func: anytype, frame: *SyscallFrame, args: [6]usize) isize {
    @setEvalBranchQuota(20000);
    const FuncType = @TypeOf(func);
    const type_info = @typeInfo(FuncType);

    // Handle function definitions directly vs function pointers if necessary
    // Functions are usually .Fn in Zig, but let's be safe
    const info = switch (type_info) {
        .@"fn" => |f| f,
        else => @compileError("Syscall handler must be a function: " ++ @typeName(FuncType)),
    };

    const ArgsTuple = std.meta.ArgsTuple(FuncType);
    var call_args: ArgsTuple = undefined;

    comptime var arg_idx = 0;

    inline for (info.params, 0..) |param, i| {
        // Special case: Pass frame pointer if requested
        if (param.type == *SyscallFrame) {
            call_args[i] = frame;
        } else {
            // Otherwise consume a register argument
            if (arg_idx >= 6) {
                @compileError("Syscall handler requires too many arguments");
            }
            const ArgType = param.type.?;
            switch (@typeInfo(ArgType)) {
                .int => |int_info| {
                    if (int_info.signedness == .signed) {
                        call_args[i] = @as(ArgType, @truncate(@as(isize, @bitCast(args[arg_idx]))));
                    } else {
                        call_args[i] = @as(ArgType, @truncate(args[arg_idx]));
                    }
                },
                .pointer => call_args[i] = @ptrFromInt(args[arg_idx]),
                else => {
                    if (@sizeOf(ArgType) == @sizeOf(usize)) {
                        call_args[i] = @as(ArgType, @bitCast(args[arg_idx]));
                    } else {
                        @compileError("Unsupported syscall argument type: " ++ @typeName(ArgType));
                    }
                },
            }
            arg_idx += 1;
        }
    }

    // Determine return type handling at comptime
    const ReturnType = info.return_type.?;

    // Legacy handler returning isize directly
    if (ReturnType == isize) {
        return @call(.auto, func, call_args);
    }

    // New error union handler returning SyscallError!usize
    const return_info = @typeInfo(ReturnType);
    if (return_info == .error_union) {
        const result = @call(.auto, func, call_args);
        if (result) |value| {
            return @as(isize, @intCast(value));
        } else |err| {
            return uapi.errno.errorToReturn(err);
        }
    }

    @compileError("Syscall handler must return isize or SyscallError!usize, got: " ++ @typeName(ReturnType));
}

/// Convert "SYS_NAME" to "sys_name" at comptime
fn toSyscallName(comptime name: []const u8) []const u8 {
    var buffer: [name.len]u8 = undefined;
    for (name, 0..) |c, i| {
        buffer[i] = std.ascii.toLower(c);
    }
    return buffer[0..name.len];
}

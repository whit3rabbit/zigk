// poll(2) readiness helper.

const types = @import("types.zig");
const state = @import("state.zig");
const tcp = @import("../tcp.zig");
const tcp_state = @import("../tcp/state.zig");
const uapi = @import("uapi");
const poll_def = uapi.poll;

/// Poll socket for events
/// Returns mask of ready events (POLLIN, POLLOUT, etc.)
///
/// Lock ordering: tcp_state.lock (5) -> socket/state.lock (6) per CLAUDE.md.
/// This matches the RX interrupt handler path which holds tcp_state.lock
/// while processing incoming packets that update socket state.
pub fn checkPollEvents(fd: usize, events: u16) u16 {
    // Acquire TCP state lock FIRST per documented lock ordering (CLAUDE.md item 5).
    // RX interrupt path holds tcp_state.lock then accesses sockets, so we must
    // acquire in the same order to prevent deadlock.
    const tcp_held = tcp_state.lock.acquire();
    defer tcp_held.release();

    const sock = state.acquireSocket(fd) orelse return poll_def.POLLNVAL;
    defer state.releaseSocket(sock);
    var revents: u16 = 0;

    // Check for readable data (POLLIN)
    if ((events & poll_def.POLLIN) != 0) {
        if (sock.sock_type == types.SOCK_DGRAM) {
            // UDP: Check RX queue
            if (sock.rx_count > 0) {
                revents |= poll_def.POLLIN;
            }
        } else if (sock.sock_type == types.SOCK_STREAM) {
            // TCP: Check receive buffer or state
            if (sock.tcb) |tcb| {
                if (tcb.state == .Listen) {
                    // Listen socket ready if accept queue not empty
                    if (sock.accept_count > 0) {
                        revents |= poll_def.POLLIN;
                    }
                } else if (tcb.state == .Established or tcb.state == .CloseWait) {
                    if (tcb.recvBufferAvailable() < tcp.BUFFER_SIZE) {
                        if (tcb.recvBufferAvailable() > 0) {
                            revents |= poll_def.POLLIN;
                        }
                    }
                    if (tcb.state == .CloseWait) {
                        // End of file is readable (returns 0)
                        revents |= poll_def.POLLIN;
                    }
                } else if (tcb.state == .Closed) {
                    revents |= poll_def.POLLHUP;
                }
            }
        }
    }

    // Check for writable data (POLLOUT)
    if ((events & poll_def.POLLOUT) != 0) {
        if (sock.sock_type == types.SOCK_DGRAM) {
            // UDP always writable (fire and forget basically)
            revents |= poll_def.POLLOUT;
        } else if (sock.sock_type == types.SOCK_STREAM) {
            if (sock.tcb) |tcb| {
                if (tcb.state == .Established or tcb.state == .CloseWait) {
                    if (tcb.sendBufferSpace() > 0) {
                        revents |= poll_def.POLLOUT;
                    }
                } else if (tcb.state == .SynSent or tcb.state == .SynReceived) {
                    // Still connecting
                } else {
                    revents |= poll_def.POLLERR;
                }
            }
        }
    }

    return revents;
}

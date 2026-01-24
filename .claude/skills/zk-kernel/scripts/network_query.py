#!/usr/bin/env python3
"""
Network Stack Query Tool for zk kernel.

Query network protocols, socket API, constants, and security features.

Usage:
    python network_query.py tcp              # TCP protocol overview
    python network_query.py tcp_states       # TCP state machine details
    python network_query.py socket           # Socket API and syscalls
    python network_query.py socket_options   # Socket options (setsockopt)
    python network_query.py udp              # UDP protocol
    python network_query.py arp              # ARP cache and resolution
    python network_query.py dns              # DNS resolver security
    python network_query.py icmp             # ICMP handling
    python network_query.py reassembly       # IP fragment reassembly
    python network_query.py security         # All security features
    python network_query.py constants        # Protocol constants/limits
    python network_query.py blocking         # Blocking I/O integration
    python network_query.py async            # Async socket API
    python network_query.py template <name>  # Generate code template
    python network_query.py --all            # List all topics

Templates:
    protocol      - New transport protocol handler
    socket_op     - Socket operation implementation
    packet_parse  - Safe packet parsing pattern
    state_machine - Protocol state machine pattern
"""

import sys

PATTERNS = {
    "tcp": """
## TCP Protocol Overview

Location: src/net/transport/tcp/

### Key Structures
- **TCB (Transmission Control Block)**: Per-connection state in `types.zig`
- **State Machine**: 11 states in `state.zig`
- **Hash Table**: 1024 buckets with SipHash-2-4 for collision resistance

### Buffer Sizes
- Send/Receive buffers: 8192 bytes (8KB)
- Receive window: 8192 bytes
- Max TCP payload: 1460 bytes (MTU - IP - TCP headers)

### Connection Limits
- TCB hash table: 1024 buckets
- Max TCBs: 256 connections
- Max half-open (SYN-RECEIVED): 128 connections

### ISN Generation (RFC 6528)
- Algorithm: M + F(4-tuple, secret_key)
- M = time component (250 increments/ms ~ 4us resolution)
- F = SipHash-2-4(key, local_ip, local_port, remote_ip, remote_port, entropy)
- Re-seed threshold: 10,000 ISN generations

### Retransmission
- Initial RTO: 1000ms
- Max RTO: 64000ms (64 seconds)
- Max retries: 8
- Delayed ACK: 200ms (RFC 1122)

### TCP Options Supported
- MSS (kind 2): Maximum Segment Size
- Window Scale (kind 3): RFC 7323
- SACK Permitted (kind 4): RFC 2018
- Timestamps (kind 8): RFC 7323
""",

    "tcp_states": """
## TCP State Machine (RFC 793)

Location: src/net/transport/tcp/types.zig (TcpState enum)

### States
```
                              +---------+
                              |  CLOSED |
                              +---------+
                                   |
              passive open         |  active open (send SYN)
              (listen)             v
          +---------+         +---------+
          | LISTEN  |         | SYN_SENT|
          +---------+         +---------+
               |                   |
     rcv SYN   |                   | rcv SYN+ACK (send ACK)
     send SYN+ACK                  v
               |              +---------+
               +------------->|  ESTAB  |<-----------+
                              +---------+            |
                                   |                 |
             close (send FIN)      |                 | rcv FIN (send ACK)
                                   v                 |
                              +---------+       +---------+
                              |FIN_WAIT1|       |CLOSE_WAIT|
                              +---------+       +---------+
                                   |                 |
                  rcv ACK          |                 | close (send FIN)
                                   v                 v
                              +---------+       +---------+
                              |FIN_WAIT2|       | LAST_ACK|
                              +---------+       +---------+
                                   |                 |
                  rcv FIN          |                 | rcv ACK
                  send ACK         v                 v
                              +---------+       +---------+
                              |TIME_WAIT|       |  CLOSED |
                              +---------+       +---------+
```

### State Timeouts (GC thresholds)
| State        | Timeout     | Purpose                          |
|--------------|-------------|----------------------------------|
| SYN_SENT     | 75 seconds  | 15s * 5 retries                  |
| SYN_RECEIVED | 75 seconds  | SYN flood mitigation             |
| ESTABLISHED  | 2 hours     | TCP keepalive interval           |
| CLOSE_WAIT   | 60 seconds  | App should close promptly        |
| LAST_ACK     | 60 seconds  | Waiting for final ACK            |
| LISTEN       | No timeout  | Listening sockets persist        |
| CLOSED       | Immediate   | Already closed                   |

### Half-Open Connection Management
- Max half-open: 128 (MAX_HALF_OPEN)
- Eviction: O(1) doubly-linked list (oldest first)
- Counter: half_open_count in state.zig
""",

    "socket": """
## Socket API

Location: src/net/transport/socket/

### Syscall Interface
| Syscall  | Number | Signature                                    |
|----------|--------|----------------------------------------------|
| socket   | 41     | socket(domain, type, protocol) -> fd         |
| connect  | 42     | connect(fd, addr, addrlen) -> 0              |
| accept   | 43     | accept(fd, addr, addrlen) -> new_fd          |
| sendto   | 44     | sendto(fd, buf, len, flags, addr, len) -> n  |
| recvfrom | 45     | recvfrom(fd, buf, len, flags, addr, len) -> n|
| bind     | 49     | bind(fd, addr, addrlen) -> 0                 |
| listen   | 50     | listen(fd, backlog) -> 0                     |

### Socket Types
```zig
pub const AF_INET: i32 = 2;       // IPv4
pub const SOCK_STREAM: i32 = 1;   // TCP
pub const SOCK_DGRAM: i32 = 2;    // UDP
```

### Socket Structure (types.zig)
```zig
pub const Socket = struct {
    allocated: bool,
    family: i32,           // AF_INET
    sock_type: i32,        // SOCK_STREAM or SOCK_DGRAM
    local_port: u16,       // Host byte order
    local_addr: u32,       // Host byte order
    tcb: ?*Tcb,            // TCP Control Block (TCP only)
    accept_queue: [8]?*Tcb,// Pending connections (listening)
    rx_queue: [8]RxEntry,  // UDP receive queue
    blocking: bool,        // Blocking mode (default: true)
    blocked_thread: ?*Thread, // Thread waiting on this socket
    refcount: AtomicRefcount,
    closing: atomic(bool),
    // ... options, multicast, etc.
};
```

### Limits
- MAX_SOCKETS: 1024 (soft limit, grows dynamically)
- SOCKET_RX_QUEUE_SIZE: 8 packets (UDP)
- ACCEPT_QUEUE_SIZE: 8 pending connections
- Ephemeral ports: 49152-65535 (RFC 6335)
""",

    "socket_options": """
## Socket Options

Location: src/net/transport/socket/types.zig, options.zig

### setsockopt/getsockopt Interface
```zig
setsockopt(fd, level, optname, optval, optlen) -> 0 or -errno
getsockopt(fd, level, optname, optval, optlen) -> 0 or -errno
```

### SOL_SOCKET Level (level = 1)
| Option       | Value | Type     | Description                      |
|--------------|-------|----------|----------------------------------|
| SO_REUSEADDR | 2     | int      | Allow address reuse              |
| SO_BROADCAST | 6     | int      | Allow broadcast sends            |
| SO_RCVTIMEO  | 20    | timeval  | Receive timeout (ms)             |
| SO_SNDTIMEO  | 21    | timeval  | Send timeout (ms)                |

### IPPROTO_IP Level (level = 0)
| Option             | Value | Type    | Description                    |
|--------------------|-------|---------|--------------------------------|
| IP_TOS             | 1     | int     | Type of Service                |
| IP_TTL             | 2     | int     | Time to Live                   |
| IP_ADD_MEMBERSHIP  | 35    | ip_mreq | Join multicast group           |
| IP_DROP_MEMBERSHIP | 36    | ip_mreq | Leave multicast group          |
| IP_MULTICAST_IF    | 32    | in_addr | Multicast interface            |
| IP_MULTICAST_TTL   | 33    | int     | Multicast TTL (default: 1)     |

### IPPROTO_TCP Level (level = 6)
| Option      | Value | Type | Description                         |
|-------------|-------|------|-------------------------------------|
| TCP_NODELAY | 1     | int  | Disable Nagle's algorithm           |

### Multicast Support
- Max groups per socket: 8 (MAX_MULTICAST_GROUPS)
- Default multicast TTL: 1 (local subnet only)
- ip_mreq struct: { multiaddr: u32, interface: u32 }
""",

    "udp": """
## UDP Protocol

Location: src/net/transport/udp.zig

### Characteristics
- Connectionless, unreliable datagram service
- No state machine (stateless)
- Checksum optional but recommended

### Header Format (8 bytes)
```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|          Source Port          |       Destination Port        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|            Length             |           Checksum            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### Socket Integration
- Uses Socket.rx_queue for received packets (8 entries)
- sendto() builds UDP header + calls IPv4 transmit
- recvfrom() dequeues from rx_queue

### Multicast Support
- IP_ADD_MEMBERSHIP / IP_DROP_MEMBERSHIP via setsockopt
- Socket.multicast_groups[] array (max 8 groups)
- isMulticastMember() checks membership before delivery
""",

    "arp": """
## ARP Protocol

Location: src/net/ipv4/arp/

### Cache Structure
```zig
pub const ArpEntry = struct {
    ip_addr: u32,
    mac_addr: [6]u8,
    state: ArpState,          // free, incomplete, reachable, stale
    timestamp: u64,
    retries: u8,
    pending_pkts: [4]?[]u8,   // Queue for incomplete entries
    is_static: bool,          // Static binding (immune to ARP)
    conflict_detected: bool,  // Security: ARP race detection
    generation: u32,          // TOCTOU detection
    hash_next: ?*ArpEntry,    // O(1) lookup chain
};
```

### Constants
| Name              | Value  | Description                    |
|-------------------|--------|--------------------------------|
| ARP_TIMEOUT       | 1200s  | Entry expiration (20 minutes)  |
| ARP_MAX_RETRIES   | 3      | Retries for incomplete entries |
| MAX_ARP_ENTRIES   | 256    | Maximum cache size             |
| ARP_HASH_SIZE     | 512    | Hash table buckets             |
| MAX_INCOMPLETE    | 64     | DoS protection limit           |
| QUEUE_SIZE        | 4      | Pending packets per entry      |

### States
1. **free**: Entry not in use
2. **incomplete**: ARP request sent, awaiting reply
3. **reachable**: Valid MAC, recently confirmed
4. **stale**: Entry old, may need refresh

### Security Features
- Static bindings (is_static flag)
- Conflict detection for ARP race attacks
- Rate limiting (ARP_UPDATE_RATE_LIMIT = 100 ticks)
- Incomplete entry limit (DoS protection)
- Generation counter for TOCTOU detection
""",

    "dns": """
## DNS Resolver

Location: src/net/dns/

### Architecture
- Stub resolver (queries upstream server)
- UDP-only (no TCP fallback yet)
- CNAME following (up to 8 hops)

### RFC Compliance
- RFC 1034: Domain names - Concepts and facilities
- RFC 1035: Domain names - Implementation and specification
- RFC 5452: DNS anti-spoofing

### Security Features (RFC 5452)
1. **Random source port**: Ephemeral port randomization
2. **Random transaction ID**: 16-bit random ID per query
3. **Combined entropy**: ~32 bits unpredictability
4. **Response validation**:
   - Source IP matches server IP
   - Source port matches (port 53)
   - Transaction ID matches
   - Question section matches query

### Limits
| Name                | Value | Description                   |
|---------------------|-------|-------------------------------|
| DNS_MAX_LABEL       | 63    | Max label length              |
| DNS_MAX_NAME        | 253   | Max domain name length        |
| DNS_MAX_UDP         | 512   | Max UDP message size          |
| DNS_MAX_CNAME_DEPTH | 8     | Max CNAME chain depth         |
| DNS_MAX_COMP_JUMPS  | 10    | Max compression pointer jumps |
| DNS_HEADER_SIZE     | 12    | Header size (bytes)           |

### Error Handling
- TimedOut: 2-second deadline
- CnameLoop: Exceeded 8 CNAME redirects
- IdMismatch: Possible spoofing attempt
- Truncated: Response too large for UDP
""",

    "icmp": """
## ICMP Protocol

Location: src/net/transport/icmp.zig

### Supported Message Types
| Type | Code | Description              |
|------|------|--------------------------|
| 0    | 0    | Echo Reply               |
| 3    | 0-15 | Destination Unreachable  |
| 8    | 0    | Echo Request             |
| 11   | 0-1  | Time Exceeded            |

### Destination Unreachable Codes
| Code | Meaning                    |
|------|----------------------------|
| 0    | Network unreachable        |
| 1    | Host unreachable           |
| 2    | Protocol unreachable       |
| 3    | Port unreachable           |
| 4    | Fragmentation needed (PMTU)|

### PMTU Discovery (RFC 1191)
- ICMP Type 3 Code 4 triggers PMTU update
- Next-hop MTU extracted from ICMP payload
- Validated against active TCP connections (RFC 5927)
- Sequence number in ICMP payload must match in-flight data

### Security
- ICMP error rate limiting
- Sequence number validation for PMTU updates
- Soft vs hard error distinction
""",

    "reassembly": """
## IP Fragment Reassembly

Location: src/net/ipv4/reassembly.zig

### Constants
| Name                    | Value  | Description                    |
|-------------------------|--------|--------------------------------|
| MAX_IP_PACKET_SIZE      | 65535  | Maximum IP packet (64KB)       |
| REASSEMBLY_TIMEOUT      | 15s    | Fragment expiration (reduced)  |
| MAX_REASSEMBLIES        | 128    | Max concurrent reassemblies    |
| MIN_FRAGMENT_SIZE       | 256    | Minimum middle fragment size   |
| MIN_FIRST_FRAGMENT_SIZE | 20     | Minimum first fragment size    |

### DoS Protections
1. **Memory cap**: Shared packet pool budget (no heap per-fragment)
2. **Timeout reduction**: 15s vs RFC 791's 60-120s
3. **Fragment size limits**: Prevents tiny fragment attacks
4. **Hole tracking limit**: Max 64 holes per reassembly
5. **First fragment validation**: Must contain transport header

### Fragment Key
```zig
const FragmentKey = struct {
    src_ip: u32,
    dst_ip: u32,
    protocol: u8,
    id: u16,
};
```

### Hole Algorithm (RFC 815)
- Track holes (gaps) in reassembly buffer
- Update holes as fragments arrive
- Complete when no holes remain

### Security: Overlap Detection
- Overlapping fragments with different data are rejected
- Prevents Teardrop-style attacks
""",

    "security": """
## Network Security Features

### TCP Security
**ISN Generation (RFC 6528)**
- SipHash-2-4 with 128-bit key
- Per-connection hardware entropy mixing
- Key re-seeding every 10,000 ISNs
- Time component prevents replay

**SYN Flood Protection**
- MAX_HALF_OPEN: 128 connections limit
- O(1) oldest-first eviction via doubly-linked list
- Atomic state transitions prevent TOCTOU

**Connection Hash**
- SipHash-2-4 for hash table buckets
- Stable key (no re-seeding) for consistent lookups
- 1024 buckets for collision resistance

### IP Security
**Fragment Reassembly DoS**
- 15-second timeout (vs 60-120s RFC)
- 128 max concurrent reassemblies
- 512KB memory cap via shared pool
- Minimum fragment size enforcement
- Overlap rejection

### DNS Security (RFC 5452)
- Random source port (ephemeral range)
- Random 16-bit transaction ID
- Combined ~32 bits entropy
- Response validation (IP, port, ID, question)

### ARP Security
- Static bindings (immune to spoofing)
- Conflict detection (race attack mitigation)
- Rate limiting on cache updates
- Incomplete entry limit (64 max)
- Generation counters for TOCTOU

### Socket Security
- Atomic refcounting (prevents double-free)
- Closing flag (prevents use-after-close)
- Per-socket spinlock for RX queue
- Timeout support for blocking operations
""",

    "constants": """
## Protocol Constants

Location: src/net/constants.zig

### Header Sizes
| Header   | Size (bytes) | Notes                      |
|----------|--------------|----------------------------|
| Ethernet | 14           | dst + src + ethertype      |
| IPv4     | 20-60        | Min 20, max with options   |
| TCP      | 20-60        | Min 20, max with options   |
| UDP      | 8            | Fixed size                 |
| ICMP     | 8            | Type + code + checksum + data |

### Protocol Numbers
| Protocol | Number | Constant      |
|----------|--------|---------------|
| ICMP     | 1      | PROTO_ICMP    |
| TCP      | 6      | PROTO_TCP     |
| UDP      | 17     | PROTO_UDP     |

### Ethertypes
| Protocol | Value  | Constant        |
|----------|--------|-----------------|
| IPv4     | 0x0800 | ETHERTYPE_IPV4  |
| ARP      | 0x0806 | ETHERTYPE_ARP   |
| IPv6     | 0x86DD | ETHERTYPE_IPV6  |

### TCP Constants
| Name               | Value  | Description                |
|--------------------|--------|----------------------------|
| DEFAULT_MSS        | 1460   | Ethernet MSS               |
| MIN_MSS            | 536    | RFC 793 minimum            |
| BUFFER_SIZE        | 8192   | Send/recv buffer (8KB)     |
| RECV_WINDOW_SIZE   | 8192   | Advertised window          |
| INITIAL_RTO_MS     | 1000   | Initial retransmit timeout |
| MAX_RTO_MS         | 64000  | Maximum RTO (64s)          |
| MAX_RETRIES        | 8      | Max retransmissions        |
| TCP_DELAYED_ACK_MS | 200    | Delayed ACK timeout        |
| TCB_HASH_SIZE      | 1024   | Hash table buckets         |
| MAX_TCBS           | 256    | Max connections            |
| MAX_HALF_OPEN      | 128    | SYN flood protection       |
| TCP_MAX_WSCALE     | 14     | Max window scale           |
| TCP_MAX_OPTIONS    | 40     | Max options size           |

### Socket Constants
| Name                | Value  | Description                |
|---------------------|--------|----------------------------|
| MAX_SOCKETS         | 1024   | Soft socket limit          |
| SOCKET_RX_QUEUE     | 8      | UDP receive queue          |
| ACCEPT_QUEUE_SIZE   | 8      | Pending TCP connections    |
| MAX_MULTICAST       | 8      | Multicast groups/socket    |

### ARP Constants
| Name              | Value | Description                  |
|-------------------|-------|------------------------------|
| ARP_TIMEOUT       | 1200  | Entry timeout (seconds)      |
| ARP_MAX_RETRIES   | 3     | Request retries              |
| MAX_ARP_ENTRIES   | 256   | Maximum cache size           |
| ARP_HASH_SIZE     | 512   | Hash table buckets           |

### Misc
| Name           | Value | Description              |
|----------------|-------|--------------------------|
| DEFAULT_TTL    | 64    | IP packet TTL            |
| MAX_PACKET     | 2048  | Max packet buffer size   |
""",

    "blocking": """
## Blocking I/O Integration

Location: src/net/transport/socket/scheduler.zig

### Thread Blocking Pattern
```zig
// In syscall handler (e.g., recvfrom)
pub fn sys_recvfrom(...) SyscallError!usize {
    const sock = acquireSocket(fd) orelse return error.EBADF;
    defer releaseSocket(sock);

    // Check for data
    if (sock.hasData()) {
        return sock.dequeuePacket(buf, ...);
    }

    // No data - block if blocking mode
    if (!sock.blocking) return error.EAGAIN;

    // Set blocked thread and yield
    sock.blocked_thread = getCurrentThread();
    scheduler.blockCurrentThread();

    // Re-check after wake
    if (sock.hasData()) {
        return sock.dequeuePacket(buf, ...);
    }
    return error.EINTR; // Interrupted
}
```

### Waking Blocked Threads
```zig
// In packet processing (e.g., UDP receive)
pub fn deliverPacket(sock: *Socket, data: []const u8, ...) void {
    sock.lock.acquire();
    defer sock.lock.release();

    if (sock.enqueuePacket(data, src_addr, src_port)) {
        // Wake blocked thread if any
        scheduler.wakeThread(sock.blocked_thread);
    }
}
```

### Timeout Support
- SO_RCVTIMEO: Receive timeout (milliseconds)
- SO_SNDTIMEO: Send timeout (milliseconds)
- 0 = infinite timeout (default)
- Timeout triggers EAGAIN return
""",

    "async": """
## Async Socket API

Location: src/net/transport/socket/types.zig (pending_* fields)

### Pending Request Pattern (Phase 2)
```zig
pub const Socket = struct {
    // ...
    pending_accept: ?*anyopaque,  // Waiting for connection
    pending_recv: ?*anyopaque,    // Waiting for data
    pending_send: ?*anyopaque,    // Waiting for buffer space
    pending_connect: ?*anyopaque, // Waiting for handshake
};
```

### Integration with io_uring
1. Syscall submits async operation
2. Sets pending_* pointer to IoRequest
3. Returns immediately (or with EINPROGRESS)
4. Packet processing completes the request
5. Request posted to completion queue

### Completion Flow
```zig
// In TCP packet processing
fn handleEstablishedPacket(tcb: *Tcb, ...) void {
    // Data received
    if (tcb.recv_buffer.hasData()) {
        if (socket.pending_recv) |req| {
            const copied = copyToUserBuffer(req, tcb.recv_buffer);
            completeIoRequest(req, copied);
            socket.pending_recv = null;
        }
    }
}
```

### Supported Async Operations
- accept: Completed when connection arrives
- recv/recvfrom: Completed when data available
- send/sendto: Completed when buffer space available
- connect: Completed when handshake finishes
""",

    # ==========================================================================
    # Templates
    # ==========================================================================

    "template_protocol": """
// New Transport Protocol Handler Template
// Location: src/net/transport/<protocol>.zig

const std = @import("std");
const packet = @import("../core/packet.zig");
const ipv4 = @import("../ipv4/root.zig").ipv4;
const checksum = @import("../core/checksum.zig");
const constants = @import("../constants.zig");
const Interface = @import("../core/interface.zig").Interface;

/// Protocol header (use extern struct for network layout)
pub const Header = extern struct {
    // Define header fields in network byte order
    src_port: u16,
    dst_port: u16,
    // ... other fields

    pub fn getSrcPort(self: Header) u16 {
        return @byteSwap(self.src_port);
    }

    pub fn getDstPort(self: Header) u16 {
        return @byteSwap(self.dst_port);
    }
};

/// Process incoming packet
pub fn processPacket(
    iface: *Interface,
    src_ip: u32,
    dst_ip: u32,
    payload: []const u8,
) void {
    // Step 1: Validate minimum header size
    if (payload.len < @sizeOf(Header)) {
        return; // Drop: too short
    }

    // Step 2: Parse header (no copy, pointer cast)
    const hdr: *const Header = @ptrCast(@alignCast(payload.ptr));

    // Step 3: Validate checksum (if applicable)
    // const cksum = checksum.internetChecksum(...);
    // if (cksum != 0) return; // Drop: bad checksum

    // Step 4: Validate header fields against payload length
    // const claimed_len = hdr.getLength();
    // if (claimed_len > payload.len) return; // Drop: truncated

    // Step 5: Process payload
    const data = payload[@sizeOf(Header)..];
    _ = data;
    _ = iface;
    _ = src_ip;
    _ = dst_ip;

    // TODO: Demux to socket, update state, etc.
}

/// Send packet
pub fn sendPacket(
    iface: *Interface,
    src_ip: u32,
    dst_ip: u32,
    src_port: u16,
    dst_port: u16,
    data: []const u8,
) !void {
    // Allocate TX buffer
    var buf: [constants.MAX_PACKET_SIZE]u8 = undefined;
    const hdr: *Header = @ptrCast(@alignCast(&buf));

    // Fill header (convert to network byte order)
    hdr.src_port = @byteSwap(src_port);
    hdr.dst_port = @byteSwap(dst_port);
    // ... other fields

    // Copy payload
    const payload_start = @sizeOf(Header);
    const payload_end = payload_start + data.len;
    @memcpy(buf[payload_start..payload_end], data);

    // Calculate checksum (if applicable)
    // hdr.checksum = checksum.tcpUdpChecksum(...);

    // Send via IPv4
    try ipv4.transmit.sendPacket(
        iface,
        src_ip,
        dst_ip,
        constants.PROTO_XXX, // Your protocol number
        buf[0..payload_end],
    );
}
""",

    "template_socket_op": """
// Socket Operation Implementation Template
// Location: src/net/transport/socket/<operation>.zig

const std = @import("std");
const state = @import("state.zig");
const types = @import("types.zig");
const Socket = types.Socket;
const scheduler = @import("scheduler.zig");

pub const OperationError = error{
    EBADF,     // Bad file descriptor
    EINVAL,    // Invalid argument
    EAGAIN,    // Would block (non-blocking mode)
    ENOTCONN,  // Not connected
    EPIPE,     // Broken pipe
    ETIMEDOUT, // Operation timed out
};

/// Perform operation on socket
pub fn operation(fd: usize, args: anytype) OperationError!usize {
    // Step 1: Acquire socket with refcount
    const sock = state.acquireSocket(fd) orelse return error.EBADF;
    defer state.releaseSocket(sock);

    // Step 2: Validate socket state
    if (sock.closing.load(.acquire)) {
        return error.EBADF; // Socket is closing
    }

    // Step 3: Validate socket type if needed
    if (sock.sock_type != types.SOCK_STREAM) {
        return error.EINVAL; // Only for TCP
    }

    // Step 4: Acquire socket lock for state access
    sock.lock.acquire();
    defer sock.lock.release();

    // Step 5: Check preconditions
    // e.g., for send: check connected, not shutdown_write
    // e.g., for recv: check connected, not shutdown_read

    // Step 6: Perform operation or block
    if (canComplete(sock, args)) {
        return doOperation(sock, args);
    }

    // Step 7: Handle blocking
    if (!sock.blocking) {
        return error.EAGAIN;
    }

    // Set up blocking
    sock.blocked_thread = scheduler.getCurrentThread();
    sock.lock.release(); // Release before blocking

    scheduler.blockCurrentThread();

    // Re-acquire and retry after wake
    sock.lock.acquire();

    if (canComplete(sock, args)) {
        return doOperation(sock, args);
    }

    return error.EAGAIN; // Spurious wake
}

fn canComplete(sock: *Socket, args: anytype) bool {
    _ = sock;
    _ = args;
    // Check if operation can complete now
    return false;
}

fn doOperation(sock: *Socket, args: anytype) usize {
    _ = sock;
    _ = args;
    // Perform the actual operation
    return 0;
}
""",

    "template_packet_parse": """
// Safe Packet Parsing Template
// Pattern: Validate BEFORE cast, use ACTUAL buffer length

const std = @import("std");
const constants = @import("../constants.zig");

/// Protocol header (extern struct for exact layout)
pub const Header = extern struct {
    field1: u16,
    field2: u16,
    length: u16,  // Claimed length in header
    checksum: u16,

    pub fn getLength(self: Header) u16 {
        return @byteSwap(self.length);
    }
};

pub const ParseError = error{
    PacketTooShort,    // Buffer smaller than header
    HeaderTruncated,   // Claimed length > buffer
    BadChecksum,       // Checksum mismatch
    InvalidHeader,     // Malformed header fields
};

/// Parse packet with full validation
pub fn parsePacket(buffer: []const u8) ParseError!struct {
    header: *const Header,
    payload: []const u8,
} {
    // Step 1: Validate minimum header size BEFORE cast
    // SECURITY: Prevents out-of-bounds read on short packets
    if (buffer.len < @sizeOf(Header)) {
        return error.PacketTooShort;
    }

    // Step 2: Cast to header (now safe)
    const header: *const Header = @ptrCast(@alignCast(buffer.ptr));

    // Step 3: Validate claimed length against ACTUAL buffer
    // SECURITY: Never trust length fields in packet headers
    const claimed_len = header.getLength();
    if (claimed_len > buffer.len) {
        return error.HeaderTruncated;
    }

    // Step 4: Validate checksum (if applicable)
    // const computed = computeChecksum(buffer[0..claimed_len]);
    // if (computed != 0) return error.BadChecksum;

    // Step 5: Validate header field ranges
    // if (header.field1 < MIN_VALUE) return error.InvalidHeader;

    // Step 6: Extract payload (use validated length)
    const payload_start = @sizeOf(Header);
    const payload_end = @min(claimed_len, buffer.len);

    if (payload_start > payload_end) {
        return error.InvalidHeader;
    }

    return .{
        .header = header,
        .payload = buffer[payload_start..payload_end],
    };
}

/// Construct packet with proper initialization
pub fn buildPacket(buf: []u8, src: u16, dst: u16, payload: []const u8) ![]u8 {
    const total_len = @sizeOf(Header) + payload.len;
    if (total_len > buf.len) return error.BufferTooSmall;

    // SECURITY: Zero-initialize to prevent stack leaks
    @memset(buf[0..total_len], 0);

    const header: *Header = @ptrCast(@alignCast(buf.ptr));
    header.field1 = @byteSwap(src);
    header.field2 = @byteSwap(dst);
    header.length = @byteSwap(@as(u16, @intCast(total_len)));

    // Copy payload
    @memcpy(buf[@sizeOf(Header)..][0..payload.len], payload);

    // Calculate checksum
    // header.checksum = computeChecksum(buf[0..total_len]);

    return buf[0..total_len];
}
""",

    "template_state_machine": """
// Protocol State Machine Template
// Pattern: Enum states + transition function + timeout handling

const std = @import("std");
const sync = @import("../sync.zig");

/// Protocol states
pub const State = enum {
    Idle,
    Connecting,
    Connected,
    Disconnecting,
    Closed,
};

/// State timeout values (milliseconds)
pub const StateTimeouts = struct {
    connecting: u64 = 30_000,     // 30 seconds
    connected: u64 = 0,           // No timeout (keepalive handled separately)
    disconnecting: u64 = 10_000,  // 10 seconds
};

/// Control block for protocol instance
pub const ControlBlock = struct {
    state: State,
    created_at: u64,           // Timestamp for timeout calculation
    last_activity: u64,        // Last packet time
    generation: u64,           // TOCTOU detection
    closing: bool,             // Prevent new operations
    mutex: sync.Mutex,         // Per-instance lock

    // ... other protocol-specific fields

    pub fn init() ControlBlock {
        return .{
            .state = .Idle,
            .created_at = 0,
            .last_activity = 0,
            .generation = 0,
            .closing = false,
            .mutex = .{},
        };
    }

    /// Transition to new state with validation
    pub fn transition(self: *ControlBlock, new_state: State) bool {
        // Validate transition is legal
        if (!isValidTransition(self.state, new_state)) {
            return false;
        }

        // Update state
        self.state = new_state;
        self.last_activity = getCurrentTimestamp();

        return true;
    }

    /// Check if state has timed out
    pub fn isTimedOut(self: *const ControlBlock, now: u64) bool {
        const timeout = switch (self.state) {
            .Connecting => StateTimeouts{}.connecting,
            .Connected => StateTimeouts{}.connected,
            .Disconnecting => StateTimeouts{}.disconnecting,
            else => 0,
        };

        if (timeout == 0) return false;

        return (now - self.created_at) > timeout;
    }
};

/// Valid state transitions
fn isValidTransition(from: State, to: State) bool {
    return switch (from) {
        .Idle => to == .Connecting or to == .Closed,
        .Connecting => to == .Connected or to == .Closed,
        .Connected => to == .Disconnecting or to == .Closed,
        .Disconnecting => to == .Closed,
        .Closed => false, // Terminal state
    };
}

fn getCurrentTimestamp() u64 {
    // Return current monotonic timestamp
    return 0; // Implement based on kernel timer
}

/// Garbage collect timed-out entries
/// Call periodically from timer tick
pub fn gcTimedOut(pool: *std.ArrayListUnmanaged(*ControlBlock), now: u64) void {
    var i: usize = 0;
    while (i < pool.items.len) {
        const cb = pool.items[i];

        if (cb.isTimedOut(now)) {
            // Mark as closing to prevent new operations
            cb.closing = true;

            // Remove from pool
            _ = pool.swapRemove(i);

            // Free resources
            // ...
        } else {
            i += 1;
        }
    }
}
""",
}

TEMPLATES = {
    "protocol": "template_protocol",
    "socket_op": "template_socket_op",
    "packet_parse": "template_packet_parse",
    "state_machine": "template_state_machine",
}


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    query = sys.argv[1].lower()

    # Handle --all: list all topics
    if query == "--all":
        non_template = {k: v for k, v in PATTERNS.items() if not k.startswith("template_")}
        print("Available topics:")
        for topic in sorted(non_template.keys()):
            print(f"  {topic}")
        print("\nAvailable templates:")
        for name in sorted(TEMPLATES.keys()):
            print(f"  {name}")
        return

    # Handle template command
    if query == "template":
        if len(sys.argv) < 3:
            print("Usage: python network_query.py template <type>")
            print(f"Available templates: {', '.join(sorted(TEMPLATES.keys()))}")
            sys.exit(1)
        template_type = sys.argv[2].lower()
        if template_type not in TEMPLATES:
            print(f"Unknown template: {template_type}")
            print(f"Available templates: {', '.join(sorted(TEMPLATES.keys()))}")
            sys.exit(1)
        print(PATTERNS[TEMPLATES[template_type]])
        return

    # Filter out template patterns from fuzzy match
    non_template_patterns = {k: v for k, v in PATTERNS.items() if not k.startswith("template_")}

    # Fuzzy match
    matches = [k for k in non_template_patterns.keys() if query in k]

    if not matches:
        print(f"Unknown topic: {query}")
        print(f"Available: {', '.join(sorted(non_template_patterns.keys()))}")
        sys.exit(1)

    for match in matches:
        print(PATTERNS[match])


if __name__ == "__main__":
    main()

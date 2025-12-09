# ZigK Network Stack

This document describes the network stack implementation in ZigK.

## Architecture Overview

```
+------------------------------------------------------------------+
|                        Userland                                   |
|  socket() / bind() / sendto() / recvfrom() / connect() / accept()|
+------------------------------------------------------------------+
                              |
                         Syscall Layer
                    (src/kernel/syscall/net.zig)
                              |
+------------------------------------------------------------------+
|                      Socket Layer                                 |
|                 (src/net/transport/socket.zig)                    |
|         BSD-style socket API, FD management, blocking I/O         |
+------------------------------------------------------------------+
                              |
         +--------------------+--------------------+
         |                    |                    |
+----------------+   +----------------+   +----------------+
|      TCP       |   |      UDP       |   |      ICMP      |
|   (tcp.zig)    |   |   (udp.zig)    |   |   (icmp.zig)   |
|  7-state FSM   |   |   Datagram     |   |   Echo/Reply   |
|  Retransmit    |   |   Stateless    |   |                |
+----------------+   +----------------+   +----------------+
         |                    |                    |
+------------------------------------------------------------------+
|                         IPv4 Layer                                |
|                    (src/net/ipv4/ipv4.zig)                        |
|              Routing, fragmentation (future), TTL                 |
+------------------------------------------------------------------+
                              |
+------------------------------------------------------------------+
|                         ARP Layer                                 |
|                    (src/net/ipv4/arp.zig)                         |
|                  IP-to-MAC address resolution                     |
+------------------------------------------------------------------+
                              |
+------------------------------------------------------------------+
|                      Ethernet Layer                               |
|                (src/net/ethernet/ethernet.zig)                    |
|                    Frame parsing, dispatch                        |
+------------------------------------------------------------------+
                              |
+------------------------------------------------------------------+
|                      NIC Driver                                   |
|                  (src/drivers/net/e1000e.zig)                     |
|                   Intel 82574L PCIe NIC                           |
+------------------------------------------------------------------+
```

## Protocol Layers

### Ethernet Layer (`src/net/ethernet/ethernet.zig`)

Handles raw Ethernet frame parsing and construction.

**Ethertype dispatch:**
- `0x0800` - IPv4
- `0x0806` - ARP

**Functions:**
- `processFrame()` - Parse received frame, dispatch to IPv4/ARP
- `sendFrame()` - Build and transmit Ethernet frame

### ARP Layer (`src/net/ipv4/arp.zig`)

Address Resolution Protocol - maps IPv4 addresses to MAC addresses.

**Features:**
- Static ARP cache (64 entries)
- Request/Reply handling
- Cache timeout (1200 seconds / 20 minutes)
- LRU eviction when cache is full
- ARP snooping (learns from observed traffic)

**Functions:**
- `processPacket()` - Handle incoming ARP requests/replies
- `resolve()` - Look up or request MAC for IP address
- `sendRequest()` - Broadcast ARP request
- `clearCache()` - Reset ARP cache

### IPv4 Layer (`src/net/ipv4/ipv4.zig`)

Internet Protocol version 4 - routing and protocol dispatch.

**Protocol dispatch:**
- `1` - ICMP
- `6` - TCP
- `17` - UDP

**Functions:**
- `processPacket()` - Parse IPv4 header, dispatch to transport layer
- `sendPacket()` - Build IPv4 packet, resolve next-hop, transmit

**Current limitations:**
- No fragmentation/reassembly
- Single interface (no routing table)

#### Path MTU Discovery (RFC 1191)

The IPv4 layer implements Path MTU Discovery to avoid fragmentation:

**PMTU Cache:**
- 16-entry cache with LRU-style replacement
- Default MTU: 1500 bytes (Ethernet)
- Minimum MTU: 576 bytes (RFC 791 requirement)

**Functions:**
- `lookupPmtu(dst_ip)` - Returns cached MTU or DEFAULT_MTU (1500)
- `updatePmtu(dst_ip, new_mtu)` - Update cache (called from ICMP handler)
- `getEffectiveMss(dst_ip)` - Returns MTU - 40 for TCP MSS calculation

**Flow:**
1. TCP sends packet with DF (Don't Fragment) bit set
2. Router drops packet if too large, sends ICMP Type 3 Code 4
3. ICMP handler extracts next-hop MTU from ICMP message
4. `updatePmtu()` stores lower MTU in cache
5. TCP retransmits with smaller MSS based on `getEffectiveMss()`

**Cache entry structure:**
```zig
const PmtuEntry = struct {
    destination_ip: u32,  // 0 = empty slot
    mtu: u16,            // Discovered MTU
    age: u32,            // Access counter for LRU
};
```

### ICMP Layer (`src/net/transport/icmp.zig`)

Internet Control Message Protocol - diagnostics and error reporting.

**Implemented message types:**
- Type 0: Echo Reply
- Type 3: Destination Unreachable (codes: Net/Host/Proto/Port Unreachable, Fragmentation Needed)
- Type 8: Echo Request (ping)

**Parsed but not actively used:**
- Type 4: Source Quench
- Type 5: Redirect
- Type 11: Time Exceeded
- Type 12: Parameter Problem
- Type 13/14: Timestamp Request/Reply

**Functions:**
- `processPacket()` - Handle incoming ICMP messages
- `handleEchoRequest()` - Respond to ping requests (Smurf attack prevention included)
- `handleDestUnreachable()` - Process Type 3 messages; Code 4 updates PMTU cache
- `sendEchoRequest()` - Send ping requests
- `sendDestUnreachable()` - Send destination unreachable errors

### UDP Layer (`src/net/transport/udp.zig`)

User Datagram Protocol - connectionless datagram service.

**Features:**
- Stateless operation
- Checksum validation (optional per RFC)
- Port-based demultiplexing

**Functions:**
- `processPacket()` - Parse UDP header, deliver to socket
- `sendDatagram()` - Build and transmit UDP datagram

### TCP Layer (`src/net/transport/tcp.zig`)

Transmission Control Protocol - reliable, ordered byte stream.

**Simplified 7-State Machine:**

Note: This is a simplified implementation that skips TIME-WAIT and FIN-WAIT states
for reduced complexity. Connections close directly via LAST-ACK.

```
CLOSED -----> LISTEN (passive open)
   |
   +--------> SYN-SENT (active open)
                  |
                  v
             SYN-RECEIVED <---- LISTEN (incoming SYN)
                  |
                  v
             ESTABLISHED <----> data transfer
                  |
                  v (receive FIN)
             CLOSE-WAIT
                  |
                  v (send FIN)
              LAST-ACK
                  |
                  v (receive ACK)
               CLOSED
```

**Features:**
- Connection hash table (64 buckets, 128 max connections)
- Fixed 8KB send/receive window (circular buffers)
- Timeout-based retransmission (1s initial RTO, exponential backoff to 64s max)
- Maximum 8 retransmission attempts before connection reset
- In-order delivery only (out-of-order segments dropped)
- Proper scheduler integration for blocking I/O
- ISN generation using hardware entropy (RFC 6528)
- MSS option parsing (minimum 536 bytes per RFC 793)
- Sequence number wraparound handling (32-bit arithmetic)

**Connection Tracking:**
- Jenkins one-at-a-time hash for connection lookup
- State-based garbage collection timeouts:
  - SYN_SENT / SYN_RECV: 75 seconds
  - ESTABLISHED: 2 hours (7,200,000 ms)
  - CLOSE_WAIT / LAST_ACK: 60 seconds
- SYN flood protection: MAX_HALF_OPEN = 16 half-open connections
- TCB includes `created_at` timestamp for timeout tracking

**Key structures:**
```zig
pub const Tcb = struct {
    // 4-tuple identity
    local_ip: u32,
    local_port: u16,
    remote_ip: u32,
    remote_port: u16,

    // State machine
    state: TcpState,

    // Sequence numbers (RFC 793)
    snd_una: u32,    // Oldest unacked
    snd_nxt: u32,    // Next to send
    rcv_nxt: u32,    // Next expected
    iss: u32,        // Initial send seq
    irs: u32,        // Initial recv seq

    // Buffers (circular, 8KB each)
    send_buf: [8192]u8,
    recv_buf: [8192]u8,
};
```

**Deferred features:**
- Congestion control (slow start, AIMD)
- Fast retransmit (3 duplicate ACKs)
- SACK, window scaling
- TIME-WAIT state
- Out-of-order segment buffering

## Socket Layer (`src/net/transport/socket.zig`)

BSD-style socket API for userland.

**Supported socket types:**
- `SOCK_STREAM` (1) - TCP
- `SOCK_DGRAM` (2) - UDP

**Address family:**
- `AF_INET` (2) - IPv4 only

**Socket table:**
- 32 max sockets
- Index = FD - 3 (stdin/stdout/stderr reserved)
- Per-socket receive queue (16 packets for UDP)
- Accept queue (8 pending connections for TCP listeners)
- Ephemeral port range: 49152-65535

**Blocking I/O:**
- Sockets default to blocking mode
- Thread wake callbacks integrate with kernel scheduler
- `blocked_thread` field tracks waiting thread per socket/TCB

**Functions:**
- `socket()` - Create socket
- `bind()` - Bind to local address/port
- `listen()` - Mark socket as listening (TCP)
- `accept()` - Accept incoming connection (TCP)
- `connect()` - Initiate connection (TCP)
- `sendto()` - Send datagram (UDP)
- `recvfrom()` - Receive datagram (UDP)
- `tcpSend()` - Send data (TCP)
- `tcpRecv()` - Receive data (TCP)
- `close()` - Close socket

### Socket Options

Socket options are configured via `setsockopt()` and queried via `getsockopt()`.

**SOL_SOCKET level options:**

| Option | Value | Type | Description |
|--------|-------|------|-------------|
| SO_RCVTIMEO | 20 | TimeVal | Receive timeout (blocks until data or timeout) |
| SO_SNDTIMEO | 21 | TimeVal | Send timeout |
| SO_BROADCAST | 6 | int | Enable broadcast sending (required for 255.255.255.255) |

**IPPROTO_IP level options:**

| Option | Value | Type | Description |
|--------|-------|------|-------------|
| IP_TOS | 1 | u8 | Type of Service / DSCP value for outgoing packets |
| IP_ADD_MEMBERSHIP | 35 | IpMreq | Join multicast group |
| IP_DROP_MEMBERSHIP | 36 | IpMreq | Leave multicast group |

**Structures:**

```zig
// Timeout value (matches Linux timeval)
pub const TimeVal = extern struct {
    tv_sec: i64,   // Seconds
    tv_usec: i64,  // Microseconds
};

// Multicast group request
pub const IpMreq = extern struct {
    imr_multiaddr: u32,  // Multicast group address (network byte order)
    imr_interface: u32,  // Local interface address (0 = default interface)
};
```

**Multicast support:**
- Maximum 8 multicast groups per socket
- `addMulticastGroup()` / `dropMulticastGroup()` manage membership
- UDP delivers to all sockets that are members of the destination group
- Broadcast packets delivered to all bound UDP sockets (if SO_BROADCAST set on sender)

## Syscall Interface

Network syscalls follow Linux x86_64 ABI. See `specs/syscall-table.md` for numbers.

| Syscall | Number | Description |
|---------|--------|-------------|
| socket | 41 | Create socket |
| connect | 42 | Connect to address (blocking for TCP) |
| accept | 43 | Accept connection (blocking) |
| sendto | 44 | Send datagram (UDP) |
| recvfrom | 45 | Receive datagram (UDP) |
| bind | 49 | Bind to address |
| listen | 50 | Listen for connections |
| close | 3 | Close socket (shared with file close) |

**TCP data transfer:**

TCP sockets use `tcpSend()` and `tcpRecv()` internally via the socket layer.
These are accessed through standard read/write syscalls on the socket FD.

**FD allocation:**
- Socket FDs start at 3 (after stdin=0, stdout=1, stderr=2)
- Socket index = FD - 3

## Blocking I/O Integration

The network stack integrates with the kernel scheduler for proper blocking I/O.

**Architecture:**
```
Syscall Layer                Socket/TCP Layer              Scheduler
     |                              |                          |
 set blocked_thread          wake callback set          block/unblock
     |                              |                          |
 sched.block() -----> (suspended) <--- wakeThread() <--- timer tick
```

**Flow for blocking accept():**
1. Syscall layer calls `socket.accept()`
2. If no connections pending, returns `WouldBlock`
3. Syscall layer sets `socket.blocked_thread = current_thread`
4. Syscall layer calls `sched.block()`
5. Thread is suspended, other threads run
6. TCP layer completes connection handshake
7. TCP layer calls `socket.wakeThread(blocked_thread)`
8. Thread is unblocked, retry accept succeeds

**Flow for blocking connect():**
1. Syscall layer calls `socket.connect()` - sends SYN
2. Returns immediately (connection in progress)
3. Syscall layer sets `tcb.blocked_thread = current_thread`
4. Syscall layer calls `sched.block()`
5. Thread is suspended
6. TCP layer receives SYN-ACK, sends ACK, sets state = Established
7. TCP layer calls `socket.wakeThread(tcb.blocked_thread)`
8. Thread unblocked, checks state, returns success

## Zero-Copy Packet Buffer

The `PacketBuffer` structure enables zero-copy packet processing:

```zig
pub const PacketBuffer = struct {
    data: [*]u8,           // Raw packet data
    len: usize,            // Current length
    capacity: usize,       // Buffer capacity (max 2048 bytes)

    // Layer offsets for header access
    eth_offset: usize,     // Ethernet header (14 bytes)
    ip_offset: usize,      // IPv4 header (20 bytes min)
    transport_offset: usize, // TCP/UDP/ICMP header
    payload_offset: usize,  // Application data

    // Source info (populated on receive)
    src_mac: [6]u8,
    src_ip: u32,
    src_port: u16,

    // Protocol info
    ethertype: u16,        // 0x0800=IPv4, 0x0806=ARP
    ip_protocol: u8,       // 1=ICMP, 6=TCP, 17=UDP

    // Packet delivery flags (set during IP processing)
    is_broadcast: bool,    // Directed or limited broadcast
    is_multicast: bool,    // Multicast group packet (224.x.x.x - 239.x.x.x)
};
```

**Header size constants:**
- `MAX_PACKET_SIZE` = 2048 bytes
- `ETH_HEADER_SIZE` = 14 bytes
- `IP_HEADER_SIZE` = 20 bytes (minimum)
- `TCP_HEADER_SIZE` = 20 bytes (minimum)
- `UDP_HEADER_SIZE` = 8 bytes
- `ICMP_HEADER_SIZE` = 8 bytes

Packets flow through layers with offsets updated, avoiding copies until data reaches userland.

## Checksum Support (`src/net/core/checksum.zig`)

All checksums use standard ones-complement algorithm:

- `ipChecksum()` - IPv4 header checksum
- `udpChecksum()` - UDP checksum with pseudo-header
- `tcpChecksum()` - TCP checksum with pseudo-header
- `icmpChecksum()` - ICMP checksum

## Interface Structure

Network interface abstraction (`src/net/core/interface.zig`):

```zig
pub const Interface = struct {
    name: [16]u8,          // e.g., "eth0"
    mac_addr: [6]u8,       // Hardware address
    ip_addr: u32,          // IPv4 address (host order)
    netmask: u32,          // Subnet mask
    gateway: u32,          // Default gateway
    mtu: u16,              // Maximum transmission unit
    flags: InterfaceFlags, // UP, BROADCAST, etc.

    // Driver callbacks
    send_fn: SendFn,       // Transmit packet
    driver_data: ?*anyopaque, // Driver-specific data
};
```

## Error Handling

Network errors map to Linux errno values:

| Error | Errno | Value |
|-------|-------|-------|
| EBADF | Bad file descriptor | 9 |
| EAGAIN | Would block | 11 |
| ENOMEM | Out of memory | 12 |
| EACCES | Permission denied | 13 |
| ENOTSOCK | Not a socket | 88 |
| ENOPROTOOPT | Protocol not available | 92 |
| EAFNOSUPPORT | Address family not supported | 97 |
| EADDRINUSE | Address in use | 98 |
| EADDRNOTAVAIL | Address not available | 99 |
| ENETDOWN | Network down | 100 |
| ENETUNREACH | Network unreachable | 101 |
| ECONNRESET | Connection reset | 104 |
| EISCONN | Already connected | 106 |
| ENOTCONN | Not connected | 107 |
| ETIMEDOUT | Connection timed out | 110 |
| ECONNREFUSED | Connection refused | 111 |

## File Organization

```
src/net/
  root.zig              # Module entry point, re-exports
  core/
    root.zig            # Core module exports
    packet.zig          # PacketBuffer, header structs (EthernetHeader, Ipv4Header, etc.)
    interface.zig       # Interface abstraction, transmit callback
    checksum.zig        # IP, TCP, UDP, ICMP checksum algorithms
  ethernet/
    root.zig            # Ethernet module exports
    ethernet.zig        # Frame parsing, ethertype dispatch
  ipv4/
    root.zig            # IPv4 module exports
    ipv4.zig            # IPv4 processing, protocol dispatch
    arp.zig             # ARP cache, request/reply handling
  transport/
    root.zig            # Transport module exports
    socket.zig          # BSD socket API, FD management
    tcp.zig             # TCP state machine, TCB pool
    udp.zig             # UDP datagram handling
    icmp.zig            # ICMP echo/error handling

src/kernel/syscall/
  net.zig               # Network syscall handlers (sys_socket, sys_bind, etc.)
  table.zig             # Syscall dispatch (includes net syscalls)

src/drivers/net/
  e1000e.zig            # Intel 82574L PCIe NIC driver
```

## RFC References

| RFC | Title | Implementation Status |
|-----|-------|----------------------|
| RFC 768 | User Datagram Protocol | Full |
| RFC 791 | Internet Protocol | Partial (no fragmentation) |
| RFC 792 | Internet Control Message Protocol | Partial (echo, dest unreachable) |
| RFC 793 | Transmission Control Protocol | Partial (simplified states) |
| RFC 826 | Ethernet Address Resolution Protocol | Full |
| RFC 1122 | Host Requirements | Partial |
| RFC 1191 | Path MTU Discovery | Partial (cache + ICMP Type 3 Code 4) |
| RFC 6528 | Defending Against Sequence Number Attacks | ISN generation only |
| RFC 7323 | TCP Extensions for High Performance | Not implemented |

## Usage Example

```zig
// Kernel-side: Initialize network stack
const iface = driver.getInterface();
net.init(iface);

// Userland (via syscalls):
// Create TCP socket
const fd = socket(AF_INET, SOCK_STREAM, 0);

// Connect to server
var addr = SockAddrIn{
    .family = AF_INET,
    .port = htons(80),
    .addr = inet_addr("10.0.2.2"),
};
connect(fd, &addr, sizeof(addr));

// Send/receive data
send(fd, "GET / HTTP/1.0\r\n\r\n", 18, 0);
recv(fd, buffer, sizeof(buffer), 0);

// Close
close(fd);
```

## Testing

Network stack can be tested with QEMU user networking:

```bash
# Run with TAP networking
zig build run -Dbios=/path/to/OVMF.fd

# From host, test ping
ping 10.0.2.15

# Test TCP with netcat
nc -l 8080  # Listen on host
# Connect from kernel to 10.0.2.2:8080
```

## Roadmap

### Phase 1: Core Reliability (High Priority)

| Feature | Description | Complexity | Location |
|---------|-------------|------------|----------|
| sys_shutdown | Graceful socket shutdown (SHUT_RD, SHUT_WR, SHUT_RDWR) | Low | `src/kernel/syscall/net.zig` (new syscall 48) |
| getsockname/getpeername | Query local/remote socket addresses | Low | `src/kernel/syscall/net.zig` (syscalls 51, 52) |
| TCP TIME-WAIT | Proper connection termination with 2MSL timeout | Medium | `src/net/transport/tcp.zig:160-175` (TcpState enum) |
| TCP FIN-WAIT states | Complete TCP state machine (FIN-WAIT-1, FIN-WAIT-2, CLOSING) | Medium | `src/net/transport/tcp.zig:160-175` (TcpState enum) |
| Out-of-order buffering | Buffer and reassemble out-of-order TCP segments | High | `src/net/transport/tcp.zig:961-1034` (processEstablished) |
| IPv4 fragmentation | Handle packets larger than MTU, reassembly | High | `src/net/ipv4/ipv4.zig` (new reassembly module needed) |
| Retransmission improvements | RTT estimation (Karn's algorithm), better RTO calculation | Medium | `src/net/transport/tcp.zig:1289-1328` (processTimers) |

### Phase 2: Performance (Medium Priority)

| Feature | Description | Complexity | Location |
|---------|-------------|------------|----------|
| TCP congestion control | Slow start, congestion avoidance (AIMD) | High | `src/net/transport/tcp.zig:182-295` (Tcb struct, add cwnd/ssthresh) |
| Fast retransmit | 3 duplicate ACKs trigger retransmission | Medium | `src/net/transport/tcp.zig:961-1034` (processEstablished) |
| TCP window scaling | RFC 7323, windows larger than 64KB | Medium | `src/net/transport/tcp.zig:1062-1101` (parseMssOption, extend for WS) |
| SACK | Selective acknowledgment for efficient recovery | High | `src/net/transport/tcp.zig:182-295` (Tcb struct, add sack blocks) |
| Nagle's algorithm | Reduce small packet overhead | Low | `src/net/transport/tcp.zig:1248-1282` (transmitPendingData) |
| Delayed ACK | Reduce ACK traffic | Low | `src/net/transport/tcp.zig:625-627` (sendAck) |

### Phase 3: Features (Medium Priority)

| Feature | Description | Complexity | Location |
|---------|-------------|------------|----------|
| fcntl F_GETFL/F_SETFL | Non-blocking mode via O_NONBLOCK flag | Low | `src/kernel/syscall/` (syscall 72) |
| SO_LINGER | Control close() behavior for pending data | Low | `src/net/transport/socket.zig` (linger struct) |
| IP_MULTICAST_TTL | Control multicast packet TTL | Low | `src/net/transport/socket.zig` (multicast_ttl field) |
| Routing table | Multiple interfaces, static routes, longest prefix match | Medium | `src/net/ipv4/ipv4.zig` (new routing.zig module) |
| Raw sockets | SOCK_RAW for custom protocols | Medium | `src/net/transport/socket.zig:247-270` (socket function) |
| Socket options | SO_REUSEADDR, SO_KEEPALIVE, SO_RCVBUF, etc. | Low | `src/net/transport/socket.zig:107-172` (Socket struct) |
| Non-blocking I/O | O_NONBLOCK flag, proper EAGAIN handling | Low | `src/net/transport/socket.zig:136` (blocking field) |
| select/poll | Multiplexed I/O for multiple sockets | Medium | `src/kernel/syscall/` (new poll.zig) |
| DHCP client | Dynamic IP configuration (RFC 2131) | Medium | `src/net/` (new dhcp.zig module) |
| DNS resolver | Name resolution (stub resolver) | Medium | `src/net/` (new dns.zig module) |

### Phase 4: Protocol Extensions (Lower Priority)

| Feature | Description | Complexity | Location |
|---------|-------------|------------|----------|
| IPv6 | Dual-stack operation, NDP, ICMPv6 | Very High | `src/net/ipv6/` (new module tree) |
| ICMP improvements | Redirect handling, timestamp replies | Medium | `src/net/transport/icmp.zig:37-76` (processPacket) |
| TCP keepalive | Detect dead connections | Low | `src/net/transport/tcp.zig:182-295` (Tcb struct) |
| TCP urgent data | Out-of-band data support | Low | `src/net/transport/tcp.zig:73-153` (TcpHeader) |
| Multicast | IGMP, multicast routing | High | `src/net/ipv4/` (new igmp.zig) |
| VLAN support | 802.1Q tagging | Low | `src/net/ethernet/ethernet.zig` |

### Phase 5: Advanced Features (Future)

| Feature | Description | Complexity | Location |
|---------|-------------|------------|----------|
| TLS/SSL | Secure transport layer | Very High | `src/net/tls/` (new module, requires crypto) |
| HTTP client | Basic HTTP/1.1 implementation | Medium | `src/net/app/` (new application layer) |
| NTP client | Time synchronization | Low | `src/net/app/` (new ntp.zig) |
| epoll | Scalable I/O multiplexing | Medium | `src/kernel/syscall/` (new epoll.zig) |
| Zero-copy sendfile | Efficient file-to-socket transfer | Medium | `src/kernel/syscall/` (new sendfile handler) |
| TCP BBR | Modern congestion control | Very High | `src/net/transport/tcp.zig` (replace congestion control) |
| Network namespaces | Container networking | Very High | `src/kernel/` (major restructuring) |

### Known Limitations

Current implementation has these intentional limitations:

| Limitation | Description | Rationale |
|------------|-------------|-----------|
| Single interface | No routing between interfaces; uses global_iface | MVP design - single NIC sufficient for kernel demo (ping, UDP, TCP); multi-interface support deferred to Phase 5+. Interface abstraction already prepared for future migration. |
| No IP fragmentation | Drops fragmented packets (MF bit or frag offset != 0) | Complexity not needed for MTU-sized test packets; PMTUD reduces this need |
| No congestion control | Fixed window, no slow start/AIMD | TCP throughput is artificially limited; sufficient for demo purposes |

### Recently Addressed

| Feature | Description | Implementation |
|---------|-------------|----------------|
| Socket timeouts | SO_RCVTIMEO/SO_SNDTIMEO via setsockopt | `src/net/transport/socket.zig` (TimeVal, rcv_timeout_ms) |
| QoS/ToS/DSCP | IP_TOS option sets ToS field in IP header | `src/net/transport/socket.zig` (tos field), `tcp.zig` (tcb.tos) |
| TCP options | Window Scale, SACK Permitted, Timestamps (RFC 7323, 2018) | `src/net/transport/tcp.zig` (parseOptions, buildSynOptions) |
| IP options | Validates and skips options, drops LSRR/SSRR (RFC 7126) | `src/net/ipv4/ipv4.zig` (validateOptions) |
| Path MTU Discovery | PMTU cache, ICMP Code 4 handling, TCP MSS adjustment (RFC 1191) | `src/net/ipv4/ipv4.zig` (pmtu_cache, updatePmtu, lookupPmtu), `icmp.zig` (handleDestUnreachable) |
| Multicast/Broadcast | IP broadcast/multicast acceptance, UDP multi-socket delivery, IP_ADD_MEMBERSHIP/IP_DROP_MEMBERSHIP, SO_BROADCAST | `src/net/ipv4/ipv4.zig` (processPacket), `socket.zig` (deliverUdpPacket, multicast_groups) |
| Connection Tracking | State-based timeouts, half-open connection limits (SYN flood protection), Jenkins hash for better distribution | `src/net/transport/tcp.zig` (STATE_TIMEOUT_MS, countHalfOpen, hashConnection, processTimers) |

### Not Planned

These features are explicitly out of scope:

- IPv4 options processing
- IPsec / VPN
- Advanced routing protocols (OSPF, BGP)
- Wireless/WiFi support
- Netfilter/iptables equivalent
- Full POSIX socket compatibility

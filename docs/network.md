# ZK Network Stack

This document describes the network stack implementation in ZK.

## Architecture Overview

```
+------------------------------------------------------------------+
|                        Userland                                   |
|  socket() / bind() / sendto() / recvfrom() / connect() / accept()|
|                     getaddrinfo() / resolve()                     |
+------------------------------------------------------------------+
                              |
                         Syscall Layer
                     (src/kernel/sys/syscall/net/net.zig)
                   (centralized networking syscalls)
               (matches network syscalls in src/uapi/syscalls.zig)
                              |
+------------------------------------------------------------------+
|                      Socket Layer                                 |
|                (src/net/transport/socket/)                        |
|         BSD-style socket API, FD management, blocking I/O         |
|         Protocol-specific APIs (tcp_api.zig, udp_api.zig)         |
+------------------------------------------------------------------+
                              |
         +--------------------+--------------------+
         |                    |                    |
+----------------+   +----------------+   +----------------+   +----------------+
|      TCP       |   |      UDP       |   |      ICMP      |   |      DNS       |
| (tcp/state.zig)|   |   (udp.zig)    |   |   (icmp.zig)   |   | (dns/client.zig)|
|  7-state FSM   |   |   Datagram     |   |   Echo/Reply   |   |   Stub Resolver|
|  Retransmit    |   |   Stateless    |   |                |   |   UDP-based    |
|  SipHash ISN   |   |                |   |                |   |                |
+----------------+   +----------------+   +----------------+   +----------------+
         |                    |                    |                    |
+------------------------------------------------------------------+
|                         IPv4 Layer                                |
|                    (src/net/ipv4/ipv4.zig)                        |
+------------------------------------------------------------------+
|                     Fragment Reassembly                           |
|                  (src/net/ipv4/reassembly.zig)                    |
|                DoS Protection, Overlap Detection                  |
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
|            (src/drivers/net/e1000e/root.zig)                      |
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

#### Fragment Reassembly (`src/net/ipv4/reassembly.zig`)

Handles reassembly of fragmented IPv4 packets with robust DoS protection.

**Security Features:**
- **Memory Cap**: Global limit (512KB) on reassembly buffers to prevent OOM.
- **Fragment Count Cap**: Max 128 concurrent reassembly contexts.
- **Timeout**: Strict 15s timeout for incomplete packets (older fragments evicted).
- **Anti-Fragment Bomb**: Drops suspiciously small middle fragments (< 256 bytes).
- **Overlap Detection**: Rejects fragments that overlap existing data (defends against Teardrop/Ping-of-Death).
- **Fail-safe cleanup**: Automatically frees resources on timeout or error.

#### Path MTU Discovery (RFC 1191)

The IPv4 layer implements Path MTU Discovery to avoid fragmentation:

**PMTU Cache:**
- 16-entry cache with LRU-style replacement
- Default MTU: 1500 bytes (Ethernet)
- Minimum MTU: 576 bytes (RFC 791 requirement)

**Flow:**
1. TCP sends packet with DF (Don't Fragment) bit set
2. Router drops packet if too large, sends ICMP Type 3 Code 4
3. ICMP handler extracts next-hop MTU from ICMP message
4. `updatePmtu()` stores lower MTU in cache
5. TCP retransmits with smaller MSS based on `getEffectiveMss()`

### ICMP Layer (`src/net/transport/icmp.zig`)

Internet Control Message Protocol - diagnostics and error reporting.

**Implemented message types:**
- Type 0: Echo Reply
- Type 3: Destination Unreachable (codes: Net/Host/Proto/Port Unreachable, Fragmentation Needed)
- Type 8: Echo Request (ping)

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
- Port-based demultiplexing via `udp_api.zig`

### TCP Layer (`src/net/transport/tcp/`)

Transmission Control Protocol - reliable, ordered byte stream.

**Simplified 7-State Machine:**
Note: This implementation skips TIME-WAIT and FIN-WAIT states for reduced complexity. Connections close directly via LAST-ACK.

**Features:**
- **Connection Tracking**: SipHash-2-4 based hash table for fast lookup and collision resistance.
- **ISN Generation**: Cryptographically secure ISN generation (RFC 6528) using SipHash and hardware entropy.
- **Fixed Buffers**: 8KB send/receive window (circular buffers).
- **Retransmission**: Timeout-based (1s initial RTO, exponential backoff).
- **DoS Protection**:
    - MAX_HALF_OPEN limit (SYN Flood protection).
    - Active eviction of oldest half-open connection when full.
    - Strict state timeouts (SynSent 75s, Established 2h).
- **Scheduler Integration**: Integrates with kernel scheduler for blocking I/O.
- **MSS**: Minimum 536 bytes per RFC 793, supports MSS option parsing.

**Key structures (`tcp/types.zig`):**
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

### DNS Layer (`src/net/dns/client.zig`)

Domain Name System stub resolver (`getaddrinfo` equivalent).

**Features:**
- **Resolves**: A records (IPv4).
- **CNAME Support**: Follows CNAME chains (up to 8 hops).
- **Security**:
    - **Random Source Port**: Uses ephemeral port randomization (RFC 5452) to prevent cache poisoning.
    - **Random TX ID**: Cryptographically secure 16-bit ID.
    - **Anti-Spoofing**: Validates response source IP, port, and Question section.
    - **Loop Detection**: Detects and bounds compression pointer loops and CNAME loops.
- **Timeout**: Deadline-based timeout (2s) to resist packet floods.

## Socket Layer (`src/net/transport/socket/`)

BSD-style socket API for userland, refactored into modular components.

**Modules:**
- `root.zig`: Core socket exports.
- `state.zig`: Socket state management (tables, allocation).
- `types.zig`: Socket/TimeVal structures.
- `tcp_api.zig`: TCP-specific socket operations (connect, accept, send, recv).
- `udp_api.zig`: UDP-specific socket operations (sendto, recvfrom).
- `options.zig`: `setsockopt` / `getsockopt` implementation.
- `poll.zig`: Support for `poll()` / `select()` (future).

**Supported socket types:**
- `SOCK_STREAM` (1) - TCP
- `SOCK_DGRAM` (2) - UDP

**Socket Options (`options.zig`):**
- **SOL_SOCKET**: `SO_RCVTIMEO`, `SO_SNDTIMEO`, `SO_BROADCAST`.
- **IPPROTO_IP**: `IP_TOS`, `IP_ADD_MEMBERSHIP`, `IP_DROP_MEMBERSHIP`.

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

## Blocking I/O Integration

The network stack integrates with the kernel scheduler for proper blocking I/O.
Operations like `accept`, `recv`, and `connect` will block the calling thread (via `sched.block()`) if the operation cannot complete immediately (e.g., no data, no incoming connection). The network stack (specifically `tcp/state.zig` or `socket/state.zig`) stores the blocked thread and wakes it (`sched.wake()`) when the condition is met (packet arrival, connection established).

## File Organization

```
src/net/
  root.zig              # Module entry point
  core/
    root.zig            # Core exports
    packet.zig          # PacketBuffer, headers
    interface.zig       # Network interface abstraction
    checksum.zig        # Checksum algorithms
  ethernet/
    root.zig
    ethernet.zig        # Frame processing
  ipv4/
    root.zig
    ipv4.zig            # IPv4 protocol logic
    arp.zig             # ARP implementation
    reassembly.zig      # Fragment reassembly & DoS protection
    pmtu.zig            # Path MTU Discovery
  transport/
    root.zig
    icmp.zig            # ICMP implementation
    udp.zig             # UDP protocol logic
    tcp/                # TCP Implementation
      root.zig
      tcp.zig           # Main logic
      state.zig         # State machine & TCB pool
      types.zig         # TCB / State structs
      timers.zig        # Retransmission timers
      rx.zig            # Receive path
      tx.zig            # Transmit path
    socket/             # Socket Layer
      root.zig
      socket.zig        # Main API
      state.zig         # Socket tables
      tcp_api.zig       # TCP socket glue
      udp_api.zig       # UDP socket glue
      options.zig       # setsockopt/getsockopt
  dns/
    root.zig
    client.zig          # Resolver implementation
    dns.zig             # DNS packet formatting

src/drivers/net/e1000e/ # Intel 82574L Driver
  root.zig              # Driver entry
  regs.zig              # Register definitions
  tx.zig                # Transmit ring
  rx.zig                # Receive ring
```

## RFC References

| RFC | Title | Implementation Status |
|-----|-------|----------------------|
| RFC 768 | User Datagram Protocol | Full |
| RFC 791 | Internet Protocol | Full (with reassembly) |
| RFC 792 | Internet Control Message Protocol | Partial (echo, dest unreachable) |
| RFC 793 | Transmission Control Protocol | Partial (simplified states) |
| RFC 826 | Ethernet Address Resolution Protocol | Full |
| RFC 1034/1035 | Domain Names (Concepts/Impl) | Client/Stub Resolver |
| RFC 1122 | Host Requirements | Partial |
| RFC 1191 | Path MTU Discovery | Partial (cache + ICMP Type 3 Code 4) |
| RFC 5452 | DNS Resilience against Spoofing | Full (Random ports + IDs) |
| RFC 6528 | Defending Against Sequence Number Attacks | Full (SipHash + Entropy) |

## Usage Example

```zig
// Userland (via syscalls):
const fd = socket(AF_INET, SOCK_STREAM, 0);

// Resolve hostname (internal API usage example, userland usually has getaddrinfo)
// Note: In this kernel, we currently expose DNS via a library or direct usage for now
// Standard C library would wrap this.

// Connect
var addr = SockAddrIn{
    .family = AF_INET,
    .port = htons(80),
    .addr = inet_addr("10.0.2.2"),
};
connect(fd, &addr, sizeof(addr));

// Send/Recv
send(fd, "GET / HTTP/1.0\r\n\r\n", 18, 0);
recv(fd, buffer, sizeof(buffer), 0);
close(fd);
```

## Roadmap

### Recently Addressed

| Feature | Description | Implementation |
|---------|-------------|----------------|
| **DoS Protection** | TCP Syn Flood protection, IP Reassembly memory caps, SipHash for hash tables | `src/net/transport/tcp/state.zig`, `src/net/ipv4/reassembly.zig` |
| **Refactoring** | Split TCP and Socket layers into modular files | `src/net/transport/tcp/`, `src/net/transport/socket/` |
| **DNS Client** | Stub resolver with anti-spoofing security | `src/net/dns/client.zig` |
| **Protocol Security** | SipHash-2-4 usage for ISN and connection hashing | `src/net/transport/tcp/state.zig` |
| **Fixes** | Fixed TCP half-open limit logic (eviction) | `src/net/transport/tcp/state.zig` |

### Next Steps (Phase 2+)

See `TODO.md` and `docs/ASYNC.md` for broader architectural plans.

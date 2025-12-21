# Net Audit Checklist (src/net)

## File Inventory
- src/net/dns/root.zig
- src/net/dns/client.zig
- src/net/dns/dns.zig
- src/net/sync.zig
- src/net/root.zig
- src/net/loopback.zig
- src/net/entropy.zig
- src/net/ipv4/root.zig
- src/net/ipv4/reassembly.zig
- src/net/ipv4/arp/monitor.zig
- src/net/ipv4/arp/root.zig
- src/net/ipv4/arp/packet.zig
- src/net/ipv4/arp/cache.zig
- src/net/ipv4/ipv4/id.zig
- src/net/ipv4/ipv4/root.zig
- src/net/ipv4/ipv4/validation.zig
- src/net/ipv4/ipv4/types.zig
- src/net/ipv4/ipv4/utils.zig
- src/net/ipv4/ipv4/transmit.zig
- src/net/ipv4/ipv4/process.zig
- src/net/ipv4/pmtu.zig
- src/net/ethernet/root.zig
- src/net/ethernet/ethernet.zig
- src/net/core/root.zig
- src/net/core/packet.zig
- src/net/core/checksum.zig
- src/net/core/interface.zig
- src/net/platform.zig
- src/net/transport/udp.zig
- src/net/transport/root.zig
- src/net/transport/icmp.zig
- src/net/transport/tcp.zig
- src/net/transport/socket.zig
- src/net/transport/socket/poll.zig
- src/net/transport/socket/state.zig
- src/net/transport/socket/lifecycle.zig
- src/net/transport/socket/options.zig
- src/net/transport/socket/root.zig
- src/net/transport/socket/scheduler.zig
- src/net/transport/socket/tcp_api.zig
- src/net/transport/socket/types.zig
- src/net/transport/socket/udp_api.zig
- src/net/transport/socket/errors.zig
- src/net/transport/socket/control.zig
- src/net/transport/tcp/api.zig
- src/net/transport/tcp/types.zig
- src/net/transport/tcp/rx/established.zig
- src/net/transport/tcp/rx/root.zig
- src/net/transport/tcp/rx/listen.zig
- src/net/transport/tcp/rx/syn.zig
- src/net/transport/tcp/constants.zig
- src/net/transport/tcp/state.zig
- src/net/transport/tcp/options.zig
- src/net/transport/tcp/root.zig
- src/net/transport/tcp/timers.zig
- src/net/transport/tcp/errors.zig
- src/net/transport/tcp/tx/root.zig
- src/net/transport/tcp/tx/data.zig
- src/net/transport/tcp/tx/segment.zig
- src/net/transport/tcp/tx/control.zig

## Checklist by File (Expanded, with Findings)

### src/net/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | Confirm init/tick/processFrame call ordering is single-threaded or externally synchronized. | Needs confirmation: no internal locking. |
| Memory | Verify allocator lifetime and ownership of `iface` pointer passed to init. | Needs confirmation: allocator and iface ownership external. |
| Bounds | Ensure any future header offsets are validated before use. | OK: no header arithmetic here. |
| Overflow | Confirm `ticks_per_sec` is sanitized by callers. | Needs confirmation: no validation here. |

### src/net/sync.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | Verify all IrqLock users call `init()` and release Held tokens. | OK: IrqLock panics if uninitialized; Held token pattern. |
| Locking | Confirm Spinlock disables IRQs (per comment) or replace with IrqLock where required. | OK: acquire/tryAcquire disable/restore IRQs. |
| Memory | Audit `AtomicRefcount` retain/release usage for all network objects. | Needs confirmation: used in sockets; ensure balanced retain/release. |
| Overflow | Check refcount increment cannot overflow in long-lived objects. | Potential: no overflow guard on refcount. |

### src/net/platform.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Memory | Userspace syscalls use undefined buffers; confirm no read-before-write on failure. | OK: only read on successful getrandom/clock_gettime; panic/0 otherwise. |
| Overflow | Audit `timeout_us * 1000` and `sec_ns * 1_000_000_000` for overflow. | Potential: unchecked/wrapping math in userspace path. |
| Policy | Inline asm outside `src/arch`; verify exception or relocate. | Violation: inline asm present in src/net/platform.zig. |
| Error | Ensure `userspaceGetMonotonicNs` failure path is safe for callers. | Potential: returns 0 on syscall failure; callers must handle. |

### src/net/entropy.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Memory | Ensure partial getrandom reads handle EINTR and zero-init is preserved. | OK: zeroed buffer and EINTR retry loop. |
| Overflow | Check `total += ret` and cast from isize cannot wrap. | OK: ret bounded by requested length. |
| Policy | Inline asm outside `src/arch`; verify exception or relocate. | Violation: inline asm present in src/net/entropy.zig. |

### src/net/loopback.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | Confirm no concurrent mutation of `loopback_interface` after init. | Potential: no lock around interface field updates after init. |
| Memory | Ensure packet_data and PacketBuffer freed on all paths. | OK: alloc/free paired on all paths. |
| Bounds | Verify header size checks prevent OOB read/write. | OK: eth/IP minimum checks before access. |
| Lifetime | Confirm synchronous processing rule is enforced in handlers. | Needs confirmation: relies on protocol handlers to copy data. |

### src/net/core/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| API | Re-exports only; confirm consistent types and functions. | OK: simple re-export surface. |

### src/net/core/packet.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | Unchecked header accessors only used after validation. | Potential: unchecked accessors are public and used in multiple paths. |
| Bounds | Validate `offset + size` arithmetic cannot overflow. | Potential: unchecked add; relies on caller bounds. |
| Memory | Ensure `payload_offset` and `len` updates are consistent. | OK: helpers guard against payload_offset >= len. |
| Safety | Favor `getHeaderAs*` for untrusted input paths. | OK: safe accessors provided; usage must be audited. |

### src/net/core/checksum.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | Callers validate `total_length` vs buffer before slicing. | Needs confirmation: relies on IP layer validation. |
| Overflow | Ensure length truncation to u16 does not hide errors. | OK: udp/tcp reject >65535 and return 0. |
| Validation | Confirm UDP/TCP checksum rejection paths are enforced for security-sensitive traffic. | OK: checksum helpers used in UDP/TCP processing. |

### src/net/core/interface.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | Stats and multicast lists updated without locks; assess concurrency risks. | Potential: data races on stats/multicast lists. |
| Bounds | `multicast_count` bounds enforced on join/leave. | OK: join checks MAX_MULTICAST_ADDRESSES. |
| Overflow | Packet counters may wrap; ensure acceptable. | Potential: unchecked u64 increments. |

### src/net/ethernet/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| API | Re-exports only; ensure functions are in sync with ethernet.zig. | OK: simple re-export surface. |

### src/net/ethernet/ethernet.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | `pkt.ethHeader()` only after length validation. | Potential: assumes eth_offset==0 after length checks. |
| Bounds | `buildFrame` validates header placement; verify no overflow on `eth_offset + size`. | Potential: unchecked add could overflow if offset corrupted. |
| I/O | Zero padding for short frames prevents leaks. | OK: padding is zeroed. |
| Filtering | `isForUs` multicast behavior matches interface settings. | OK: respects accept_all_multicast and subscriptions. |

### src/net/ipv4/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| API | Re-exports only; ensure alignment with ipv4/arp modules. | OK: simple re-export surface. |

### src/net/ipv4/ipv4/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Memory | Global allocator lifetime and thread-safety. | Needs confirmation: global allocator set once. |
| Init | Ensure `init` called before use of ARP/reassembly. | Needs confirmation: external init order. |

### src/net/ipv4/ipv4/types.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Constants | Validate header size constants match protocol parsing assumptions. | OK: constants match standard header sizes. |

### src/net/ipv4/ipv4/utils.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Overflow | Wrapping add in `isValidNetmask` is intended. | OK: uses wrapping add on inverted mask. |
| Validation | Ensure broadcast/multicast checks align with interface logic. | OK: used consistently in IPv4 processing. |

### src/net/ipv4/ipv4/validation.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | Ensure `options_end` and `offset + option_len` checks cannot overflow. | OK: uses pkt.len and header_len bounds. |
| Policy | Rejects LSRR/SSRR/RR/TS; confirm expected behavior. | OK: explicitly rejects these options. |

### src/net/ipv4/ipv4/id.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | Atomic initialization race acceptable and consistent. | OK: uses atomic cmpxchg and flag. |
| Entropy | Hardware entropy fallback mixing is sufficient for IP ID use. | OK: mixes rdtsc and address for fallback. |
| Overflow | Wrapping arithmetic in PRNG is acceptable. | OK: PRNG uses wrapping by design. |

### src/net/ipv4/ipv4/transmit.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | Verify `payload_len` and MTU comparisons avoid underflow when MTU < header size. | Potential: `iface.mtu - ip_header_len` can underflow. |
| Memory | Fragment buffer allocation size and lifetime correct. | Potential: reuses single frag buffer; assumes transmit is synchronous. |
| TOCTOU | ARP resolve/queue ownership and lifetime safe. | OK: uses resolveOrRequest for queuing. |
| Overflow | Length math uses unchecked add/sub; audit all paths. | Potential: unchecked arithmetic in header/payload size math. |
| MTU | Compare `pkt.len` (includes eth header) against MTU. | Potential: may fragment too early (L2 vs L3 length). |

### src/net/ipv4/ipv4/process.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | Validate `ip_offset + header_len/total_len` against overflow. | Potential: unchecked add; relies on sane offsets. |
| Validation | Checksum and options validation complete for all paths. | OK: checksum and options validated. |
| Memory | Reassembly payload ownership and synchronous use enforced. | OK: reassembly returns owned buffer; deferred free. |
| Filtering | Broadcast/multicast acceptance logic correct. | OK: sets is_broadcast/is_multicast and filters others. |

### src/net/ipv4/reassembly.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | All cache entry operations happen under lock; IRQ disable verified. | OK: lock held for all operations; uses Spinlock with IRQ disable. |
| Memory | `current_memory_usage` stays consistent; deinit always under lock. | OK: deinit under lock; checked arithmetic. |
| Overflow | Audit unchecked `start/end` additions and hole updates. | Potential: unchecked add in `end = start + payload.len`. |
| TOCTOU | Overlap check and memcpy are atomic under lock. | OK: lock held across overlap check and copy. |

### src/net/ipv4/pmtu.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | All cache accesses under `pmtu_lock`. | OK: lookup/update lock. |
| Overflow | Tick/age math and `mtu - overhead` checks safe. | OK: MIN_MTU well above overhead. |
| Validation | Update only decreases MTU and rate-limited. | OK: clamps and rate limits using ticks. |

### src/net/ipv4/arp/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| API | Re-exports only; ensure cache/monitor init ordering. | OK: re-exports only. |

### src/net/ipv4/arp/cache.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | All mutations and hash table ops under `lock`. | Potential: `updateCache` is public and does not lock internally. |
| Memory | Pending packet queue alloc/free on all paths. | OK: freePending clears and frees slots. |
| Bounds | Queue indices use u8 and modulo; verify correctness. | OK: modulo by QUEUE_SIZE. |
| TOCTOU | `findEntry` usage always under lock. | Needs confirmation: helper is unlocked. |
| I/O | UpdateCache transmits while holding lock. | Potential: lock held across transmit call. |

### src/net/ipv4/arp/packet.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | `processPacket` uses cache lock; `resolveOrRequest` deferred send re-checks generation. | OK: lock held; generation re-check before send. |
| Bounds | ARP header size and VLAN offset validation. | OK: validates len vs offset and header size. |
| Memory | Stack buffers for request/reply fully initialized. | OK: all fields written before transmit. |
| Overflow | Backoff/jitter math bounds with ticks_per_second. | Potential: unchecked mul/add; ticks_per_second capped but still large. |

### src/net/ipv4/arp/monitor.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | `ageCache` holds cache lock during iteration. | OK: lock held. |
| Overflow | `ticks_per_second` multiplications cannot overflow u64. | Potential: unchecked mul; ticks_per_second capped at 1_000_000. |
| Logging | logSecurityEvent is non-blocking and safe in IRQ context. | OK: stubbed no-op. |

### src/net/dns/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| API | Re-exports only; confirm stable names. | OK: simple re-exports. |

### src/net/dns/dns.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | `readName` enforces buffer bounds and jump limits. | OK: limits jumps and checks bounds. |
| Overflow | `total_name_len += label_len + 1` cannot wrap. | Potential: unchecked add, but bounded by DNS_MAX_NAME_LENGTH. |
| Validation | Rejects forward compression pointers and reserved label types. | OK: rejects forward pointers and reserved types. |

### src/net/dns/client.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| I/O | recv loop enforces deadline and packet count limit. | OK: deadline and packet count enforced. |
| Bounds | Response parsing validates `pos + rdlen` and header sizes. | OK: checks sizes before reads. |
| Overflow | timeout arithmetic and packet_count increments safe. | Potential: unchecked `rcv_timeout_ms * 1000` and counter wrap. |
| Security | Transaction ID and source port randomization correct. | OK: random port + tx_id mixing. |

### src/net/transport/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| API | Re-exports only; confirm names/types. | OK: simple re-exports. |

### src/net/transport/udp.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | UDP length vs IP payload length validated; verify all paths. | OK: udp_len checked against ip_payload_len. |
| Memory | TX buffer pool alloc/free pairing. | OK: allocTxBuffer/freeTxBuffer used. |
| Validation | DNS checksum non-zero policy enforced. | OK: rejects zero checksum for DNS. |
| TOCTOU | ARP resolution/queueing with packet copy is safe. | OK: uses resolveOrRequest for queuing. |
| Efficiency | Duplicate `arp.resolve` call. | Potential: double lookup could be avoided. |

### src/net/transport/icmp.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | UDP transmit cache lock used consistently. | OK: lock held on read/write. |
| Bounds | ICMP payload lengths and IP header checks safe. | OK: checks ip_total_len and lengths. |
| Overflow | total_len and MTU/backoff math safe. | Potential: unchecked add/mul in some paths. |
| Security | PMTU update validation for TCP/UDP is correct. | OK: validates connection/UDP recent transmit. |

### src/net/transport/tcp.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| API | Re-exports only; ensure names match root.zig. | OK: simple re-exports. |

### src/net/transport/socket.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| API | Re-exports only; ensure types match socket/root.zig. | OK: simple re-exports. |

### src/net/transport/socket/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| API | Re-exports only; ensure module wiring is correct. | OK: simple re-exports. |

### src/net/transport/socket/types.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | All enqueue/dequeue operations are under socket lock. | Needs confirmation: functions do not lock internally. |
| Bounds | `copy_len` and rx queue index wrap are correct. | OK: copy_len limited to entry size and modulo updates. |
| Memory | rx_queue buffers are not leaked and do not expose uninitialized data. | Potential: data buffers initialized on copy; unused tail remains uninitialized but not exposed beyond len. |

### src/net/transport/socket/state.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | All socket_table/udp_sockets access under IrqLock. | Potential: findByPort/findUdpSocket are unlocked helpers. |
| Memory | Refcount retain/release pairs are correct and safe. | OK: tryRetain/release used in acquire/release paths. |
| Overflow | Ephemeral port generation and range math safe. | OK: range math bounded; uses u16. |
| TOCTOU | findByPort/register/unregister use lock consistently. | Potential: helper functions can be called without lock. |

### src/net/transport/socket/lifecycle.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | No lock inversion between state.lock and tcp_state.lock. | Potential: close() holds socket state.lock then calls tcp.close (tcp_state.lock). |
| Memory | close() handles TCB and accept queue safely. | OK: iterates accept_queue and closes TCBs. |
| Bounds | Port reuse checks correct for all sockets. | OK: bind checks existing port in table. |

### src/net/transport/socket/options.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| UserPtr | Callers validate user pointers before optval casts. | Needs confirmation: syscall layer must enforce UserPtr checks. |
| Locking | Per-socket option updates do not race with packet processing. | Potential: options updated without socket lock. |
| Overflow | Timeval conversions and bounds. | OK: tv_usec validated; millis conversion uses u64. |

### src/net/transport/socket/udp_api.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | Lock order: state.lock then sock.lock in all paths. | OK: global lock held for iteration, then per-socket lock. |
| Bounds | Payload length and offsets validated before copy. | OK: payload length checked before slice. |
| Overflow | `rcv_timeout_ms * 1000` cannot overflow u64. | Potential: unchecked multiply. |
| Policy | Inline asm (sti; hlt) outside src/arch is approved. | Violation: inline asm present in src/net/transport/socket/udp_api.zig. |
| Concurrency | `blocked_thread` set without socket lock. | Potential: data race on SMP. |

### src/net/transport/socket/tcp_api.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | Verify lock ordering vs tcp_state.lock and IRQ disable. | OK: tcp_state.lock acquired without holding socket state.lock. |
| Memory | Pending request pointers have safe lifetimes and cancellation. | Needs confirmation: relies on io_uring/request lifetime. |
| Bounds | accept queue indexes and backlog limits enforced. | OK: backlog clamped to ACCEPT_QUEUE_SIZE. |
| TOCTOU | Generation checks on TCBs and sockets are sufficient. | OK: generation checks on connect path. |

### src/net/transport/socket/poll.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | tcp_state.lock held before socket acquire; no deadlocks. | OK: lock order matches RX path. |
| Bounds | Poll event checks do not read invalid TCBs. | OK: checks tcb null/state before use. |

### src/net/transport/socket/control.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | Shutdown transitions do not race with TCP state updates. | Potential: no socket lock around shutdown flags. |
| Validation | `how` parameter and connection state checks. | OK: validates SHUT_* values. |

### src/net/transport/socket/errors.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Mapping | Errno mapping matches kernel ABI. | Needs confirmation: verify errno enum values. |

### src/net/transport/socket/scheduler.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | Function pointer access protected; no recursion. | OK: spinlock around reads/writes. |
| IRQ | Confirm callbacks are IRQ-safe or only used in safe contexts. | Needs confirmation: depends on scheduler implementation. |

### src/net/transport/tcp/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| API | Re-exports only; ensure consistent with tcp/* modules. | OK: simple re-exports. |

### src/net/transport/tcp/constants.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Limits | Validate MAX_TCBS, MAX_HALF_OPEN, timeouts vs memory. | Needs confirmation: sizing vs memory budget. |

### src/net/transport/tcp/types.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | TCB fields updated under mutex where required. | Needs confirmation: some code updates fields without mutex. |
| Bounds | send/recv buffer index wrap is correct. | OK: modulo arithmetic for ring buffers. |
| Overflow | Window scale and buffer math safe. | OK: scale clamped to 14 in rx. |

### src/net/transport/tcp/state.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | IrqLock usage consistent; lock ordering with socket/state. | OK: state.lock used in most operations. |
| Memory | TCB allocation/free and tx pool double-free protections. | OK: double-free guarded in tx pool. |
| Overflow | timestamp and ms_per_tick math safe. | Potential: unchecked math; wrap uses +%= . |
| TOCTOU | validateConnectionExists uses lock and sequence checks. | OK: lock held and seq range checked. |
| Concurrency | nextTimestamp uses global counter without lock. | Potential: data race on SMP if called without state.lock. |

### src/net/transport/tcp/api.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | state.lock then tcb.mutex ordering consistent. | OK: uses state.lock then tcb.mutex. |
| Memory | close() teardown safe with in-flight operations. | OK: sets closing, detaches, frees under lock. |
| Overflow | seq arithmetic and buffer indexes correct. | OK: uses wrapping for seq; ring buffer modulo. |

### src/net/transport/tcp/errors.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Mapping | Errno mapping values correct. | Needs confirmation: verify numeric errno values. |

### src/net/transport/tcp/options.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | Options parsing respects header length and packet bounds. | OK: checks options_end vs pkt.len. |
| Overflow | options_end computations cannot wrap. | Potential: unchecked add; relies on sane offsets. |
| Validation | Window scale/MSS limits enforced. | OK: MSS recorded; window scale clamped. |

### src/net/transport/tcp/timers.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | state.lock held during scan; wake list processed after release. | OK: releases lock before waking. |
| Memory | wake_list initialized before read; no uninitialized access. | OK: only reads up to wake_count. |
| Overflow | RTO backoff and timestamps safe. | Potential: unchecked multiplication and wrapping adds. |

### src/net/transport/tcp/rx/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | state.lock and tcb.mutex held; generation check prevents UAF. | OK: generation check before free. |
| Bounds | TCP segment length and checksum slice validated. | OK: checks ip_total_len and pkt.len. |
| Validation | Drops broadcast/multicast and bad checksum packets. | OK: explicit drop. |

### src/net/transport/tcp/rx/listen.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | state.lock held around half-open allocation and list updates. | OK: acquires state.lock at entry. |
| Overflow | window scaling shift bounded to 14. | OK: clamp with u5 and warn. |
| Resource | SYN flood eviction logic is correct under load. | Needs confirmation: eviction logic relies on half-open list. |

### src/net/transport/tcp/rx/syn.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | Half-open list updates happen under state.lock (verify caller). | Issue: `processSynReceived` updates half_open_count/list without state.lock. |
| Validation | ACK handling and reset path correct. | OK: verifies ACK and RST behavior. |
| Overflow | seq/window scaling math safe. | OK: seq uses wrapping; scale clamped. |

### src/net/transport/tcp/rx/established.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | Caller holds tcb.mutex for all updates. | Needs confirmation: RX path acquires mutex. |
| Bounds | recv buffer space checks prevent overflow. | OK: computes space before copy. |
| Overflow | cwnd updates and ack math safe. | Potential: some adds are unchecked with saturation fallback. |

### src/net/transport/tcp/tx/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| API | Re-exports only; ensure names match submodules. | OK: simple re-exports. |

### src/net/transport/tcp/tx/segment.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | total_len and header lengths validated before copy. | OK: validates ip_len <= 65535 and buffer size. |
| Memory | tx buffer pool usage correct for all paths. | OK: alloc/free paired. |
| TOCTOU | ARP resolve/queueing uses packet copy safely. | OK: uses resolveOrRequest with wrapper PacketBuffer. |

### src/net/transport/tcp/tx/control.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | options_len and header size calculations safe. | OK: options_len from builder; validates ip_len. |
| Memory | options buffer fully initialized before use. | OK: copies only options_len. |
| TOCTOU | ARP resolve/queueing ownership safe. | OK: uses resolveOrRequest with wrapper PacketBuffer. |

### src/net/transport/tcp/tx/data.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | send_len <= MAX_TCP_PAYLOAD and buffer size. | OK: send_len limited by MAX_TCP_PAYLOAD. |
| Overflow | window and flight size arithmetic safe. | Potential: unchecked arithmetic on u32/u64. |
| Locking | Caller holds tcb.mutex. | Needs confirmation: send path does hold tcb.mutex. |

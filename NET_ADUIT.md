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
| Locking | Confirm init/tick/processFrame call ordering is single-threaded or externally synchronized. | OK: user netstack runs single-threaded loops (`src/user/netstack/main.zig:69`, `src/user/netstack/main.zig:113`). |
| Memory | Verify allocator lifetime and ownership of `iface` pointer passed to init. | OK: iface and allocator live for process lifetime in netstack (`src/user/netstack/main.zig:20`, `src/user/netstack/main.zig:33`). |
| Bounds | Ensure any future header offsets are validated before use. | OK: no header arithmetic in this file (`src/net/root.zig:54`). |
| Overflow | Confirm `ticks_per_sec` is sanitized by callers. | OK: submodules clamp/validate ticks_per_sec (`src/net/ipv4/arp/cache.zig:322`, `src/net/transport/tcp/state.zig:169`). |

### src/net/sync.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | Verify all IrqLock users call `init()` and release Held tokens. | OK: IrqLock enforces init and Held release pattern (`src/net/sync.zig:52`). |
| Locking | Confirm Spinlock disables IRQs (per comment) or replace with IrqLock where required. | OK: acquire/tryAcquire disable/restore IRQs (`src/net/sync.zig:18`, `src/net/sync.zig:33`). |
| Memory | Audit `AtomicRefcount` retain/release usage for all network objects. | OK: socket acquire/release uses tryRetain/release (`src/net/transport/socket/state.zig:51`, `src/net/transport/socket/state.zig:103`). |
| Overflow | Check refcount increment cannot overflow in long-lived objects. | Potential: no overflow guard on refcount (`src/net/sync.zig:95`). |

### src/net/platform.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Memory | Userspace syscalls use undefined buffers; confirm no read-before-write on failure. | OK: only read on success; panic/0 on failure (`src/net/platform.zig:11`, `src/net/platform.zig:83`). |
| Overflow | Audit `timeout_us * 1000` and `sec_ns * 1_000_000_000` for overflow. | Potential: unchecked math (`src/net/platform.zig:57`, `src/net/platform.zig:90`). |
| Policy | Inline asm outside `src/arch`; verify exception or relocate. | Violation: inline asm in userspace stubs (`src/net/platform.zig:28`, `src/net/platform.zig:75`). |
| Error | Ensure `userspaceGetMonotonicNs` failure path is safe for callers. | Potential: returns 0 on syscall failure (`src/net/platform.zig:83`). |

### src/net/entropy.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Memory | Ensure partial getrandom reads handle EINTR and zero-init is preserved. | OK: zero-init and EINTR retry loop (`src/net/entropy.zig:13`, `src/net/entropy.zig:16`). |
| Overflow | Check `total += ret` and cast from isize cannot wrap. | OK: ret bounded by remaining length (`src/net/entropy.zig:16`). |
| Policy | Inline asm outside `src/arch`; verify exception or relocate. | Violation: inline asm in userspace getrandom (`src/net/entropy.zig:36`). |

### src/net/loopback.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | Confirm no concurrent mutation of `loopback_interface` after init. | Potential: interface fields written without lock (`src/net/loopback.zig:33`). |
| Memory | Ensure packet_data and PacketBuffer freed on all paths. | OK: frees packet_data and PacketBuffer on all paths (`src/net/loopback.zig:85`, `src/net/loopback.zig:105`). |
| Bounds | Verify header size checks prevent OOB read/write. | OK: eth/IP size checks before use (`src/net/loopback.zig:74`, `src/net/loopback.zig:81`). |
| Lifetime | Confirm synchronous processing rule is enforced in handlers. | OK: UDP/TCP handlers copy data into queues/buffers before return (`src/net/transport/socket/udp_api.zig:206`, `src/net/transport/tcp/rx/established.zig:96`). |

### src/net/core/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| API | Re-exports only; confirm consistent types and functions. | OK: simple re-export surface (`src/net/core/root.zig:6`). |

### src/net/core/packet.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | Unchecked header accessors only used after validation. | Potential: unchecked accessors are public (`src/net/core/packet.zig:91`). |
| Bounds | Validate `offset + size` arithmetic cannot overflow. | Potential: unchecked adds in accessors and append (`src/net/core/packet.zig:93`, `src/net/core/packet.zig:144`). |
| Memory | Ensure `payload_offset` and `len` updates are consistent. | OK: payload helpers guard against invalid offsets (`src/net/core/packet.zig:112`). |
| Safety | Favor `getHeaderAs*` for untrusted input paths. | OK: safe accessors provided (`src/net/core/packet.zig:312`). |

### src/net/core/checksum.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | Callers validate `total_length` vs buffer before slicing. | OK: IPv4 layer bounds checks `total_len` and clamps pkt.len before transport (`src/net/ipv4/ipv4/process.zig:41`, `src/net/ipv4/ipv4/process.zig:47`). |
| Overflow | Ensure length truncation to u16 does not hide errors. | OK: rejects >65535 lengths (`src/net/core/checksum.zig:55`, `src/net/core/checksum.zig:112`). |
| Validation | Confirm UDP/TCP checksum rejection paths are enforced for security-sensitive traffic. | OK: UDP/TCP use checksum helpers (`src/net/core/checksum.zig:41`). |

### src/net/core/interface.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | Stats and multicast lists updated without locks; assess concurrency risks. | Potential: fields updated without synchronization (`src/net/core/interface.zig:76`, `src/net/core/interface.zig:130`). |
| Bounds | `multicast_count` bounds enforced on join/leave. | OK: join checks MAX_MULTICAST_ADDRESSES (`src/net/core/interface.zig:131`). |
| Overflow | Packet counters may wrap; ensure acceptable. | Potential: unchecked increments (`src/net/core/interface.zig:83`). |

### src/net/ethernet/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| API | Re-exports only; ensure functions are in sync with ethernet.zig. | OK: simple re-export surface (`src/net/ethernet/root.zig:6`). |

### src/net/ethernet/ethernet.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | `pkt.ethHeader()` only after length validation. | Potential: uses unchecked ethHeader; assumes len checked (`src/net/ethernet/ethernet.zig:57`). |
| Bounds | `buildFrame` validates header placement; verify no overflow on `eth_offset + size`. | Potential: unchecked add in bounds check (`src/net/ethernet/ethernet.zig:126`). |
| I/O | Zero padding for short frames prevents leaks. | OK: padding zeroed (`src/net/ethernet/ethernet.zig:152`). |
| Filtering | `isForUs` multicast behavior matches interface settings. | OK: accept_all_multicast and join list honored (`src/net/ethernet/ethernet.zig:94`). |

### src/net/ipv4/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| API | Re-exports only; ensure alignment with ipv4/arp modules. | OK: simple re-export surface (`src/net/ipv4/root.zig:6`). |

### src/net/ipv4/ipv4/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Memory | Global allocator lifetime and thread-safety. | OK: allocator set during net.init in netstack main (`src/net/root.zig:39`, `src/user/netstack/main.zig:43`). |
| Init | Ensure `init` called before use of ARP/reassembly. | OK: net.init calls ipv4.init before use (`src/net/root.zig:41`). |

### src/net/ipv4/ipv4/types.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Constants | Validate header size constants match protocol parsing assumptions. | OK: standard values (`src/net/ipv4/ipv4/types.zig:5`). |

### src/net/ipv4/ipv4/utils.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Overflow | Wrapping add in `isValidNetmask` is intended. | OK: uses wrapping add (`src/net/ipv4/ipv4/utils.zig:6`). |
| Validation | Ensure broadcast/multicast checks align with interface logic. | OK: used by IPv4 processing (`src/net/ipv4/ipv4/utils.zig:12`). |

### src/net/ipv4/ipv4/validation.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | Ensure `options_end` and `offset + option_len` checks cannot overflow. | OK: bounds checks on header length and option length (`src/net/ipv4/ipv4/validation.zig:9`, `src/net/ipv4/ipv4/validation.zig:36`). |
| Policy | Rejects LSRR/SSRR/RR/TS; confirm expected behavior. | OK: explicit rejection (`src/net/ipv4/ipv4/validation.zig:42`). |

### src/net/ipv4/ipv4/id.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | Atomic initialization race acceptable and consistent. | OK: uses cmpxchg and atomic flag (`src/net/ipv4/ipv4/id.zig:13`). |
| Entropy | Hardware entropy fallback mixing is sufficient for IP ID use. | OK: entropy/rdtsc mixing (`src/net/ipv4/ipv4/id.zig:9`). |
| Overflow | Wrapping arithmetic in PRNG is acceptable. | OK: uses wrapping ops (`src/net/ipv4/ipv4/id.zig:23`). |

### src/net/ipv4/ipv4/transmit.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | Verify `payload_len` and MTU comparisons avoid underflow when MTU < header size. | Potential: `iface.mtu - ip_header_len` can underflow (`src/net/ipv4/ipv4/transmit.zig:120`). |
| Memory | Fragment buffer allocation size and lifetime correct. | Potential: uses single `frag_buf` for all fragments; assumes transmit is synchronous (`src/net/ipv4/ipv4/transmit.zig:122`). |
| TOCTOU | ARP resolve/queue ownership and lifetime safe. | OK: resolveOrRequest used for queuing (`src/net/ipv4/ipv4/transmit.zig:91`). |
| Overflow | Length math uses unchecked add/sub; audit all paths. | Potential: unchecked adds on header/payload lengths (`src/net/ipv4/ipv4/transmit.zig:48`, `src/net/ipv4/ipv4/transmit.zig:155`). |
| MTU | Compare `pkt.len` (includes L2) against MTU. | Potential: MTU check uses `pkt.len` vs `iface.mtu` (`src/net/ipv4/ipv4/transmit.zig:103`). |

### src/net/ipv4/ipv4/process.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | Validate `ip_offset + header_len/total_len` against overflow. | Potential: unchecked adds (`src/net/ipv4/ipv4/process.zig:34`, `src/net/ipv4/ipv4/process.zig:42`). |
| Validation | Checksum and options validation complete for all paths. | OK: validation and checksum checked (`src/net/ipv4/ipv4/process.zig:36`, `src/net/ipv4/ipv4/process.zig:38`). |
| Memory | Reassembly payload ownership and synchronous use enforced. | OK: uses owned buffer with defer deinit (`src/net/ipv4/ipv4/process.zig:99`). |
| Filtering | Broadcast/multicast acceptance logic correct. | OK: sets is_broadcast/is_multicast and rejects others (`src/net/ipv4/ipv4/process.zig:53`). |

### src/net/ipv4/reassembly.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | All cache entry operations happen under lock; IRQ disable verified. | OK: lock held for processFragment path (`src/net/ipv4/reassembly.zig:209`). |
| Memory | `current_memory_usage` stays consistent; deinit always under lock. | OK: deinit adjusts accounting (`src/net/ipv4/reassembly.zig:89`). |
| Overflow | Audit unchecked `start/end` additions and hole updates. | Potential: `end = start + payload.len` unchecked (`src/net/ipv4/reassembly.zig:253`). |
| TOCTOU | Overlap check and memcpy are atomic under lock. | OK: overlap check and memcpy under lock (`src/net/ipv4/reassembly.zig:360`, `src/net/ipv4/reassembly.zig:367`). |

### src/net/ipv4/pmtu.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | All cache accesses under `pmtu_lock`. | OK: lock held in lookup/update (`src/net/ipv4/pmtu.zig:42`, `src/net/ipv4/pmtu.zig:66`). |
| Overflow | Tick/age math and `mtu - overhead` checks safe. | OK: uses u64 ticks; overhead bounded (`src/net/ipv4/pmtu.zig:92`, `src/net/ipv4/pmtu.zig:129`). |
| Validation | Update only decreases MTU and rate-limited. | OK: clamps and rate limits (`src/net/ipv4/pmtu.zig:74`). |

### src/net/ipv4/arp/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| API | Re-exports only; ensure cache/monitor init ordering. | OK: simple re-exports (`src/net/ipv4/arp/root.zig:1`). |

### src/net/ipv4/arp/cache.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | All mutations and hash table ops under `lock`. | OK: updateCache called under cache.lock in ARP packet path (`src/net/ipv4/arp/packet.zig:18`, `src/net/ipv4/arp/packet.zig:50`). |
| Memory | Pending packet queue alloc/free on all paths. | OK: freePending clears and frees slots (`src/net/ipv4/arp/cache.zig:130`). |
| Bounds | Queue indices use u8 and modulo; verify correctness. | OK: modulo by QUEUE_SIZE (`src/net/ipv4/arp/cache.zig:273`). |
| TOCTOU | `findEntry` usage always under lock. | OK: all call sites are under cache.lock (`src/net/ipv4/arp/packet.zig:18`, `src/net/ipv4/arp/packet.zig:50`). |
| I/O | UpdateCache transmits while holding lock. | Potential: transmit inside update path (`src/net/ipv4/arp/cache.zig:270`, `src/net/ipv4/arp/cache.zig:282`). |

### src/net/ipv4/arp/packet.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | `processPacket` uses cache lock; `resolveOrRequest` deferred send re-checks generation. | OK: lock held during processPacket and resolveOrRequest (`src/net/ipv4/arp/packet.zig:18`, `src/net/ipv4/arp/packet.zig:185`). |
| Bounds | ARP header size and VLAN offset validation. | OK: validates VLAN offset and header size (`src/net/ipv4/arp/packet.zig:24`, `src/net/ipv4/arp/packet.zig:33`). |
| Memory | Stack buffers for request/reply fully initialized. | OK: full header writes before transmit (`src/net/ipv4/arp/packet.zig:110`, `src/net/ipv4/arp/packet.zig:135`). |
| Overflow | Backoff/jitter math bounds with ticks_per_second. | Potential: unchecked mul/add in backoff (`src/net/ipv4/arp/packet.zig:59`). |

### src/net/ipv4/arp/monitor.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | `ageCache` holds cache lock during iteration. | OK: lock held (`src/net/ipv4/arp/monitor.zig:51`). |
| Overflow | `ticks_per_second` multiplications cannot overflow u64. | Potential: unchecked mul with ticks_per_second (`src/net/ipv4/arp/monitor.zig:71`, `src/net/ipv4/arp/monitor.zig:82`). |
| Logging | logSecurityEvent is non-blocking and safe in IRQ context. | OK: stubbed no-op (`src/net/ipv4/arp/monitor.zig:36`). |

### src/net/dns/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| API | Re-exports only; confirm stable names. | OK: simple re-exports (`src/net/dns/root.zig:1`). |

### src/net/dns/dns.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | `readName` enforces buffer bounds and jump limits. | OK: bounds and jump checks (`src/net/dns/dns.zig:136`, `src/net/dns/dns.zig:151`). |
| Overflow | `total_name_len += label_len + 1` cannot wrap. | Potential: unchecked add, though capped (`src/net/dns/dns.zig:178`). |
| Validation | Rejects forward compression pointers and reserved label types. | OK: rejects forward pointers and reserved types (`src/net/dns/dns.zig:161`, `src/net/dns/dns.zig:168`). |

### src/net/dns/client.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| I/O | recv loop enforces deadline and packet count limit. | OK: deadline and packet cap (`src/net/dns/client.zig:154`, `src/net/dns/client.zig:166`). |
| Bounds | Response parsing validates `pos + rdlen` and header sizes. | OK: header and rdlen checks (`src/net/dns/client.zig:233`, `src/net/dns/client.zig:260`). |
| Overflow | timeout arithmetic and packet_count increments safe. | Potential: packet_count unchecked increment (`src/net/dns/client.zig:166`). |
| Security | Transaction ID and source port randomization correct. | OK: random port + tx_id mixing (`src/net/dns/client.zig:100`, `src/net/dns/client.zig:123`). |

### src/net/transport/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| API | Re-exports only; confirm names/types. | OK: simple re-exports (`src/net/transport/root.zig:6`). |

### src/net/transport/udp.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | UDP length vs IP payload length validated; verify all paths. | OK: udp_len checked vs ip_payload_len (`src/net/transport/udp.zig:51`, `src/net/transport/udp.zig:56`). |
| Memory | TX buffer pool alloc/free pairing. | OK: allocTxBuffer/freeTxBuffer used (`src/net/transport/udp.zig:140`). |
| Validation | DNS checksum non-zero policy enforced. | OK: rejects zero checksum for DNS (`src/net/transport/udp.zig:74`). |
| TOCTOU | ARP resolution/queueing with packet copy is safe. | OK: resolveOrRequest used for queuing (`src/net/transport/udp.zig:196`). |
| Efficiency | Duplicate `arp.resolve` call. | Potential: resolve called twice (`src/net/transport/udp.zig:130`, `src/net/transport/udp.zig:131`). |

### src/net/transport/icmp.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | UDP transmit cache lock used consistently. | OK: lock acquired in record/validate (`src/net/transport/icmp.zig:69`, `src/net/transport/icmp.zig:84`). |
| Bounds | ICMP payload lengths and IP header checks safe. | OK: checks ip_total_len/header_len (`src/net/transport/icmp.zig:126`). |
| Overflow | total_len and MTU/backoff math safe. | Potential: unchecked `total_len` adds (`src/net/transport/icmp.zig:187`). |
| Security | PMTU update validation for TCP/UDP is correct. | OK: validates TCP/UDP before PMTU update (`src/net/transport/icmp.zig:308`). |

### src/net/transport/tcp.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| API | Re-exports only; ensure names match root.zig. | OK: simple re-exports (`src/net/transport/tcp.zig:2`). |

### src/net/transport/socket.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| API | Re-exports only; ensure types match socket/root.zig. | OK: simple re-exports (`src/net/transport/socket.zig:6`). |

### src/net/transport/socket/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| API | Re-exports only; ensure module wiring is correct. | OK: simple re-exports (`src/net/transport/socket/root.zig:3`). |

### src/net/transport/socket/types.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | All enqueue/dequeue operations are under socket lock. | OK: UDP delivery and recv acquire sock.lock before enqueue/dequeue (`src/net/transport/socket/udp_api.zig:247`, `src/net/transport/socket/udp_api.zig:175`). |
| Bounds | `copy_len` and rx queue index wrap are correct. | OK: copy_len limited and modulo wrap (`src/net/transport/socket/types.zig:275`, `src/net/transport/socket/types.zig:282`). |
| Memory | rx_queue buffers are not leaked and do not expose uninitialized data. | OK: copy_len bounds and len recorded (`src/net/transport/socket/types.zig:275`, `src/net/transport/socket/types.zig:302`). |

### src/net/transport/socket/state.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | All socket_table/udp_sockets access under IrqLock. | Potential: `findByPort`/`findUdpSocket` are unlocked helpers (`src/net/transport/socket/state.zig:198`, `src/net/transport/socket/state.zig:210`). |
| Memory | Refcount retain/release pairs are correct and safe. | OK: tryRetain/release used in acquire/release (`src/net/transport/socket/state.zig:51`, `src/net/transport/socket/state.zig:103`). |
| Overflow | Ephemeral port generation and range math safe. | OK: u16 range math bounded (`src/net/transport/socket/state.zig:123`). |
| TOCTOU | findByPort/register/unregister use lock consistently. | Potential: helpers are unlocked (`src/net/transport/socket/state.zig:198`, `src/net/transport/socket/state.zig:214`). |

### src/net/transport/socket/lifecycle.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | No lock inversion between state.lock and tcp_state.lock. | Potential: close() holds state.lock then calls tcp.close (`src/net/transport/socket/lifecycle.zig:80`, `src/net/transport/socket/lifecycle.zig:92`). |
| Memory | close() handles TCB and accept queue safely. | OK: closes TCB and accept_queue entries (`src/net/transport/socket/lifecycle.zig:91`, `src/net/transport/socket/lifecycle.zig:100`). |
| Bounds | Port reuse checks correct for all sockets. | OK: bind checks existing port (`src/net/transport/socket/lifecycle.zig:58`). |

### src/net/transport/socket/options.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| UserPtr | Callers validate user pointers before optval casts. | OK: sys_setsockopt/getsockopt validate/copy user buffers (`src/kernel/sys/syscall/net.zig:567`, `src/kernel/sys/syscall/net.zig:604`). |
| Locking | Per-socket option updates do not race with packet processing. | Potential: options updated without socket lock (`src/net/transport/socket/options.zig:25`). |
| Overflow | Timeval conversions and bounds. | OK: tv_usec validated (`src/net/transport/socket/options.zig:22`). |

### src/net/transport/socket/udp_api.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | Lock order: state.lock then sock.lock in all paths. | OK: state.lock held for iteration, then sock.lock (`src/net/transport/socket/udp_api.zig:47`, `src/net/transport/socket/udp_api.zig:69`). |
| Bounds | Payload length and offsets validated before copy. | OK: payload length checked (`src/net/transport/socket/udp_api.zig:206`, `src/net/transport/socket/udp_api.zig:214`). |
| Overflow | `rcv_timeout_ms * 1000` cannot overflow u64. | Potential: unchecked multiply (`src/net/transport/socket/udp_api.zig:123`). |
| Policy | Inline asm (sti; hlt) outside src/arch is approved. | Violation: inline asm in recv fallback (`src/net/transport/socket/udp_api.zig:187`). |
| Concurrency | `blocked_thread` set without socket lock. | Potential: data race on SMP (`src/net/transport/socket/udp_api.zig:154`). |

### src/net/transport/socket/tcp_api.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | Verify lock ordering vs tcp_state.lock and IRQ disable. | OK: tcp_state.lock acquired without holding state.lock in async path (`src/net/transport/socket/tcp_api.zig:381`). |
| Memory | Pending request pointers have safe lifetimes and cancellation. | OK: IoRequest lifetime is pool-managed until completion, and pending_* cleared on complete (`src/kernel/io/types.zig:166`, `src/net/transport/socket/tcp_api.zig:571`). |
| Bounds | accept queue indexes and backlog limits enforced. | OK: backlog clamped to ACCEPT_QUEUE_SIZE (`src/net/transport/socket/tcp_api.zig:31`, `src/net/transport/socket/tcp_api.zig:90`). |
| TOCTOU | Generation checks on TCBs and sockets are sufficient. | OK: connect path uses generation checks (`src/net/transport/socket/tcp_api.zig:219`). |

### src/net/transport/socket/poll.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | tcp_state.lock held before socket acquire; no deadlocks. | OK: lock order matches RX path (`src/net/transport/socket/poll.zig:9`). |
| Bounds | Poll event checks do not read invalid TCBs. | OK: tcb null/state checks (`src/net/transport/socket/poll.zig:22`). |

### src/net/transport/socket/control.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | Shutdown transitions do not race with TCP state updates. | Potential: shutdown flags set without socket lock (`src/net/transport/socket/control.zig:26`, `src/net/transport/socket/control.zig:36`). |
| Validation | `how` parameter and connection state checks. | OK: validates SHUT_* values (`src/net/transport/socket/control.zig:20`). |

### src/net/transport/socket/errors.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Mapping | Errno mapping matches kernel ABI. | OK: uses uapi.Errno enum values (`src/net/transport/socket/errors.zig:24`, `src/uapi/errno.zig:12`). |

### src/net/transport/socket/scheduler.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | Function pointer access protected; no recursion. | OK: lock protects reads/writes (`src/net/transport/socket/scheduler.zig:12`). |
| IRQ | Confirm callbacks are IRQ-safe or only used in safe contexts. | Needs confirmation: depends on scheduler callbacks (`src/net/transport/socket/scheduler.zig:19`). |

### src/net/transport/tcp/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| API | Re-exports only; ensure consistent with tcp/* modules. | OK: simple re-exports (`src/net/transport/tcp/root.zig:12`). |

### src/net/transport/tcp/constants.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Limits | Validate MAX_TCBS, MAX_HALF_OPEN, timeouts vs memory. | Needs confirmation: sizes depend on system constraints (`src/net/transport/tcp/constants.zig:24`). |

### src/net/transport/tcp/types.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | TCB fields updated under mutex where required. | OK: rx/root acquires tcb.mutex for established/listen; api/timers also hold mutex (`src/net/transport/tcp/rx/root.zig:78`, `src/net/transport/tcp/api.zig:124`, `src/net/transport/tcp/timers.zig:26`). |
| Bounds | send/recv buffer index wrap is correct. | OK: modulo arithmetic used for ring buffers (`src/net/transport/tcp/types.zig:214`). |
| Overflow | Window scale and buffer math safe. | OK: scale clamped and window limited (`src/net/transport/tcp/types.zig:204`). |

### src/net/transport/tcp/state.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | IrqLock usage consistent; lock ordering with socket/state. | OK: state.lock used for critical sections (`src/net/transport/tcp/state.zig:89`). |
| Memory | TCB allocation/free and tx pool double-free protections. | OK: tx pool double-free guard (`src/net/transport/tcp/state.zig:52`). |
| Overflow | timestamp and ms_per_tick math safe. | Potential: unchecked add in tick and time_component multiply (`src/net/transport/tcp/state.zig:83`, `src/net/transport/tcp/state.zig:403`). |
| TOCTOU | validateConnectionExists uses lock and sequence checks. | OK: lock held and seq checked (`src/net/transport/tcp/state.zig:353`). |
| Concurrency | nextTimestamp uses global counter without lock. | Potential: global counter not synchronized (`src/net/transport/tcp/state.zig:443`). |

### src/net/transport/tcp/api.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | state.lock then tcb.mutex ordering consistent. | OK: state.lock acquired then tcb.mutex (`src/net/transport/tcp/api.zig:63`, `src/net/transport/tcp/api.zig:101`). |
| Memory | close() teardown safe with in-flight operations. | OK: sets closing and frees under lock (`src/net/transport/tcp/api.zig:62`, `src/net/transport/tcp/api.zig:115`). |
| Overflow | seq arithmetic and buffer indexes correct. | OK: uses wrapping for seq/ring buffers (`src/net/transport/tcp/api.zig:83`, `src/net/transport/tcp/api.zig:153`). |

### src/net/transport/tcp/errors.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Mapping | Errno mapping values correct. | OK: numeric values match uapi.Errno table (`src/net/transport/tcp/errors.zig:9`, `src/uapi/errno.zig:172`). |

### src/net/transport/tcp/options.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | Options parsing respects header length and packet bounds. | OK: checks options_end vs pkt.len (`src/net/transport/tcp/options.zig:34`). |
| Overflow | options_end computations cannot wrap. | Potential: unchecked adds on offsets (`src/net/transport/tcp/options.zig:35`, `src/net/transport/tcp/options.zig:36`). |
| Validation | Window scale/MSS limits enforced. | OK: window scale clamped and MSS captured (`src/net/transport/tcp/options.zig:92`). |

### src/net/transport/tcp/timers.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | state.lock held during scan; tcb.mutex held for per-TCB mutation; wake list processed after release. | OK: tryAcquire tcb.mutex per TCB and release before free (`src/net/transport/tcp/timers.zig:26`, `src/net/transport/tcp/timers.zig:46`); release state.lock before wake (`src/net/transport/tcp/timers.zig:130`). |
| Memory | wake_list initialized before read; no uninitialized access. | OK: only reads up to wake_count (`src/net/transport/tcp/timers.zig:15`, `src/net/transport/tcp/timers.zig:134`). |
| Overflow | RTO backoff and timestamps safe. | Potential: `rto_ms * 2` unchecked (`src/net/transport/tcp/timers.zig:105`). |

### src/net/transport/tcp/rx/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | state.lock and tcb.mutex held; generation check prevents UAF. | OK: generation check before free (`src/net/transport/tcp/rx/root.zig:30`, `src/net/transport/tcp/rx/root.zig:52`). |
| Bounds | TCP segment length and checksum slice validated. | OK: length checks before checksum (`src/net/transport/tcp/rx/root.zig:16`, `src/net/transport/tcp/rx/root.zig:33`). |
| Validation | Drops broadcast/multicast and bad checksum packets. | OK: explicit drop (`src/net/transport/tcp/rx/root.zig:52`). |

### src/net/transport/tcp/rx/listen.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | state.lock held around half-open allocation and list updates. | OK: acquires state.lock at entry (`src/net/transport/tcp/rx/listen.zig:28`). |
| Overflow | window scaling shift bounded to 14. | OK: clamp to 14 (`src/net/transport/tcp/rx/listen.zig:86`). |
| Resource | SYN flood eviction logic is correct under load. | Potential: eviction relies on half-open list integrity; syn path mutates list without lock (`src/net/transport/tcp/rx/listen.zig:31`, `src/net/transport/tcp/rx/syn.zig:108`). |

### src/net/transport/tcp/rx/syn.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | Half-open list updates happen under state.lock (verify caller). | Issue: updates half-open list/count without lock (`src/net/transport/tcp/rx/syn.zig:108`, `src/net/transport/tcp/rx/syn.zig:111`). |
| Validation | ACK handling and reset path correct. | OK: ACK checked and RST on mismatch (`src/net/transport/tcp/rx/syn.zig:23`, `src/net/transport/tcp/rx/syn.zig:101`). |
| Overflow | seq/window scaling math safe. | OK: scale clamped and wrapping seq math (`src/net/transport/tcp/rx/syn.zig:68`). |

### src/net/transport/tcp/rx/established.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Locking | Caller holds tcb.mutex for all updates. | OK: rx/root acquires tcb.mutex before dispatch (`src/net/transport/tcp/rx/root.zig:78`). |
| Bounds | recv buffer space checks prevent overflow. | OK: computes space before copy (`src/net/transport/tcp/rx/established.zig:97`). |
| Overflow | cwnd updates and ack math safe. | Potential: arithmetic uses add with fallback but no global bounds (`src/net/transport/tcp/rx/established.zig:36`). |

### src/net/transport/tcp/tx/root.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| API | Re-exports only; ensure names match submodules. | OK: simple re-exports (`src/net/transport/tcp/tx/root.zig:1`). |

### src/net/transport/tcp/tx/segment.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | total_len and header lengths validated before copy. | OK: checks ip_len <= 65535 and buffer size (`src/net/transport/tcp/tx/segment.zig:33`, `src/net/transport/tcp/tx/segment.zig:43`). |
| Memory | tx buffer pool usage correct for all paths. | OK: alloc/free paired (`src/net/transport/tcp/tx/segment.zig:41`). |
| TOCTOU | ARP resolve/queueing uses packet copy safely. | OK: resolveOrRequest uses wrapper PacketBuffer (`src/net/transport/tcp/tx/segment.zig:71`). |

### src/net/transport/tcp/tx/control.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | options_len and header size calculations safe. | OK: options_len from builder; ip_len checked (`src/net/transport/tcp/tx/control.zig:20`, `src/net/transport/tcp/tx/control.zig:35`). |
| Memory | options buffer fully initialized before use. | OK: copies only options_len (`src/net/transport/tcp/tx/control.zig:67`). |
| TOCTOU | ARP resolve/queueing ownership safe. | OK: resolveOrRequest used (`src/net/transport/tcp/tx/control.zig:80`). |

### src/net/transport/tcp/tx/data.zig
| Area | Checklist | Findings |
| --- | --- | --- |
| Bounds | send_len <= MAX_TCP_PAYLOAD and buffer size. | OK: send_len limited by MAX_TCP_PAYLOAD (`src/net/transport/tcp/tx/data.zig:79`). |
| Overflow | window and flight size arithmetic safe. | Potential: unchecked arithmetic on u32/u64 (`src/net/transport/tcp/tx/data.zig:48`, `src/net/transport/tcp/tx/data.zig:72`). |
| Locking | Caller holds tcb.mutex. | OK: callers hold tcb.mutex in api and timers (`src/net/transport/tcp/api.zig:124`, `src/net/transport/tcp/timers.zig:26`). |

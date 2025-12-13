#!/usr/bin/env python3
"""
Packet Fuzzer for Zscapek Network Stack

Sends malformed network packets to test driver and protocol stack robustness.
Designed to find crashes, hangs, and resource leaks in the kernel network code.

Requirements:
    - scapy: pip install scapy
    - Root/sudo for raw socket access
    - QEMU with user networking or TAP interface

Usage:
    # With QEMU user networking (default gateway 10.0.2.2)
    sudo python3 fuzz_packets.py --target 10.0.2.15 --iface en0

    # With TAP interface
    sudo python3 fuzz_packets.py --target 10.0.2.15 --iface tap0 --tap

Test Categories:
    1. Malformed Ethernet frames
    2. Invalid IP headers
    3. TCP flag combinations
    4. UDP with bad lengths
    5. ICMP edge cases
    6. Truncated packets
    7. Oversized packets

Author: Zscapek Development Team
"""

import argparse
import random
import time
import sys

try:
    from scapy.all import (
        Ether, IP, TCP, UDP, ICMP, ARP, Raw,
        send, sendp, conf, RandIP, RandMAC, RandShort
    )
except ImportError:
    print("Error: scapy not installed. Run: pip install scapy")
    sys.exit(1)


class PacketFuzzer:
    """Network packet fuzzer for kernel testing."""

    def __init__(self, target_ip: str, target_mac: str = None, iface: str = None):
        self.target_ip = target_ip
        self.target_mac = target_mac or "52:54:00:12:34:56"  # QEMU default
        self.iface = iface
        self.stats = {
            'sent': 0,
            'errors': 0,
            'categories': {}
        }

    def _send(self, pkt, layer2: bool = False) -> bool:
        """Send packet and track statistics."""
        try:
            if layer2:
                sendp(pkt, iface=self.iface, verbose=0)
            else:
                send(pkt, iface=self.iface, verbose=0)
            self.stats['sent'] += 1
            return True
        except Exception as e:
            self.stats['errors'] += 1
            print(f"  Error: {e}")
            return False

    def _track_category(self, category: str):
        """Track packets by test category."""
        self.stats['categories'][category] = self.stats['categories'].get(category, 0) + 1

    # =========================================================================
    # Test Category 1: Malformed Ethernet
    # =========================================================================

    def fuzz_ethernet_truncated(self, count: int = 10):
        """Send truncated Ethernet frames."""
        print(f"[1/7] Fuzzing truncated Ethernet frames ({count} packets)...")
        for i in range(count):
            # Frames shorter than 14 bytes (Ethernet header size)
            length = random.randint(1, 13)
            raw_data = bytes(random.getrandbits(8) for _ in range(length))
            pkt = Ether(dst=self.target_mac) / Raw(raw_data)
            self._send(pkt, layer2=True)
            self._track_category('eth_truncated')

    def fuzz_ethernet_broadcast(self, count: int = 10):
        """Send broadcast frames with various payloads."""
        print(f"[1/7] Fuzzing Ethernet broadcast ({count} packets)...")
        for _ in range(count):
            # Random ethertype
            ethertype = random.choice([0x0800, 0x0806, 0x86DD, random.randint(0, 0xFFFF)])
            pkt = Ether(dst="ff:ff:ff:ff:ff:ff", type=ethertype) / Raw(b"\x00" * 64)
            self._send(pkt, layer2=True)
            self._track_category('eth_broadcast')

    # =========================================================================
    # Test Category 2: Invalid IP Headers
    # =========================================================================

    def fuzz_ip_bad_version(self, count: int = 10):
        """Send IP packets with invalid version field."""
        print(f"[2/7] Fuzzing IP bad version ({count} packets)...")
        for _ in range(count):
            # Version should be 4, try others
            version = random.choice([0, 1, 2, 3, 5, 6, 7, 15])
            pkt = IP(dst=self.target_ip, version=version) / ICMP()
            self._send(pkt)
            self._track_category('ip_bad_version')

    def fuzz_ip_bad_ihl(self, count: int = 10):
        """Send IP packets with invalid IHL (header length)."""
        print(f"[2/7] Fuzzing IP bad IHL ({count} packets)...")
        for _ in range(count):
            # IHL must be >= 5 (20 bytes), try smaller values
            ihl = random.choice([0, 1, 2, 3, 4])
            pkt = IP(dst=self.target_ip, ihl=ihl) / ICMP()
            self._send(pkt)
            self._track_category('ip_bad_ihl')

    def fuzz_ip_bad_total_length(self, count: int = 10):
        """Send IP packets with mismatched total length."""
        print(f"[2/7] Fuzzing IP bad total length ({count} packets)...")
        for _ in range(count):
            # Total length smaller than actual packet
            pkt = IP(dst=self.target_ip, len=10) / Raw(b"A" * 100)
            self._send(pkt)
            self._track_category('ip_bad_length')

    def fuzz_ip_bad_checksum(self, count: int = 10):
        """Send IP packets with invalid checksum."""
        print(f"[2/7] Fuzzing IP bad checksum ({count} packets)...")
        for _ in range(count):
            pkt = IP(dst=self.target_ip, chksum=0xDEAD) / ICMP()
            self._send(pkt)
            self._track_category('ip_bad_checksum')

    def fuzz_ip_fragments(self, count: int = 10):
        """Send malformed IP fragments."""
        print(f"[2/7] Fuzzing IP fragments ({count} packets)...")
        for _ in range(count):
            # Overlapping fragments, missing fragments, etc.
            frag_offset = random.randint(0, 8191)
            flags = random.choice([0, 1, 2, 3])  # MF flag variations
            pkt = IP(dst=self.target_ip, flags=flags, frag=frag_offset) / Raw(b"X" * 8)
            self._send(pkt)
            self._track_category('ip_fragments')

    # =========================================================================
    # Test Category 3: TCP Flag Combinations
    # =========================================================================

    def fuzz_tcp_invalid_flags(self, count: int = 20):
        """Send TCP packets with unusual flag combinations."""
        print(f"[3/7] Fuzzing TCP invalid flags ({count} packets)...")
        invalid_combos = [
            "FSRPAUEC",  # All flags set
            "",          # No flags
            "SR",        # SYN+RST (invalid)
            "SF",        # SYN+FIN (invalid)
            "FPU",       # FIN+PSH+URG without ACK
            "RPAU",      # RST with extra flags
        ]
        for _ in range(count):
            flags = random.choice(invalid_combos)
            port = random.randint(1, 65535)
            pkt = IP(dst=self.target_ip) / TCP(dport=port, flags=flags)
            self._send(pkt)
            self._track_category('tcp_invalid_flags')

    def fuzz_tcp_bad_checksum(self, count: int = 10):
        """Send TCP packets with invalid checksum."""
        print(f"[3/7] Fuzzing TCP bad checksum ({count} packets)...")
        for _ in range(count):
            pkt = IP(dst=self.target_ip) / TCP(dport=80, flags="S", chksum=0xBEEF)
            self._send(pkt)
            self._track_category('tcp_bad_checksum')

    def fuzz_tcp_bad_offset(self, count: int = 10):
        """Send TCP packets with invalid data offset."""
        print(f"[3/7] Fuzzing TCP bad offset ({count} packets)...")
        for _ in range(count):
            # Data offset must be >= 5, try smaller
            offset = random.choice([0, 1, 2, 3, 4])
            pkt = IP(dst=self.target_ip) / TCP(dport=80, dataofs=offset, flags="S")
            self._send(pkt)
            self._track_category('tcp_bad_offset')

    def fuzz_tcp_seq_wrap(self, count: int = 10):
        """Send TCP packets with sequence number edge cases."""
        print(f"[3/7] Fuzzing TCP sequence wrap ({count} packets)...")
        edge_seqs = [0, 1, 0xFFFFFFFF, 0x7FFFFFFF, 0x80000000]
        for _ in range(count):
            seq = random.choice(edge_seqs)
            pkt = IP(dst=self.target_ip) / TCP(dport=80, seq=seq, flags="S")
            self._send(pkt)
            self._track_category('tcp_seq_wrap')

    # =========================================================================
    # Test Category 4: UDP Edge Cases
    # =========================================================================

    def fuzz_udp_bad_length(self, count: int = 10):
        """Send UDP packets with mismatched length field."""
        print(f"[4/7] Fuzzing UDP bad length ({count} packets)...")
        for _ in range(count):
            # Length field smaller than header (8 bytes)
            bad_len = random.choice([0, 1, 4, 7])
            pkt = IP(dst=self.target_ip) / UDP(dport=53, len=bad_len) / Raw(b"data")
            self._send(pkt)
            self._track_category('udp_bad_length')

    def fuzz_udp_bad_checksum(self, count: int = 10):
        """Send UDP packets with invalid checksum."""
        print(f"[4/7] Fuzzing UDP bad checksum ({count} packets)...")
        for _ in range(count):
            pkt = IP(dst=self.target_ip) / UDP(dport=53, chksum=0xCAFE) / Raw(b"test")
            self._send(pkt)
            self._track_category('udp_bad_checksum')

    # =========================================================================
    # Test Category 5: ICMP Edge Cases
    # =========================================================================

    def fuzz_icmp_types(self, count: int = 20):
        """Send ICMP packets with various type/code combinations."""
        print(f"[5/7] Fuzzing ICMP types ({count} packets)...")
        for _ in range(count):
            icmp_type = random.randint(0, 255)
            icmp_code = random.randint(0, 255)
            pkt = IP(dst=self.target_ip) / ICMP(type=icmp_type, code=icmp_code)
            self._send(pkt)
            self._track_category('icmp_types')

    def fuzz_icmp_oversized(self, count: int = 5):
        """Send oversized ICMP packets."""
        print(f"[5/7] Fuzzing ICMP oversized ({count} packets)...")
        for _ in range(count):
            # Large payload
            size = random.randint(1000, 65000)
            pkt = IP(dst=self.target_ip) / ICMP() / Raw(b"X" * size)
            self._send(pkt)
            self._track_category('icmp_oversized')

    # =========================================================================
    # Test Category 6: Truncated Packets
    # =========================================================================

    def fuzz_truncated_headers(self, count: int = 20):
        """Send packets with truncated protocol headers."""
        print(f"[6/7] Fuzzing truncated headers ({count} packets)...")
        for _ in range(count):
            # Truncate at various points in headers
            trunc_len = random.randint(1, 39)  # IP(20) + TCP(20) - 1
            full_pkt = bytes(IP(dst=self.target_ip) / TCP(dport=80, flags="S"))
            truncated = full_pkt[:trunc_len]
            pkt = Ether(dst=self.target_mac, type=0x0800) / Raw(truncated)
            self._send(pkt, layer2=True)
            self._track_category('truncated')

    # =========================================================================
    # Test Category 7: ARP Fuzzing
    # =========================================================================

    def fuzz_arp(self, count: int = 10):
        """Send malformed ARP packets."""
        print(f"[7/7] Fuzzing ARP ({count} packets)...")
        for _ in range(count):
            op = random.choice([1, 2, 3, 4, 255])  # Request, Reply, invalid
            pkt = Ether(dst="ff:ff:ff:ff:ff:ff") / ARP(
                op=op,
                hwsrc=RandMAC(),
                psrc=RandIP(),
                hwdst="00:00:00:00:00:00",
                pdst=self.target_ip
            )
            self._send(pkt, layer2=True)
            self._track_category('arp')

    # =========================================================================
    # Main Fuzzing Loop
    # =========================================================================

    def run_all_tests(self, iterations: int = 1):
        """Run all fuzzing tests."""
        print(f"\nPacket Fuzzer - Target: {self.target_ip}")
        print(f"Interface: {self.iface or 'default'}")
        print(f"Iterations: {iterations}")
        print("=" * 50)

        for i in range(iterations):
            if iterations > 1:
                print(f"\n--- Iteration {i + 1}/{iterations} ---")

            # Run each test category
            self.fuzz_ethernet_truncated()
            self.fuzz_ethernet_broadcast()
            self.fuzz_ip_bad_version()
            self.fuzz_ip_bad_ihl()
            self.fuzz_ip_bad_total_length()
            self.fuzz_ip_bad_checksum()
            self.fuzz_ip_fragments()
            self.fuzz_tcp_invalid_flags()
            self.fuzz_tcp_bad_checksum()
            self.fuzz_tcp_bad_offset()
            self.fuzz_tcp_seq_wrap()
            self.fuzz_udp_bad_length()
            self.fuzz_udp_bad_checksum()
            self.fuzz_icmp_types()
            self.fuzz_icmp_oversized()
            self.fuzz_truncated_headers()
            self.fuzz_arp()

            # Small delay between iterations
            if i < iterations - 1:
                time.sleep(0.5)

        self._print_stats()

    def _print_stats(self):
        """Print fuzzing statistics."""
        print("\n" + "=" * 50)
        print("Fuzzing Statistics:")
        print(f"  Total packets sent: {self.stats['sent']}")
        print(f"  Send errors: {self.stats['errors']}")
        print("\n  By category:")
        for cat, count in sorted(self.stats['categories'].items()):
            print(f"    {cat}: {count}")


def main():
    parser = argparse.ArgumentParser(
        description="Network packet fuzzer for Zscapek kernel testing"
    )
    parser.add_argument(
        "--target", "-t",
        default="10.0.2.15",
        help="Target IP address (default: 10.0.2.15)"
    )
    parser.add_argument(
        "--mac", "-m",
        default="52:54:00:12:34:56",
        help="Target MAC address (default: QEMU default)"
    )
    parser.add_argument(
        "--iface", "-i",
        default=None,
        help="Network interface to use"
    )
    parser.add_argument(
        "--iterations", "-n",
        type=int,
        default=1,
        help="Number of test iterations (default: 1)"
    )
    parser.add_argument(
        "--quiet", "-q",
        action="store_true",
        help="Suppress scapy warnings"
    )

    args = parser.parse_args()

    if args.quiet:
        conf.verb = 0

    fuzzer = PacketFuzzer(
        target_ip=args.target,
        target_mac=args.mac,
        iface=args.iface
    )

    try:
        fuzzer.run_all_tests(iterations=args.iterations)
    except KeyboardInterrupt:
        print("\n\nFuzzing interrupted by user")
        fuzzer._print_stats()
        sys.exit(0)
    except PermissionError:
        print("Error: Root privileges required. Run with sudo.")
        sys.exit(1)


if __name__ == "__main__":
    main()

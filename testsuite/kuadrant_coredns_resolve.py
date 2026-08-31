"""Pytest plugin: resolve Kuadrant DNSPolicy hostnames via cluster CoreDNS.
   ppc64le adaptation of the s390x CI workflow getaddrinfo resolver.
   Redirects *.kuadrant.internal lookups to CoreDNS ClusterIP:5353.
"""
from __future__ import annotations
import os, socket, struct, sys

_ZONE = os.environ.get("KUADRANT_COREDNS_ZONE", "kuadrant.internal").strip(".").lower()
_DNS_HOST = os.environ.get("KUADRANT_COREDNS_DNS_HOST", "172.30.153.203")
_DNS_PORT = int(os.environ.get("KUADRANT_COREDNS_DNS_PORT", "5353"))
_ORIG_GETADDRINFO = socket.getaddrinfo


def _belongs_to_zone(host: str) -> bool:
    h = host.strip(".").lower()
    return h == _ZONE or h.endswith("." + _ZONE)


def _encode_name(name: str) -> bytes:
    out = b""
    for label in name.strip(".").split("."):
        raw = label.encode("idna")
        out += bytes([len(raw)]) + raw
    return out + b"\x00"


def _dns_query_a(name: str) -> str | None:
    question = _encode_name(name) + struct.pack("!HH", 1, 1)
    header = struct.pack("!HHHHHH", 0xC0DE, 0x0100, 1, 0, 0, 0)
    payload = header + question
    try:
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp.settimeout(3.0)
        udp.sendto(payload, (_DNS_HOST, _DNS_PORT))
        data, _ = udp.recvfrom(512)
        udp.close()
    except OSError:
        try:
            with socket.create_connection((_DNS_HOST, _DNS_PORT), timeout=3.0) as s:
                s.sendall(struct.pack("!H", len(payload)) + payload)
                s.settimeout(3.0)
                lb = s.recv(2)
                if len(lb) < 2: return None
                (ml,) = struct.unpack("!H", lb)
                data = b""
                while len(data) < ml:
                    c = s.recv(ml - len(data))
                    if not c: break
                    data += c
        except OSError:
            return None
    if len(data) < 12: return None
    ancount = struct.unpack("!H", data[6:8])[0]
    i = 12
    while i < len(data) and data[i] != 0:
        i += 1 + data[i]
    i += 5
    for _ in range(ancount):
        if i >= len(data): break
        if data[i] & 0xC0 == 0xC0:
            i += 2
        else:
            while i < len(data) and data[i] != 0:
                i += 1 + data[i]
            i += 1
        if i + 10 > len(data): break
        rtype, _, _, rdlen = struct.unpack("!HHIH", data[i:i+10])
        i += 10
        rdata = data[i:i+rdlen]
        i += rdlen
        if rtype == 1 and rdlen == 4:
            return socket.inet_ntoa(rdata)
    return None


def _patched_getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
    host_str = host.decode("utf-8", errors="ignore") if isinstance(host, bytes) else (host if isinstance(host, str) else "")
    if host_str and _DNS_HOST and _belongs_to_zone(host_str):
        ip = _dns_query_a(host_str)
        if ip:
            print(f"[coredns_resolve] {host_str} -> {ip} (CoreDNS:{_DNS_PORT})", file=sys.stderr)
            return _ORIG_GETADDRINFO(ip, port, family, type, proto, flags)
        print(f"[coredns_resolve] {host_str} -> NO ANSWER from {_DNS_HOST}:{_DNS_PORT}", file=sys.stderr)
        raise socket.gaierror(socket.EAI_NONAME, "Name or service not known")
    return _ORIG_GETADDRINFO(host, port, family, type, proto, flags)


def _qname_text(qname) -> str:
    return (qname.to_text() if hasattr(qname, "to_text") else str(qname)).rstrip(".")


def _install_dnspython():
    if not _DNS_HOST: return
    try:
        import dns.resolver
    except ImportError:
        return
    if getattr(dns.resolver.resolve, "_kuadrant_coredns", False):
        return
    orig = dns.resolver.resolve
    def _coredns_resolver():
        r = dns.resolver.Resolver(configure=False)
        r.nameservers = [_DNS_HOST]; r.port = _DNS_PORT
        r.nameserver_ports = {_DNS_HOST: _DNS_PORT}
        r.cache = None; r.lifetime = 5.0
        return r
    def _resolve(qname, *args, **kwargs):
        if _belongs_to_zone(_qname_text(qname)):
            print(f"[coredns_resolve] dnspython {_qname_text(qname)} -> CoreDNS:{_DNS_PORT}", file=sys.stderr)
            return _coredns_resolver().resolve(qname, *args, **kwargs)
        return orig(qname, *args, **kwargs)
    _resolve._kuadrant_coredns = True
    dns.resolver.resolve = _resolve
    print(f"[coredns_resolve] dnspython patched for *.{_ZONE} -> {_DNS_HOST}:{_DNS_PORT}", file=sys.stderr)


def install():
    if socket.getaddrinfo is not _patched_getaddrinfo:
        socket.getaddrinfo = _patched_getaddrinfo
        print(f"[coredns_resolve] getaddrinfo patched for *.{_ZONE} -> {_DNS_HOST}:{_DNS_PORT}", file=sys.stderr)
        if _DNS_HOST:
            tip = _dns_query_a(f"probe.{_ZONE}")
            print(f"[coredns_resolve] DNS probe: {'OK ('+tip+')' if tip else 'no answer (zone may be empty)'}", file=sys.stderr)
        _install_dnspython()


def pytest_configure(config):
    install()


install()

import contextlib
import fcntl
import ipaddress
import json
from pathlib import Path
import sys

SERVERS = Path('/etc/macosdocker-ipv4-dns.json')
LOCK = Path('/run/macosdocker/resolver.lock')
RESOLVER = Path('/etc/resolv.conf')
IPV6_SERVERS = Path('/etc/macosdocker-ipv6-dns.json')


def replace(path, text, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.macosdocker.tmp')
    temporary.write_text(text)
    temporary.chmod(mode)
    temporary.replace(path)


@contextlib.contextmanager
def locked():
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    with LOCK.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def current():
    if SERVERS.exists():
        return json.loads(SERVERS.read_text())
    values = []
    for line in RESOLVER.read_text().splitlines() if RESOLVER.exists() else []:
        parts = line.split()
        if len(parts) >= 2 and parts[0] == 'nameserver':
            try:
                value = str(ipaddress.IPv4Address(parts[1]))
            except ValueError:
                continue
            if value not in values:
                values.append(value)
    return values[:3]


def configure(values):
    servers = []
    for value in values:
        try:
            server = str(ipaddress.IPv4Address(value))
        except (ValueError, TypeError):
            continue
        if server not in servers:
            servers.append(server)
    with locked():
        replace(SERVERS, json.dumps(servers[:3]))
        replace(RESOLVER, ''.join('nameserver ' + value + '\n' for value in combined(servers[:3], ipv6_servers())), 0o644)



def combined(ipv4, ipv6):
    result = []
    for index in range(3):
        for family in (ipv4, ipv6):
            if index < len(family) and family[index] not in result:
                result.append(family[index])
    return result[:3]


def ipv6_servers():
    try:
        return [str(ipaddress.IPv6Address(value)) for value in json.loads(IPV6_SERVERS.read_text())][:3]
    except (OSError, ValueError, TypeError):
        return []


def configure_ipv6(values):
    servers = list(dict.fromkeys(str(ipaddress.IPv6Address(value)) for value in values))[:3]
    with locked():
        replace(IPV6_SERVERS, json.dumps(servers))
        replace(RESOLVER, ''.join('nameserver ' + value + '\n' for value in combined(current(), servers)), 0o644)


if __name__ == '__main__':
    configure(sys.argv[1:])

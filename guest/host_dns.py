import ipaddress
import json
from pathlib import Path
import socket
import socketserver
import struct
import subprocess
import threading

ADDRESS = '169.254.127.254'
CLIENTS = {}
LOCK = threading.Lock()
LIMIT = threading.BoundedSemaphore(64)


def question(packet):
    if len(packet) < 12 or struct.unpack('!H', packet[4:6])[0] != 1:
        raise ValueError('Invalid DNS question')
    offset = 12
    labels = []
    while True:
        if offset >= len(packet):
            raise ValueError('Truncated DNS name')
        length = packet[offset]
        offset += 1
        if length == 0:
            break
        if length > 63 or offset + length > len(packet) or offset > 267:
            raise ValueError('Invalid DNS label')
        labels.append(packet[offset:offset + length].decode('ascii').lower())
        offset += length
    if offset + 4 > len(packet):
        raise ValueError('Truncated DNS question')
    kind, category = struct.unpack('!HH', packet[offset:offset + 4])
    return '.'.join(labels), kind, category, offset + 4


def answer(packet, address):
    name, kind, category, end = question(packet)
    if name != 'host.docker.internal':
        return None
    payload = b''
    ip = ipaddress.ip_address(address)
    if category == 1 and ((kind == 1 and ip.version == 4) or (kind == 28 and ip.version == 6)):
        payload = b'\xc0\x0c' + struct.pack('!HHIH', kind, 1, 1, len(ip.packed)) + ip.packed
    flags = 0x8080 | (struct.unpack('!H', packet[2:4])[0] & 0x0100)
    return packet[:2] + struct.pack('!HHHHH', flags, 1, int(bool(payload)), 0, 0) + packet[12:end] + payload


def upstreams():
    result = []
    saved = Path('/var/lib/macosdocker/dns-upstream.json')
    if saved.exists():
        result = [str(ipaddress.ip_address(value)) for value in json.loads(saved.read_text()) if value != ADDRESS]
    if result:
        return result[:3]
    for line in Path('/etc/resolv.conf').read_text().splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == 'nameserver':
            address = str(ipaddress.ip_address(parts[1]))
            if address != ADDRESS:
                result.append(address)
    return result[:3]


def read_exact(stream, count):
    result = b''
    while len(result) < count:
        data = stream.recv(count - len(result))
        if not data:
            raise OSError('Truncated DNS stream')
        result += data
    return result


def resolve(packet, client, tcp=False):
    with LOCK:
        destination = CLIENTS.get(client)
    if destination is None:
        return None
    try:
        direct = answer(packet, destination)
        if direct is not None:
            return direct
        for upstream in upstreams():
            try:
                with socket.socket(socket.AF_INET6 if ':' in upstream else socket.AF_INET, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM) as remote:
                    remote.settimeout(2)
                    remote.connect((upstream, 53))
                    if tcp:
                        remote.sendall(struct.pack('!H', len(packet)) + packet)
                        response = read_exact(remote, struct.unpack('!H', read_exact(remote, 2))[0])
                    else:
                        remote.send(packet)
                        response = remote.recv(65535)
                    if response[:2] == packet[:2]:
                        return response
            except OSError:
                continue
        return packet[:2] + struct.pack('!HHHHH', 0x8182, 0, 0, 0, 0)
    except (ValueError, UnicodeError, OSError):
        return None


class UDP(socketserver.ThreadingUDPServer):
    daemon_threads = True
    def process_request(self, request, client_address):
        if LIMIT.acquire(blocking=False):
            try:
                super().process_request(request, client_address)
            except Exception:
                LIMIT.release()
                raise
    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            LIMIT.release()


class TCP(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    def process_request(self, request, client_address):
        if not LIMIT.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            LIMIT.release()
            raise
    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            LIMIT.release()


class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        packet, stream = self.request
        response = resolve(packet, self.client_address[0])
        if response is not None:
            stream.sendto(response, self.client_address)


class TCPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        try:
            packet = read_exact(self.request, struct.unpack('!H', read_exact(self.request, 2))[0])
            response = resolve(packet, self.client_address[0], tcp=True)
            if response is not None:
                self.request.sendall(struct.pack('!H', len(response)) + response)
        except OSError:
            return


def configure():
    def run(*args):
        subprocess.run(args, check=True, capture_output=True, timeout=10)
    interfaces = json.loads(subprocess.run(['ip', '-j', '-4', 'address'], check=True, capture_output=True, text=True).stdout)
    if any(value.get('local') == ADDRESS and interface['ifname'] != 'mdhostdns' for interface in interfaces for value in interface.get('addr_info', [])):
        raise RuntimeError('Host DNS address is already in use')
    if subprocess.run(['ip', 'link', 'show', 'mdhostdns'], capture_output=True).returncode:
        run('ip', 'link', 'add', 'mdhostdns', 'type', 'dummy')
    run('ip', 'address', 'replace', ADDRESS + '/32', 'dev', 'mdhostdns')
    run('ip', 'link', 'set', 'mdhostdns', 'up')
    path = Path('/etc/docker/daemon.json')
    config = json.loads(path.read_text()) if path.exists() else {}
    if config.get('dns') != [ADDRESS]:
        saved = Path('/var/lib/macosdocker/dns-upstream.json')
        saved.parent.mkdir(parents=True, exist_ok=True)
        saved.write_text(json.dumps(config.get('dns', [])))
        config['dns'] = [ADDRESS]
        temp = path.with_suffix('.host-dns.tmp')
        temp.write_text(json.dumps(config) + '\n')
        temp.replace(path)


def set_clients(clients):
    global CLIENTS
    with LOCK:
        CLIENTS = dict(clients)


def start():
    configure()
    servers = []
    try:
        for server_type, handler in [(UDP, UDPHandler), (TCP, TCPHandler)]:
            servers.append(server_type((ADDRESS, 53), handler))
    except Exception:
        for server in servers:
            server.server_close()
        raise
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()

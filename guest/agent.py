#!/usr/bin/env python3
"""Host-only management and transparent Docker transport over AF_VSOCK."""
from concurrent.futures import ThreadPoolExecutor
import http.server
import ipaddress
import json
import os
import re
import select
import socket
import subprocess
import threading
import time
from volume_smb import export_volume
import engine_update
import host_access
import bridge_mtu
import ipv6_config
import mac_binds
import network_policy
import resolver_config
import docker_socket
from pathlib import Path

REGISTRY = Path('/var/lib/macosdocker/shares.json')
SHARE_HISTORY = Path('/var/lib/macosdocker/share-history.json')
MOUNT_ROOT = Path('/macos')
LEGACY_MOUNT_ROOT = Path('/mnt/macos')
RESERVED_ROOTS = {'bin', 'boot', 'dev', 'etc', 'home', 'lib', 'lib64', 'lost+found', 'macos', 'media', 'mnt', 'opt', 'proc', 'root', 'run', 'sbin', 'srv', 'sys', 'tmp', 'usr', 'var'}
LOCK = threading.Lock()
NETWORK_LOCK = threading.Lock()
STARTUP_LOCK = threading.Lock()


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or 'Command failed')
    return result.stdout.strip()


def network_configure(config):
    mode = config.get('mode')
    if mode not in ('dhcp', 'static'):
        raise ValueError('Invalid network mode')
    text = 'auto lo\niface lo inet loopback\nauto eth0\n'
    dns = []
    if mode == 'dhcp':
        text += 'iface eth0 inet dhcp\n'
    else:
        prefix = config.get('prefix')
        if type(prefix) is not int or not 1 <= prefix <= 30:
            raise ValueError('Prefix must be between 1 and 30')
        interface = ipaddress.IPv4Interface(f"{config.get('address')}/{prefix}")
        address = interface.ip
        if address.is_loopback or address.is_multicast or address.is_unspecified or address.is_link_local or address in (interface.network.network_address, interface.network.broadcast_address):
            raise ValueError('Invalid host IPv4 address')
        text += f'iface eth0 inet static\n    address {address}/{prefix}\n'
        if config.get('gateway'):
            gateway = ipaddress.IPv4Address(config['gateway'])
            if gateway not in interface.network or gateway in (address, interface.network.network_address, interface.network.broadcast_address):
                raise ValueError('Gateway must be another host in the same subnet')
            text += f'    gateway {gateway}\n'
        dns = config.get('dns', [])
        if not isinstance(dns, list) or len(dns) > 3:
            raise ValueError('Provide at most three IPv4 DNS servers')
        dns = [str(ipaddress.IPv4Address(server)) for server in dns]
    with NETWORK_LOCK:
        ipv6_config.configure(config.get('ipv6', {}))
        path = Path('/etc/network/interfaces')
        old = path.read_text()
        old_ipv4_dns = resolver_config.current()
        # DHCP is the unchanged default; avoid interrupting a working lease on boot.
        if old == text and mode == 'dhcp':
            return {'mode': mode}
        resolver = Path('/etc/resolv.conf')
        old_dns = resolver.read_text() if resolver.exists() else ''
        try:
            subprocess.run(['ifdown', 'eth0'], capture_output=True, timeout=30)
            path.write_text(text)
            run('ip', '-4', 'address', 'flush', 'dev', 'eth0')
            run('ip', '-4', 'route', 'flush', 'dev', 'eth0')
            run('ifup', 'eth0')
            if mode == 'static':
                resolver_config.configure(dns or old_ipv4_dns)
        except Exception:
            path.write_text(old)
            resolver_config.configure(old_ipv4_dns)
            subprocess.run(['ifdown', 'eth0'], capture_output=True, timeout=30)
            subprocess.run(['ifup', 'eth0'], capture_output=True, timeout=30)
            resolver.write_text(old_dns)
            raise
    return {'mode': mode}


def guest_mounts():
    # Unlike ismount(), mountinfo also identifies bind mounts on the same filesystem.
    def unescape(value):
        return re.sub(r'\\([0-7]{3})', lambda match: chr(int(match.group(1), 8)), value)
    return {unescape(line.split()[4]) for line in Path('/proc/self/mountinfo').read_text().splitlines()}


def remove_empty_mount_directory(path, mounts):
    path = Path(path)
    # Never traverse symlinks or remove a directory inside an active shared filesystem.
    if path.is_symlink() or str(path.resolve()) != str(path):
        return False
    if any(m != '/' and (str(path) == m or str(path).startswith(m.rstrip('/') + '/')) for m in mounts):
        return False
    try:
        path.rmdir()  # No recursive deletion: files and nonempty directories are always retained.
        return True
    except FileNotFoundError:
        return True
    except OSError:
        return False


def share_mount_path(share):
    value = share.get('mount')
    if value is None:
        return LEGACY_MOUNT_ROOT / share['key']
    if not isinstance(value, str) or os.path.normpath(value) != value or not (MOUNT_ROOT in Path(value).parents or (value == share['path'] and len(Path(value).parts) > 1 and Path(value).parts[1] not in RESERVED_ROOTS)):
        raise ValueError('Invalid share mount path')
    return Path(value)


def assign_mount_paths(shares, previous):
    existing = {entry['key']: entry for entry in previous}
    mounts = guest_mounts()
    for share in shares:
        target = Path(share['path'])
        old = existing.get(share['key'], {})
        fallback = MOUNT_ROOT / share['path'].lstrip('/')
        reserved = target.parts[1] in RESERVED_ROOTS
        managed = old.get('path') == share['path'] and old.get('layout') == 2
        keep_fallback = managed and old.get('mount') == str(fallback)
        occupied = target.exists() or target.is_symlink()
        known_alias = old.get('path') == share['path'] and old.get('layout') != 2 and share['path'].startswith(('/Users/', '/Volumes/'))
        safe_existing = (known_alias or (managed and old.get('mount') == str(target))) and (str(target) in mounts or (target.is_dir() and not any(target.iterdir())))
        try:
            symbolic = target.is_symlink() or target.resolve() != target
        except (OSError, RuntimeError):
            symbolic = True
        conflict = reserved or keep_fallback or symbolic or (occupied and not safe_existing)
        share['mount'] = str(fallback if conflict else target)
        share['layout'] = 2



def cleanup_retired_shares(previous, current, mounts):
    paths = {share['path'] for share in current}
    sources = {str(share_mount_path(share)) for share in current}
    pending = []
    for share in previous:
        path, key = share.get('path', ''), share.get('key', '')
        if not isinstance(path, str) or not path.startswith('/') or path == '/' or os.path.normpath(path) != path or '\x00' in path:
            continue
        if not isinstance(key, str) or not re.fullmatch(r'share[a-f0-9]{32}', key):
            continue
        try:
            source = share_mount_path(share)
        except ValueError:
            continue
        legacy_alias = share.get('layout') != 2 and path.startswith(('/Users/', '/Volumes/'))
        path_done = path in paths or not legacy_alias or remove_empty_mount_directory(path, mounts)
        source_done = str(source) in sources or remove_empty_mount_directory(source, mounts)
        if source_done and str(source) not in sources and MOUNT_ROOT in source.parents:
            parent = source.parent
            while parent != MOUNT_ROOT and remove_empty_mount_directory(parent, mounts):
                parent = parent.parent
        if not path_done or not source_done:
            pending.append(share)
    remove_empty_mount_directory(LEGACY_MOUNT_ROOT, mounts)
    return pending


def shares_sync(shares, start_docker=True):
    if not isinstance(shares, list):
        raise ValueError('Invalid shares list')
    normalized = []
    for share in shares:
        key, path, tag = share.get('key', ''), share.get('path', ''), share.get('tag', '')
        directory = share.get('directory')
        if not isinstance(tag, str) or not (tag == 'macos' or re.fullmatch(r'macos(?:[0-9]|1[0-5])', tag)):
            raise ValueError('Invalid VirtioFS device tag')
        if not isinstance(key, str) or not re.fullmatch(r'share[a-f0-9]{32}', key):
            raise ValueError('Invalid share key')
        if (tag == 'macos' and directory != key) or (tag != 'macos' and directory is not None):
            raise ValueError('Invalid shared directory name')
        if not isinstance(path, str) or not path.startswith('/') or path == '/' or '\x00' in path or os.path.normpath(path) != path:
            raise ValueError('Share path must be a normalized absolute Mac directory below root')
        if any(path == s['path'] or path.startswith(s['path'] + '/') or s['path'].startswith(path + '/') or key == s['key'] or (tag != 'macos' and tag == s['tag']) for s in normalized):
            raise ValueError('Overlapping or duplicate shares')
        entry = {'key': key, 'tag': tag, 'path': path, 'readonly': bool(share.get('readonly', False))}
        if directory is not None:
            entry['directory'] = directory
        normalized.append(entry)
    with LOCK:
        if MOUNT_ROOT.is_symlink() or MOUNT_ROOT.resolve() != MOUNT_ROOT:
            raise ValueError('Symlink in share mount root')
        MOUNT_ROOT.mkdir(parents=True, exist_ok=True)
        old = json.loads(REGISTRY.read_text()) if REGISTRY.exists() else []
        assign_mount_paths(normalized, old)
        mounts = guest_mounts()
        # Refuse live removal or permission changes; existing containers retain mounts.
        for previous in old:
            if previous not in normalized and str(share_mount_path(previous)) in mounts:
                raise ValueError('Stop the VM before removing or changing an existing share')
        history = json.loads(SHARE_HISTORY.read_text()) if SHARE_HISTORY.exists() else []
        for share in old:
            if share not in history:
                history.append(share)
        pending = cleanup_retired_shares(history, normalized, mounts)
        for share in normalized:
            source = share_mount_path(share)
            if source.is_symlink() or source.resolve() != source:
                raise ValueError('Symlink in share mount path')
            source.mkdir(parents=True, exist_ok=True)
            if not os.path.ismount(source):
                if any(source.iterdir()):
                    raise ValueError('Refusing to hide existing guest files: ' + str(source))
                if share['tag'] == 'macos':
                    shared_root = Path('/run/macosdocker-shares')
                    shared_root.mkdir(parents=True, exist_ok=True)
                    if not os.path.ismount(shared_root):
                        run('mount', '-t', 'virtiofs', 'macos', str(shared_root))
                    directory = shared_root / share['directory']
                    if not directory.is_dir():
                        raise ValueError('Shared Mac directory is unavailable: ' + share['path'])
                    run('mount', '--bind', str(directory), str(source))
                    if share['readonly']:
                        run('mount', '-o', 'remount,bind,ro', str(source))
                else:
                    run('mount', '-t', 'virtiofs', share['tag'], str(source))
            if not source.is_dir():
                raise ValueError('VirtioFS share is not available: ' + share['path'])
        REGISTRY.parent.mkdir(parents=True, exist_ok=True)
        temporary = REGISTRY.with_suffix('.tmp')
        temporary.write_text(json.dumps(normalized))
        temporary.replace(REGISTRY)
        history = pending + [share for share in normalized if share not in pending]
        temporary = SHARE_HISTORY.with_suffix('.tmp')
        temporary.write_text(json.dumps(history))
        temporary.replace(SHARE_HISTORY)
        if start_docker and not Path(docker_socket.BACKEND).exists():
            run('macosdocker-service', 'docker', 'start')
    return {'mounted': normalized}


def prepare_startup_network(config):
    if config.get('mode') == 'static':
        return network_configure(config)
    worker = None
    next_attempt = 0
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            status = subprocess.run(['macosdocker-service', 'networking', 'status'], capture_output=True, timeout=min(5, remaining))
        except subprocess.TimeoutExpired:
            continue
        if status.returncode == 0:
            return network_configure(config)
        if status.returncode == 1 and time.monotonic() >= next_attempt and (worker is None or worker.poll() is not None):
            with open('/var/log/network.log', 'ab') as log:
                worker = subprocess.Popen(['macosdocker-service', 'networking', 'start'], stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
            next_attempt = time.monotonic() + 1
        remaining = deadline - time.monotonic()
        if remaining > 0:
            time.sleep(min(0.1, remaining))
    try:
        details = Path('/var/log/network.log').read_text(errors='replace')[-4096:].strip()
    except OSError:
        details = ''
    message = 'Guest networking did not become ready within 60 seconds. Check the network adapter and DHCP server.'
    raise RuntimeError(message + ('\n' + details if details else ''))


def prepare_startup(body):
    with STARTUP_LOCK:
        network_policy.configure(body.get('bridge', False))
        began = time.monotonic()
        with ThreadPoolExecutor(max_workers=2) as workers:
            network = workers.submit(prepare_startup_network, body.get('network', {}))
            shares = workers.submit(shares_sync, body.get('shares'), False)
            mounted = shares.result()
            network.result()
        prepared = time.monotonic()
        with LOCK:
            if not Path(docker_socket.BACKEND).exists():
                run('macosdocker-service', 'docker', 'start')
        network_policy.restore()
        bridge_mtu.reconcile(network_policy.request)
        return {'mounted': mounted['mounted'], 'prepareSeconds': prepared - began, 'dockerSeconds': time.monotonic() - prepared}


DIRECT_LOCK = threading.Lock()
DIRECT_CONFIG = None


def direct_routes(body):
    """Allow only the requesting Mac to reach current Docker bridge endpoints."""
    import http.client
    source = str(ipaddress.IPv4Address(body.get('source', '')))
    addresses = json.loads(run('ip', '-j', 'address', 'show', 'dev', 'eth0'))
    subnets = [ipaddress.IPv4Interface(str(a['local']) + '/' + str(a['prefixlen']))
               for item in addresses for a in item.get('addr_info', []) if a.get('family') == 'inet']
    if not any(ipaddress.IPv4Address(source) in a.network and source != str(a.ip) for a in subnets):
        raise ValueError('Direct route source must be the Mac on the VM LAN')
    class DockerConnection(http.client.HTTPConnection):
        def connect(self):
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.settimeout(5)
            self.sock.connect(docker_socket.BACKEND)
    def docker(path):
        connection = DockerConnection('localhost', timeout=5)
        try:
            connection.request('GET', path)
            response = connection.getresponse()
            if response.status != 200: raise RuntimeError('Docker inventory unavailable')
            return json.loads(response.read())
        finally: connection.close()
    networks = {n['Id'] for n in docker('/networks') if n.get('Driver') == 'bridge'}
    ips = sorted({str(ipaddress.IPv4Address(n['IPAddress']))
                  for c in docker('/containers/json')
                  for n in c.get('NetworkSettings', {}).get('Networks', {}).values()
                  if n.get('NetworkID') in networks and n.get('IPAddress')})
    if len(ips) > 256: raise ValueError('Too many direct container routes')
    global DIRECT_CONFIG
    with DIRECT_LOCK:
        config = (source, ips)
        present = subprocess.run(['iptables', '-w', '2', '-C', 'DOCKER-USER', '-j', 'MACOSDOCKER-DIRECT'], capture_output=True).returncode == 0
        raw_present = subprocess.run(['iptables', '-w', '2', '-t', 'raw', '-C', 'PREROUTING', '-j', 'MACOSDOCKER-DIRECT'], capture_output=True).returncode == 0
        if DIRECT_CONFIG != config or not present or not raw_present:
            # Only our chain is replaced; Docker's isolation rules remain intact.
            rules = ['*filter', ':MACOSDOCKER-DIRECT - [0:0]', '-F MACOSDOCKER-DIRECT']
            for ip in ips:
                rules += ['-A MACOSDOCKER-DIRECT -s ' + source + ' -d ' + ip + ' -j ACCEPT',
                          '-A MACOSDOCKER-DIRECT -s ' + ip + ' -d ' + source + ' -j ACCEPT']
            rules += ['-A MACOSDOCKER-DIRECT -j RETURN', 'COMMIT', '*raw', ':MACOSDOCKER-DIRECT - [0:0]', '-F MACOSDOCKER-DIRECT']
            # Docker 28+ drops direct ingress in raw PREROUTING before DOCKER-USER.
            # Bypass that early drop exclusively for the Mac and current endpoints.
            for ip in ips:
                rules += ['-A MACOSDOCKER-DIRECT -s ' + source + ' -d ' + ip + ' -j ACCEPT']
            rules += ['-A MACOSDOCKER-DIRECT -j RETURN', 'COMMIT', '']
            subprocess.run(['iptables-restore', '--noflush', '--wait', '2'], input='\n'.join(rules), text=True, capture_output=True, check=True, timeout=5)
            if not raw_present: run('iptables', '-w', '2', '-t', 'raw', '-I', 'PREROUTING', '1', '-j', 'MACOSDOCKER-DIRECT')
            if not present: run('iptables', '-w', '2', '-I', 'DOCKER-USER', '1', '-j', 'MACOSDOCKER-DIRECT')
            DIRECT_CONFIG = config
    return {'addresses': ips}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, format, *args):
        print(format % args, flush=True)

    def respond(self, status, value):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

    def do_GET(self):
        try:
            if self.path == '/engine-update':
                return self.respond(200, engine_update.status())
            if self.path != '/health':
                return self.respond(404, {'message': 'Not found'})
            self.respond(200, {'ready': True, 'ipv6PolicyVersion': 1, 'parallelStartupVersion': 1, 'automaticMacBindsVersion': 1, 'hostAccessVersion': 2, 'hostAccess': host_access.STATUS, 'bridgeMTUVersion': 1, 'bridgeMTU': bridge_mtu.STATUS, 'directRoutingVersion': 1, 'shareCleanupVersion': 1, 'engineUpdateVersion': 2, 'networkConfigurationVersion': 1, 'volumeSMBVersion': 1, 'volumeSMBLANVersion': 2, 'macvlanPolicyVersion': 1, 'dockerSocket': Path(docker_socket.BACKEND).exists(), 'addresses': json.loads(run('ip', '-j', 'address')), 'shares': json.loads(REGISTRY.read_text()) if REGISTRY.exists() else []})
        except Exception as error:
            self.respond(503, {'message': str(error)})

    def do_POST(self):
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 <= length <= (16 * 1024 * 1024 if self.path in ('/startup', '/shares') else 65536):
                return self.respond(413, {'message': 'Request too large'})
            body = json.loads(self.rfile.read(length) or b'{}')
            if self.path == '/startup':
                self.respond(200, prepare_startup(body))
            elif self.path == '/network':
                self.respond(200, network_configure(body))
            elif self.path == '/direct-routes':
                self.respond(200, direct_routes(body))
            elif self.path == '/shares':
                self.respond(200, shares_sync(body.get('shares')))
            elif self.path == '/volume-smb':
                self.respond(200, export_volume(body))
            elif self.path == '/engine-update/check':
                self.respond(200, engine_update.check())
            elif self.path == '/engine-update':
                self.respond(202, engine_update.start())
            elif self.path == '/shutdown':
                self.respond(200, {'stopping': True})
                subprocess.Popen(['/sbin/poweroff'])
            else:
                self.respond(404, {'message': 'Not found'})
        except Exception as error:
            self.respond(400, {'message': str(error)})


def docker_proxy(client, smb=False):
    target = socket.socket(socket.AF_INET if smb else socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        target.connect(('127.0.0.1', 445) if smb else '/var/run/docker.sock')
        # Half-close semantics are required for Docker attach / exec / streaming.
        def copy(source, destination):
            try:
                while data := source.recv(65536):
                    destination.sendall(data)
            except OSError:
                pass
            finally:
                try:
                    destination.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
        worker = threading.Thread(target=copy, args=(client, target), daemon=True)
        worker.start()
        copy(target, client)
        worker.join()
    finally:
        target.close()
        client.close()


def serve(port, callback):
    listener = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    listener.bind((socket.VMADDR_CID_ANY, port))
    listener.listen(64)
    while True:
        client, address = listener.accept()
        if address[0] != socket.VMADDR_CID_HOST:
            client.close()
            continue
        threading.Thread(target=callback, args=(client,), daemon=True).start()


def control(client):
    try:
        client.settimeout(45)
        Handler(client, ('host', 0), None)
    finally:
        client.close()


if __name__ == '__main__':
    mac_binds.start()
    docker_socket.start()
    host_access.start()
    # Mounts are restored by the Mac before Docker auto-starts saved containers.
    threading.Thread(target=serve, args=(2375, docker_proxy), daemon=True).start()
    threading.Thread(target=serve, args=(2377, lambda client: docker_proxy(client, smb=True)), daemon=True).start()
    serve(2376, control)

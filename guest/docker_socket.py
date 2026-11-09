import json
import os
from pathlib import Path
import re
import socket
import socketserver
import threading
from urllib.parse import unquote, urlsplit

BACKEND = '/run/macosdocker-engine.sock'
FRONTEND = '/run/docker.sock'
REGISTRY = Path('/var/lib/macosdocker/shares.json')
LIMIT = 1024 * 1024


def shares():
    try:
        return json.loads(REGISTRY.read_text())
    except FileNotFoundError:
        return []


def within(path, root):
    return path == root or path.startswith(root + '/')


def resolve_source(source, entries=None):
    if not isinstance(source, str) or source in ('/var/run/docker.sock', '/run/docker.sock'):
        return source
    entries = shares() if entries is None else entries
    for entry in sorted(entries, key=lambda item: len(item.get('mount', item['path'])), reverse=True):
        mounted = entry.get('mount', entry['path'])
        if within(source, mounted):
            if os.path.normpath(source) != source:
                raise ValueError('Use a normalized Mac bind path')
            return source
    for entry in sorted(entries, key=lambda item: len(item['path']), reverse=True):
        original = entry['path']
        mounted = entry.get('mount', original)
        for prefix in ('/macos' + original, original):
            if within(source, prefix):
                if os.path.normpath(source) != source:
                    raise ValueError('Use a normalized Mac bind path')
                return mounted + source[len(prefix):]
    return source


def mac_source(source):
    entries = shares()
    for entry in sorted(entries, key=lambda item: len(item.get('mount', item['path'])), reverse=True):
        mounted = entry.get('mount', entry['path'])
        if within(source, mounted):
            return entry['path'] + source[len(mounted):]
    for entry in sorted(entries, key=lambda item: len(item['path']), reverse=True):
        for prefix in (entry.get('mount', entry['path']), '/macos' + entry['path'], entry['path']):
            if within(source, prefix):
                return entry['path'] + source[len(prefix):]
    return source


def rewrite(config, volume=False):
    if volume:
        options = config.get('DriverOpts') or {}
        if config.get('Driver', 'local') in ('', 'local') and {'bind', 'rbind'}.intersection(options.get('o', '').split(',')):
            options['device'] = resolve_source(options.get('device'))
        return config
    host = config.get('HostConfig') or {}
    if host.get('Binds'):
        host['Binds'] = [':'.join([resolve_source(parts[0]), *parts[1:]]) for value in host['Binds'] for parts in [value.split(':')]]
    for mount in host.get('Mounts') or []:
        if mount.get('Type') == 'bind':
            mount['Source'] = resolve_source(mount.get('Source'))
        elif mount.get('Type') == 'volume':
            driver = (mount.get('VolumeOptions') or {}).get('DriverConfig') or {}
            options = driver.get('Options') or {}
            if driver.get('Name', 'local') in ('', 'local') and {'bind', 'rbind'}.intersection(options.get('o', '').split(',')):
                options['device'] = resolve_source(options.get('device'))
    return config


def copy(source, target):
    try:
        while data := source.recv(65536):
            target.sendall(data)
    except OSError:
        pass
    finally:
        try:
            target.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def read_exact(stream, count):
    result = bytearray()
    while len(result) < count:
        data = stream.read(count - len(result))
        if not data:
            raise ValueError('Incomplete Docker request')
        result.extend(data)
    return bytes(result)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        backend = None
        try:
            self.request.settimeout(120)
            stream = self.request.makefile('rb', buffering=0)
            request = stream.readline(LIMIT + 1)
            if len(request) > LIMIT or not request.endswith(b'\r\n'):
                raise ValueError('Invalid Docker request line')
            fields = request.decode('ascii').strip().split(' ')
            if len(fields) != 3:
                raise ValueError('Invalid Docker request line')
            headers = []
            total = len(request)
            while True:
                line = stream.readline(LIMIT + 1)
                total += len(line)
                if not line or len(line) > LIMIT or total > LIMIT:
                    raise ValueError('Invalid Docker headers')
                if line == b'\r\n':
                    break
                key, value = line.decode('latin1').split(':', 1)
                headers.append((key.strip(), value.strip()))
            values = {key.lower(): value for key, value in headers}
            path = re.sub(r'^/v[0-9]+\.[0-9]+/', '/', unquote(urlsplit(fields[1]).path))
            body = None
            if fields[0] == 'POST' and path in ('/containers/create', '/volumes/create', '/networks/create'):
                if values.get('expect', '').lower() == '100-continue':
                    self.request.sendall(b'HTTP/1.1 100 Continue\r\n\r\n')
                if 'transfer-encoding' in values:
                    if values['transfer-encoding'].lower() != 'chunked':
                        raise ValueError('Unsupported Docker request encoding')
                    payload = bytearray()
                    while True:
                        size = int(stream.readline(128).split(b';', 1)[0].strip(), 16)
                        if size < 0 or len(payload) + size > LIMIT:
                            raise ValueError('Docker request too large')
                        if size == 0:
                            if stream.readline(LIMIT + 1) != b'\r\n':
                                raise ValueError('Docker trailers are not supported')
                            break
                        payload.extend(read_exact(stream, size))
                        if read_exact(stream, 2) != b'\r\n':
                            raise ValueError('Invalid Docker chunk')
                else:
                    size = int(values.get('content-length', '0'))
                    if not 0 < size <= LIMIT:
                        raise ValueError('Invalid Docker request length')
                    payload = read_exact(stream, size)
                config = json.loads(payload)
                import ipv6_policy
                if path == '/containers/create':
                    config = ipv6_policy.container_config(config)
                elif path == '/networks/create':
                    config = ipv6_policy.network_config(config)
                if path == '/containers/create':
                    import mac_binds
                    mac_binds.prepare(mac_binds.container_binds(config) + mac_binds.inherited_binds(config, mac_binds.inspect_container))
                elif path == '/volumes/create':
                    import mac_binds
                    mac_binds.prepare(mac_binds.volume_binds(config))
                body = json.dumps(rewrite(config, path == '/volumes/create')).encode()
                headers = [(key, value) for key, value in headers if key.lower() not in ('content-length', 'transfer-encoding', 'expect')]
                headers.append(('Content-Length', str(len(body))))
            upgrade = 'upgrade' in values.get('connection', '').lower() and 'upgrade' in values
            if not upgrade:
                headers = [(key, value) for key, value in headers if key.lower() != 'connection']
                headers.append(('Connection', 'close'))
            backend = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            backend.connect(BACKEND)
            backend.sendall(request + ''.join(key + ': ' + value + '\r\n' for key, value in headers).encode('latin1') + b'\r\n')
            if body is not None:
                backend.sendall(body)
            self.request.settimeout(None)
            worker = threading.Thread(target=copy, args=(self.request, backend), daemon=True)
            worker.start()
            copy(backend, self.request)
            try:
                self.request.shutdown(socket.SHUT_RD)
            except OSError:
                pass
            worker.join(timeout=5)
        except Exception as error:
            if backend is None:
                data = json.dumps({'message': str(error)}).encode()
                try:
                    self.request.sendall(b'HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: ' + str(len(data)).encode() + b'\r\n\r\n' + data)
                except OSError:
                    pass
        finally:
            if backend is not None:
                backend.close()


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    request_queue_size = 128


def start():
    Path(FRONTEND).unlink(missing_ok=True)
    server = Server(FRONTEND, Handler)
    os.chmod(FRONTEND, 0o600)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server

import base64
import http.client
import http.server
import json
import os
import re
import socket
import socketserver
import struct
import threading
from pathlib import Path
import docker_socket
import network_policy
import ipv6_policy
from urllib.parse import quote, unquote, urlsplit

SOCKET = '/run/macosdocker-mounts.sock'
PLUGIN = 'macosdocker-mounts'
MAXIMUM = 1024 * 1024


def bind(source, readonly=False):
    if not isinstance(source, str) or not source or '\x00' in source:
        raise ValueError('Invalid Mac bind source')
    if source in ('/var/run/docker.sock', '/run/docker.sock'):
        return []
    if not source.startswith('/'):
        return []
    source = docker_socket.mac_source(source)
    path = os.path.normpath(source)
    registered = any(docker_socket.within(path, entry['path']) for entry in docker_socket.shares())
    if registered:
        if source != path:
            raise ValueError('Use a normalized absolute Mac path: ' + source)
        return [{'source': source, 'readOnly': bool(readonly)}]
    if source.startswith('/macos/'):
        raise ValueError('Mac path is not shared: ' + source)
    if not source.startswith(('/Users/', '/Volumes/')) and not path.startswith(('/Users/', '/Volumes/')):
        return []
    if not path.startswith(('/Users/', '/Volumes/')):
        raise ValueError('Mac bind path leaves /Users or /Volumes: ' + source)
    if path != source:
        raise ValueError('Use a normalized absolute Mac path: ' + source)
    return [{'source': source, 'readOnly': bool(readonly)}]


def container_binds(config):
    host = config.get('HostConfig') or {}
    result = []
    for value in host.get('Binds') or []:
        parts = value.split(':')
        if len(parts) not in (2, 3):
            raise ValueError('Invalid bind mount')
        result += bind(parts[0], len(parts) == 3 and 'ro' in parts[2].split(','))
    for mount in host.get('Mounts') or []:
        if mount.get('Type') == 'bind':
            source = mount.get('Source')
            if not isinstance(source, str) or not source.startswith('/'):
                raise ValueError('Bind mounts require an absolute source path')
            result += bind(source, mount.get('ReadOnly', False))
        elif mount.get('Type') == 'volume':
            options = (mount.get('VolumeOptions') or {}).get('DriverConfig') or {}
            result += volume_binds({'Driver': options.get('Name', 'local'), 'DriverOpts': options.get('Options')})
    for mount in config.get('Mounts') or []:
        if mount.get('Type') == 'bind':
            result += bind(mount.get('Source'), not mount.get('RW', True))
    return result


def inherited_binds(config, inspect):
    result = []
    for value in (config.get('HostConfig') or {}).get('VolumesFrom') or []:
        parts = value.rsplit(':', 1)
        source = inspect(parts[0])
        mounts = container_binds(source)
        if len(parts) == 2 and parts[1] == 'ro':
            mounts = [dict(mount, readOnly=True) for mount in mounts]
        result += mounts
    return result


def volume_binds(config):
    options = config.get('DriverOpts') or {}
    if config.get('Driver', 'local') in ('', 'local') and {'bind', 'rbind'}.intersection(options.get('o', '').split(',')):
        source = options.get('device')
        if not isinstance(source, str) or not source.startswith('/'):
            raise ValueError('Bind volumes require an absolute source path')
        return bind(source, 'ro' in options.get('o', '').split(','))
    return []


def receive(connection, count):
    data = bytearray()
    while len(data) < count:
        part = connection.recv(count - len(data))
        if not part:
            raise RuntimeError('Mac mount preparation connection closed')
        data.extend(part)
    return bytes(data)


def prepare(binds):
    if not binds:
        return
    if len(binds) > 256:
        raise ValueError('Too many Mac bind mounts')
    data = json.dumps({'binds': binds}).encode()
    if len(data) > MAXIMUM:
        raise ValueError('Mac mount request too large')
    with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as connection:
        connection.settimeout(120)
        connection.connect((socket.VMADDR_CID_HOST, 2378))
        connection.sendall(struct.pack('!I', len(data)) + data)
        size = struct.unpack('!I', receive(connection, 4))[0]
        if not 0 < size <= MAXIMUM:
            raise RuntimeError('Invalid Mac mount reply')
        reply = json.loads(receive(connection, size))
        if reply.get('success') is not True:
            raise RuntimeError(reply.get('error') or 'Mac mounts could not be prepared')


def inspect_container(name):
    connection = http.client.HTTPConnection('localhost', timeout=10)
    connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.sock.settimeout(10)
    connection.sock.connect(docker_socket.BACKEND)
    try:
        connection.request('GET', '/containers/' + quote(name, safe='') + '/json')
        response = connection.getresponse()
        data = response.read(MAXIMUM + 1)
        if len(data) > MAXIMUM:
            raise RuntimeError('Container mount inspection response too large')
        if response.status != 200:
            try:
                message = str(json.loads(data).get('message', 'Docker API request failed'))[:512]
            except (ValueError, AttributeError):
                message = 'Docker API request failed'
            raise RuntimeError('Container mounts could not be inspected (HTTP ' + str(response.status) + '): ' + message)
        return json.loads(data)
    finally:
        connection.close()


def authorize(request, prepare_mounts=prepare, inspect=inspect_container):
    network_policy.authorize(request, inspect)
    ipv6_policy.authorize(request)
    if request.get('RequestMethod') != 'POST':
        return
    path = re.sub(r'^/v[0-9]+\.[0-9]+/', '/', unquote(urlsplit(request.get('RequestUri', request.get('RequestURI', ''))).path))
    if path in ('/containers/create', '/volumes/create'):
        encoded = request.get('RequestBody')
        if not isinstance(encoded, str) or not encoded:
            raise ValueError('Mac bind validation requires an application/json request body')
        config = json.loads(base64.b64decode(encoded, validate=True))
        binds = container_binds(config) + inherited_binds(config, inspect) if path == '/containers/create' else volume_binds(config)
        prepare_mounts(binds)
    else:
        match = re.fullmatch(r'/containers/([^/]+)/(start|restart)', path)
        if match:
            prepare_mounts(container_binds(inspect(match[1])))


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 <= size <= 2 * MAXIMUM:
                raise ValueError('Mount validation request too large')
            body = self.rfile.read(size)
            if len(body) != size:
                raise ValueError('Incomplete mount validation request')
            request = json.loads(body) if body else {}
            if self.path == '/Plugin.Activate':
                result = {'Implements': ['authz']}
            elif self.path == '/AuthZPlugin.AuthZReq':
                authorize(request)
                result = {'Allow': True}
            elif self.path == '/AuthZPlugin.AuthZRes':
                result = {'Allow': True}
            else:
                raise ValueError('Unknown mount validation endpoint')
        except Exception as error:
            result = {'Allow': False, 'Msg': str(error)}
        data = json.dumps(result).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(125)
        return connection, address


def start():
    Path(SOCKET).unlink(missing_ok=True)
    server = Server(SOCKET, Handler)
    os.chmod(SOCKET, 0o600)
    specs = Path('/etc/docker/plugins')
    specs.mkdir(parents=True, exist_ok=True)
    (specs / (PLUGIN + '.spec')).write_text('unix://' + SOCKET + '\n')
    path = Path('/etc/docker/daemon.json')
    config = json.loads(path.read_text()) if path.exists() else {}
    config['hosts'] = ['unix://' + docker_socket.BACKEND]
    plugins = config.setdefault('authorization-plugins', [])
    if PLUGIN not in plugins:
        plugins.append(PLUGIN)
    temporary = path.with_suffix('.mac-binds.tmp')
    temporary.write_text(json.dumps(config) + '\n')
    temporary.replace(path)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server

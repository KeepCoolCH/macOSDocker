import base64
import http.client
import json
from pathlib import Path
import re
import socket
import struct
import subprocess
from urllib.parse import quote, unquote, urlsplit
import docker_socket

STATE = Path('/run/macosdocker/network-policy.json')
MODULE_CONFIG = Path('/etc/modprobe.d/macosdocker-macvlan.conf')
CONTAINERS = Path('/var/lib/docker/containers')
SNAPSHOT = Path('/var/lib/docker/.macosdocker-macvlan-networks.json')
ERROR = 'Macvlan requires Bridge mode. Stop the VM and select a bridge adapter in Runtime.'


def require_bridge():
    try:
        with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as connection:
            connection.settimeout(1)
            connection.connect((socket.VMADDR_CID_HOST, 2378))
            data = json.dumps({'binds': [], 'requireBridge': True}).encode()
            connection.sendall(struct.pack('!I', len(data)) + data)
            connection.recv(4)
    except (OSError, AttributeError):
        pass
    raise ValueError(ERROR)


def enabled():
    try:
        return json.loads(STATE.read_text()).get('bridge') is True
    except (OSError, ValueError, AttributeError):
        return False


def configure(bridge):
    if not isinstance(bridge, bool):
        raise ValueError('Invalid bridge policy')
    if Path(docker_socket.BACKEND).exists() and bridge != enabled():
        raise ValueError('Restart the VM to change the network policy')
    if not bridge:
        snapshot()
    MODULE_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    if bridge:
        MODULE_CONFIG.unlink(missing_ok=True)
        subprocess.run(['modprobe', 'macvlan'], check=True, capture_output=True, timeout=10)
    else:
        MODULE_CONFIG.write_text('install macvlan /bin/false\n')
        if Path('/sys/module/macvlan').exists():
            subprocess.run(['modprobe', '-r', 'macvlan'], check=True, capture_output=True, timeout=10)
    STATE.parent.mkdir(parents=True, exist_ok=True)
    temporary = STATE.with_suffix('.tmp')
    temporary.write_text(json.dumps({'bridge': bridge}))
    temporary.replace(STATE)


def snapshot():
    saved = json.loads(SNAPSHOT.read_text()) if SNAPSHOT.exists() else {}
    for path in CONTAINERS.glob('*/config.v2.json'):
        config = json.loads(path.read_text())
        networks = (config.get('NetworkSettings') or {}).get('Networks') or {}
        if networks:
            saved.setdefault(path.parent.name, {}).update(networks)
    if saved:
        temporary = SNAPSHOT.with_suffix('.tmp')
        temporary.write_text(json.dumps(saved))
        temporary.chmod(0o600)
        temporary.replace(SNAPSHOT)


def request(method, path, body=None):
    connection = http.client.HTTPConnection('localhost', timeout=30)
    connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.sock.settimeout(30)
    connection.sock.connect(docker_socket.BACKEND)
    try:
        data = json.dumps(body).encode() if body is not None else None
        connection.request(method, path, body=data, headers={'Content-Type': 'application/json'})
        response = connection.getresponse()
        data = response.read(8 * 1024 * 1024 + 1)
        if response.status not in (200, 201, 204) or len(data) > 8 * 1024 * 1024:
            raise ValueError('Network policy request failed: ' + path + ' ' + data[:512].decode(errors='replace'))
        return json.loads(data) if data else {}
    finally:
        connection.close()


def inspect_network(name):
    return request('GET', '/networks/' + quote(name, safe=''))


def restore():
    if not enabled() or not SNAPSHOT.exists():
        return
    saved = json.loads(SNAPSHOT.read_text())
    networks = {n['Name']: n for n in request('GET', '/networks') if n.get('Driver') == 'macvlan'}
    containers = {c['Id'] for c in request('GET', '/containers/json?all=1')}
    for identifier, endpoints in saved.items():
        if identifier not in containers:
            continue
        current = request('GET', '/containers/' + identifier + '/json')
        attached = (current.get('NetworkSettings') or {}).get('Networks') or {}
        for name, endpoint in endpoints.items():
            network = networks.get(name)
            if name in attached or not network or (endpoint.get('NetworkID') and endpoint['NetworkID'] != network['Id']):
                continue
            configuration = dict(endpoint.get('IPAMConfig') or {})
            if endpoint.get('IPAddress'):
                configuration['IPv4Address'] = endpoint['IPAddress']
            if endpoint.get('GlobalIPv6Address'):
                configuration['IPv6Address'] = endpoint['GlobalIPv6Address']
            restored = {'IPAMConfig': configuration}
            if endpoint.get('DesiredMacAddress'):
                restored['MacAddress'] = endpoint['DesiredMacAddress']
            for key in ('MacAddress', 'Aliases', 'DriverOpts'):
                if endpoint.get(key):
                    restored[key] = endpoint[key]
            request('POST', '/networks/' + network['Id'] + '/connect', {'Container': identifier, 'EndpointConfig': restored})
    SNAPSHOT.unlink()


def validate_container(config, inspect_container, network, depth=0):
    if depth > 8:
        raise ValueError('Invalid container network reference')
    host = config.get('HostConfig') or {}
    mode = host.get('NetworkMode') or ''
    if mode.startswith('container:'):
        validate_container(inspect_container(mode.split(':', 1)[1]), inspect_container, network, depth + 1)
        return
    names = set((config.get('NetworkingConfig') or {}).get('EndpointsConfig') or {})
    names.update((config.get('NetworkSettings') or {}).get('Networks') or {})
    if mode not in ('', 'default', 'bridge', 'host', 'none'):
        names.add(mode)
    for name in names:
        if name not in ('', 'default', 'bridge', 'host', 'none') and network(name).get('Driver') == 'macvlan':
            require_bridge()


def authorize(request, inspect_container, network=inspect_network):
    if enabled() or request.get('RequestMethod') != 'POST':
        return
    path = re.sub(r'^/v[0-9]+\.[0-9]+/', '/', unquote(urlsplit(request.get('RequestUri', request.get('RequestURI', ''))).path))
    if path in ('/networks/create', '/containers/create') or re.fullmatch(r'/networks/[^/]+/(connect|disconnect)', path):
        config = json.loads(base64.b64decode(request.get('RequestBody', ''), validate=True))
        if path == '/networks/create':
            inherited = (config.get('ConfigFrom') or {}).get('Network')
            if config.get('Driver') == 'macvlan' or (inherited and network(inherited).get('Driver') == 'macvlan'):
                require_bridge()
        elif path == '/containers/create':
            validate_container(config, inspect_container, network)
        elif network(path.split('/')[2]).get('Driver') == 'macvlan':
            require_bridge()
    else:
        match = re.fullmatch(r'/containers/([^/]+)/(start|restart|unpause)', path)
        if match:
            validate_container(inspect_container(match[1]), inspect_container, network)

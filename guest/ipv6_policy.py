import base64
import http.client
import json
from pathlib import Path
import re
import socket
import threading
from urllib.parse import quote, unquote, urlsplit
import docker_socket

STATE = Path('/etc/macosdocker-ipv6-policy.json')
LABEL = 'com.macosdocker.ipv6'
NETWORK = 'macosdocker-dualstack'
LOCK = threading.Lock()


def enabled():
    try:
        return json.loads(STATE.read_text()).get('enabled') is True
    except (OSError, ValueError, AttributeError):
        return False


def configure(value):
    if not isinstance(value, bool):
        raise ValueError('Invalid IPv6 creation policy')
    STATE.parent.mkdir(parents=True, exist_ok=True)
    temporary = STATE.with_suffix('.tmp')
    temporary.write_text(json.dumps({'enabled': value}))
    temporary.chmod(0o600)
    temporary.replace(STATE)


def api(method, path, body=None):
    connection = http.client.HTTPConnection('localhost', timeout=30)
    connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.sock.settimeout(30)
    connection.sock.connect(docker_socket.BACKEND)
    try:
        data = json.dumps(body).encode() if body is not None else None
        connection.request(method, path, data, {'Content-Type': 'application/json'})
        response = connection.getresponse()
        data = response.read(8 * 1024 * 1024 + 1)
        if len(data) > 8 * 1024 * 1024:
            raise RuntimeError('IPv6 network response too large')
        result = json.loads(data) if data else {}
        if response.status == 404:
            return None
        if response.status not in (200, 201, 204):
            raise RuntimeError(str(result.get('message', 'IPv6 network request failed')))
        return result
    finally:
        connection.close()


def default_network():
    with LOCK:
        network = api('GET', '/networks/' + quote(NETWORK, safe=''))
        if network is None:
            api('POST', '/networks/create', {'Name': NETWORK, 'Driver': 'bridge', 'EnableIPv6': True, 'Options': {'com.docker.network.driver.mtu': '65535'}, 'Labels': {LABEL: 'managed'}})
            network = api('GET', '/networks/' + quote(NETWORK, safe=''))
        if not network or not network.get('EnableIPv6') or (network.get('Labels') or {}).get(LABEL) != 'managed':
            raise ValueError('The managed IPv6 network name is already in use: ' + NETWORK)
        return NETWORK


def network_config(config):
    if not enabled():
        if config.get('EnableIPv6') or any(':' in item.get('Subnet', '') for item in (config.get('IPAM') or {}).get('Config') or []):
            raise ValueError('IPv6 is disabled for new containers and networks. Enable it in Runtime first.')
        config['EnableIPv6'] = False
    elif config.get('Driver', 'bridge') in ('', 'bridge') and config.get('EnableIPv6') is None:
        config['EnableIPv6'] = True
    return config


def container_config(config):
    use = enabled()
    host = config.get('HostConfig') or {}
    config['HostConfig'] = host
    mode = host.get('NetworkMode') or ''
    if mode not in ('host',) and not mode.startswith('container:'):
        settings = host.get('Sysctls') or {}
        host['Sysctls'] = settings
        if not use and any(key.startswith('net.ipv6.') and str(value) == '0' and key.endswith('disable_ipv6') for key, value in settings.items()):
            raise ValueError('IPv6 is disabled for new containers. Enable it in Runtime first.')
        settings['net.ipv6.conf.all.disable_ipv6'] = '0' if use else '1'
        settings['net.ipv6.conf.default.disable_ipv6'] = '0' if use else '1'
    if not use and mode != 'host' and not mode.startswith('container:'):
        bindings = host.get('PortBindings') or {}
        if host.get('PublishAllPorts'):
            for port in config.get('ExposedPorts') or {}:
                bindings.setdefault(port, [{'HostPort': '', 'HostIp': '0.0.0.0'}])
            host['PublishAllPorts'] = False
        for values in bindings.values():
            for binding in values or []:
                address = binding.get('HostIp') or ''
                if ':' in address:
                    raise ValueError('IPv6 port bindings require enabling IPv6 in Runtime.')
                if not address:
                    binding['HostIp'] = '0.0.0.0'
        if bindings:
            host['PortBindings'] = bindings
    if use and mode in ('', 'default', 'bridge'):
        name = default_network()
        host['NetworkMode'] = name
        networking = config.get('NetworkingConfig') or {}
        endpoints = networking.get('EndpointsConfig') or {}
        for source in ('bridge', 'default', ''):
            if source in endpoints:
                if name in endpoints:
                    raise ValueError('Duplicate default network endpoint')
                endpoints[name] = endpoints.pop(source)
        if endpoints:
            networking['EndpointsConfig'] = endpoints
            config['NetworkingConfig'] = networking
    labels = config.get('Labels') or {}
    labels[LABEL] = 'enabled' if use else 'disabled'
    config['Labels'] = labels
    return config


def authorize(request):
    if request.get('RequestMethod') != 'POST':
        return
    path = re.sub(r'^/v[0-9]+\.[0-9]+/', '/', unquote(urlsplit(request.get('RequestUri', request.get('RequestURI', ''))).path))
    if path != '/networks/create':
        return
    config = json.loads(base64.b64decode(request.get('RequestBody', ''), validate=True))
    network_config(config)

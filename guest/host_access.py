import http.client
import host_dns
import bridge_mtu
import docker_socket
import ipaddress
import json
import os
import re
from pathlib import Path
import socket
import subprocess
import threading
import time
from urllib.parse import urlencode

NAME = 'host.docker.internal'
MARKER = '# macOSDocker-host-access'
ALIAS = 'macOSDocker host access'
STATUS = {'ready': False, 'configured': 0, 'errors': []}


def command(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or 'Host access command failed')
    return result.stdout.strip()


def docker(path):
    connection = http.client.HTTPConnection('localhost', timeout=5)
    connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.sock.settimeout(5)
    try:
        connection.sock.connect(docker_socket.BACKEND)
        connection.request('GET', path)
        response = connection.getresponse()
        if response.status != 200:
            raise RuntimeError('Docker API: ' + str(response.status))
        return json.loads(response.read())
    finally:
        connection.close()


def hosts_content(text, address):
    lines = [line for line in text.splitlines() if not line.endswith(MARKER)]
    if any(NAME in line.split('#', 1)[0].split()[1:] for line in lines):
        return '\n'.join(lines) + '\n'
    if address:
        lines.append(address + '\t' + NAME + ' ' + MARKER)
    return '\n'.join(lines) + '\n'


def write_hosts(info, address):
    path = Path(info.get('HostsPath', ''))
    if not re.fullmatch(r'/var/lib/docker/containers/[a-f0-9]{64}/hosts', str(path)) or path.is_symlink():
        raise RuntimeError('Unexpected container hosts path')
    with path.open('r+') as file:
        text = file.read()
        updated = hosts_content(text, address)
        if updated != text:
            file.seek(0)
            file.write(updated)
            file.truncate()
        for line in updated.splitlines():
            fields = line.split('#', 1)[0].split()
            if len(fields) > 1 and NAME in fields[1:]:
                return str(ipaddress.ip_address(fields[0]))
        return address


def namespace(pid):
    return os.stat('/proc/' + str(pid) + '/ns/net').st_ino


def root_address():
    interfaces = json.loads(command('ip', '-j', '-4', 'address'))
    for name in ['docker0', 'eth0']:
        for interface in interfaces:
            if interface['ifname'] == name:
                for address in interface.get('addr_info', []):
                    if address.get('family') == 'inet':
                        return address['local']
    raise RuntimeError('No VM IPv4 address')


class HostAccess:
    def __init__(self):
        self.links = {}
        self.cleaned = False
        self.rules = None

    def firewall(self, addresses, containers):
        mappings = set()
        vm_addresses = {a['local'] for interface in json.loads(command('ip', '-j', '-4', 'address'))
                        for a in interface.get('addr_info', []) if a.get('family') == 'inet'}
        for container in containers:
            targets = [n.get('IPAddress') for n in container.get('NetworkSettings', {}).get('Networks', {}).values() if n.get('IPAddress')]
            if not targets:
                continue
            target = str(ipaddress.IPv4Address(targets[0]))
            for port in container.get('Ports', []):
                bound = port.get('IP', '')
                if bound not in ('', '0.0.0.0') and bound not in vm_addresses:
                    continue
                if bound.startswith('127.') or port.get('Type') not in ('tcp', 'udp') or not port.get('PublicPort'):
                    continue
                mappings.add((port['Type'], int(port['PublicPort']), target, int(port['PrivatePort'])))
        signature = (tuple(sorted(addresses)), tuple(sorted(mappings)))
        chains = [('nat', 'MDHOST-IN', 'PREROUTING'), ('nat', 'MDHOST-OUT', 'OUTPUT'),
                  ('nat', 'MDHOST-SNAT', 'POSTROUTING'), ('filter', 'MACOSDOCKER-HOST', 'DOCKER-USER')]
        intact = all(subprocess.run(['iptables', '-w', '2', '-t', table, '-C', parent, '-j', chain], capture_output=True).returncode == 0
                     for table, chain, parent in chains)
        if self.rules == signature and intact:
            return
        lines = ['*nat', ':MDHOST-IN - [0:0]', ':MDHOST-OUT - [0:0]', ':MDHOST-PORTS - [0:0]', ':MDHOST-SNAT - [0:0]']
        lines += ['-F ' + c for c in ['MDHOST-IN', 'MDHOST-OUT', 'MDHOST-PORTS', 'MDHOST-SNAT']]
        for address in sorted(addresses):
            address = str(ipaddress.IPv4Address(address))
            for chain in ['MDHOST-IN', 'MDHOST-OUT']:
                lines.append('-A ' + chain + ' -d ' + address + '/32 -j MDHOST-PORTS')
            lines.append('-A MDHOST-SNAT -m conntrack --ctstate DNAT --ctorigdst ' + address + ' -j MASQUERADE')
        for protocol, public, target, private in sorted(mappings):
            lines.append(f'-A MDHOST-PORTS -p {protocol} --dport {public} -j DNAT --to-destination {target}:{private}')
        lines += ['COMMIT', '*filter', ':MACOSDOCKER-HOST - [0:0]', '-F MACOSDOCKER-HOST']
        for address in sorted(addresses):
            lines.append('-A MACOSDOCKER-HOST -m conntrack --ctstate DNAT --ctorigdst ' + address + ' -j ACCEPT')
        lines += ['COMMIT', '']
        result = subprocess.run(['iptables-restore', '--noflush', '--wait', '2'], input='\n'.join(lines), text=True, capture_output=True, timeout=10)
        if result.returncode:
            raise RuntimeError(result.stderr.strip())
        for table, chain, parent in chains:
            if subprocess.run(['iptables', '-w', '2', '-t', table, '-C', parent, '-j', chain], capture_output=True).returncode:
                command('iptables', '-w', '2', '-t', table, '-I', parent, '1', '-j', chain)
        self.rules = signature

    def clean_stale(self):
        for link in json.loads(command('ip', '-j', 'link')):
            if link.get('ifalias') == ALIAS and link['ifname'].startswith('mdh'):
                command('ip', 'link', 'delete', link['ifname'])
        self.cleaned = True

    def private_link(self, pid, ns):
        if ns in self.links:
            name, address = self.links[ns]
            if subprocess.run(['ip', 'link', 'show', name], capture_output=True).returncode == 0:
                return address
            self.links.pop(ns)
        routes = json.loads(command('ip', '-j', '-4', 'route', 'show', 'table', 'all'))
        routes += json.loads(command('nsenter', '-t', str(pid), '-n', 'ip', '-j', '-4', 'route', 'show', 'table', 'all'))
        occupied = [ipaddress.ip_network(r['dst'], strict=False) for r in routes if r.get('dst') not in (None, 'default')]
        network = next((n for n in ipaddress.ip_network('169.254.128.0/17').subnets(new_prefix=30)
                        if not any(n.overlaps(existing) for existing in occupied)), None)
        if network is None:
            raise RuntimeError('No unused link-local subnet for host access')
        host, peer = str(network[1]), str(network[2])
        name = 'mdh' + format(ns, 'x')[-10:]
        peer_name = 'mdp' + format(ns, 'x')[-10:]
        command('ip', 'link', 'add', name, 'type', 'veth', 'peer', 'name', peer_name)
        try:
            command('ip', 'link', 'set', name, 'alias', ALIAS)
            command('ip', 'address', 'add', host + '/30', 'dev', name)
            command('ip', 'link', 'set', name, 'up')
            command('ip', 'link', 'set', peer_name, 'netns', str(pid))
            command('nsenter', '-t', str(pid), '-n', 'ip', 'address', 'add', peer + '/30', 'dev', peer_name)
            command('nsenter', '-t', str(pid), '-n', 'ip', 'link', 'set', peer_name, 'up')
            command('nsenter', '-t', str(pid), '-n', 'ip', 'route', 'add', host_dns.ADDRESS + '/32', 'via', host, 'dev', peer_name)
            if namespace(pid) != ns:
                raise RuntimeError('Container network namespace changed')
            self.links[ns] = (name, host)
            return host
        except Exception:
            subprocess.run(['ip', 'link', 'delete', name], capture_output=True)
            raise

    def sync(self):
        global STATUS
        containers = docker('/containers/json')
        if not self.cleaned:
            self.clean_stale()
        network_details = docker('/networks')
        networks = {n['Id']: n['Driver'] for n in network_details}
        inspected = []
        active = set()
        errors = []
        configured = 0
        addresses = set()
        vm_address = root_address()
        clients = {host_dns.ADDRESS: vm_address, '127.0.0.1': vm_address}
        for interface in json.loads(command('ip', '-j', '-4', 'address')):
            for value in interface.get('addr_info', []):
                if value.get('family') == 'inet':
                    clients[value['local']] = vm_address
        for container in containers:
            try:
                info = docker('/containers/' + container['Id'] + '/json')
                inspected.append(info)
                pid = info['State']['Pid']
                if not pid or not info['State'].get('Running'):
                    continue
                mode = info.get('HostConfig', {}).get('NetworkMode', '')
                if mode.startswith('container:'):
                    parent = docker('/containers/' + mode.split(':', 1)[1] + '/json')
                    mode = parent.get('HostConfig', {}).get('NetworkMode', '')
                if mode == 'none':
                    write_hosts(info, None)
                    continue
                ns = namespace(pid)
                active.add(ns)
                if ns == namespace(1):
                    address = root_address()
                else:
                    attached = info.get('NetworkSettings', {}).get('Networks', {})
                    gateways = [n.get('Gateway') for n in attached.values()
                                if networks.get(n.get('NetworkID')) == 'bridge' and n.get('Gateway')]
                    address = gateways[0] if gateways else self.private_link(pid, ns)
                addresses.add(address)
                dns_address = write_hosts(info, address)
                for interface in json.loads(command('nsenter', '-t', str(pid), '-n', 'ip', '-j', '-4', 'address')):
                    for value in interface.get('addr_info', []):
                        if value.get('family') == 'inet' and not value['local'].startswith('127.'):
                            clients[value['local']] = dns_address
                configured += 1
            except Exception as error:
                errors.append(container['Id'][:12] + ': ' + str(error))
        for ns in list(self.links):
            if ns not in active:
                subprocess.run(['ip', 'link', 'delete', self.links.pop(ns)[0]], capture_output=True)
        bridge_mtu.synchronize(network_details, inspected)
        if errors:
            STATUS = {'ready': False, 'configured': configured, 'errors': errors}
            return
        self.firewall(addresses, containers)
        host_dns.set_clients(clients)
        STATUS = {'ready': not errors, 'configured': configured, 'errors': errors}


CONTROL_INTERVAL = 60
EVENT_ACTIONS = {
    'container': {'start', 'die', 'stop', 'destroy', 'restart', 'unpause', 'update'},
    'network': {'create', 'destroy', 'connect', 'disconnect'},
    'daemon': {'reload'},
}


def relevant_event(event):
    return event.get('Action', event.get('status')) in EVENT_ACTIONS.get(event.get('Type'), set())


def docker_events(changed):
    filters = json.dumps({'type': list(EVENT_ACTIONS)})
    while True:
        connection = http.client.HTTPConnection('localhost', timeout=5)
        connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.sock.settimeout(5)
        try:
            connection.sock.connect(docker_socket.BACKEND)
            connection.request('GET', '/events?' + urlencode({'filters': filters}))
            response = connection.getresponse()
            if response.status != 200:
                raise RuntimeError('Docker events: ' + str(response.status))
            connection.sock.settimeout(None)
            changed.set()
            while True:
                line = response.readline(1048576)
                if not line:
                    raise ConnectionError('Docker event stream closed')
                if relevant_event(json.loads(line)):
                    changed.set()
        except (OSError, ValueError, RuntimeError, http.client.HTTPException):
            changed.set()
            time.sleep(5)
        finally:
            connection.close()


def watch(service, changed):
    global STATUS
    dns_started = False
    while True:
        changed.clear()
        retry = CONTROL_INTERVAL
        try:
            if not dns_started:
                host_dns.start()
                dns_started = True
            service.sync()
            if not STATUS['ready'] or not bridge_mtu.STATUS['ready']:
                retry = 5
        except Exception as error:
            STATUS = {'ready': False, 'configured': 0, 'errors': [str(error)]}
            retry = 5
        changed.wait(retry)
        if changed.is_set():
            time.sleep(0.25)


def start():
    changed = threading.Event()
    threading.Thread(target=docker_events, args=(changed,), daemon=True).start()
    threading.Thread(target=watch, args=(HostAccess(), changed), daemon=True).start()

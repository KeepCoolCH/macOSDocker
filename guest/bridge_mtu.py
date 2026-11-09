import json
import os
import subprocess
import threading

MTU = 65535
LOCK = threading.Lock()
STATUS = {'ready': False, 'mtu': MTU, 'interfaces': 0, 'errors': []}


def command(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or 'Docker bridge MTU configuration failed')
    return result.stdout.strip()


def plan(networks, links):
    by_name = {link['ifname']: link for link in links}
    bridges = []
    ports = {}
    for network in networks:
        if network.get('Driver') != 'bridge':
            continue
        options = network.get('Options') or {}
        name = options.get('com.docker.network.bridge.name')
        if not name:
            name = 'docker0' if network.get('Name') == 'bridge' else 'br-' + network['Id'][:12]
        bridge = by_name.get(name)
        if not bridge or (bridge.get('linkinfo') or {}).get('info_kind') != 'bridge':
            continue
        members = [link for link in links if link.get('master') in (name, bridge['ifindex'])]
        if any((link.get('linkinfo') or {}).get('info_kind') != 'veth' for link in members):
            continue
        bridges.append((bridge, {link['ifindex'] for link in members}))
        ports.update({link['ifindex']: link for link in members})
    return bridges, ports


def change(link, prefix=()):
    if link.get('mtu') == MTU:
        return
    command(*prefix, 'ip', 'link', 'set', 'dev', link['ifname'], 'mtu', str(MTU))



def reconcile(request):
    global STATUS
    try:
        networks = request('GET', '/networks')
        containers = [request('GET', '/containers/' + container['Id'] + '/json')
                      for container in request('GET', '/containers/json')]
        return synchronize(networks, containers)
    except Exception as error:
        STATUS = {'ready': False, 'mtu': MTU, 'interfaces': 0, 'errors': [str(error)]}
        return dict(STATUS)


def synchronize(networks, containers):
    global STATUS
    with LOCK:
        errors = []
        changed = set()
        try:
            bridges, ports = plan(networks, json.loads(command('ip', '-j', '-d', 'link', 'show')))
            host_namespace = os.stat('/proc/1/ns/net').st_ino
            seen = {host_namespace}
            for container in containers:
                state = container.get('State') or {}
                pid = state.get('Pid')
                if not pid or not state.get('Running'):
                    continue
                try:
                    namespace = os.stat('/proc/' + str(pid) + '/ns/net').st_ino
                    if namespace in seen:
                        continue
                    seen.add(namespace)
                    prefix = ('nsenter', '-t', str(pid), '-n')
                    links = json.loads(command(*prefix, 'ip', '-j', '-d', 'link', 'show'))
                    for link in links:
                        peer = link.get('link_index')
                        if peer not in ports or (link.get('linkinfo') or {}).get('info_kind') != 'veth':
                            continue
                        change(link, prefix)
                        change(ports[peer])
                        changed.add(peer)
                except Exception as error:
                    errors.append(str(error))
            for bridge, members in bridges:
                missing = members - changed
                if missing:
                    errors.append('Docker bridge peers not ready: ' + bridge['ifname'])
                    continue
                try:
                    change(bridge)
                except Exception as error:
                    errors.append(str(error))
        except Exception as error:
            errors.append(str(error))
        STATUS = {'ready': not errors, 'mtu': MTU, 'interfaces': len(changed), 'errors': errors}
        return dict(STATUS)

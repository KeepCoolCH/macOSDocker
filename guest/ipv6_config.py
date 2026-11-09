import ipaddress
import json
from pathlib import Path
import subprocess
import resolver_config
import ipv6_policy
import network_policy

STATE = Path('/var/lib/docker/.macosdocker-ipv6.json')


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=15)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or 'IPv6 configuration failed')
    return result.stdout.strip()


def normalized(value):
    mode = value.get('mode', 'disabled')
    if mode not in ('disabled', 'automatic', 'manual'):
        raise ValueError('Invalid IPv6 mode')
    result = {'mode': mode}
    if mode == 'manual':
        prefix = value.get('prefix', 64)
        if type(prefix) is not int or not 1 <= prefix <= 128:
            raise ValueError('IPv6 prefix must be between 1 and 128')
        interface = ipaddress.IPv6Interface(str(value.get('address', '')) + '/' + str(prefix))
        address = interface.ip
        if address.is_unspecified or address.is_loopback or address.is_multicast or address.is_link_local:
            raise ValueError('Invalid IPv6 host address')
        result.update(address=str(address), prefix=prefix)
        gateway = value.get('gateway', '').strip()
        if gateway:
            router = ipaddress.IPv6Address(gateway)
            if router.is_unspecified or router.is_loopback or router.is_multicast or router == address or (not router.is_link_local and router not in interface.network):
                raise ValueError('Invalid IPv6 gateway')
            result['gateway'] = str(router)
        servers = value.get('dns', [])
        if not isinstance(servers, list) or len(servers) > 3:
            raise ValueError('Provide at most three IPv6 DNS servers')
        result['dns'] = [str(ipaddress.IPv6Address(server)) for server in servers]
    return result


def configure(value):
    config = normalized(value or {})
    requested = config['mode'] != 'disabled'
    previous = json.loads(STATE.read_text()) if STATE.exists() else {'mode': 'disabled'}
    effective = config if requested else previous
    if effective['mode'] == 'manual' and not network_policy.enabled():
        effective = {'mode': 'automatic'}
    if effective['mode'] == 'disabled':
        run('sysctl', '-w', 'net.ipv6.conf.eth0.disable_ipv6=1')
        resolver_config.configure_ipv6([])
    else:
        run('sysctl', '-w', 'net.ipv6.conf.eth0.disable_ipv6=0', 'net.ipv6.conf.lo.disable_ipv6=0', 'net.ipv6.conf.default.disable_ipv6=0')
        automatic = effective['mode'] == 'automatic'
        run('sysctl', '-w', 'net.ipv6.conf.eth0.accept_ra=' + ('2' if automatic else '0'), 'net.ipv6.conf.eth0.autoconf=' + ('1' if automatic else '0'))
        if not automatic:
            links = json.loads(run('ip', '-j', '-6', 'address', 'show', 'dev', 'eth0'))
            present = any(address.get('local') == effective['address'] and address.get('prefixlen') == effective['prefix']
                          for link in links for address in link.get('addr_info', []))
            if not present:
                run('ip', '-6', 'address', 'flush', 'dev', 'eth0', 'scope', 'global')
                run('ip', '-6', 'address', 'replace', effective['address'] + '/' + str(effective['prefix']), 'dev', 'eth0')
            if not present or previous.get('gateway') != effective.get('gateway'):
                run('ip', '-6', 'route', 'flush', 'default', 'dev', 'eth0')
            if effective.get('gateway'):
                run('ip', '-6', 'route', 'replace', 'default', 'via', effective['gateway'], 'dev', 'eth0')
        resolver_config.configure_ipv6(effective.get('dns', []))
    if requested:
        temporary = STATE.with_suffix('.tmp')
        temporary.write_text(json.dumps(config))
        temporary.chmod(0o600)
        temporary.replace(STATE)
    ipv6_policy.configure(requested)
    return {'mode': config['mode'], 'transport': effective['mode']}

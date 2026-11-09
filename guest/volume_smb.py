"""On-demand authenticated exports with optional guest LAN access."""
import json
import ipaddress
import re
import socket
import subprocess
import threading
from pathlib import Path

LOCK = threading.Lock()
CONFIG = Path('/run/macosdocker-smb.conf')
STATE = Path('/run/macosdocker-samba')
EXPORTS = {}
PROCESS = None
PASSWORD = None
LAN = False
GLOBAL = '''[global]
    ncalrpc dir = /run/macosdocker-samba/ncalrpc
    private dir = /run/macosdocker-samba/private
    state directory = /run/macosdocker-samba/state
    cache directory = /run/macosdocker-samba/cache
    lock directory = /run/macosdocker-samba/lock
    pid directory = /run/macosdocker-samba
    netbios name = MACOSDOCKER
    name resolve order = lmhosts
    dns proxy = no
    hostname lookups = no
    server role = standalone server
    security = user
    map to guest = Never
    interfaces = 127.0.0.1
    bind interfaces only = yes
    smb ports = 445
    disable netbios = yes
    server min protocol = SMB2_02
    server multi channel support = no
    load printers = no
    printing = bsd
    printcap name = /dev/null
    logging = file
    log file = /var/log/macosdocker-smb.log
    max log size = 256
'''


def export_volume(body):
    global PROCESS, PASSWORD, LAN
    name, password = body.get('name', ''), body.get('password', '')
    if not isinstance(name, str) or not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]{0,254}', name):
        raise ValueError('Invalid volume name')
    if not isinstance(password, str) or not re.fullmatch(r'[a-f0-9]{64}', password):
        raise ValueError('Invalid SMB credential')
    lan = body.get('lan', False)
    if not isinstance(lan, bool):
        raise ValueError('Invalid SMB network selection')
    with LOCK:
        result = subprocess.run(['docker', 'volume', 'inspect', name], capture_output=True, text=True, timeout=15, check=True)
        volume = json.loads(result.stdout)[0]
        expected = Path('/var/lib/docker/volumes') / name / '_data'
        # Plugin, NFS and bind-backed volumes require driver-specific lifecycle handling.
        if volume['Driver'] != 'local' or volume.get('Options') or volume['Mountpoint'] != str(expected):
            raise ValueError('Only ordinary local Docker volumes can be opened in Finder')
        if not expected.is_dir() or expected.resolve() != expected:
            raise ValueError('Volume directory unavailable or contains symbolic links')
        if PASSWORD is not None and PASSWORD != password:
            raise ValueError('SMB session credential mismatch; restart the VM')
        if PASSWORD is not None and lan != LAN:
            raise ValueError('SMB network changed; restart the VM')
        interfaces = '127.0.0.1'
        if lan:
            addresses = json.loads(subprocess.run(['ip', '-j', '-4', 'address', 'show', 'dev', 'eth0'], capture_output=True, text=True, timeout=5, check=True).stdout)
            for interface in addresses:
                for address in interface.get('addr_info', []):
                    if address.get('scope') == 'global':
                        interfaces += ' ' + str(ipaddress.IPv4Address(address['local']))
            if interfaces == '127.0.0.1':
                raise ValueError('VM LAN address unavailable')
        configuration = GLOBAL.replace('interfaces = 127.0.0.1', 'interfaces = ' + interfaces)
        first = PASSWORD is None
        if first:
            for directory in ('private', 'state', 'cache', 'lock'):
                (STATE / directory).mkdir(mode=0o700, parents=True, exist_ok=True)
            CONFIG.write_text(configuration)
            CONFIG.chmod(0o600)
            subprocess.run(['smbpasswd', '-s', '-c', str(CONFIG), '-a', 'volumeaccess'], input=password + '\n' + password + '\n', text=True, capture_output=True, timeout=15, check=True)
            PASSWORD = password
            LAN = lan
        share_name = name + ".volume" if name.lower() in {"global", "homes", "printers"} else name
        EXPORTS[share_name] = expected
        text = configuration
        for share, path in EXPORTS.items():
            text += f'''\n[{share}]
    path = {path}
    valid users = volumeaccess
    force user = root
    read only = no
    browseable = no
    guest ok = no
    wide links = no
    follow symlinks = no
    create mask = 0644
    directory mask = 0755
'''
        CONFIG.write_text(text)
        if PROCESS is None or PROCESS.poll() is not None:
            with open('/var/log/macosdocker-smb-start.log', 'ab') as log:
                PROCESS = subprocess.Popen(['smbd', '--foreground', '--no-process-group', '--configfile=' + str(CONFIG)], stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        else:
            subprocess.run(['smbcontrol', '-s', str(CONFIG), 'all', 'reload-config'], capture_output=True, timeout=15, check=True)
        for _ in range(50):
            try:
                with socket.create_connection(('127.0.0.1', 445), timeout=0.1):
                    return {'share': share_name, 'username': 'volumeaccess'}
            except OSError:
                threading.Event().wait(0.1)
        detail = 'exit=' + str(PROCESS.poll()) + ' '
        for log in ('/var/log/macosdocker-smb-start.log', '/var/log/macosdocker-smb.log'):
            if Path(log).exists():
                detail += Path(log).read_text()[-1500:]
        raise RuntimeError('SMB service did not start: ' + detail)

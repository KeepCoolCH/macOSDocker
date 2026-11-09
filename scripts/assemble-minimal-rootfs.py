#!/usr/bin/python3
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

root = Path(sys.argv[1])
source = Path(sys.argv[2])
root.mkdir(parents=True, exist_ok=True)
for directory in ('usr/bin', 'usr/sbin', 'usr/lib', 'etc', 'dev', 'proc', 'sys', 'run', 'tmp', 'var/log', 'var/log/samba', 'var/lib', 'var/lib/samba', 'var/cache/samba', 'root', 'mnt', 'opt/docker/releases', 'usr/local/lib/macosdocker', 'etc/network', 'etc/containerd', 'etc/docker'):
    (root / directory).mkdir(parents=True, exist_ok=True)
for name, target in (('bin', 'usr/bin'), ('sbin', 'usr/sbin'), ('lib', 'usr/lib'), ('var/run', '/run'), ('var/lock', '/run/lock')):
    (root / name).symlink_to(target)
seen = set()


def add(path):
    path = Path(path)
    if str(path) in seen:
        return
    seen.add(str(path))
    destination = root / str(path).lstrip('/')
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink() or destination.is_file():
        destination.unlink()
    if path.is_symlink():
        target = str(path.resolve())
        destination.symlink_to(target)
        add(path.resolve())
        return
    shutil.copy2(path, destination)
    if path.read_bytes()[:4] == b'\x7fELF':
        result = subprocess.run(['ldd', str(path)], capture_output=True, text=True)
        if 'not found' in result.stdout:
            raise RuntimeError('Unresolved dependency: ' + str(path) + '\n' + result.stdout)
        for dependency in re.findall(r'(?:=>\s+|^\s*)(/\S+)', result.stdout, re.MULTILINE):
            add(dependency)


subprocess.run(['cc', '-Os', '-Wall', '-Wextra', '-Werror', str(source / 'guest/init.c'), '-o', '/macosdocker-init'], check=True)
add('/bin/busybox')
applets = subprocess.check_output(['/bin/busybox', '--list'], text=True).splitlines()
for applet in applets:
    path = root / 'usr/bin' / applet
    if not path.exists():
        path.symlink_to('/bin/busybox')
for applet in ('init', 'poweroff', 'reboot', 'switch_root'):
    (root / 'usr/sbin' / applet).symlink_to('/bin/busybox')
add('/macosdocker-init')
(root / 'usr/sbin/init').unlink()
(root / 'macosdocker-init').rename(root / 'usr/sbin/init')
for executable in ('python3', 'ip', 'ss', 'iptables', 'iptables-save', 'iptables-restore', 'ip6tables', 'ip6tables-save', 'ip6tables-restore', 'modprobe', 'depmod', 'blkid', 'mkfs.ext4', 'mount', 'umount', 'mountpoint', 'findmnt', 'lsblk', 'smbd', 'smbpasswd', 'smbcontrol', 'iperf3', 'nsenter', 'unshare', 'flock'):
    add(shutil.which(executable))
stdlib = Path('/usr/lib/python' + '.'.join(map(str, sys.version_info[:2])))
shutil.copytree(stdlib, root / stdlib.relative_to('/'), ignore=shutil.ignore_patterns('__pycache__', 'test', 'tests', 'idlelib', 'tkinter', 'ensurepip', 'config-*'))
for library in stdlib.rglob('*.so'):
    if (root / library.relative_to('/')).exists():
        add(library)
for directory in ('/usr/lib/aarch64-linux-gnu/gconv', '/usr/lib/aarch64-linux-gnu/samba', '/usr/lib/aarch64-linux-gnu/xtables', '/usr/share/samba', '/etc/ssl/certs'):
    path = Path(directory)
    shutil.copytree(path, root / path.relative_to('/'), symlinks=False, dirs_exist_ok=True)
    for library in path.rglob('*.so*'):
        if library.is_file():
            add(library)
(root / 'usr/lib/ssl').mkdir(parents=True, exist_ok=True)
(root / 'usr/lib/ssl/cert.pem').symlink_to('/etc/ssl/certs/ca-certificates.crt')
(root / 'usr/lib/ssl/certs').symlink_to('/etc/ssl/certs')
add('/etc/ssl/openssl.cnf')
(root / 'usr/lib/ssl/openssl.cnf').symlink_to('/etc/ssl/openssl.cnf')
for library in Path('/usr/lib/aarch64-linux-gnu').glob('libnss_*.so.2'):
    add(library)
for name in ('agent.py', 'ipv6_config.py', 'ipv6_policy.py', 'bridge_mtu.py', 'resolver_config.py', 'network_policy.py', 'volume_smb.py', 'engine_update.py', 'host_access.py', 'host_dns.py', 'mac_binds.py', 'docker_socket.py', 'runtime_service.py', 'agent.sh', 'dhcp.sh', 'boot.sh', 'shutdown.sh'):
    shutil.copy2(source / 'guest' / name, root / 'usr/local/lib/macosdocker' / name)
    (root / 'usr/local/lib/macosdocker' / name).chmod(0o755)
(root / 'usr/sbin/macosdocker-service').symlink_to('/usr/local/lib/macosdocker/runtime_service.py')
for name in ('ifup', 'ifdown'):
    destination = root / 'usr/sbin' / name
    destination.unlink(missing_ok=True)
    destination.symlink_to('/usr/local/lib/macosdocker/runtime_service.py')
files = {
    'etc/os-release': 'NAME="macOSDocker Linux"\nID=macosdocker\nVERSION_ID=1\nPRETTY_NAME="macOSDocker minimal userspace"\n',
    'etc/hostname': 'macosdocker\n',
    'etc/hosts': '127.0.0.1 localhost macosdocker\n',
    'etc/resolv.conf': '',
    'etc/nsswitch.conf': 'passwd: files\ngroup: files\nshadow: files\nhosts: files dns\n',
    'etc/passwd': 'root:x:0:0:root:/root:/bin/sh\nvolumeaccess:x:100:100:Volume access:/nonexistent:/bin/false\nnobody:x:65534:65534:Unprivileged:/nonexistent:/bin/false\n',
    'etc/group': 'root:x:0:\ntty:x:5:\nvolumeaccess:x:100:\nnogroup:x:65534:\n',
    'etc/shadow': 'root:!:1:0:99999:7:::\nvolumeaccess:!:1:0:99999:7:::\n',
    'etc/network/interfaces': 'auto lo\niface lo inet loopback\nauto eth0\niface eth0 inet dhcp\n',
    'etc/inittab': '::sysinit:/usr/local/lib/macosdocker/boot.sh\n::respawn:/usr/local/lib/macosdocker/agent.sh\n::shutdown:/usr/local/lib/macosdocker/shutdown.sh\n',
    'etc/containerd/config.toml': 'version = 2\nroot = "/var/lib/containerd"\nstate = "/run/containerd"\ndisabled_plugins = ["io.containerd.grpc.v1.cri"]\n[grpc]\n  address = "/run/containerd/containerd.sock"\n',
    'etc/docker/daemon.json': json.dumps({'hosts': ['unix:///var/run/docker.sock'], 'log-driver': 'local', 'userland-proxy': False, 'mtu': 65535, 'default-network-opts': {'bridge': {'com.docker.network.driver.mtu': '65535'}}, 'ipv6': False, 'ip6tables': True}) + '\n',
}
for name, value in files.items():
    (root / name).write_text(value)
(root / 'etc/shadow').chmod(0o600)
(root / 'tmp').chmod(0o1777)
manifest = subprocess.check_output(['dpkg-query', '-W', '-f=${Package}\t${Version}\t${source:Package}\n'], text=True)
(root / 'usr/share/macosdocker').mkdir(parents=True, exist_ok=True)
(root / 'usr/share/macosdocker/build-packages.tsv').write_text(manifest)
licenses = root / 'usr/share/licenses'
licenses.mkdir()
for directory in Path('/usr/share/doc').iterdir():
    if (directory / 'copyright').is_file():
        shutil.copyfile(directory / 'copyright', licenses / (directory.name + '.copyright'))

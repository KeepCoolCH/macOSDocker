#!/usr/bin/python3
from pathlib import Path
import gzip
import lzma
import shutil
import subprocess
import sys

root = Path(sys.argv[1])
release = sys.argv[2]
initial = Path(sys.argv[3])
modules = root / 'lib/modules' / release
for compressed in modules.rglob('*.ko.gz'):
    with gzip.open(compressed, 'rb') as source, compressed.with_suffix('').open('wb') as output:
        shutil.copyfileobj(source, output)
    compressed.unlink()
subprocess.run(['depmod', '-b', str(root), release], check=True)
boot = ['virtio_pci', 'virtio_blk', 'virtio_console', 'ext4']
required = boot + ['virtio_net', 'virtiofs', 'vmw_vsock_virtio_transport', 'overlay', 'bridge', 'veth', 'tun', 'macvlan', 'ipvlan', 'vxlan', 'dummy', 'nf_conntrack', 'nf_nat', 'br_netfilter', 'ip_tables', 'nf_tables']
for directory in ('kernel/net', 'kernel/fs', 'kernel/crypto', 'kernel/drivers/virtio'):
    required += [path.name.split('.ko')[0] for path in (modules / directory).rglob('*.ko*')]


def dependencies(names):
    files = set()
    for name in set(names):
        result = subprocess.run(['modprobe', '-d', str(root), '-S', release, '--show-depends', name], capture_output=True, text=True)
        if result.returncode:
            if name in boot + ['virtio_net', 'virtiofs', 'vmw_vsock_virtio_transport']:
                raise RuntimeError(result.stderr)
            continue
        for line in result.stdout.splitlines():
            if line.startswith('insmod '):
                files.add(Path(line.split()[1]))
    return files


keep = dependencies(required)
for path in dependencies(boot):
    destination = initial / path.relative_to(root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, destination)
for path in modules.rglob('*.ko*'):
    if path not in keep:
        path.unlink()
for name in ('modules.builtin', 'modules.builtin.modinfo', 'modules.order'):
    if (modules / name).exists():
        destination = initial / 'lib/modules' / release / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(modules / name, destination)
for module in modules.rglob('*.ko'):
    with module.open('rb') as source, lzma.open(str(module) + '.xz', 'wb', preset=1) as output:
        shutil.copyfileobj(source, output)
    module.unlink()
subprocess.run(['depmod', '-b', str(root), release], check=True)
subprocess.run(['depmod', '-b', str(initial), release], check=True)

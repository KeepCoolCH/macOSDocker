#!/usr/bin/python3
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

RUN = Path('/run/macosdocker')
SERVICES = {
    'containerd': ['containerd', '--config', '/etc/containerd/config.toml'],
    'docker': ['dockerd'],
}


def alive(pid):
    try:
        return Path(f'/proc/{pid}/stat').read_text().split()[2] != 'Z'
    except (FileNotFoundError, ProcessLookupError):
        return False


def process(name):
    path = RUN / (name + '.json')
    try:
        record = json.loads(path.read_text())
        pid = int(record['pid'])
        if alive(pid) and Path(f'/proc/{pid}/stat').read_text().split()[21] == record['start']:
            return pid
    except (OSError, ValueError, KeyError):
        pass
    return None


def stop(name):
    pid = process(name)
    if pid:
        os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 30
        while process(name) and time.monotonic() < deadline:
            time.sleep(0.05)
        if process(name):
            os.kill(pid, signal.SIGKILL)
            for _ in range(100):
                if not process(name):
                    break
                time.sleep(0.05)
        if process(name):
            raise RuntimeError('Service did not stop: ' + name)
    (RUN / (name + '.json')).unlink(missing_ok=True)


CONTAINERS = Path('/var/lib/docker/containers')
NETWORK_SYSCTL = Path('/proc/sys/net')


def prepare_container_settings():
    for path in CONTAINERS.glob('*/hostconfig.json'):
        value = json.loads(path.read_text())
        settings = value.get('Sysctls') or {}
        unsupported = [key for key in settings if key.startswith('net.') and not (NETWORK_SYSCTL / key.split('.')[1]).exists()]
        if unsupported:
            for key in unsupported:
                settings.pop(key)
            value['Sysctls'] = settings
            temporary = path.with_suffix('.runtime.tmp')
            temporary.write_text(json.dumps(value) + '\n')
            temporary.chmod(0o600)
            temporary.replace(path)


def start(name):
    if process(name):
        return
    if name == 'docker':
        prepare_container_settings()
    with open('/var/log/' + name + '.log', 'ab') as log:
        child = subprocess.Popen(SERVICES[name], stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    (RUN / (name + '.json')).write_text(json.dumps({'pid': child.pid, 'start': Path(f'/proc/{child.pid}/stat').read_text().split()[21]}))
    socket = Path('/run/macosdocker-engine.sock' if name == 'docker' else '/run/containerd/containerd.sock')
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if child.poll() is not None:
            raise RuntimeError(name + ' exited: ' + Path('/var/log/' + name + '.log').read_text()[-8192:])
        if socket.exists():
            return
        time.sleep(0.05)
    stop(name)
    raise RuntimeError('Service startup timed out: ' + name)


def network(action):
    ready = RUN / 'network.ready'
    pidfile = Path('/run/udhcpc.eth0.pid')
    if action == 'status':
        return 0 if ready.exists() else 1
    if action == 'stop':
        if pidfile.exists():
            try:
                pid = int(pidfile.read_text())
                if b'udhcpc' in Path(f'/proc/{pid}/cmdline').read_bytes():
                    os.kill(pid, signal.SIGTERM)
            except (OSError, ValueError):
                pass
            pidfile.unlink(missing_ok=True)
        ready.unlink(missing_ok=True)
        return 0
    if ready.exists():
        return 0
    ready.unlink(missing_ok=True)
    subprocess.run(['ip', 'link', 'set', 'lo', 'up'], check=True)
    subprocess.run(['ip', 'link', 'set', 'eth0', 'up'], check=True)
    text = Path('/etc/network/interfaces').read_text()
    if 'iface eth0 inet dhcp' in text:
        subprocess.run(['udhcpc', '-i', 'eth0', '-p', str(pidfile), '-s', '/usr/local/lib/macosdocker/dhcp.sh', '-t', '20', '-T', '1', '-n'], check=True, timeout=30)
    else:
        fields = dict(line.strip().split(None, 1) for line in text.splitlines() if line.strip().startswith(('address ', 'gateway ')))
        subprocess.run(['ip', 'address', 'replace', fields['address'], 'dev', 'eth0'], check=True)
        if fields.get('gateway'):
            subprocess.run(['ip', 'route', 'replace', 'default', 'via', fields['gateway'], 'dev', 'eth0'], check=True)
    ready.touch()
    return 0


def main():
    RUN.mkdir(parents=True, exist_ok=True)
    executable = Path(sys.argv[0]).name
    if executable in ('ifup', 'ifdown'):
        name, action = 'networking', 'start' if executable == 'ifup' else 'stop'
    else:
        name, action = sys.argv[1:3]
    if name == 'networking':
        if action not in ('start', 'stop', 'status'):
            raise ValueError('Unknown networking action')
        with open(RUN / 'network.lock', 'a') as lock:
            if action == 'status':
                try:
                    fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
                except BlockingIOError:
                    return 75
            else:
                fcntl.flock(lock, fcntl.LOCK_EX)
            return network(action)
    if name not in SERVICES or action not in ('start', 'stop', 'status'):
        raise ValueError('Unknown service or action')
    with open(RUN / 'engine.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if action == 'status':
            return 0 if process(name) else 1
        (start if action == 'start' else stop)(name)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)

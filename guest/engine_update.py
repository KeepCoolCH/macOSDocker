import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import threading
import urllib.request

BASE = 'https://download.docker.com/linux/static/stable/aarch64/'
RELEASES = Path('/opt/docker/releases')
CURRENT = Path('/opt/docker/current')
BINARIES = {'docker', 'dockerd', 'containerd', 'containerd-shim-runc-v2', 'ctr', 'runc', 'docker-init', 'docker-proxy'}
LOCK = threading.Lock()
STATE = {'state': 'idle'}


def command(*args, timeout=120):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout or 'Command failed')[-8192:])
    return result.stdout.strip()


def version(value):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', value):
        raise ValueError('Invalid Docker release version')
    return tuple(map(int, value.split('.')))


def latest():
    request = urllib.request.Request(BASE, headers={'User-Agent': 'macOSDocker-updater/1'})
    with urllib.request.urlopen(request, timeout=60) as response:
        page = response.read(2 * 1024 * 1024 + 1)
    if len(page) > 2 * 1024 * 1024:
        raise ValueError('Docker release index too large')
    releases = set(re.findall(rb'href="docker-([0-9]+\.[0-9]+\.[0-9]+)\.tgz"', page))
    if not releases:
        raise RuntimeError('No stable Docker release found')
    return max((item.decode('ascii') for item in releases), key=version)


def status():
    return dict(STATE)


def check():
    if not LOCK.acquire(blocking=False):
        raise RuntimeError('Docker update already in progress')
    try:
        installed = command('docker', 'version', '--format', '{{.Server.Version}}')
        available = latest()
        updates = f'docker-engine-{installed} < {available}' if version(available) > version(installed) else ''
        return {'installed': 'docker-engine-' + installed, 'updates': updates, 'available': bool(updates)}
    finally:
        LOCK.release()


def cleanup_releases():
    active = CURRENT.resolve()
    if not RELEASES.exists():
        return
    for path in RELEASES.iterdir():
        if path.is_symlink() or not path.is_dir() or path.resolve() == active:
            continue
        if re.fullmatch(r'(?:[0-9]+\.[0-9]+\.[0-9]+(?:-[a-f0-9]{16})?|\.update-.+)', path.name):
            shutil.rmtree(path)


def stage(release):
    version(release)
    RELEASES.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix='.update-', dir=RELEASES))
    try:
        archive = temporary / 'docker.tgz'
        digest = hashlib.sha256()
        size = 0
        with urllib.request.urlopen(BASE + 'docker-' + release + '.tgz', timeout=120) as response, archive.open('wb') as output:
            while block := response.read(1024 * 1024):
                size += len(block)
                if size > 256 * 1024 * 1024:
                    raise ValueError('Docker archive too large')
                digest.update(block)
                output.write(block)
        extracted = set()
        with tarfile.open(archive, 'r:gz') as bundle:
            for member in bundle:
                name = member.name.removeprefix('./')
                if member.isdir() and name.rstrip('/') == 'docker':
                    continue
                if not member.isfile() or name not in {'docker/' + binary for binary in BINARIES} or member.size > 256 * 1024 * 1024:
                    raise ValueError('Unexpected Docker archive entry: ' + member.name)
                binary = name.split('/')[1]
                if binary in extracted:
                    raise ValueError('Duplicate Docker archive entry')
                with bundle.extractfile(member) as source, (temporary / binary).open('wb') as output:
                    shutil.copyfileobj(source, output)
                (temporary / binary).chmod(0o755)
                extracted.add(binary)
        if extracted != BINARIES:
            raise ValueError('Incomplete Docker archive')
        reported = command(str(temporary / 'dockerd'), '--version')
        if not re.search(r'\b' + re.escape(release) + r'\b', reported):
            raise ValueError('Docker archive version mismatch')
        (temporary / 'archive.sha256').write_text(digest.hexdigest() + '\n')
        archive.unlink()
        destination = RELEASES / (release + '-' + digest.hexdigest()[:16])
        if destination.exists():
            shutil.rmtree(temporary)
        else:
            temporary.rename(destination)
        return destination
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def activate(destination):
    link = CURRENT.with_name('.current-next')
    link.unlink(missing_ok=True)
    link.symlink_to(destination)
    link.replace(CURRENT)
    os.sync()


def start():
    if not LOCK.acquire(blocking=False):
        raise RuntimeError('Docker update already in progress')
    STATE.clear()
    STATE.update(state='running', message='Preparing Docker update')
    threading.Thread(target=update, daemon=True).start()
    return status()



def container_state(identifier):
    rows = command('docker', 'ps', '--all', '--no-trunc', '--format', '{{.ID}} {{.State}}').splitlines()
    matches = [fields[1] for row in rows if len(fields := row.split()) == 2 and fields[0].startswith(identifier)]
    if len(matches) > 1:
        raise RuntimeError('Ambiguous container ID: ' + identifier)
    return matches[0] if matches else None


def stop_containers(identifiers):
    active = [identifier for identifier in identifiers if container_state(identifier) in ('running', 'paused', 'restarting')]
    if not active:
        return
    try:
        command('docker', 'stop', '--time', '20', *active, timeout=180)
    except Exception:
        if any(container_state(identifier) in ('running', 'paused', 'restarting') for identifier in active):
            raise


def resume_containers(identifiers):
    for identifier in identifiers:
        state = container_state(identifier)
        if state is None or state == 'running':
            continue
        try:
            command('docker', 'start', identifier, timeout=180)
        except Exception:
            if container_state(identifier) not in (None, 'running'):
                raise


def update():
    running = []
    previous = CURRENT.resolve()
    stopped = False
    switched = False
    try:
        release = latest()
        installed = command('docker', 'version', '--format', '{{.Server.Version}}')
        if version(release) <= version(installed):
            STATE.update(state='completed', message=installed)
            return
        STATE['message'] = 'Downloading Docker release ' + release
        cleanup_releases()
        destination = stage(release)
        running = command('docker', 'ps', '-q', '--no-trunc').split()
        stopped = True
        stop_containers(running)
        command('macosdocker-service', 'docker', 'stop')
        command('macosdocker-service', 'containerd', 'stop')
        activate(destination)
        switched = True
        command('macosdocker-service', 'docker', 'start')
        command('docker', 'info')
        resume_containers(running)
        STATE.update(state='completed', message=command('docker', 'version', '--format', '{{.Server.Version}}'))
    except Exception as error:
        recovery = ''
        if stopped:
            try:
                if switched:
                    command('macosdocker-service', 'docker', 'stop')
                    command('macosdocker-service', 'containerd', 'stop')
                    activate(previous)
                command('macosdocker-service', 'docker', 'start')
                resume_containers(running)
            except Exception as failure:
                recovery = '; recovery failed: ' + str(failure)
        STATE.update(state='failed', message=str(error) + recovery)
    finally:
        LOCK.release()

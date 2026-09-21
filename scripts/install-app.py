#!/usr/bin/env python3
"""Install a verified YAVR bundle with temporary rollback."""
import argparse
import datetime
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time

NEW_ID = 'com.yavr.app'
KNOWN = {NEW_ID: 'YAVR'}


def metadata(app):
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if KNOWN.get(info.get('CFBundleIdentifier')) != info.get('CFBundleExecutable'):
        raise ValueError(f'Not a recognized YAVR installation: {app}')
    return info


def validate(app):
    info = metadata(app)
    if info['CFBundleIdentifier'] != NEW_ID:
        raise ValueError('The new bundle must use com.yavr.app')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    subprocess.run([str(app / 'Contents/MacOS/YAVR'), '--check-installation'], check=True)


def read_preferences(domain):
    result = subprocess.run(['defaults', 'export', domain, '-'], capture_output=True)
    if result.returncode != 0:
        return None
    return plistlib.loads(result.stdout)


def stop(app, executable):
    expected = str(app / 'Contents/MacOS' / executable)
    output = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True)
    pids = []
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and fields[1] == expected:
            pid = int(fields[0])
            try:
                os.kill(pid, signal.SIGTERM)
                pids.append(pid)
            except ProcessLookupError:
                pass
    deadline = time.monotonic() + 10
    for pid in pids:
        while True:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError('YAVR did not exit; close it and retry installation')
            time.sleep(0.1)


def install(source, target, backups, launch=True):
    validate(source)
    previous = metadata(target) if target.exists() else None
    backups.mkdir(parents=True, exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix=datetime.datetime.now().strftime('%Y%m%d-%H%M%S-'), dir=backups))
    # A staging directory on the target volume makes bundle replacement a rename.
    stage_root = Path(tempfile.mkdtemp(prefix='.yavr-install-', dir=target.parent))
    staged, rollback = stage_root / 'YAVR.app', stage_root / 'previous.app'
    current = read_preferences(NEW_ID)
    replaced = False
    succeeded = False
    try:
        shutil.copytree(source, staged, symlinks=True)
        validate(staged)
        if current is not None:
            (backup / 'current-preferences.plist').write_bytes(plistlib.dumps(current))
        if previous:
            stop(target, previous['CFBundleExecutable'])
        if target.exists():
            target.rename(rollback)
        staged.rename(target)
        replaced = True
        validate(target)
        if launch:
            subprocess.run(['open', str(target)], check=True)
        succeeded = True
    except Exception:
        if replaced and target.exists():
            shutil.rmtree(target)
        if rollback.exists():
            rollback.rename(target)
        if previous and launch and target.exists():
            subprocess.run(['open', str(target)], check=False)
        raise
    finally:
        # Keep rollback intact if recovery itself failed.
        if succeeded or not rollback.exists():
            shutil.rmtree(stage_root)
    print(f'Installed: {target}\nSettings backup: {backup}')
    return backup


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    args = parser.parse_args()
    install(args.source.resolve(), Path('/Applications/YAVR.app'),
            Path(__file__).resolve().parent.parent / 'dist/backups')

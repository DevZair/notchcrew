"""Install only Office's Codex hooks. Never change permission policy or hook trust."""
from __future__ import annotations

import datetime as dt
import json
import os
import shlex
import uuid
from pathlib import Path

EVENTS = ('PermissionRequest',)
DEFAULT_HOOK = Path('/Applications/NotchCrew.app/Contents/Resources/codex_hook.py')


def save(path: Path, original: bytes | None, data: dict) -> None:
    """Atomic replacement with a private backup and concurrent-edit guard."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ValueError('Refusing a symlink hook configuration')
    if original is not None:
        backup = path.with_name(f'hooks.json.office-backup-{dt.datetime.now().strftime("%Y%m%d-%H%M%S")}-{uuid.uuid4().hex[:6]}')
        with backup.open('xb') as stream:
            os.chmod(backup, 0o600)
            stream.write(original)
    temporary = path.with_name(f'.office-hooks-{uuid.uuid4().hex}.tmp')
    try:
        with temporary.open('x', encoding='utf-8') as stream:
            os.chmod(temporary, 0o600)
            json.dump(data, stream, ensure_ascii=False, indent=2)
            stream.write('\n')
        current = path.read_bytes() if path.exists() else None
        if path.is_symlink() or current != original:
            raise RuntimeError('Codex hooks changed concurrently; retry')
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def load(home: Path) -> tuple[Path, bytes | None, dict]:
    path = home / '.codex/hooks.json'
    if path.is_symlink():
        raise ValueError('Refusing a symlink hook configuration')
    original = path.read_bytes() if path.exists() else None
    data = json.loads(original) if original is not None else {}
    if not isinstance(data, dict) or not isinstance(data.get('hooks', {}), dict):
        raise ValueError('Unexpected Codex hooks format; unchanged')
    for entries in data.get('hooks', {}).values():
        if not isinstance(entries, list) or any(not isinstance(g, dict) or not isinstance(g.get('hooks', []), list)
            or any(not isinstance(h, dict) for h in g.get('hooks', [])) for g in entries):
            raise ValueError('Unexpected Codex hook handlers; unchanged')
    return path, original, data


def install(home: Path, python: str, hook: Path = DEFAULT_HOOK) -> None:
    path, original, data = load(home)
    # Imported hook modules must not create bytecode inside the signed app bundle.
    command = f'{shlex.quote(python)} -B {shlex.quote(str(hook))}'
    hooks = data.setdefault('hooks', {})
    for event in EVENTS:
        entries = hooks.setdefault(event, [])
        own = [h for g in entries for h in g.get('hooks', []) if h.get('command') == command]
        timeout = 150 if event == 'PermissionRequest' else 3
        for handler in own:
            handler['timeout'] = timeout
        if not own:
            entries.append({'matcher': '', 'hooks': [{'type': 'command', 'command': command, 'timeout': timeout,
                'statusMessage': 'Ответьте в чёлке · NotchCrew' if event == 'PermissionRequest' else 'NotchCrew · событие'}]})
    if original is not None and data == json.loads(original):
        print('Codex Office hooks already installed')
        return
    save(path, original, data)
    print('Codex Office hooks installed. Review and trust them in Codex /hooks. Permission policy unchanged.')


def uninstall(home: Path, hook: Path = DEFAULT_HOOK) -> None:
    path, original, data = load(home)
    if original is None:
        return
    for event, groups in list(data.get('hooks', {}).items()):
        remaining = []
        for group in groups:
            children = group.get('hooks', [])
            keep = [h for h in children if str(hook) not in h.get('command', '')]
            if keep or not children:
                remaining.append({**group, 'hooks': keep} if children else group)
        if remaining:
            data['hooks'][event] = remaining
        else:
            del data['hooks'][event]
    if data != json.loads(original):
        save(path, original, data)


if __name__ == '__main__':
    import sys
    if '--remove' in sys.argv:
        uninstall(Path.home())
    else:
        install(Path.home(), sys.executable)

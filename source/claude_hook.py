"""Local telemetry and human replies through the Office's private file inbox."""
from __future__ import annotations

import fcntl
import json
import os
import stat
import sys
import time
import uuid
from pathlib import Path

MAX_BYTES = 128 * 1024


def private_json(path: Path) -> dict:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > MAX_BYTES:
            raise ValueError('Unsafe inbox file')
        raw = stream.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            raise ValueError('Inbox file too large')
        value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError('Expected object')
    return value


def append_event(folder: Path, event: dict, name: str | None = None) -> None:
    allowed = ('session_id', 'hook_event_name', 'agent_id', 'agent_type', 'cwd', 'notification_type', 'agent_source', 'turn_id')
    record = {key: str(event[key])[:600] for key in allowed if isinstance(event.get(key), (str, int))}
    if name:
        record['hook_event_name'] = name
    record['ts'] = time.time()
    fd = os.open(folder / 'events.lock', os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = folder / 'events.jsonl'
        if path.exists() and path.stat().st_size > 8 * 1024 * 1024:
            path.replace(folder / 'events.previous.jsonl')
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'a', encoding='utf-8') as stream:
            stream.write(json.dumps(record, ensure_ascii=False) + '\n')


def bridge_alive(folder: Path) -> bool:
    try:
        heartbeat = private_json(folder / 'bridge-alive.json')
        return 0 <= time.time() - heartbeat['time'] < 12
    except (OSError, ValueError, KeyError, TypeError):
        return False


def protocol_reply(event: dict, answer: dict) -> dict | None:
    behavior = answer.get('behavior')
    if behavior not in {'allow', 'deny'}:
        return None  # No hook decision: the original CLI prompt remains available.
    name = event.get('hook_event_name')
    tool_input = event.get('tool_input', {})
    questions = tool_input.get('questions') if event.get('tool_name') == 'AskUserQuestion' else None
    updated = None
    if questions and behavior == 'allow':
        answers = answer.get('answers', {})
        if not isinstance(answers, dict) or any(not isinstance(answers.get(q.get('question')), str) or not answers[q['question']].strip() for q in questions):
            raise ValueError('Missing question answer')
        updated = {**tool_input, 'answers': {q['question']: answers[q['question']] for q in questions}}
    if name == 'PermissionRequest':
        decision = {'behavior': behavior}
        if behavior == 'deny':
            decision['message'] = 'Пользователь отклонил запрос в NotchCrew.'
        if updated:
            decision['updatedInput'] = updated
        return {'hookSpecificOutput': {'hookEventName': name, 'decision': decision}}
    if name == 'PreToolUse' and updated:
        return {'hookSpecificOutput': {'hookEventName': name, 'permissionDecision': 'allow', 'updatedInput': updated}}
    return None


def interactive_reply(folder: Path, event: dict, timeout: float = 120) -> dict | None:
    name = event.get('hook_event_name')
    if name != 'PermissionRequest' and not (name == 'PreToolUse' and event.get('tool_name') == 'AskUserQuestion'):
        return None
    if not bridge_alive(folder):
        return None
    tool_input = event.get('tool_input', {})
    if not isinstance(tool_input, dict):
        return None
    source = event.get('agent_source', 'Claude Code')
    if source not in {'Claude Code', 'Codex'}:
        return None
    questions = tool_input.get('questions') if event.get('tool_name') == 'AskUserQuestion' else None
    if questions is not None and (not isinstance(questions, list) or not questions or any(not isinstance(q, dict) or not isinstance(q.get('question'), str) for q in questions)):
        return None
    inbox = folder / 'requests'
    inbox.mkdir(mode=0o700, exist_ok=True)
    if inbox.is_symlink():
        raise ValueError('Unsafe inbox directory')
    ident = uuid.uuid4().hex
    request = {'id': ident, 'pid': os.getpid(), 'sessionId': str(event.get('session_id', '')),
               'source': source, 'turnId': str(event.get('turn_id', '')), 'cwd': str(event.get('cwd') or ''),
               'role': str(event.get('agent_type', '')), 'project': Path(event.get('cwd') or '').name,
               'tool': str(event.get('tool_name', '')), 'input': tool_input,
               'kind': 'question' if questions else 'permission', 'questions': questions or [],
               'createdAt': time.time(), 'expiresAt': time.time() + timeout}
    raw = json.dumps(request, ensure_ascii=False).encode('utf-8')
    if len(raw) > MAX_BYTES:
        return None  # Never approve a truncated command or tool input.
    path = inbox / f'{ident}.request.json'
    answer_path = inbox / f'{ident}.answer.json'
    # Atomic publication prevents the reader seeing a half-written question.
    temporary = inbox / f'{ident}.tmp'
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(raw)
    temporary.replace(path)
    append_event(folder, event, 'PermissionRequest')
    try:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and bridge_alive(folder):
            try:
                answer = private_json(answer_path)
            except FileNotFoundError:
                time.sleep(0.15)
                continue
            reply = protocol_reply(event, answer)
            if reply:
                append_event(folder, event, 'PreToolUse')
            return reply
        return None
    finally:
        path.unlink(missing_ok=True)
        answer_path.unlink(missing_ok=True)


def main(source: str = 'Claude Code') -> None:
    try:
        # Bound untrusted tool input; regular telemetry does not need full prompt bodies.
        raw = sys.stdin.buffer.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            return
        event = json.loads(raw)
        if not isinstance(event, dict):
            return
        event['agent_source'] = source
        folder = Path.home() / 'Library/Application Support/NotchCrew'
        folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        append_event(folder, event)
        reply = interactive_reply(folder, event)
        if reply:
            print(json.dumps(reply, ensure_ascii=False), flush=True)
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(f'Agent Office: local bridge unavailable ({type(error).__name__})', file=sys.stderr)


if __name__ == '__main__':
    main()

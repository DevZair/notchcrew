"""Add Office hooks and optional human replies; retain all existing settings."""
from __future__ import annotations

import datetime as dt
import json
import os
import shlex
from pathlib import Path

EVENTS = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "Notification", "Stop", "SubagentStart", "SubagentStop"]


def install(home: Path, python: str, hook: Path) -> None:
    settings = home / ".claude/settings.json"
    settings.parent.mkdir(parents=True, exist_ok=True)
    original = settings.read_bytes() if settings.exists() else b"{}"
    data = json.loads(original)
    if not isinstance(data, dict) or not isinstance(data.get("hooks", {}), dict):
        raise ValueError("Unexpected Claude Code settings format; no changes made")
    # Imported hook modules must not create bytecode inside the signed app bundle.
    command = f"{shlex.quote(python)} -B {shlex.quote(str(hook))}"
    hooks = data.setdefault("hooks", {})
    for event in EVENTS:
        entries = hooks.setdefault(event, [])
        if not isinstance(entries, list):
            raise ValueError(f"Unexpected {event} hooks format; no changes made")
        own = [
            h
            for entry in entries if isinstance(entry, dict)
            for h in entry.get("hooks", []) if isinstance(h, dict)
            if h.get("command") == command
        ]
        timeout = 150 if event in {"PreToolUse", "PermissionRequest"} else 3
        for h in own:
            h["timeout"] = timeout
        if not own:
            entries.append({"matcher": "", "hooks": [{"type": "command", "command": command, "timeout": timeout}]})
    if json.loads(original) == data:
        print("Observation hooks already installed")
        return
    backup = settings.with_name(f"settings.json.agent-office-backup-{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}")
    backup.write_bytes(original)
    os.chmod(backup, 0o600)
    temporary = settings.with_name(".settings-agent-office.tmp")
    try:
        with temporary.open("x", encoding="utf-8") as stream:
            os.chmod(temporary, 0o600)
            json.dump(data, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        # Do not overwrite a settings change made concurrently by the user or another tool.
        if settings.exists() and settings.read_bytes() != original:
            raise RuntimeError("Claude settings changed during installation; retry")
        temporary.replace(settings)
    finally:
        temporary.unlink(missing_ok=True)
    folder = home / "Library/Application Support/NotchCrew"
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    (folder / "events.jsonl").touch(mode=0o600, exist_ok=True)
    print(f"Installed {len(EVENTS)} observation hooks. Backup: {backup.name}")


if __name__ == "__main__":
    import sys
    install(Path.home(), sys.executable, Path("/Applications/NotchCrew.app/Contents/Resources/claude_hook.py"))

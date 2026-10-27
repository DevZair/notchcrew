"""Remove only this app's observation hooks, retaining unrelated current settings."""
from __future__ import annotations

import datetime as dt
import json
import os
from pathlib import Path


def main() -> None:
    path = Path.home() / ".claude/settings.json"
    original = path.read_bytes()
    data = json.loads(original)
    hooks = data.get("hooks", {})
    marker = "/Applications/NotchCrew.app/Contents/Resources/claude_hook.py"
    for event, entries in list(hooks.items()):
        remaining = []
        for entry in entries:
            children = entry.get("hooks", [])
            keep = [hook for hook in children if marker not in hook.get("command", "")]
            if keep or not children:
                remaining.append({**entry, "hooks": keep} if children else entry)
        if remaining:
            hooks[event] = remaining
        else:
            del hooks[event]
    if data == json.loads(original):
        print("Office hooks not found; settings unchanged")
        return
    backup = path.with_name(f"settings.json.before-office-removal-{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}")
    backup.write_bytes(original)
    os.chmod(backup, 0o600)
    temporary = path.with_name(".settings-office-removal.tmp")
    try:
        with temporary.open("x", encoding="utf-8") as stream:
            os.chmod(temporary, 0o600)
            json.dump(data, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        if path.read_bytes() != original:
            raise RuntimeError("Settings changed during removal; retry")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    print("Only Office observation hooks removed")


if __name__ == "__main__":
    main()

"""Read local agent telemetry. No sockets, API requests, or settings writes."""
from __future__ import annotations

import argparse
from contextlib import closing
import datetime as dt
import json
import math
import os
import re
import sqlite3
import sys
import time
from pathlib import Path
from claude_hook import private_json

STALE_SECONDS = 900
READ_LIMIT = 2 * 1024 * 1024


def finite_number(value: object) -> bool:
    if type(value) not in (int, float):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def valid_inbox_request(request: dict, now: float) -> bool:
    """Validate one private record before using it in native/UI decision surfaces."""
    pid = request.get("pid")
    expiry = request.get("expiresAt")
    if type(pid) is not int or not 0 < pid <= 2_147_483_647:
        return False
    if not finite_number(expiry) or expiry <= now:
        return False
    if any(not isinstance(request.get(key, ""), str) for key in ("sessionId", "role", "tool", "project")):
        return False
    if not isinstance(request.get("sessionId"), str):
        return False
    if request.get("source", "Claude Code") not in {"Claude Code", "Codex"}:
        return False
    if any(not isinstance(request.get(key, ""), str) for key in ("cwd", "turnId")):
        return False
    if request.get("source") == "Codex" and request.get("kind") != "permission":
        return False
    tool_input = request.get("input")
    if not isinstance(tool_input, dict) or not isinstance(tool_input.get("command", ""), str):
        return False
    try:
        json.dumps(tool_input, allow_nan=False)
    except (ValueError, RecursionError):
        return False
    created = request.get("createdAt", 0)
    if not finite_number(created) or not 0 <= created < expiry:
        return False
    kind, questions = request.get("kind"), request.get("questions", [])
    if kind == "permission":
        return questions == []
    if kind != "question" or not isinstance(questions, list) or not questions:
        return False
    if request.get("tool", "AskUserQuestion") != "AskUserQuestion" or tool_input.get("questions") != questions:
        return False
    texts = set()
    for question in questions:
        if not isinstance(question, dict):
            return False
        text = question.get("question")
        if not isinstance(text, str) or not text.strip() or text in texts:
            return False
        texts.add(text)
        if type(question.get("multiSelect", False)) is not bool or not isinstance(question.get("options", []), list):
            return False
        labels = set()
        for option in question.get("options", []):
            if not isinstance(option, dict):
                return False
            label = option.get("label")
            if not isinstance(label, str) or not label.strip() or label in labels or not isinstance(option.get("description", ""), str):
                return False
            labels.add(label)
    return True
GROUPS = [
    ("Планирование", "mint", ["architect", "code-architect", "planner", "gan-planner", "type-design-analyzer", "code-explorer", "docs-lookup", "chief-of-staff"]),
    ("Разработка", "blue", ["build-error-resolver", "cpp-build-resolver", "csharp-reviewer", "dart-build-resolver", "go-build-resolver", "java-build-resolver", "kotlin-build-resolver", "rust-build-resolver"]),
    ("Ревью кода", "lavender", ["code-reviewer", "typescript-reviewer", "python-reviewer", "cpp-reviewer", "go-reviewer", "java-reviewer", "kotlin-reviewer", "rust-reviewer"]),
    ("Качество", "peach", ["a11y-architect", "tdd-guide", "e2e-runner", "pr-test-analyzer", "gan-evaluator", "silent-failure-hunter", "comment-analyzer", "flutter-reviewer"]),
    ("Системы и данные", "lime", ["database-reviewer", "security-reviewer", "performance-optimizer", "healthcare-reviewer", "pytorch-build-resolver", "seo-specialist", "harness-optimizer", "loop-operator"]),
    ("Выпуск", "rose", ["gan-generator", "code-simplifier", "refactor-cleaner", "doc-updater", "opensource-forker", "opensource-packager", "opensource-sanitizer", "conversation-analyzer"]),
]
LABELS = {
    "architect": "Архитектор", "code-architect": "Архитектор кода", "planner": "Планировщик",
    "gan-planner": "Продуктовый план", "type-design-analyzer": "Дизайн типов", "code-explorer": "Исследователь",
    "docs-lookup": "Документация", "chief-of-staff": "Координатор",
    "build-error-resolver": "Сборка · JS", "cpp-build-resolver": "Сборка · C++", "csharp-reviewer": "C# / .NET",
    "dart-build-resolver": "Сборка · Dart", "go-build-resolver": "Сборка · Go", "java-build-resolver": "Сборка · Java",
    "kotlin-build-resolver": "Сборка · Kotlin", "rust-build-resolver": "Сборка · Rust",
    "code-reviewer": "Ревьюер", "typescript-reviewer": "TypeScript", "python-reviewer": "Python",
    "cpp-reviewer": "C++", "go-reviewer": "Go", "java-reviewer": "Java", "kotlin-reviewer": "Kotlin", "rust-reviewer": "Rust",
    "a11y-architect": "Доступность", "tdd-guide": "TDD", "e2e-runner": "E2E-тесты", "pr-test-analyzer": "Тесты PR",
    "gan-evaluator": "Оценка продукта", "silent-failure-hunter": "Поиск ошибок", "comment-analyzer": "Комментарии",
    "flutter-reviewer": "Flutter", "database-reviewer": "Базы данных", "security-reviewer": "Безопасность",
    "performance-optimizer": "Быстродействие", "healthcare-reviewer": "Медицина", "pytorch-build-resolver": "PyTorch",
    "seo-specialist": "SEO", "harness-optimizer": "Среда агентов", "loop-operator": "Оператор циклов",
    "gan-generator": "Создатель продукта", "code-simplifier": "Упрощение кода", "refactor-cleaner": "Рефакторинг",
    "doc-updater": "Технический писатель", "opensource-forker": "Open source · fork",
    "opensource-packager": "Упаковка релиза", "opensource-sanitizer": "Проверка релиза", "conversation-analyzer": "Анализ диалогов",
}


def timestamp(value: object) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        except ValueError:
            return 0
    return 0


def objects(raw: bytes) -> list[dict]:
    result = []
    for line in raw.splitlines():
        try:
            obj = json.loads(line)
        except (ValueError, UnicodeDecodeError):
            continue  # A live JSONL file may end in an incomplete write.
        if isinstance(obj, dict):
            result.append(obj)
    return result


class Journal:
    """Bounded incremental JSONL reader; incomplete writes remain for the next poll."""

    def __init__(self) -> None:
        self.offsets: dict[Path, tuple[int, int]] = {}

    def read(self, path: Path) -> tuple[list[dict], bool]:
        stat = path.stat()
        previous, inode = self.offsets.get(path, (0, stat.st_ino))
        reset = previous > stat.st_size or inode != stat.st_ino
        if reset:
            previous = 0
        start = max(previous, stat.st_size - READ_LIMIT)
        with path.open("rb") as stream:
            stream.seek(start)
            if start > previous:
                stream.readline()  # Drop the partial first record of a bounded tail.
            raw = stream.read(READ_LIMIT)
            end = stream.tell()
        newline = raw.rfind(b"\n")
        if newline < 0:
            return [], reset
        consumed = newline + 1
        self.offsets[path] = (end - len(raw) + consumed, stat.st_ino)
        return objects(raw[:consumed]), reset


class Collector:
    def __init__(self, home: Path) -> None:
        self.home = home
        self.journal = Journal()
        self.sessions: dict[str, dict] = {}
        self.codex_meta: dict[Path, dict] = {}
        self.claude: dict[str, dict] = {}
        self.warnings: list[str] = []
        self.roster = self.load_roster()
        self.roster_warnings = list(self.warnings)

    def load_roster(self) -> list[dict]:
        found: dict[str, dict] = {}
        for provider, folder, suffix in [
            ("Codex", self.home / ".codex/agents", "*.toml"),
            ("Claude Code", self.home / ".claude/agents", "*.md"),
        ]:
            if not folder.is_dir():
                self.warnings.append(f"Нет каталога ролей {provider}")
                continue
            for file in sorted(folder.glob(suffix)):
                role = file.stem
                try:
                    text = file.read_text(encoding="utf-8")
                except (OSError, UnicodeError) as error:
                    self.warnings.append(f"Не удалось прочитать роль {role}: {error.strerror if isinstance(error, OSError) else 'кодировка'}")
                    continue
                match = re.search(r'^description\s*=\s*"([^"\n]*)"', text, re.M)
                if not match:
                    match = re.search(r'^description:\s*(.+)$', text, re.M)
                entry = found.setdefault(role, {"id": role, "label": LABELS.get(role, role), "providers": [], "description": ""})
                entry["providers"].append(provider)
                if match:
                    entry["description"] = match[1].strip('"')
        ordered = []
        for index, (name, color, roles) in enumerate(GROUPS):
            for role in roles:
                if role in found:
                    ordered.append({**found.pop(role), "department": name, "room": index, "color": color})
        ordered.extend({**value, "department": "Другие", "room": 6, "color": "mint"} for value in found.values())
        return ordered

    def codex(self, now: float) -> bool:
        root = self.home / ".codex/sessions"
        if not root.is_dir():
            self.warnings.append("Журналы Codex недоступны")
            return False
        try:
            paths = set(root.rglob("*.jsonl"))
            for old in set(self.codex_meta) - paths:
                meta = self.codex_meta.pop(old)
                self.sessions.pop(meta.get("id", str(old)), None)
                self.journal.offsets.pop(old, None)
            for path in paths:
                self.read_codex(path, now)
        except OSError as error:
            self.warnings.append(f"Ошибка чтения Codex: {error.strerror}")
            return False
        return True

    def read_codex(self, path: Path, now: float) -> None:
        records, reset = self.journal.read(path)
        if path not in self.codex_meta or reset:
            with path.open("rb") as stream:
                first = objects(stream.readline(READ_LIMIT))
            meta = first[0].get("payload", {}) if first else {}
            self.codex_meta[path] = meta
            source = meta.get("source", {})
            spawn = source.get("subagent", {}).get("thread_spawn", {}) if isinstance(source, dict) else {}
            key = meta.get("id", str(path))
            self.sessions[key] = {
                "sessionId": key,
                "role": meta.get("agent_role") or spawn.get("agent_role"), "source": "Codex",
                "project": Path(meta.get("cwd", "")).name, "state": "resting", "time": 0,
                "kind": "subagent" if isinstance(source, dict) else "main",
                "nickname": meta.get("agent_nickname") or spawn.get("agent_nickname", ""),
                "pending": {},
            }
        meta = self.codex_meta[path]
        session = self.sessions[meta.get("id", str(path))]
        for record in records:
            when = timestamp(record.get("timestamp"))
            if record.get("type") == "response_item":
                self.codex_call(session, record.get("payload", {}), when)
                continue
            if record.get("type") != "event_msg":
                continue
            event = record.get("payload", {}).get("type")
            if event in {"task_complete", "turn_aborted", "turn_paused"}:
                session.update(state="resting", time=when)
                session["pending"].clear()
            elif event in {"task_started", "token_count", "item_completed"}:
                session.update(state="waiting" if session["pending"] else "working", time=when)
            elif event in {"approval_request", "permission_request"}:
                session.update(state="waiting", time=when)
            elif event in {"approval_response", "permission_response"}:
                session.update(state="working", time=when)
        session["status"] = self.fresh_status(session, now)

    @staticmethod
    def codex_call(session: dict, payload: dict, when: float) -> None:
        if payload.get("type") == "function_call":
            try:
                args = json.loads(payload.get("arguments", "{}"))
            except (ValueError, TypeError):
                return
            if isinstance(args, dict) and args.get("sandbox_permissions") == "require_escalated":
                session["pending"][str(payload.get("call_id"))] = {
                    "tool": str(payload.get("name", "")),
                    "command": str(args.get("justification") or "Агент ожидает разрешения в исходном чате."),
                }
                session.update(state="waiting", time=when)
        elif payload.get("type") == "function_call_output":
            pending = session["pending"]
            if pending.pop(str(payload.get("call_id")), None):
                session.update(state="waiting" if pending else "working", time=when)

    @staticmethod
    def fresh_status(session: dict, now: float) -> str:
        if session["state"] != "resting" and (not session["time"] or now - session["time"] > STALE_SECONDS):
            return "unknown"
        return session["state"]

    def claude_events(self, now: float) -> bool:
        path = self.home / "Library/Application Support/NotchCrew/events.jsonl"
        if not path.is_file():
            self.warnings.append("Нет событий Claude Code: начните новую сессию после установки офиса")
            return False
        try:
            records, reset = self.journal.read(path)
            if reset:
                self.claude.clear()
            for event in records:
                self.apply_claude(event)
        except OSError as error:
            self.warnings.append(f"Ошибка чтения событий Claude Code: {error.strerror}")
            return False
        for session in self.claude.values():
            session["status"] = self.fresh_status(session, now)
        return True

    def apply_claude(self, event: dict) -> None:
        if event.get("agent_source", "Claude Code") != "Claude Code":
            return
        name = event.get("hook_event_name", "")
        parent = str(event.get("session_id", ""))
        if not parent:
            return
        when = timestamp(event.get("ts") or event.get("timestamp"))
        agent = event.get("agent_id")
        key = f"{parent}:{agent}" if agent else parent
        session = self.claude.setdefault(key, {
            "sessionId": parent,
            "role": event.get("agent_type"), "source": "Claude Code", "project": "",
            "state": "resting", "time": when, "parent": parent, "kind": "subagent" if agent else "main",
        })
        session["project"] = Path(event.get("cwd") or session.get("project") or "").name
        if event.get("agent_type"):
            session["role"] = event["agent_type"]
        active = {"SubagentStart", "PreToolUse", "PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "TaskCreated"}
        if name in active:
            session.update(state="working", time=when)
        elif name == "PermissionRequest" or (name == "Notification" and event.get("notification_type") == "permission_prompt"):
            session.update(state="waiting", time=when)
        elif name in {"SubagentStop", "Stop", "SessionEnd", "StopFailure"}:
            session.update(state="resting", time=when)
            # A parent may finish its turn while background specialists keep working.
            if not agent and name == "SessionEnd":
                for child in self.claude.values():
                    if child.get("parent") == parent:
                        child.update(state="resting", time=when)

    def pending_requests(self, sessions: list[dict], now: float) -> list[dict]:
        result = []
        inbox = self.home / "Library/Application Support/NotchCrew/requests"
        if not inbox.is_symlink():
            for path in sorted(inbox.glob("*.request.json"))[:100]:
                try:
                    request = private_json(path)
                    ident = request["id"]
                    if not isinstance(ident, str) or not re.fullmatch(r"[a-f0-9]{32}", ident) or path.name != f"{ident}.request.json":
                        continue
                    if not valid_inbox_request(request, now) or (inbox / f"{ident}.answer.json").exists():
                        continue
                    pid = request["pid"]
                    os.kill(pid, 0)
                    tool_input = request.get("input", {})
                    public = {k: request[k] for k in ("id", "pid", "sessionId", "source", "turnId", "cwd", "role", "project", "tool", "input", "kind", "questions", "createdAt", "expiresAt") if k in request}
                    source = request.get("source", "Claude Code")
                    matched = next((s for s in sessions if s.get("sessionId") == request["sessionId"] and s.get("source") == source), {})
                    role = request.get("role") or matched.get("role")
                    result.append({**public, "source": source, "interactive": True,
                                   "command": str(tool_input.get("command", "")),
                                   "label": LABELS.get(role, role or source)})
                except (OSError, ValueError, KeyError, TypeError, RecursionError):
                    continue
        interactive_sessions = {(r["source"], r["sessionId"]) for r in result if r["sessionId"]}
        for session in sessions:
            if session.get("status") != "waiting" or (session.get("source"), session.get("sessionId")) in interactive_sessions:
                continue
            pending = session.get("pending") or {"waiting": {}}
            for call_id, details in pending.items():
                result.append({"id": f'{session.get("sessionId", "")}-{call_id}',
                               "sessionId": session.get("sessionId", ""), "source": session["source"],
                               "label": LABELS.get(session.get("role"), session.get("role") or "Общая сессия"),
                               "project": session["project"], "interactive": False,
                               "kind": "permission", "tool": details.get("tool", ""), "command": details.get("command", "")})
        return result

    def thread_titles(self, sessions: list[dict]) -> dict[str, str]:
        """Optional titles from the local Codex index; session logs remain authoritative."""
        ids = [s.get("sessionId") for s in sessions if s.get("source") == "Codex" and isinstance(s.get("sessionId"), str)][:64]
        if not ids:
            return {}
        databases = sorted((p for p in (self.home / ".codex").glob("state_*.sqlite") if p.stem.removeprefix("state_").isdigit()), key=lambda p: int(p.stem.removeprefix("state_")), reverse=True)
        for database in databases:
            try:
                with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=0.1)) as connection:
                    placeholders = ",".join("?" for _ in ids)
                    columns = {row[1] for row in connection.execute("PRAGMA table_info(threads)")}
                    title_column = "COALESCE(NULLIF(TRIM(name), ''), title)" if "name" in columns else "title"
                    rows = connection.execute(f"SELECT id,{title_column} FROM threads WHERE id IN ({placeholders})", ids)
                    return {identifier: title[:256] for identifier, title in rows if isinstance(title, str) and title.strip()}
            except (OSError, sqlite3.Error, ValueError):
                continue
        return {}

    def snapshot(self, now: float | None = None) -> dict:
        now = now if now is not None else time.time()
        self.warnings = list(self.roster_warnings)
        codex_ok = self.codex(now)
        claude_ok = self.claude_events(now)
        sessions = list(self.sessions.values()) + list(self.claude.values())
        sources = {"Codex": codex_ok, "Claude Code": claude_ok}
        for session in sessions:
            if not sources[session["source"]]:
                session["status"] = "unknown"
        agents = []
        priorities = {"resting": 0, "unknown": 1, "working": 2, "waiting": 3}
        known = {entry["id"] for entry in self.roster}
        for role in self.roster:
            attached = [s for s in sessions if s.get("role") == role["id"]]
            live = [s for s in attached if s.get("status") != "resting"]
            latest = max(attached, key=lambda s: s["time"], default=None)
            status = max((s["status"] for s in attached), key=priorities.get, default="resting")
            if status == "resting" and any(not sources[p] for p in role["providers"]):
                status = "unknown"
            # Expose only metadata used by the UI; no commands, prompts or full paths.
            public = {k: v for k, v in latest.items() if k in {"role", "source", "project", "state", "time", "status", "nickname"}} if latest else None
            agents.append({**role, "status": status, "instances": len(live), "latest": public})
        general = [s for s in sessions if s.get("role") not in known and s.get("status") != "resting"]
        general_working = sum(s["status"] == "working" for s in general)
        general_waiting = sum(s["status"] == "waiting" for s in general)
        general = sorted(general, key=lambda s: s["time"], reverse=True)[:12]
        titles = self.thread_titles(general)
        return {
            "agents": agents, "updatedAt": now, "warnings": self.warnings,
            "sources": sources,
            "requests": self.pending_requests(sessions, now),
            "activity": {"generalWorking": general_working,
                         "generalWaiting": general_waiting},
            "general": [{**{k: s[k] for k in ("sessionId", "source", "project", "status", "time", "kind")}, "title": titles.get(s.get("sessionId"), s.get("project", "")) if s.get("source") == "Codex" else s.get("project", "")} for s in general],
        }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    collector = Collector(args.home)
    folder = args.home / "Library/Application Support/NotchCrew"
    while True:
        try:
            if not args.once:
                folder.mkdir(parents=True, exist_ok=True, mode=0o700)
                heartbeat = folder / f".bridge-{os.getpid()}.tmp"
                fd = os.open(heartbeat, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, "w") as stream:
                    json.dump({"time": time.time()}, stream)
                heartbeat.replace(folder / "bridge-alive.json")
            print(json.dumps(collector.snapshot(), ensure_ascii=False), flush=True)
        except BrokenPipeError:
            return
        if args.once:
            return
        time.sleep(3)


if __name__ == "__main__":
    main()

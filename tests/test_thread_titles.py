"""Read-only Codex title lookup checks using isolated local databases."""
from __future__ import annotations

import importlib.util
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SOURCE = Path(__file__).parents[1] / "source"
sys.path.insert(0, str(SOURCE))
SPEC = importlib.util.spec_from_file_location("title_collector", SOURCE / "collector.py")
collector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(collector)
NOW = 1793110000.0


class ThreadTitleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="office titles #")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        (self.home / ".codex/agents").mkdir(parents=True)
        self.sessions = self.home / ".codex/sessions"
        self.sessions.mkdir()
        self.events = self.home / "Library/Application Support/NotchCrew/events.jsonl"
        self.events.parent.mkdir(parents=True)
        self.events.touch()
        self.reader = collector.Collector(self.home)

    def database(self, version: int, rows: list[tuple[str, object]]) -> Path:
        path = self.home / f".codex/state_{version}.sqlite"
        connection = sqlite3.connect(path)
        try:
            connection.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT)")
            connection.executemany("INSERT INTO threads VALUES (?, ?)", rows)
            connection.commit()
        finally:
            connection.close()
        return path

    @staticmethod
    def session(identifier: str, source: str = "Codex") -> dict:
        return {"sessionId": identifier, "source": source}

    def codex_session(self, identifier: str, when: float = NOW) -> None:
        records = [
            {"type": "session_meta", "payload": {"id": identifier, "source": "vscode", "cwd": "/local/project"}},
            {"type": "event_msg", "timestamp": when, "payload": {"type": "task_started"}},
        ]
        (self.sessions / f"{identifier}.jsonl").write_text(
            "".join(json.dumps(record) + "\n" for record in records)
        )

    def test_titles_are_bounded_filtered_and_queries_parameterized(self) -> None:
        injected = "id') OR 1=1; DROP TABLE threads; --"
        self.database(1, [(injected, "Задача"), ("long", "a" * 300),
                          ("blank", " \n"), ("null", None), ("unrelated", "private")])
        result = self.reader.thread_titles([
            self.session(injected), self.session("long"), self.session("blank"),
            self.session("null"), self.session("unrelated", "Claude Code"),
        ])
        self.assertEqual(result, {injected: "Задача", "long": "a" * 256})

    def test_no_codex_sessions_skip_database_open(self) -> None:
        with patch.object(collector.sqlite3, "connect") as connect:
            self.assertEqual(self.reader.thread_titles([self.session("a", "Claude Code")]), {})
        connect.assert_not_called()

    def test_read_only_uri_handles_spaces_and_hash_in_local_path(self) -> None:
        self.database(1, [("a", "A")])
        original = sqlite3.connect
        calls = []

        def connect(database_uri: str, **kwargs):
            calls.append((database_uri, kwargs))
            return original(database_uri, **kwargs)

        with patch.object(collector.sqlite3, "connect", side_effect=connect):
            self.assertEqual(self.reader.thread_titles([self.session("a")]), {"a": "A"})
        self.assertEqual(len(calls), 1)
        self.assertIn("%23", calls[0][0])
        self.assertTrue(calls[0][0].endswith("?mode=ro"))
        self.assertEqual(calls[0][1], {"uri": True, "timeout": 0.1})

    def test_corrupt_index_is_optional_and_older_valid_index_still_works(self) -> None:
        self.database(1, [("a", "A")])
        (self.home / ".codex/state_2.sqlite").write_bytes(b"not a database")
        self.assertEqual(self.reader.thread_titles([self.session("a")]), {"a": "A"})

    def test_input_lookup_is_limited_to_64_ids(self) -> None:
        self.database(1, [(str(i), str(i)) for i in range(70)])
        result = self.reader.thread_titles([self.session(str(i)) for i in range(70)])
        self.assertEqual(set(result), {str(i) for i in range(64)})

    def test_latest_numeric_schema_version_wins(self) -> None:
        self.database(9, [("a", "Old")])
        self.database(10, [("a", "Current")])
        self.assertEqual(self.reader.thread_titles([self.session("a")]), {"a": "Current"})

    def test_chat_name_is_preferred_and_empty_names_fall_back_to_title(self) -> None:
        path = self.database(1, [
            ("named", "Original prompt"), ("empty", "Empty fallback"),
            ("spaces", "Spaces fallback"), ("null", "Null fallback"),
        ])
        connection = sqlite3.connect(path)
        try:
            connection.execute("ALTER TABLE threads ADD COLUMN name TEXT")
            connection.executemany("UPDATE threads SET name = ? WHERE id = ?", [
                ("  Переименованный чат  ", "named"), ("", "empty"),
                ("   ", "spaces"), (None, "null"),
            ])
            connection.commit()
        finally:
            connection.close()
        result = self.reader.thread_titles([
            self.session(identifier) for identifier in ("named", "empty", "spaces", "null")
        ])
        self.assertEqual(result, {
            "named": "Переименованный чат", "empty": "Empty fallback",
            "spaces": "Spaces fallback", "null": "Null fallback",
        })

    def test_database_connection_is_closed_before_lookup_returns(self) -> None:
        self.database(1, [("a", "A")])
        original = sqlite3.connect
        connections = []

        class TrackingConnection(sqlite3.Connection):
            closed = False

            def close(self) -> None:
                self.closed = True
                super().close()

        def connect(database_uri: str, **kwargs):
            connection = original(database_uri, factory=TrackingConnection, **kwargs)
            connections.append(connection)
            return connection

        try:
            with patch.object(collector.sqlite3, "connect", side_effect=connect):
                self.assertEqual(self.reader.thread_titles([self.session("a")]), {"a": "A"})
            self.assertTrue(all(connection.closed for connection in connections))
        finally:
            for connection in connections:
                connection.close()

    def test_title_does_not_cross_provider_when_session_ids_collide(self) -> None:
        self.database(1, [("shared", "Codex title")])
        self.codex_session("shared")
        self.events.write_text(json.dumps({
            "session_id": "shared", "hook_event_name": "UserPromptSubmit",
            "cwd": "/local/Claude project", "ts": NOW,
        }) + "\n")
        sessions = {s["source"]: s for s in self.reader.snapshot(NOW)["general"]}
        self.assertEqual(sessions["Codex"]["title"], "Codex title")
        self.assertEqual(sessions["Claude Code"]["title"], "Claude project")

    def test_counts_cover_more_than_the_12_display_rows_and_stale_is_not_working(self) -> None:
        self.database(1, [(f"session-{i}", f"Task {i}") for i in range(16)])
        for index in range(15):
            self.codex_session(f"session-{index}", NOW - index)
        self.codex_session("session-15", NOW - collector.STALE_SECONDS - 1)
        snapshot = self.reader.snapshot(NOW)
        self.assertEqual(snapshot["activity"], {"generalWorking": 15, "generalWaiting": 0})
        self.assertEqual(len(snapshot["general"]), 12)
        self.assertEqual(snapshot["general"][0]["title"], "Task 0")


if __name__ == "__main__":
    unittest.main()

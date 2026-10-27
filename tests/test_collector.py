"""Behavior checks on isolated telemetry fixtures, never the user's real sessions."""
from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parents[1] / "source"))

SPEC = importlib.util.spec_from_file_location("collector", Path(__file__).parents[1] / "source/collector.py")
collector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(collector)
NOW = 1793110000.0


class StatusTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.roles = self.home / ".codex/agents"
        self.roles.mkdir(parents=True)
        for _, _, roles in collector.GROUPS:
            for role in roles:
                (self.roles / f"{role}.toml").write_text(f'name = "{role}"\ndescription = "Test role"\n')
        self.sessions = self.home / ".codex/sessions"
        self.sessions.mkdir()
        self.events = self.home / "Library/Application Support/NotchCrew/events.jsonl"
        self.events.parent.mkdir(parents=True)
        self.events.touch()
        self.reader = collector.Collector(self.home)

    def write(self, path, records, append=False):
        with path.open("a" if append else "w") as stream:
            for record in records:
                stream.write(json.dumps(record) + "\n")

    def codex(self, role="architect", state="task_started", name="session", when=NOW):
        path = self.sessions / f"{name}.jsonl"
        self.write(path, [
            {"type": "session_meta", "payload": {"id": name, "source": {"subagent": {"thread_spawn": {"agent_role": role}}}, "cwd": "/local/project"}},
            {"type": "event_msg", "timestamp": when, "payload": {"type": state}},
        ])
        return path

    def agent(self, role="architect", now=NOW):
        snapshot = self.reader.snapshot(now)
        return next(a for a in snapshot["agents"] if a["id"] == role)

    def test_live_request_visible_until_answer_or_expiry(self):
        inbox = self.events.parent / 'requests'
        inbox.mkdir(mode=0o700)
        ident = 'a' * 32
        request = {'id': ident, 'pid': os.getpid(), 'sessionId': 'fixture',
                   'role': 'planner', 'kind': 'question', 'questions': [{'question': 'Цвет?'}],
                   'expiresAt': NOW + 30, 'input': {'questions': [{'question': 'Цвет?'}]}}
        path = inbox / f'{ident}.request.json'
        path.write_text(json.dumps(request))
        path.chmod(0o600)
        first = self.reader.snapshot(NOW)['requests']
        self.assertEqual(len(first), 1)
        self.assertTrue(first[0]['interactive'])
        self.assertEqual(first[0]['label'], 'Планировщик')
        self.assertEqual(self.reader.snapshot(NOW + 31)['requests'], [])
        (inbox / f'{ident}.answer.json').write_text('{"behavior":"ask"}')
        self.assertEqual(self.reader.snapshot(NOW)['requests'], [])

    def test_other_apps_events_are_not_read(self):
        self.events.unlink()
        unrelated = self.home / "Library/Application Support/Lumio/agent-events.jsonl"
        unrelated.parent.mkdir(parents=True)
        self.write(unrelated, [{"session_id": "other-app", "agent_type": "architect",
                                "hook_event_name": "SubagentStart", "ts": NOW}])
        snapshot = self.reader.snapshot(NOW)
        self.assertFalse(snapshot["sources"]["Claude Code"])
        self.assertEqual(self.reader.claude, {})
        self.assertFalse(any(agent["status"] == "working" for agent in snapshot["agents"]))

    def test_fresh_home_has_no_fabricated_agents_or_activity(self):
        with tempfile.TemporaryDirectory() as clean_home:
            snapshot = collector.Collector(Path(clean_home)).snapshot(NOW)
        self.assertEqual(snapshot["agents"], [])
        self.assertEqual(snapshot["general"], [])
        self.assertEqual(snapshot["activity"], {"generalWorking": 0, "generalWaiting": 0})
        self.assertTrue(snapshot["warnings"])

    def test_all_48_stay_visible_when_no_tasks(self):
        snapshot = self.reader.snapshot(NOW)
        self.assertEqual(len(snapshot["agents"]), 48)
        self.assertTrue(all(a["status"] == "resting" for a in snapshot["agents"]))

    def test_codex_works_then_rests_without_removing_person(self):
        path = self.codex()
        self.assertEqual(self.agent()["status"], "working")
        self.write(path, [{"type": "event_msg", "timestamp": NOW + 1, "payload": {"type": "task_complete"}}], append=True)
        self.assertEqual(self.agent(now=NOW + 2)["status"], "resting")
        self.assertEqual(len(self.reader.snapshot(NOW + 2)["agents"]), 48)

    def test_stale_active_session_is_unknown(self):
        self.codex(when=NOW - 901)
        self.assertEqual(self.agent()["status"], "unknown")

    def test_healthy_status_returns_after_new_activity(self):
        path = self.codex(when=NOW - 1000)
        self.assertEqual(self.agent()["status"], "unknown")
        self.write(path, [{"type": "event_msg", "timestamp": NOW, "payload": {"type": "item_completed"}}], append=True)
        self.assertEqual(self.agent()["status"], "working")

    def test_codex_approval_waits_until_matching_output(self):
        path = self.codex()
        self.write(path, [{"type": "response_item", "timestamp": NOW, "payload": {"type": "function_call", "call_id": "approval", "arguments": '{"sandbox_permissions":"require_escalated"}'}}], append=True)
        self.assertEqual(self.agent()["status"], "waiting")
        self.write(path, [{"type": "response_item", "timestamp": NOW, "payload": {"type": "function_call_output", "call_id": "other"}}], append=True)
        self.assertEqual(self.agent()["status"], "waiting")
        self.write(path, [{"type": "response_item", "timestamp": NOW, "payload": {"type": "function_call_output", "call_id": "approval"}}], append=True)
        self.assertEqual(self.agent()["status"], "working")

    def test_claude_start_permission_resume_stop(self):
        base = {"session_id": "parent", "agent_id": "child", "agent_type": "architect", "ts": NOW}
        for event, expected in [("SubagentStart", "working"), ("PermissionRequest", "waiting"), ("PostToolUse", "working"), ("SubagentStop", "resting")]:
            self.write(self.events, [{**base, "hook_event_name": event}], append=True)
            self.assertEqual(self.agent()["status"], expected)

    def test_multiple_instances_keep_role_working(self):
        first = self.codex(name="one")
        self.codex(name="two")
        self.assertEqual(self.agent()["instances"], 2)
        self.write(first, [{"type": "event_msg", "timestamp": NOW, "payload": {"type": "task_complete"}}], append=True)
        self.assertEqual(self.agent()["status"], "working")
        self.assertEqual(self.agent()["instances"], 1)

    def test_parent_turn_stop_does_not_stop_background_specialist(self):
        self.write(self.events, [
            {"session_id": "p", "agent_id": "c", "agent_type": "architect", "hook_event_name": "SubagentStart", "ts": NOW},
            {"session_id": "p", "hook_event_name": "Stop", "ts": NOW},
        ])
        self.assertEqual(self.agent()["status"], "working")
        self.write(self.events, [{"session_id": "p", "hook_event_name": "SessionEnd", "ts": NOW}], append=True)
        self.assertEqual(self.agent()["status"], "resting")

    def test_main_chat_does_not_impersonate_specialist(self):
        path = self.sessions / "main.jsonl"
        self.write(path, [{"type": "session_meta", "payload": {"id": "main", "source": "vscode"}}, {"type": "event_msg", "timestamp": NOW, "payload": {"type": "task_started"}}])
        snapshot = self.reader.snapshot(NOW)
        self.assertEqual(len(snapshot["general"]), 1)
        self.assertEqual(self.agent()["status"], "resting")
        self.assertEqual(snapshot["activity"]["generalWorking"], 1)
        self.assertEqual(snapshot["general"][0]["sessionId"], "main")
        self.write(path, [{"type": "event_msg", "timestamp": NOW + 1, "payload": {"type": "task_complete"}}], append=True)
        self.assertEqual(self.reader.snapshot(NOW + 2)["activity"]["generalWorking"], 0)

    def test_general_counts_include_all_live_chats_without_counting_specialists_twice(self):
        self.codex(role="architect", name="specialist")
        for i in range(15):
            self.write(self.sessions / f"main-{i}.jsonl", [
                {"type": "session_meta", "payload": {"id": f"main-{i}", "source": "vscode"}},
                {"type": "event_msg", "timestamp": NOW, "payload": {"type": "task_started"}},
            ])
        stale = self.sessions / "stale-main.jsonl"
        self.write(stale, [{"type": "session_meta", "payload": {"id": "stale", "source": "cli"}},
                          {"type": "event_msg", "timestamp": NOW - 901, "payload": {"type": "task_started"}}])
        snapshot = self.reader.snapshot(NOW)
        self.assertEqual(snapshot["activity"], {"generalWorking": 15, "generalWaiting": 0})
        self.assertEqual(len(snapshot["general"]), 12)  # Presentation limit does not cap the counter.
        self.assertNotIn("specialist", [s["sessionId"] for s in snapshot["general"]])

    def test_unmapped_worker_is_still_a_real_active_agent(self):
        self.codex(role="worker", name="runtime-worker")
        snapshot = self.reader.snapshot(NOW)
        self.assertEqual(snapshot["activity"]["generalWorking"], 1)
        self.assertEqual(snapshot["general"][0]["kind"], "subagent")
        self.assertTrue(all(a["status"] == "resting" for a in snapshot["agents"]))

    def test_partial_line_waits_for_remainder(self):
        path = self.codex()
        self.assertEqual(self.agent()["status"], "working")
        event = json.dumps({"type": "event_msg", "timestamp": NOW, "payload": {"type": "task_complete"}})
        with path.open("a") as stream:
            stream.write(event[:20])
        self.assertEqual(self.agent()["status"], "working")
        with path.open("a") as stream:
            stream.write(event[20:] + "\n")
        self.assertEqual(self.agent()["status"], "resting")

    def test_rotation_resets_session_state(self):
        path = self.codex()
        self.assertEqual(self.agent()["status"], "working")
        path.unlink()
        self.codex(state="task_complete")
        self.assertEqual(self.agent()["status"], "resting")

    def test_unavailable_source_is_never_reported_idle(self):
        self.sessions.rmdir()
        snapshot = self.reader.snapshot(NOW)
        self.assertFalse(snapshot["sources"]["Codex"])
        self.assertTrue(all(a["status"] == "unknown" for a in snapshot["agents"]))

    def test_raw_commands_and_prompts_are_not_exposed(self):
        self.codex()
        self.write(self.events, [{"session_id": "p", "agent_id": "c", "agent_type": "architect", "ts": NOW, "hook_event_name": "SubagentStart", "prompt": "PRIVATE_PROMPT", "tool_input": {"command": "PRIVATE_COMMAND"}}])
        output = json.dumps(self.reader.snapshot(NOW))
        self.assertNotIn("PRIVATE_PROMPT", output)
        self.assertNotIn("PRIVATE_COMMAND", output)
        self.assertNotIn("pending", output)


if __name__ == "__main__":
    unittest.main()

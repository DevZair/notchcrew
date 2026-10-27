import importlib.util
import json
import shlex
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("install_hooks", Path(__file__).parents[1] / "source/install_hooks.py")
hooks = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hooks)


class InstallationTests(unittest.TestCase):
    def test_existing_settings_and_hooks_survive_and_install_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            settings = home / ".claude/settings.json"
            settings.parent.mkdir()
            original = {"permissions": {"defaultMode": "default"}, "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "existing hook"}]}]}}
            settings.write_text(json.dumps(original))
            hooks.install(home, "/python", Path("/app/hook.py"))
            first = settings.read_bytes()
            updated = json.loads(first)
            self.assertEqual(updated["permissions"], original["permissions"])
            self.assertEqual(updated["hooks"]["Stop"][0], original["hooks"]["Stop"][0])
            self.assertEqual(shlex.split(updated["hooks"]["PermissionRequest"][-1]["hooks"][0]["command"]),
                             ["/python", "-B", "/app/hook.py"])
            self.assertEqual(updated["hooks"]["PermissionRequest"][-1]["hooks"][0]["timeout"], 150)
            self.assertEqual(updated["hooks"]["PreToolUse"][-1]["hooks"][0]["timeout"], 150)
            hooks.install(home, "/python", Path("/app/hook.py"))
            self.assertEqual(settings.read_bytes(), first)
            backup = next(settings.parent.glob("settings.json.agent-office-backup-*"))
            self.assertEqual(json.loads(backup.read_bytes()), original)

    def test_invalid_settings_are_not_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            settings = Path(tmp) / ".claude/settings.json"
            settings.parent.mkdir()
            settings.write_text('{"hooks": "invalid"}')
            before = settings.read_bytes()
            with self.assertRaises(ValueError):
                hooks.install(Path(tmp), "/python", Path("/app/hook.py"))
            self.assertEqual(before, settings.read_bytes())


if __name__ == "__main__":
    unittest.main()

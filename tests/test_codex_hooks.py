"""Codex's real hook protocol shares the private human-decision inbox."""
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

from claude_hook import interactive_reply, private_json
from collector import Collector, valid_inbox_request
from install_codex_hooks import install, uninstall


class CodexHookTests(unittest.TestCase):
    def test_installed_hook_keeps_app_resources_free_of_bytecode(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            resources = home / 'NotchCrew.app/Contents/Resources'
            resources.mkdir(parents=True)
            source = Path(__file__).parents[1] / 'source'
            for name in ('codex_hook.py', 'claude_hook.py'):
                shutil.copyfile(source / name, resources / name)
            hook = resources / 'codex_hook.py'
            install(home, sys.executable, hook)
            settings = home / '.codex/hooks.json'
            original = settings.read_bytes()
            command = json.loads(original)['hooks']['PermissionRequest'][0]['hooks'][0]['command']
            self.assertEqual(shlex.split(command), [sys.executable, '-B', str(hook)])
            # No inherited bytecode setting may mask a missing -B in the generated command.
            env = {'HOME': str(home), 'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8'}
            subprocess.run(shlex.split(command), input='{}', text=True, env=env,
                           capture_output=True, check=True, timeout=5)
            self.assertFalse((resources / '__pycache__').exists())
            self.assertEqual(sorted(path.name for path in resources.iterdir()),
                             ['claude_hook.py', 'codex_hook.py'])
            install(home, sys.executable, hook)
            self.assertEqual(settings.read_bytes(), original)

    def test_codex_request_keeps_identity_and_returns_only_human_decision(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            heartbeat = folder / 'bridge-alive.json'
            heartbeat.write_text(json.dumps({'time': time.time()}))
            heartbeat.chmod(0o600)
            event = {'agent_source': 'Codex', 'hook_event_name': 'PermissionRequest',
                     'session_id': 'codex-thread', 'turn_id': 'turn-1', 'agent_type': 'doc-updater',
                     'cwd': '/local/project', 'tool_name': 'Bash',
                     'tool_input': {'command': 'printf approved', 'description': 'Local check'}}
            result = []
            worker = threading.Thread(target=lambda: result.append(interactive_reply(folder, event, timeout=3)))
            worker.start()
            try:
                until = time.monotonic() + 2
                files = []
                while time.monotonic() < until and not files:
                    files = list((folder / 'requests').glob('*.request.json'))
                    time.sleep(.01)
                self.assertTrue(files)
                request = private_json(files[0])
                self.assertEqual(request['source'], 'Codex')
                self.assertEqual(request['turnId'], 'turn-1')
                self.assertEqual(request['cwd'], '/local/project')
                self.assertTrue(valid_inbox_request(request, time.time()))
                self.assertEqual(result, [])  # No implicit approval while waiting.
                answer = files[0].with_name(request['id'] + '.answer.json')
                answer.write_text(json.dumps({'behavior': 'deny'}))
                answer.chmod(0o600)
            finally:
                worker.join(4)
            decision = result[0]['hookSpecificOutput']['decision']
            self.assertEqual(decision['behavior'], 'deny')
            self.assertNotIn('updatedPermissions', decision)
            self.assertFalse(list((folder / 'requests').glob('*.json')))

    def test_source_validation_does_not_accept_other_providers(self):
        request = {'pid': os.getpid(), 'sessionId': 'thread', 'source': 'Other',
                   'input': {}, 'kind': 'permission', 'questions': [], 'expiresAt': time.time() + 3}
        self.assertFalse(valid_inbox_request(request, time.time()))

    def test_install_and_uninstall_preserve_other_hooks_and_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            directory = home / '.codex'
            directory.mkdir()
            config = directory / 'config.toml'
            config.write_text('approval_policy = "on-request"\n')
            original = {'description': 'User hooks', 'hooks': {'PermissionRequest': [
                {'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': 'existing'}]}]}}
            path = directory / 'hooks.json'
            path.write_text(json.dumps(original))
            install(home, '/python', Path('/app/codex_hook.py'))
            first = path.read_bytes()
            self.assertEqual(json.loads(first)['hooks']['PermissionRequest'][0], original['hooks']['PermissionRequest'][0])
            self.assertEqual(config.read_text(), 'approval_policy = "on-request"\n')
            install(home, '/python', Path('/app/codex_hook.py'))
            self.assertEqual(first, path.read_bytes())
            uninstall(home, Path('/app/codex_hook.py'))
            self.assertEqual(json.loads(path.read_bytes()), original)


if __name__ == '__main__':
    unittest.main()

"""Test the human reply protocol in a disposable inbox, without real agent sessions."""
import json
import os
import tempfile
import threading
import time
import unittest
from pathlib import Path

from claude_hook import interactive_reply, private_json, protocol_reply


class ReplyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.write(self.folder / 'bridge-alive.json', {'time': time.time()})
        self.event = {'hook_event_name': 'PermissionRequest', 'tool_name': 'Bash',
                      'tool_input': {'command': 'printf test'}, 'session_id': 'fixture-only'}

    def write(self, path, value):
        path.write_text(json.dumps(value))
        path.chmod(0o600)

    def test_human_deny_is_returned_and_inbox_is_cleaned(self):
        failures = []
        def human_fixture():
            try:
                until = time.monotonic() + 2
                while time.monotonic() < until:
                    files = list((self.folder / 'requests').glob('*.request.json'))
                    if files:
                        request = private_json(files[0])
                        self.assertEqual(request['input']['command'], 'printf test')
                        self.write(files[0].with_name(request['id'] + '.answer.json'), {'behavior': 'deny'})
                        return
                    time.sleep(.01)
                raise AssertionError('Request not published')
            except Exception as error:
                failures.append(error)
        worker = threading.Thread(target=human_fixture)
        worker.start()
        reply = interactive_reply(self.folder, self.event, timeout=2)
        worker.join()
        self.assertFalse(failures)
        self.assertEqual(reply['hookSpecificOutput']['decision']['behavior'], 'deny')
        self.assertFalse(list((self.folder / 'requests').glob('*.json')))

    def test_no_ui_or_timeout_never_approves(self):
        self.write(self.folder / 'bridge-alive.json', {'time': time.time() - 20})
        self.assertIsNone(interactive_reply(self.folder, self.event, timeout=.1))
        self.write(self.folder / 'bridge-alive.json', {'time': time.time()})
        self.assertIsNone(interactive_reply(self.folder, self.event, timeout=.2))
        self.assertFalse(list((self.folder / 'requests').glob('*.json')))

    def test_question_protocol_preserves_original_questions(self):
        questions = [{'question': 'Какой цвет?', 'options': [{'label': 'Зелёный'}]}]
        event = {'hook_event_name': 'PreToolUse', 'tool_name': 'AskUserQuestion', 'tool_input': {'questions': questions}}
        answer = protocol_reply(event, {'behavior': 'allow', 'answers': {'Какой цвет?': 'Зелёный'}})
        specific = answer['hookSpecificOutput']
        self.assertEqual(specific['permissionDecision'], 'allow')
        self.assertEqual(specific['updatedInput'], {'questions': questions, 'answers': {'Какой цвет?': 'Зелёный'}})
        with self.assertRaises(ValueError):
            protocol_reply(event, {'behavior': 'allow', 'answers': {}})
        self.assertIsNone(protocol_reply(event, {'behavior': 'ask'}))

    def test_inbox_rejects_symlinks_and_shared_files(self):
        target = self.folder / 'target.json'
        self.write(target, {'behavior': 'allow'})
        link = self.folder / 'link.json'
        link.symlink_to(target)
        with self.assertRaises(OSError):
            private_json(link)
        target.chmod(0o644)
        with self.assertRaises(ValueError):
            private_json(target)

    def test_oversize_commands_fall_back_without_truncation(self):
        self.event['tool_input']['command'] = 'x' * 150000
        self.assertIsNone(interactive_reply(self.folder, self.event, timeout=.1))
        self.assertFalse(list((self.folder / 'requests').glob('*.request.json')))


if __name__ == '__main__':
    unittest.main()

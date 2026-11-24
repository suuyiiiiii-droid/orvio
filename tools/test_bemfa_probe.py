import io
import json
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from types import SimpleNamespace
from unittest.mock import Mock, patch

import bemfa_probe


class CompanionTests(unittest.TestCase):
    topic = "t1music006"
    uid = "fixtureUID123"

    def run_companion(self, input_text, wait, *options):
        output = io.StringIO()
        errors = io.StringIO()
        with (
            patch.object(sys, "argv", ["bemfa_probe.py", "--companion", *options]),
            patch.object(sys, "stdin", io.StringIO(input_text)),
            patch.object(bemfa_probe, "wait_for_on", side_effect=wait) as waiter,
            patch.object(bemfa_probe.subprocess, "run") as launch,
            redirect_stdout(output),
            redirect_stderr(errors),
        ):
            status = bemfa_probe.main()
        launch.assert_not_called()
        self.assertEqual(errors.getvalue(), "")
        self.assertNotIn(self.uid, output.getvalue())
        return status, [json.loads(line) for line in output.getvalue().splitlines()], waiter

    def test_ready_then_triggered(self):
        def trigger(topic, uid, *, timeout, ready, require_ready):
            self.assertEqual((topic, uid, timeout), (self.topic, self.uid, 12))
            self.assertTrue(require_ready)
            ready()
            return True

        status, events, _ = self.run_companion(self.uid + "\n", trigger, "--timeout", "12")
        self.assertEqual(status, 0)
        self.assertEqual(events, [
            {"event": "ready", "topic": self.topic},
            {"event": "triggered", "topic": self.topic},
        ])

    def test_timeout_after_subscribe(self):
        def timeout(topic, uid, *, timeout, ready, require_ready):
            ready()
            return False

        status, events, _ = self.run_companion(self.uid + "\n", timeout)
        self.assertEqual(status, 1)
        self.assertEqual([event["event"] for event in events], ["ready", "timeout"])

    def test_errors_hide_uid(self):
        status, events, _ = self.run_companion(
            self.uid + "\n", OSError(f"connection failed for {self.uid}")
        )
        self.assertEqual(status, 1)
        self.assertEqual(events, [{"event": "error", "message": "connection failed for [已隐藏]"}])

    def test_bad_uid_and_conflicting_action_fail_before_connecting(self):
        for uid, options in (("invalid uid\n", []), (self.uid + "\n", ["--open-netease"])):
            with self.subTest(options=options):
                status, events, waiter = self.run_companion(uid, AssertionError, *options)
                self.assertEqual(status, 2)
                self.assertEqual([event["event"] for event in events], ["error"])
                waiter.assert_not_called()


class ListenerTests(unittest.TestCase):
    def test_voice_hook_requires_subscription_and_a_subsequent_on(self):
        client = Mock()
        client.subscribe.return_value = (0, 12)
        mqtt = SimpleNamespace(
            Client=Mock(return_value=client),
            CallbackAPIVersion=SimpleNamespace(VERSION2=2),
            MQTTv311=4,
            MQTT_ERR_SUCCESS=0,
        )
        success = SimpleNamespace(is_failure=False)
        message = SimpleNamespace(topic="t1music006", payload=b"on", retain=False, dup=False)
        calls = []

        def publish_on():
            client.on_message(client, None, message)

        def send_voice():
            publish_on()
            calls.append("voice")

        def publish_live():
            calls.append("live")
            publish_on()

        callbacks = iter([
            lambda: client.on_connect(client, None, None, success, None),
            publish_on,
            lambda: client.on_subscribe(client, None, 12, [success], None),
            publish_live,
        ])

        def loop(timeout):
            next(callbacks)()
            return 0

        client.loop.side_effect = loop
        with patch.object(bemfa_probe, "mqtt", mqtt):
            triggered = bemfa_probe.listen(
                "t1music006",
                "fixtureUID123",
                timeout=10,
                perform=lambda: calls.append("perform"),
                on_ready=send_voice,
                status=lambda message: calls.append("status"),
            )

        self.assertTrue(triggered)
        self.assertEqual(calls, ["status", "voice", "live", "perform"])
        client.disconnect.assert_called_once()


if __name__ == "__main__":
    unittest.main()

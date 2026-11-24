import io
import json
import socket
import ssl
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from email.message import Message
from threading import Event, Thread
from types import SimpleNamespace
from unittest.mock import MagicMock, Mock, patch
from urllib.request import HTTPHandler
from urllib.response import addinfourl

import bemfa_probe
import xiaoai_daily


class XiaoAIDailyTests(unittest.TestCase):
    configuration = {
        "topic": "t1music006",
        "bemfaUID": "fixturePrivateUID",
        "homeAssistantURL": "http://127.0.0.1:8123/",
        "homeAssistantToken": "fixture.private.token",
        "notifyEntity": "notify.speaker_execute_text_directive",
        "switchCommand": "打开电脑音乐",
        "includeSilentParameter": True,
    }

    def setUp(self):
        self.bemfa_http = Mock()
        self.bemfa_http.getresponse.return_value = self.bemfa_response(b'{"code":0}')
        transport = patch.object(xiaoai_daily, "HTTPSConnection", return_value=self.bemfa_http)
        transport.start()
        self.addCleanup(transport.stop)

    @staticmethod
    def bemfa_response(payload, status=200):
        response = Mock(status=status)
        response.read.return_value = payload
        context = MagicMock()
        context.__enter__.return_value = response
        return context

    def run_bridge(self, data=None, thread_factory=None):
        if data is None:
            data = json.dumps(self.configuration, ensure_ascii=False).encode("utf-8")
        stdout = io.StringIO()
        stderr = io.StringIO()
        def immediate_thread(*, target, **kwargs):
            return SimpleNamespace(start=target)

        with (
            patch.object(xiaoai_daily, "Thread", side_effect=thread_factory or immediate_thread),
            patch.object(sys, "stdin", io.TextIOWrapper(io.BytesIO(data))),
            redirect_stdout(stdout),
            redirect_stderr(stderr),
        ):
            code = xiaoai_daily.main()
        self.assertEqual(stderr.getvalue(), "")
        self.assertEqual(len(stdout.getvalue().splitlines()), 1)
        for key in ("bemfaUID", "homeAssistantToken"):
            self.assertNotIn(self.configuration[key], stdout.getvalue())
        return code, json.loads(stdout.getvalue())

    @staticmethod
    def response(request, code, location=None, payload=b"fixture.private.token fixturePrivateUID"):
        headers = Message()
        if location:
            headers["Location"] = location
        body = io.BytesIO(payload)
        response = addinfourl(body, headers, request.full_url, code)
        response.msg = "Fixture response"
        return response

    def test_post_follows_subscription_and_trigger_requires_live_on(self):
        client = Mock()
        client.subscribe.return_value = (0, 42)
        mqtt = SimpleNamespace(
            Client=Mock(return_value=client),
            CallbackAPIVersion=SimpleNamespace(VERSION2=2),
            MQTTv311=4,
            MQTT_ERR_SUCCESS=0,
        )
        success = SimpleNamespace(is_failure=False)
        events = []

        def publish(*, retain=False):
            message = SimpleNamespace(topic="t1music006", payload=b"on", retain=retain, dup=False)
            client.on_message(client, None, message)

        def acknowledge_subscription():
            events.append("suback")
            client.on_subscribe(client, None, 42, [success], None)

        def reset_switch(method, route, body, headers):
            self.assertEqual((method, route), ("POST", "/va/postJsonMsg"))
            self.assertEqual(json.loads(body), {
                "uid": "fixturePrivateUID", "topic": "t1music006", "type": 1, "msg": "off",
            })
            events.append("reset")

        def publish_live():
            events.append("live on")
            publish()

        callbacks = iter([
            lambda: client.on_connect(client, None, None, success, None),
            publish,
            acknowledge_subscription,
            lambda: publish(retain=True),
            publish_live,
        ])

        def loop(timeout):
            next(callbacks)()
            return 0

        def handle(request):
            events.append("notify")
            self.assertEqual(events, ["reset", "suback", "notify"])
            self.assertEqual(request.full_url, "http://127.0.0.1:8123" + xiaoai_daily.NOTIFY_PATH)
            self.assertEqual(request.get_method(), "POST")
            self.assertEqual(request.get_header("Authorization"), "Bearer fixture.private.token")
            self.assertEqual(request.timeout, xiaoai_daily.HTTP_TIMEOUT)
            body = json.loads(request.data)
            self.assertEqual(body["entity_id"], self.configuration["notifyEntity"])
            self.assertEqual(json.loads(body["message"]), ["打开电脑音乐", True])
            return self.response(request, 200)

        client.loop.side_effect = loop
        self.bemfa_http.request.side_effect = reset_switch
        with (
            patch.object(bemfa_probe, "mqtt", mqtt),
            patch.object(xiaoai_daily, "read_directive_state", return_value="unknown"),
            patch.object(HTTPHandler, "http_open", side_effect=handle),
        ):
            code, event = self.run_bridge()
            self.assertEqual((code, event["event"]), (0, "triggered"))
        self.assertEqual(events, ["reset", "suback", "notify", "live on"])
        self.assertEqual(event["steps"], [
            {"stage": "ha_entity", "result": "available"},
            {"stage": "bemfa_reset", "result": "off_confirmed"},
            {"stage": "mqtt_subscription", "result": "confirmed"},
            {"stage": "ha_directive", "result": "accepted"},
            {"stage": "mqtt_on", "result": "received"},
        ])
        client.publish.assert_not_called()
        client.disconnect.assert_called_once()

    def test_redirect_is_rejected_without_forwarding_authorization(self):
        def listener(topic, client_id, *, timeout, perform, on_ready, status, **options):
            on_ready()
            self.assertTrue(options["stop_waiting"]())
            return False

        def redirect(request):
            return self.response(request, 307, "http://127.0.0.1:8321/collect")

        with (
            patch.object(bemfa_probe, "listen", side_effect=listener),
            patch.object(xiaoai_daily, "read_directive_state", return_value="unknown"),
            patch.object(HTTPHandler, "http_open", side_effect=redirect) as requests,
        ):
            code, event = self.run_bridge()
        self.assertEqual(code, 1)
        self.assertEqual(event["event"], "error")
        self.assertIn("重定向", event["message"])
        requests.assert_called_once()

    def test_http_auth_error_uses_safe_message(self):
        def listener(topic, client_id, *, timeout, perform, on_ready, status, **options):
            on_ready()
            self.assertTrue(options["stop_waiting"]())
            return False

        with (
            patch.object(bemfa_probe, "listen", side_effect=listener),
            patch.object(xiaoai_daily, "read_directive_state", return_value="unknown"),
            patch.object(HTTPHandler, "http_open", side_effect=lambda request: self.response(request, 401)),
        ):
            code, event = self.run_bridge()
        self.assertEqual(code, 1)
        self.assertEqual(event["event"], "error")
        self.assertIn("拒绝授权", event["message"])

    def test_invalid_input_never_connects(self):
        for data in (
            b"not JSON", b"\xff", b"{} {}",
            json.dumps({**self.configuration, "includeSilentParameter": 1}).encode(),
            json.dumps({**self.configuration, "notifyEntity": "switch.unrelated"}).encode(),
            json.dumps({**self.configuration, "homeAssistantURL": "http://example.com"}).encode(),
            json.dumps({**self.configuration, "homeAssistantURL": "https://user:password@127.0.0.1"}).encode(),
        ):
            with self.subTest(), patch.object(bemfa_probe, "listen") as listen:
                code, event = self.run_bridge(data)
                self.assertEqual(code, 1)
                self.assertEqual(event["event"], "error")
                listen.assert_not_called()

    def test_waiting_for_mqtt_distinguishes_whether_directive_was_sent(self):
        def after_subscription(topic, client_id, *, timeout, perform, on_ready, status, **options):
            on_ready()
            return False

        with (
            patch.object(bemfa_probe, "listen", return_value=False),
            patch.object(xiaoai_daily, "read_directive_state", return_value="unknown"),
        ):
            code, event = self.run_bridge()
        self.assertEqual(code, 1)
        self.assertEqual(event["event"], "timeout")
        self.assertIn("未发送", event["message"])

        data = json.dumps({**self.configuration, "includeSilentParameter": False}).encode()
        with (
            patch.object(bemfa_probe, "listen", side_effect=after_subscription),
            patch.object(xiaoai_daily, "read_directive_state",
                         side_effect=["unknown", "2026-11-12T00:00:00+00:00"]),
            patch.object(HTTPHandler, "http_open", side_effect=lambda request: self.response(request, 204)) as requests,
        ):
            code, event = self.run_bridge(data)
        request = requests.call_args.args[0]
        self.assertEqual(json.loads(json.loads(request.data)["message"]), ["打开电脑音乐"])
        self.assertEqual(code, 1)
        self.assertEqual(event["event"], "timeout")
        self.assertIn("未收到", event["message"])

    def test_unavailable_speaker_does_not_submit_directive(self):
        def listener(topic, client_id, *, timeout, perform, on_ready, status, **options):
            on_ready()
            self.fail("An unavailable speaker must not be sent a directive")

        def get_state(request):
            self.assertEqual(request.get_method(), "GET")
            entity = self.configuration["notifyEntity"]
            self.assertTrue(request.full_url.endswith(f"/api/states/{entity}"))
            payload = json.dumps({"entity_id": entity, "state": "unavailable"}).encode()
            return self.response(request, 200, payload=payload)

        with (
            patch.object(bemfa_probe, "listen", side_effect=listener),
            patch.object(HTTPHandler, "http_open", side_effect=get_state) as requests,
        ):
            code, event = self.run_bridge()
        requests.assert_called_once()
        self.bemfa_http.connect.assert_not_called()
        self.assertEqual((code, event["event"]), (1, "error"))
        self.assertIn("不可用", event["message"])

    def test_explicit_bemfa_rejection_does_not_subscribe_or_send(self):
        self.bemfa_http.getresponse.return_value = self.bemfa_response(
            b'{"code":40004,"message":"fixturePrivateUID"}',
        )
        with (
            patch.object(bemfa_probe, "listen") as listen,
            patch.object(xiaoai_daily, "read_directive_state", return_value="unknown"),
            patch.object(xiaoai_daily, "send_directive") as send,
        ):
            code, event = self.run_bridge()
        self.assertEqual((code, event["event"]), (1, "error"))
        self.assertIn("拒绝了 UID 或主题", event["message"])
        self.assertEqual(event["steps"][1:], [{"stage": "bemfa_reset", "result": "rejected", "phase": "json"}])
        self.bemfa_http.request.assert_called_once()
        listen.assert_not_called()
        send.assert_not_called()

    def test_timeout_with_cloud_off_allows_one_directive(self):
        self.bemfa_http.getresponse.side_effect = [
            socket.timeout(),
            self.bemfa_response(b'{"code":0,"data":[{"msg":"off"}]}'),
        ]

        def listener(topic, client_id, *, timeout, perform, on_ready, status, **options):
            on_ready()
            return True

        with (
            patch.object(bemfa_probe, "listen", side_effect=listener),
            patch.object(xiaoai_daily, "read_directive_state", return_value="unknown"),
            patch.object(xiaoai_daily, "send_directive") as send,
        ):
            code, event = self.run_bridge()
        self.assertEqual((code, event["event"]), (0, "triggered"))
        self.assertEqual(event["steps"][1:3], [
            {"stage": "bemfa_reset", "result": "timeout", "phase": "headers"},
            {"stage": "bemfa_state", "result": "off_confirmed"},
        ])
        requests = self.bemfa_http.request.call_args_list
        self.assertEqual([call.args[0] for call in requests], ["POST", "GET"])
        self.assertTrue(requests[1].args[1].startswith("/va/getmsg?"))
        send.assert_called_once()

    def test_invalid_response_and_cloud_on_do_not_send(self):
        self.bemfa_http.getresponse.side_effect = [
            self.bemfa_response(b'not JSON fixturePrivateUID'),
            self.bemfa_response(b'{"code":0,"data":[{"msg":"on"}]}'),
        ]
        with (
            patch.object(bemfa_probe, "listen") as listen,
            patch.object(xiaoai_daily, "read_directive_state", return_value="unknown"),
            patch.object(xiaoai_daily, "send_directive") as send,
        ):
            code, event = self.run_bridge()
        self.assertEqual((code, event["event"]), (1, "error"))
        self.assertEqual(event["steps"][1:], [
            {"stage": "bemfa_reset", "result": "invalid_json", "phase": "json"},
            {"stage": "bemfa_state", "result": "off_unconfirmed"},
        ])
        listen.assert_not_called()
        send.assert_not_called()

    def test_bemfa_dns_tcp_and_tls_errors_are_distinct(self):
        for error, kind in (
            (socket.gaierror(), "dns"),
            (ConnectionRefusedError(), "connection"),
            (ssl.SSLCertVerificationError(), "tls"),
        ):
            with self.subTest(kind=kind):
                self.bemfa_http.connect.side_effect = error
                with self.assertRaises(xiaoai_daily.BemfaHTTPSFailure) as result:
                    xiaoai_daily.bemfa_api("POST", "/va/postJsonMsg", 1, b"{}")
                self.assertEqual((result.exception.kind, result.exception.phase), (kind, "connect"))

    def test_successful_http_without_execution_record_is_not_reported_as_xiaoai_success(self):
        def listener(topic, client_id, *, timeout, perform, on_ready, status, **options):
            on_ready()
            return False

        calls = []
        def handle(request):
            calls.append(request.get_method())
            if request.get_method() == "POST":
                return self.response(request, 200)
            entity = self.configuration["notifyEntity"]
            payload = json.dumps({"entity_id": entity, "state": "unknown"}).encode()
            return self.response(request, 200, payload=payload)

        with (
            patch.object(bemfa_probe, "listen", side_effect=listener),
            patch.object(HTTPHandler, "http_open", side_effect=handle),
        ):
            code, event = self.run_bridge()
        self.assertEqual(calls, ["GET", "POST", "GET"])
        self.assertEqual((code, event["event"]), (1, "timeout"))
        self.assertIn("没有记录小爱指令执行", event["message"])

    def test_missing_http_reply_still_accepts_a_fresh_switch_signal(self):
        def listener(topic, client_id, *, timeout, perform, on_ready, status, **options):
            on_ready()
            return True

        with (
            patch.object(bemfa_probe, "listen", side_effect=listener),
            patch.object(xiaoai_daily, "read_directive_state", return_value="unknown"),
            patch.object(HTTPHandler, "http_open", side_effect=socket.timeout) as send,
        ):
            code, event = self.run_bridge()
            self.assertEqual((code, event["event"]), (0, "triggered"))
        send.assert_called_once()

    def test_mqtt_listens_while_the_home_assistant_request_is_in_flight(self):
        entered = Event()
        complete = Event()

        def send(*args):
            entered.set()
            self.assertTrue(complete.wait(2))

        def listener(topic, client_id, *, timeout, perform, on_ready, status, signal_timeout, stop_waiting):
            on_ready()
            if not entered.wait(2):
                self.fail("Home Assistant request did not start")
            self.assertFalse(stop_waiting())
            self.assertEqual(signal_timeout, xiaoai_daily.SIGNAL_TIMEOUT)
            complete.set()
            return True

        with (
            patch.object(bemfa_probe, "listen", side_effect=listener),
            patch.object(xiaoai_daily, "read_directive_state", return_value="unknown"),
            patch.object(xiaoai_daily, "send_directive", side_effect=send) as request,
        ):
            code, event = self.run_bridge(thread_factory=Thread)
        self.assertEqual((code, event["event"]), (0, "triggered"))
        request.assert_called_once()

    def test_missing_http_reply_and_no_execution_record_are_reported(self):
        def listener(topic, client_id, *, timeout, perform, on_ready, status, **options):
            on_ready()
            return False

        with (
            patch.object(bemfa_probe, "listen", side_effect=listener),
            patch.object(xiaoai_daily, "read_directive_state", return_value="unknown"),
            patch.object(HTTPHandler, "http_open", side_effect=socket.timeout) as send,
        ):
            code, event = self.run_bridge()
        self.assertEqual((code, event["event"]), (1, "timeout"))
        self.assertIn("未确认本次请求", event["message"])
        send.assert_called_once()


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Send a configured XiaoAI command and wait for its Bemfa switch signal."""

import ipaddress
import json
import os
import re
import socket
import ssl
import sys
from http.client import HTTPException, HTTPSConnection, RemoteDisconnected
from threading import Event, Thread
from time import monotonic
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

import bemfa_probe


NOTIFY_PATH = "/api/services/notify/send_message"
BEMFA_API_HOST = "apis.bemfa.com"
BEMFA_API_PORT = 443
HTTP_TIMEOUT = 12.0
STATE_TIMEOUT = 4.0
RESET_TIMEOUT = 7.0
RESET_READBACK_TIMEOUT = 5.0
MQTT_TIMEOUT = 10.0
SIGNAL_TIMEOUT = 13.0
T1_VIRTUAL_SWITCH = "t1music006"
MAX_INPUT_BYTES = 8192
MAX_STATE_BYTES = 65536
CONFIG_KEYS = {
    "topic", "bemfaUID", "homeAssistantURL", "homeAssistantToken",
    "notifyEntity", "switchCommand", "includeSilentParameter",
}
NOTIFY_ENTITY = re.compile(r"notify\.[a-z0-9_]{1,248}")
BEARER_TOKEN = re.compile(r"[A-Za-z0-9._~+/\-]+={0,2}")
HOST_LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", re.ASCII)
PRIVATE_NETWORKS = tuple(ipaddress.ip_network(network) for network in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7",
))


class BridgeError(Exception):
    """A failure message that is safe to display in the app."""


class DirectiveReplyMissing(BridgeError):
    """The command may have reached Home Assistant before the connection closed."""


class BemfaHTTPSFailure(BridgeError):
    def __init__(self, kind, phase, message, *, can_read_back=True):
        super().__init__(message)
        self.kind = kind
        self.phase = phase
        self.can_read_back = can_read_back


class RejectRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def notify_endpoint(origin):
    if (not isinstance(origin, str) or len(origin) > 1024 or not origin.isascii()
            or any(char.isspace() or not char.isprintable() for char in origin)
            or any(char in origin for char in "?#\\%")):
        raise BridgeError("请输入有效的 Home Assistant 地址。")
    try:
        parts = urlsplit(origin)
        host = parts.hostname
        port = parts.port
    except ValueError:
        raise BridgeError("请输入有效的 Home Assistant 地址。") from None
    if (parts.scheme not in {"http", "https"} or not host or port == 0
            or parts.username is not None or parts.password is not None
            or parts.path not in {"", "/"}):
        raise BridgeError("Home Assistant 地址应只包含协议、主机和可选端口。")

    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        name = host.removesuffix(".")
        if not all(HOST_LABEL.fullmatch(label) for label in name.split(".")):
            raise BridgeError("请输入有效的 Home Assistant 主机名。") from None
        local = name == "localhost" or name.endswith(".local")
    else:
        if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped is not None:
            address = address.ipv4_mapped
        local = address.is_loopback or any(address in network for network in PRIVATE_NETWORKS)
    if parts.scheme == "http" and not local:
        raise BridgeError("非本机或局域网的 Home Assistant 地址必须使用 HTTPS。")
    authority = f"[{host}]" if ":" in host else host
    if port is not None:
        authority = f"{authority}:{port}"
    return urlunsplit((parts.scheme, authority, NOTIFY_PATH, "", ""))


def read_configuration():
    try:
        raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
        if len(raw) > MAX_INPUT_BYTES:
            raise BridgeError("小爱桥接配置过长。")
        config = json.loads(raw.decode("utf-8"))
    except (ValueError, RecursionError, OSError):
        raise BridgeError("无法读取小爱桥接配置。") from None
    if not isinstance(config, dict) or set(config) != CONFIG_KEYS:
        raise BridgeError("小爱桥接配置的字段不完整或格式有误。")
    topic = config["topic"]
    if not isinstance(topic, str) or not bemfa_probe.TOPIC_PATTERN.fullmatch(topic):
        raise BridgeError("请输入以 006 结尾的巴法开关主题。")
    uid = config["bemfaUID"]
    if not isinstance(uid, str) or not (1 <= len(uid) <= 128 and uid.isascii() and uid.isalnum()):
        raise BridgeError("请输入巴法控制台的 UID 私钥。")
    token = config["homeAssistantToken"]
    if not isinstance(token, str) or len(token) > 4096 or not BEARER_TOKEN.fullmatch(token):
        raise BridgeError("请输入有效的 Home Assistant 访问令牌。")
    entity = config["notifyEntity"]
    if not isinstance(entity, str) or not NOTIFY_ENTITY.fullmatch(entity):
        raise BridgeError("请输入小爱音箱执行文本指令的 notify 实体。")
    command = config["switchCommand"]
    if (not isinstance(command, str) or len(command) > 256 or not command.strip()
            or not command.isprintable()):
        raise BridgeError("请输入小爱同学用来打开巴法开关的指令。")
    if not isinstance(config["includeSilentParameter"], bool):
        raise BridgeError("小爱指令的静默参数设置有误。")
    return config, notify_endpoint(config["homeAssistantURL"])


def send_directive(endpoint, token, entity, command, include_silent):
    parameters = [command, True] if include_silent else [command]
    body = json.dumps({
        "entity_id": entity,
        "message": json.dumps(parameters, ensure_ascii=False),
    }, ensure_ascii=False).encode("utf-8")
    request = Request(endpoint, data=body, method="POST", headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    })
    request_home_assistant(request)


def read_directive_state(endpoint, token, entity):
    origin = endpoint.removesuffix(NOTIFY_PATH)
    request = Request(f"{origin}/api/states/{entity}", headers={
        "Authorization": f"Bearer {token}",
    })
    data = request_home_assistant(request, read_state=True)
    try:
        state = json.loads(data)
    except (ValueError, RecursionError):
        raise BridgeError("Home Assistant 返回了无法读取的小爱实体状态。") from None
    if (not isinstance(state, dict) or state.get("entity_id") != entity
            or not isinstance(state.get("state"), str)):
        raise BridgeError("Home Assistant 返回的小爱实体状态与设置不符。")
    return state["state"]


def request_home_assistant(request, *, read_state=False):
    opener = build_opener(ProxyHandler({}), RejectRedirects())
    try:
        with opener.open(request, timeout=STATE_TIMEOUT if read_state else HTTP_TIMEOUT) as response:
            return response.read(MAX_STATE_BYTES) if read_state else None
    except HTTPError as error:
        code = error.code
        error.close()
        if 300 <= code < 400:
            raise BridgeError("Home Assistant 返回了重定向，请填写实际服务地址。") from None
        if code in {401, 403}:
            raise BridgeError("Home Assistant 拒绝授权，请核对访问令牌和账号权限。") from None
        if code == 404 and read_state:
            raise BridgeError("Home Assistant 找不到所选小爱音箱的执行文本指令实体。") from None
        raise BridgeError(f"Home Assistant 拒绝了小爱指令（HTTP {code}），请核对通知实体。") from None
    except (OSError, HTTPException, ValueError) as error:
        cause = error.reason if isinstance(error, URLError) else error
        timed_out = isinstance(cause, (socket.timeout, TimeoutError))
        if not read_state and (timed_out or isinstance(cause, (
            RemoteDisconnected, ConnectionResetError, BrokenPipeError,
        ))):
            raise DirectiveReplyMissing("Home Assistant 未返回本次指令的确认。") from None
        if timed_out:
            raise BridgeError("等待 Home Assistant 响应超时。") from None
        raise BridgeError("无法连接 Home Assistant，请核对地址和网络。") from None


def bemfa_api(method, path, timeout, body=None):
    connection = HTTPSConnection(BEMFA_API_HOST, BEMFA_API_PORT, timeout=timeout)
    start = monotonic()
    deadline = start + timeout
    phase = "connect"
    progress(method, phase, start)
    try:
        connection.connect()
        phase = "send"
        progress(method, phase, start)
        connection.sock.settimeout(max(0.001, deadline - monotonic()))
        headers = {"Content-Type": "application/json; charset=utf-8"} if body is not None else {}
        connection.request(method, path, body, headers)
        phase = "headers"
        progress(method, phase, start)
        connection.sock.settimeout(max(0.001, deadline - monotonic()))
        with connection.getresponse() as response:
            if response.status != 200:
                raise BemfaHTTPSFailure(
                    f"http_{response.status}", phase, f"巴法返回 HTTP {response.status}",
                    can_read_back=response.status >= 500,
                )
            phase = "body"
            progress(method, phase, start)
            payload = response.read(8193)
    except (socket.timeout, TimeoutError):
        operation = {"connect": "连接", "send": "发送请求", "headers": "等待响应头", "body": "读取响应正文"}
        raise BemfaHTTPSFailure("timeout", phase, f"巴法 HTTPS {operation[phase]}超时") from None
    except socket.gaierror:
        raise BemfaHTTPSFailure("dns", phase, "无法解析巴法 HTTPS 域名") from None
    except ssl.SSLError:
        raise BemfaHTTPSFailure("tls", phase, "巴法 HTTPS TLS 连接失败", can_read_back=False) from None
    except (ConnectionError, RemoteDisconnected):
        raise BemfaHTTPSFailure("connection", phase, "巴法 HTTPS 连接被拒绝或中断") from None
    except OSError:
        raise BemfaHTTPSFailure("network", phase, "巴法 HTTPS 网络连接失败") from None
    except HTTPException:
        raise BemfaHTTPSFailure("http_response", phase, "巴法 HTTPS 响应不完整或格式异常") from None
    finally:
        connection.close()
    try:
        reply = json.loads(payload) if len(payload) <= 8192 else None
    except (ValueError, RecursionError):
        reply = None
    code = reply.get("code") if isinstance(reply, dict) else None
    if code == 40004:
        raise BemfaHTTPSFailure("rejected", "json", "巴法拒绝了 UID 或主题", can_read_back=False)
    if type(code) is not int:
        raise BemfaHTTPSFailure("invalid_json", "json", "巴法返回的内容缺少有效的 JSON 状态码")
    if code != 0:
        raise BemfaHTTPSFailure(f"api_{code}", "json", f"巴法返回业务错误 {code}", can_read_back=False)
    return reply


def reset_bemfa_switch(uid, steps):
    switch = {"uid": uid, "topic": T1_VIRTUAL_SWITCH, "type": 1}
    body = json.dumps({**switch, "msg": "off"}).encode("utf-8")
    try:
        bemfa_api("POST", "/va/postJsonMsg", RESET_TIMEOUT, body)
    except BemfaHTTPSFailure as post_error:
        steps.append({"stage": "bemfa_reset", "result": post_error.kind, "phase": post_error.phase})
        if not post_error.can_read_back:
            raise BridgeError(f"{post_error}，本次未发送小爱指令。") from None
        try:
            query = urlencode({**switch, "num": 1})
            history = bemfa_api("GET", f"/va/getmsg?{query}", RESET_READBACK_TIMEOUT).get("data")
        except BemfaHTTPSFailure as read_error:
            steps.append({"stage": "bemfa_state", "result": read_error.kind, "phase": read_error.phase})
            raise BridgeError(f"{post_error}；{read_error}，本次未发送小爱指令。") from None
        recent = history[0] if isinstance(history, list) and history else None
        if not isinstance(recent, dict) or recent.get("msg") != "off":
            steps.append({"stage": "bemfa_state", "result": "off_unconfirmed"})
            raise BridgeError(f"{post_error}；云端未确认开关已关闭，本次未发送小爱指令。") from None
        steps.append({"stage": "bemfa_state", "result": "off_confirmed"})
    else:
        steps.append({"stage": "bemfa_reset", "result": "off_confirmed"})


def emit(event, **fields):
    print(json.dumps({"event": event, **fields}, ensure_ascii=False), flush=True)


def progress(method, phase, start):
    if os.environ.get("T1_BRIDGE_PROGRESS") == "1":
        elapsed_ms = round((monotonic() - start) * 1000)
        print(json.dumps({"method": method, "phase": phase, "elapsed_ms": elapsed_ms}), file=sys.stderr, flush=True)


def main():
    directive_done = Event()
    directive_state = None
    directive_error = None
    worker = None
    steps = []

    def report(event, **fields):
        emit(event, **fields, steps=steps)

    try:
        config, endpoint = read_configuration()
        prior_state = read_directive_state(endpoint, config["homeAssistantToken"], config["notifyEntity"])
        if prior_state == "unavailable":
            raise BridgeError("Home Assistant 显示小爱音箱不可用，本次未发送指令。")
        steps.append({"stage": "ha_entity", "result": "available"})
        if config["topic"] == T1_VIRTUAL_SWITCH:
            reset_bemfa_switch(config["bemfaUID"], steps)
        # Subscribe after resetting so the reset cannot enter the MQTT receive queue.
        def submit_directive():
            nonlocal directive_state, directive_error
            try:
                send_directive(
                    endpoint, config["homeAssistantToken"], config["notifyEntity"],
                    config["switchCommand"], config["includeSilentParameter"],
                )
            except DirectiveReplyMissing:
                directive_state = "no_reply"
            except BridgeError as error:
                directive_state = "rejected"
                directive_error = error
            else:
                directive_state = "accepted"
            finally:
                directive_done.set()

        def send_after_subscription():
            nonlocal worker
            steps.append({"stage": "mqtt_subscription", "result": "confirmed"})
            worker = Thread(target=submit_directive, daemon=True, name="ha-directive")
            worker.start()

        triggered = bemfa_probe.listen(
            config["topic"], config["bemfaUID"], timeout=MQTT_TIMEOUT,
            perform=lambda: None, on_ready=send_after_subscription, status=lambda _: None,
            signal_timeout=SIGNAL_TIMEOUT, stop_waiting=lambda: directive_done.is_set() and directive_error is not None,
        )
    except BridgeError as error:
        report("error", message=str(error))
        return 1
    except (OSError, RuntimeError):
        report("error", message="巴法 MQTT 连接失败，请核对本机 Python、巴法 UID 和网络。")
        return 1
    if worker is None:
        report("timeout", message="巴法 MQTT 订阅超时，未发送小爱指令。")
        return 1
    if triggered:
        directive_done.wait(0.25)
    directive_result = directive_state or "pending"
    steps.append({"stage": "ha_directive", "result": directive_result})
    if directive_error is not None:
        report("error", message=str(directive_error))
        return 1
    if not triggered:
        try:
            final_state = read_directive_state(
                endpoint, config["homeAssistantToken"], config["notifyEntity"],
            )
        except BridgeError:
            final_state = None
        if final_state == "unavailable":
            detail = "等待期间小爱音箱在 Home Assistant 中掉线，未收到巴法开启信号。"
        elif final_state is None:
            detail = "未收到巴法开启信号，也未能核对小爱音箱的执行记录。"
        elif final_state in {"unknown", prior_state}:
            if directive_result == "accepted":
                detail = "Home Assistant 接收了请求，但没有记录小爱指令执行。"
            else:
                detail = "Home Assistant 未确认本次请求，也没有新的小爱指令执行记录。"
        else:
            detail = "小爱指令已有执行记录，未收到巴法开关的实时开启信号。"
        report("timeout", message=detail)
        return 1
    steps.append({"stage": "mqtt_on", "result": "received"})
    report("triggered")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Listen once for a Bemfa virtual switch command on macOS."""

import argparse
import getpass
import json
import re
import ssl
import subprocess
import sys
import time
from typing import Callable, Optional

try:
    import paho.mqtt.client as mqtt
except ModuleNotFoundError as error:
    if error.name not in {"paho", "paho.mqtt", "paho.mqtt.client"}:
        raise
    mqtt = None


BROKER = "bemfa.com"
TLS_PORT = 9503
TOPIC_PATTERN = re.compile(r"[A-Za-z0-9]{1,61}006")


def wait_for_on(
    topic: str,
    client_id: str,
    *,
    timeout: float,
    ready: Callable[[], None],
    require_ready: bool = False,
    signal_timeout: Optional[float] = None,
    stop_waiting: Optional[Callable[[], bool]] = None,
) -> bool:
    """Wait for a live on after the subscription is acknowledged."""
    if mqtt is None:
        raise RuntimeError("当前 Python 缺少 paho-mqtt 2.1.0。")
    client = mqtt.Client(
        mqtt.CallbackAPIVersion.VERSION2,
        client_id=client_id,
        clean_session=True,
        protocol=mqtt.MQTTv311,
        reconnect_on_failure=False,
    )
    client.connect_timeout = min(timeout, 10)
    context = ssl.create_default_context()
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    client.tls_set_context(context)

    subscription_id = None
    subscribed = False
    ready_sent = False
    received_on = False
    problem = None

    def on_connect(connection, _userdata, _flags, reason, _properties):
        nonlocal problem, subscription_id
        if reason.is_failure:
            problem = f"巴法拒绝连接（{reason}）。请核对本机输入的 UID 私钥。"
            return
        result, subscription_id = connection.subscribe(topic, qos=0)
        if result != mqtt.MQTT_ERR_SUCCESS:
            problem = f"发送订阅请求失败（{mqtt.error_string(result)}）。"

    def on_subscribe(_connection, _userdata, packet_id, reasons, _properties):
        nonlocal subscribed, problem
        if packet_id != subscription_id:
            return
        if not reasons or any(reason.is_failure for reason in reasons):
            problem = "巴法未接受订阅。请核对主题是否在对应账号下创建。"
            return
        subscribed = True

    def on_message(_connection, _userdata, message):
        nonlocal received_on
        if require_ready and not ready_sent:
            return
        if message.topic == topic and message.payload == b"on" and not message.retain and not message.dup:
            received_on = True

    client.on_connect = on_connect
    client.on_subscribe = on_subscribe
    client.on_message = on_message

    deadline = time.monotonic() + timeout
    try:
        client.connect(BROKER, TLS_PORT, keepalive=30)
        while problem is None:
            if ready_sent and received_on:
                return True
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            if subscribed and not ready_sent:
                ready()
                ready_sent = True
                if signal_timeout is not None:
                    deadline = time.monotonic() + signal_timeout
                continue
            if ready_sent and stop_waiting is not None and stop_waiting():
                return False
            result = client.loop(timeout=min(remaining, 0.25 if stop_waiting is not None else 1))
            if result != mqtt.MQTT_ERR_SUCCESS and problem is None:
                if ready_sent and received_on:
                    return True
                problem = f"MQTT 连接中断（{mqtt.error_string(result)}）。"
        raise RuntimeError(problem)
    finally:
        client.disconnect()


def listen(
    topic: str,
    client_id: str,
    *,
    timeout: float,
    perform: Callable[[], None],
    on_ready: Optional[Callable[[], None]] = None,
    status: Optional[Callable[[str], None]] = None,
    signal_timeout: Optional[float] = None,
    stop_waiting: Optional[Callable[[], bool]] = None,
) -> bool:
    """Call on_ready after SUBACK, then perform once on a live on."""

    def ready():
        message = f"已订阅 {topic}，等待实时打开指令。"
        if status is None:
            print(message, flush=True)
        else:
            status(message)
        if on_ready is not None:
            on_ready()

    triggered = wait_for_on(
        topic, client_id, timeout=timeout, ready=ready, require_ready=on_ready is not None,
        signal_timeout=signal_timeout, stop_waiting=stop_waiting,
    )
    if triggered:
        perform()
    return triggered


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--topic", default="t1music006", help="巴法虚拟开关主题，必须以 006 结尾")
    parser.add_argument("--timeout", type=int, default=90, help="本次监听等待时间（秒）")
    parser.add_argument(
        "--open-netease", action="store_true", help="收到 on 后打开本机网易云音乐"
    )
    parser.add_argument(
        "--companion", action="store_true", help="从标准输入读取 UID，以 JSON 行报告订阅和触发"
    )
    options = parser.parse_args()

    def emit(event, **fields):
        print(json.dumps({"event": event, **fields}, ensure_ascii=False), flush=True)

    def invalid(message):
        if options.companion:
            emit("error", message=message)
            return 2
        parser.error(message)

    if not TOPIC_PATTERN.fullmatch(options.topic):
        return invalid("主题需要以 006 结尾，且总长为 4 至 64 个字母或数字。")
    if options.timeout < 1:
        return invalid("等待时间至少为 1 秒。")
    if options.companion and options.open_netease:
        return invalid("--companion 与 --open-netease 不能同时使用。")
    if options.open_netease and sys.platform != "darwin":
        return invalid("--open-netease 需要 macOS。")
    if options.companion and sys.stdin.isatty():
        return invalid("请通过管道传入 UID 私钥。")
    if not options.companion and not sys.stdin.isatty():
        return invalid("请从本机终端运行，以隐藏私钥输入。")

    uid = ""
    try:
        try:
            uid = (
                sys.stdin.readline(130) if options.companion
                else getpass.getpass("巴法 UID 私钥（输入不显示）：")
            ).strip()
        except UnicodeError:
            return invalid("请输入巴法控制台的 UID 私钥。")
        if not uid or not uid.isascii() or not uid.isalnum() or len(uid) > 128:
            return invalid("请输入巴法控制台的 UID 私钥。")

        if options.companion:
            triggered = wait_for_on(
                options.topic, uid, timeout=options.timeout,
                ready=lambda: emit("ready", topic=options.topic),
                require_ready=True,
            )
            emit("triggered" if triggered else "timeout", topic=options.topic)
            return 0 if triggered else 1

        def perform():
            if options.open_netease:
                subprocess.run(
                    ["/usr/bin/open", "-b", "com.netease.163music"], check=True
                )
                print("收到 on，已请求 macOS 打开网易云音乐。")
            else:
                print("收到 on，匹配的本机动作是打开网易云音乐。")

        if listen(options.topic, uid, timeout=options.timeout, perform=perform):
            return 0
        print("等待结束，未收到此开关的实时 on 消息。", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        message = str(error)
        if uid:
            message = message.replace(uid, "[已隐藏]")
        if options.companion:
            emit("error", message=message)
        else:
            print(f"试验未完成：{message}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

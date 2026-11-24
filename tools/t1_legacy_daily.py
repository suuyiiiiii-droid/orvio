#!/usr/bin/env python3
"""Prepare NetEase after a confirmed XiaoAI command for the signed T1 0.1.7 build."""

import json
import os
from pathlib import Path
import subprocess
import sys
from time import monotonic


def save_result(path, data):
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_bytes(data)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def prepare_page(executable, started):
    # T1 0.1.7 allows 45 seconds for its entire bridge process.
    budget = min(29.0, 41.0 - (monotonic() - started))
    if budget <= 0:
        return {"result": "skipped", "message": "小爱桥接已用完窗口准备时间。"}
    try:
        process = subprocess.run([str(executable)], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, timeout=budget)
    except subprocess.TimeoutExpired:
        return {"result": "timeout", "message": "网易云页面准备超时。"}
    except OSError:
        return {"result": "error", "message": "无法启动网易云页面准备组件。"}
    return {"result": "ready" if process.returncode == 0 else "error",
            "message": process.stdout.decode("utf-8", errors="replace").strip()[:400]}


def main():
    started = monotonic()
    release = Path(__file__).resolve().parent
    runtime = release.parent.parent
    with (runtime / "last-progress.jsonl").open("wb") as progress:
        bridge = subprocess.run([sys.executable, "-E", "-s", "-B", "-X", "utf8", str(release / "xiaoai_daily.py")],
                                stdout=subprocess.PIPE, stderr=progress,
                                env={**os.environ, "T1_BRIDGE_PROGRESS": "1"})
    save_result(runtime / "last-result.json", bridge.stdout)
    try:
        reply = json.loads(bridge.stdout)
    except (ValueError, RecursionError):
        reply = None
    confirmed = bridge.returncode == 0 and isinstance(reply, dict) and reply.get("event") == "triggered"
    preparation = prepare_page(release / "T1DailyPreparation", started) if confirmed else {"result": "not_requested"}
    save_result(runtime / "last-playback-prep.json", json.dumps(preparation, ensure_ascii=False).encode("utf-8"))
    sys.stdout.buffer.write(bridge.stdout)
    return bridge.returncode


if __name__ == "__main__":
    sys.exit(main())

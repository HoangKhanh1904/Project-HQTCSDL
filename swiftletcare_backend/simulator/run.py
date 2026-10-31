#!/usr/bin/env python3
"""Simulator SwiftletCare - chương trình chạy riêng, gửi dữ liệu mô phỏng qua HTTP API
như một client thật (không đụng trực tiếp vào SQL Server).

Ví dụ:
  export SIMULATOR_TOKEN=...            # cùng giá trị với .env của server (không truyền qua CLI)
  python simulator/run.py --scenario normal --device 1 --interval 3 --duration 60
  python simulator/run.py --scenario birds --house 1 --duration 120
Dừng sớm bằng Ctrl+C. Luôn có giới hạn thời gian (mặc định 60s, tối đa 3600s).
Thoát mã 1 nếu có phản hồi không như mong đợi (dùng được làm test tích hợp).
"""
import argparse
import json
import math
import os
import random
import sys
import time
import urllib.error
import urllib.request
import uuid
from collections import Counter

MAX_DURATION = 3600
# Khoảng giá trị mẫu: chỉnh cho khớp ngưỡng seed của TV1.
NORMAL_TEMP, NORMAL_HUM = (28.0, 30.0), (80.0, 90.0)
HIGH_TEMP, LOW_HUM = (34.0, 37.0), (50.0, 62.0)

READING_SCENARIOS = {"normal", "high_temperature", "low_humidity", "co2_light",
                     "repeat_event", "invalid_input"}
EVENT_SCENARIOS = {"predator": "PREDATOR", "speaker_failure": "SPEAKER_FAILURE",
                   "abnormal_sound": "ABNORMAL_SOUND", "device_offline": "DEVICE_OFFLINE"}
SCENARIOS = sorted(READING_SCENARIOS | {"birds"} | set(EVENT_SCENARIOS))


class Client:
    def __init__(self, base_url, token):
        self.base_url, self.token = base_url.rstrip("/"), token

    def post(self, path, payload):
        req = urllib.request.Request(
            self.base_url + path, data=json.dumps(payload).encode(), method="POST",
            headers={"Content-Type": "application/json", "X-Simulator-Token": self.token})
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as err:
            try:
                return err.code, json.loads(err.read() or b"{}")
            except ValueError:
                return err.code, {}
        except (urllib.error.URLError, TimeoutError, OSError):
            return 0, {"code": "CONNECTION_ERROR"}


class Runner:
    def __init__(self, client, args):
        self.client, self.args = client, args
        self.stats, self.unexpected, self.tick = Counter(), 0, 0

    def send(self, path, payload, expect, label=""):
        status, body = self.client.post(path, payload)
        self.stats[status] += 1
        good = status in expect
        if not good:
            self.unexpected += 1
        mark = "OK  " if good else "FAIL"
        print(f"[{self.tick:>4}] {mark} {path} {label}-> HTTP {status} {body.get('code', '')}")
        return status, body

    # ----- scenarios đẩy số liệu cảm biến -----
    def reading(self, temp, hum, **extra):
        return {"device_id": self.args.device, "temperature": round(temp, 2),
                "humidity": round(hum, 2), "source_event_id": str(uuid.uuid4()), **extra}

    def do_readings(self):
        s, t = self.args.scenario, self.tick
        temp, hum = random.uniform(*NORMAL_TEMP), random.uniform(*NORMAL_HUM)
        path = "/api/simulator/readings"
        if s == "normal":
            self.send(path, self.reading(temp, hum), {200, 201})
        elif s == "high_temperature":
            self.send(path, self.reading(random.uniform(*HIGH_TEMP), hum), {200, 201})
        elif s == "low_humidity":
            self.send(path, self.reading(temp, random.uniform(*LOW_HUM)), {200, 201})
        elif s == "co2_light":
            co2 = 600 + 400 * math.sin(t / 5) + random.uniform(-30, 30)
            lux = max(0.0, 300 * math.sin(t / 10))
            self.send(path, self.reading(temp, hum, co2_ppm=round(max(co2, 0), 1),
                                         light_lux=round(lux, 1)), {200, 201})
        elif s == "repeat_event":
            p = self.reading(temp, hum)
            self.send(path, p, {200, 201}, "gửi lần 1 ")
            self.send(path, p, {200}, "retry cùng UUID ")
            self.send(path, {**p, "temperature": p["temperature"] + 1}, {409},
                      "cùng UUID khác payload ")
        elif s == "invalid_input":
            bad = [
                {**self.reading(temp, hum), "humidity": 150},
                {**self.reading(temp, hum), "co2_ppm": -5},
                {**self.reading(temp, hum), "source_event_id": "khong-phai-guid"},
                {k: v for k, v in self.reading(temp, hum).items() if k != "device_id"},
                {**self.reading(temp, hum), "temperature": "nóng"},
            ]
            self.send(path, bad[t % len(bad)], {400}, f"payload lỗi #{t % len(bad)} ")

    # ----- scenarios sự kiện chim / bất thường (endpoint backend sẽ bổ sung sau) -----
    def do_birds(self):
        payload = {"house_id": self.args.house, "direction": random.choice(["IN", "OUT"]),
                   "count": random.randint(1, 8), "source_event_id": str(uuid.uuid4())}
        self.send("/api/simulator/bird-movements", payload, {200, 201},
                  f"{payload['direction']} x{payload['count']} ")

    def do_event(self):
        payload = {"house_id": self.args.house, "event_type": EVENT_SCENARIOS[self.args.scenario],
                   "source_event_id": str(uuid.uuid4())}
        if self.args.device:
            payload["device_id"] = self.args.device
        self.send("/api/simulator/events", payload, {200, 201}, payload["event_type"] + " ")

    def step(self):
        if self.args.scenario in READING_SCENARIOS:
            self.do_readings()
        elif self.args.scenario == "birds":
            self.do_birds()
        else:
            self.do_event()


def parse_args(argv=None):
    p = argparse.ArgumentParser(description="Simulator SwiftletCare")
    p.add_argument("--scenario", required=True, choices=SCENARIOS)
    p.add_argument("--api", default=os.getenv("SWIFTLET_API", "http://127.0.0.1:5000"))
    p.add_argument("--interval", type=float, default=3.0, help="giây giữa 2 lần gửi (>= 0.5)")
    p.add_argument("--duration", type=float, default=60.0,
                   help=f"tổng thời gian chạy, giây (tối đa {MAX_DURATION})")
    p.add_argument("--device", type=int, help="DeviceId (cho các scenario số liệu cảm biến)")
    p.add_argument("--house", type=int, help="HouseId (cho birds và các sự kiện)")
    p.add_argument("--seed", type=int)
    args = p.parse_args(argv)
    if args.interval < 0.5:
        p.error("--interval phải >= 0.5")
    if not 0 < args.duration <= MAX_DURATION:
        p.error(f"--duration phải trong khoảng (0, {MAX_DURATION}]")
    if args.scenario in READING_SCENARIOS and not args.device:
        p.error("scenario này cần --device")
    if (args.scenario == "birds" or args.scenario in EVENT_SCENARIOS) and not args.house:
        p.error("scenario này cần --house")
    return args


def main(argv=None):
    args = parse_args(argv)
    token = os.getenv("SIMULATOR_TOKEN")
    if not token:
        sys.exit("Thiếu biến môi trường SIMULATOR_TOKEN.")
    if args.seed is not None:
        random.seed(args.seed)
    runner = Runner(Client(args.api, token), args)
    deadline = time.monotonic() + args.duration
    print(f"Chạy '{args.scenario}' tới {args.api} trong {args.duration:g}s, mỗi {args.interval:g}s. Ctrl+C để dừng.")
    try:
        while time.monotonic() < deadline:
            runner.step()
            runner.tick += 1
            time.sleep(min(args.interval, max(0.0, deadline - time.monotonic())))
    except KeyboardInterrupt:
        print("\nĐã dừng theo yêu cầu.")
    print(f"Tổng kết: {dict(runner.stats)} | không như mong đợi: {runner.unexpected}")
    return 1 if runner.unexpected else 0


if __name__ == "__main__":
    sys.exit(main())

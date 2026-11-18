#!/usr/bin/env python3
"""Mock DMXtra controller for developing the app without the board.

Copies the HTTP API in embedded/API.md (firmware 0.2.0), including status
codes, error bodies, overlap rules, the default patch, and closing the
connection after every response. Like the board, it handles one connection
at a time. Standard library only.

    python3 tools/mock_server.py --port 8080
    python3 tools/mock_server.py --host 0.0.0.0 --port 8080   # reachable from a phone
"""

from __future__ import annotations

import argparse
import json
import socketserver
import sys
import time
from http.server import BaseHTTPRequestHandler

FIRMWARE_VERSION = "0.2.0"
UNIVERSE_SIZE = 512
MAX_FIXTURES = 32
MAX_NAME_LEN = 31
MAX_BODY = 4096

FIXTURE_TYPES = [
    {"type": "dimmer", "label": "Dimmer", "channelCount": 1, "channels": ["intensity"]},
    {"type": "rgb", "label": "RGB", "channelCount": 3, "channels": ["red", "green", "blue"]},
    {"type": "rgbw", "label": "RGBW", "channelCount": 4, "channels": ["red", "green", "blue", "white"]},
]
TYPES_BY_KEY = {t["type"]: t for t in FIXTURE_TYPES}

STATUS_TEXT = {
    200: "OK", 201: "Created", 204: "No Content", 400: "Bad Request", 404: "Not Found",
    405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large", 507: "Insufficient Storage",
}

_MISSING = object()


# ---------------------------------------------------------------------------
# State (mirrors the firmware: universe is the only store of values)
# ---------------------------------------------------------------------------
class Controller:
    def __init__(self) -> None:
        self.universe = [0] * UNIVERSE_SIZE  # index 0 == channel 1
        self.slots: list[dict | None] = [None] * MAX_FIXTURES
        self.next_id = 1
        rgb = TYPES_BY_KEY["rgb"]
        self.add("Wash 1", rgb, 1)
        self.add("Wash 2", rgb, 4)

    @property
    def fixtures(self) -> list[dict]:
        return [f for f in self.slots if f is not None]

    def find(self, fid: int) -> dict | None:
        return next((f for f in self.fixtures if f["id"] == fid), None)

    def overlaps(self, address: int, count: int, ignore_id: int) -> bool:
        end = address + count
        for f in self.fixtures:
            if f["id"] == ignore_id:
                continue
            f_end = f["address"] + f["type"]["channelCount"]
            if address < f_end and f["address"] < end:
                return True
        return False

    def add(self, name: str, ftype: dict, address: int) -> dict | None:
        for i, slot in enumerate(self.slots):
            if slot is None:
                f = {"id": self.next_id, "name": name, "type": ftype, "address": address}
                self.next_id += 1
                self.slots[i] = f
                return f
        return None

    def remove(self, f: dict) -> None:
        self.slots[self.slots.index(f)] = None

    def to_json(self, f: dict) -> dict:
        t = f["type"]
        a = f["address"]
        return {
            "id": f["id"],
            "name": f["name"],
            "type": t["type"],
            "address": a,
            "channelCount": t["channelCount"],
            "channels": list(t["channels"]),
            "values": self.universe[a - 1 : a - 1 + t["channelCount"]],
        }


# ---------------------------------------------------------------------------
# ArduinoJson-flavoured helpers
# ---------------------------------------------------------------------------
def parse_json(body: str):
    """Like deserializeJson: parses the first JSON value, ignores trailing text.
    Returns _MISSING on error (including an empty body)."""
    try:
        value, _ = json.JSONDecoder().raw_decode(body.lstrip())
        return value
    except (ValueError, json.JSONDecodeError):
        return _MISSING


def get(doc, key):
    """req["key"]: None unless doc is an object containing key."""
    return doc.get(key) if isinstance(doc, dict) else None


def is_int(v) -> bool:
    """JsonVariant::is<int>(): a JSON integer (not bool, not float) in int32 range."""
    return isinstance(v, int) and not isinstance(v, bool) and -(2**31) <= v < 2**31


def is_dmx_value(v) -> bool:
    return is_int(v) and 0 <= v <= 255


def name_ok(v) -> bool:
    return isinstance(v, str) and 1 <= len(v.encode("utf-8")) <= MAX_NAME_LEN


def parse_uint(s: str) -> int:
    """Strict non-negative integer parse; -1 if s isn't one."""
    if len(s) == 0 or len(s) > 6 or not all("0" <= c <= "9" for c in s):
        return -1
    return int(s)


def query_param(query: str, key: str) -> str:
    prefix = key + "="
    for pair in query.split("&"):
        if pair.startswith(prefix):
            return pair[len(prefix):]
    return ""


def fits(address: int, count: int) -> bool:
    return address >= 1 and address + count - 1 <= UNIVERSE_SIZE


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    controller: Controller
    latency = 0.0
    quiet = False

    # Route every method (including unknown ones) through one handler.
    def __getattr__(self, name):
        if name.startswith("do_"):
            return self.handle_request
        raise AttributeError(name)

    def log_message(self, fmt, *args):
        if not self.quiet:
            sys.stderr.write("%s %s\n" % (self.log_date_time_string(), fmt % args))

    # -- responses ---------------------------------------------------------
    def send(self, code: int, body: str = "") -> None:
        data = body.encode("utf-8")
        self.log_request(code)
        self.send_response_only(code, STATUS_TEXT.get(code, "Error"))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Connection", "close")
        if data:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

    def send_json(self, code: int, obj) -> None:
        self.send(code, json.dumps(obj, separators=(",", ":"), ensure_ascii=False))

    def send_error_json(self, code: int, message: str) -> None:
        self.send_json(code, {"error": message})

    # -- request -----------------------------------------------------------
    def handle_request(self) -> None:
        if self.latency:
            time.sleep(self.latency)
        method = self.command
        path, _, query = self.path.partition("?")
        if len(path) > 1 and path.endswith("/"):
            path = path[:-1]

        try:
            length = int(self.headers.get("Content-Length", "0").strip() or 0)
        except ValueError:
            length = 0
        if length > MAX_BODY:
            self.send_error_json(413, "body too large")
            return
        body = self.rfile.read(length).decode("utf-8", errors="replace") if length > 0 else ""

        self.route(method, path, query, body)

    def route(self, method: str, path: str, query: str, body: str) -> None:
        c = self.controller
        if method == "OPTIONS":
            return self.send(204)

        if path == "/":
            if method == "GET":
                return self.send_json(200, {
                    "name": "DMXtra", "firmware": FIRMWARE_VERSION, "universeSize": UNIVERSE_SIZE,
                    "maxFixtures": MAX_FIXTURES, "fixtureCount": len(c.fixtures),
                })
            return self.send_error_json(405, "use GET")

        if path == "/fixture-types":
            if method == "GET":
                return self.send_json(200, FIXTURE_TYPES)
            return self.send_error_json(405, "use GET")

        if path == "/fixtures":
            if method == "GET":
                ordered = sorted(c.fixtures, key=lambda f: (f["address"], f["id"]))
                return self.send_json(200, [c.to_json(f) for f in ordered])
            if method == "POST":
                return self.create_fixture(body)
            return self.send_error_json(405, "use GET or POST")

        if path.startswith("/fixtures/"):
            f = c.find(parse_uint(path[10:]))
            if f is None:
                return self.send_error_json(404, "no such fixture")
            if method == "GET":
                return self.send_json(200, c.to_json(f))
            if method == "PATCH":
                return self.update_fixture(f, body)
            if method == "DELETE":
                a, n = f["address"], f["type"]["channelCount"]
                c.universe[a - 1 : a - 1 + n] = [0] * n
                c.remove(f)
                return self.send(204)
            return self.send_error_json(405, "use GET, PATCH, or DELETE")

        if path == "/dmx":
            if method == "GET":
                return self.get_dmx(query)
            if method == "POST":
                return self.set_dmx(body)
            return self.send_error_json(405, "use GET or POST")

        if path == "/blackout":
            if method == "POST":
                c.universe = [0] * UNIVERSE_SIZE
                return self.send(204)
            return self.send_error_json(405, "use POST")

        return self.send_error_json(404, "not found")

    # -- handlers ----------------------------------------------------------
    def create_fixture(self, body: str) -> None:
        c = self.controller
        req = parse_json(body)
        if req is _MISSING:
            return self.send_error_json(400, 'body must be JSON like {"name":"Wash 3","type":"rgb","address":7}')
        name = get(req, "name")
        if not name_ok(name):
            return self.send_error_json(400, "name is required (1-31 characters)")
        type_key = get(req, "type")
        ftype = TYPES_BY_KEY.get(type_key) if isinstance(type_key, str) else None
        if ftype is None:
            return self.send_error_json(400, "type must be one of the keys from GET /fixture-types")
        address = get(req, "address")
        if not is_int(address):
            return self.send_error_json(400, "address is required")
        count = ftype["channelCount"]
        if not fits(address, count):
            return self.send_error_json(400, "fixture does not fit in the universe at that address")
        if c.overlaps(address, count, -1):
            return self.send_error_json(409, "address overlaps another fixture")
        f = c.add(name, ftype, address)
        if f is None:
            return self.send_error_json(507, "patch is full")
        self.send_json(201, c.to_json(f))

    def update_fixture(self, f: dict, body: str) -> None:
        c = self.controller
        req = parse_json(body)
        if req is _MISSING or not isinstance(req, dict):
            return self.send_error_json(400, "body must be a JSON object")
        count = f["type"]["channelCount"]

        new_name = None
        if req.get("name") is not None:
            new_name = req["name"]
            if not name_ok(new_name):
                return self.send_error_json(400, "name must be 1-31 characters")

        new_address = -1
        if req.get("address") is not None:
            if not is_int(req["address"]):
                return self.send_error_json(400, "address must be an integer")
            new_address = req["address"]
            if not fits(new_address, count):
                return self.send_error_json(400, "fixture does not fit in the universe at that address")
            if c.overlaps(new_address, count, f["id"]):
                return self.send_error_json(409, "address overlaps another fixture")

        values = req.get("values")
        if values is not None:
            if not isinstance(values, list) or len(values) != count:
                return self.send_error_json(400, "values must be an array with one entry per channel")
            for v in values:
                if v is not None and not is_dmx_value(v):
                    return self.send_error_json(400, "values must be integers 0-255 or null")

        if new_name is None and new_address < 0 and not isinstance(values, list):
            return self.send_error_json(400, "provide at least one of name, address, values")

        if new_name is not None:
            f["name"] = new_name
        if new_address >= 0 and new_address != f["address"]:
            old = f["address"]
            current = c.universe[old - 1 : old - 1 + count]
            c.universe[old - 1 : old - 1 + count] = [0] * count
            f["address"] = new_address
            c.universe[new_address - 1 : new_address - 1 + count] = current
        if isinstance(values, list):
            for i, v in enumerate(values):
                if v is not None:
                    c.universe[f["address"] - 1 + i] = v
        self.send_json(200, c.to_json(f))

    def get_dmx(self, query: str) -> None:
        s = query_param(query, "start")
        n = query_param(query, "count")
        start = parse_uint(s) if s else 1
        count = parse_uint(n) if n else UNIVERSE_SIZE - start + 1
        if start < 1 or start > UNIVERSE_SIZE or count < 1 or start + count - 1 > UNIVERSE_SIZE:
            return self.send_error_json(400, "start/count out of range (channels are 1-512)")
        self.send_json(200, {"start": start, "values": self.controller.universe[start - 1 : start - 1 + count]})

    def set_dmx(self, body: str) -> None:
        req = parse_json(body)
        if req is _MISSING:
            return self.send_error_json(400, 'body must be JSON like {"start":1,"values":[255,0,0]}')
        start = get(req, "start")
        start = start if is_int(start) else 1  # req["start"] | 1
        values = get(req, "values")
        if not isinstance(values, list) or len(values) == 0:
            return self.send_error_json(400, "values must be a non-empty array")
        if start < 1 or start + len(values) - 1 > UNIVERSE_SIZE:
            return self.send_error_json(400, "start/values out of range (channels are 1-512)")
        if not all(is_dmx_value(v) for v in values):
            return self.send_error_json(400, "values must be integers 0-255")
        self.controller.universe[start - 1 : start - 1 + len(values)] = values
        self.send_json(200, {"start": start, "count": len(values)})


class OneAtATimeServer(socketserver.TCPServer):
    """Single-threaded, like the board: one connection at a time."""
    allow_reuse_address = True
    request_queue_size = 4


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", default="127.0.0.1", help="interface to bind (use 0.0.0.0 for a phone on the LAN)")
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--latency", type=float, default=0, help="extra milliseconds per request, to feel like the board")
    p.add_argument("--quiet", action="store_true", help="don't log requests")
    args = p.parse_args()

    Handler.controller = Controller()
    Handler.latency = args.latency / 1000
    Handler.quiet = args.quiet
    with OneAtATimeServer((args.host, args.port), Handler) as server:
        print(f"Mock DMXtra {FIRMWARE_VERSION} on http://{args.host}:{args.port}", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()

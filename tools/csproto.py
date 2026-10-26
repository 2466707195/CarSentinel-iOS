"""CarSentinel 360 协议的 Python 参考实现。

用途：
  * protocol-probe.py 用它伪装成手机端，去探真实的 Android 车机端
  * fake-carunit.py   用它伪装成车机端，供本机自测
  * 两边都跑通，才能说明「按 PROTOCOL.md 的理解是一致的」

常量与 docs/PROTOCOL.md 一一对应；改这里必须同步改协议文档和两端源码。
"""
import json
import socket
import struct
import time

# ---------------------------------------------------------------- 常量（协议 §1）
SERVICE_PORT = 45678          # TCP：控制 + 视频共用，靠首字节分流
ANNOUNCE_PORT = 45677         # UDP：车机定时广播
PROBE_PORT = 45676            # UDP：手机主动探测
BROADCAST_ADDR = "255.255.255.255"

FRAME_MAGIC = b"CS60"
FRAME_VERSION = 1
HEADER_SIZE = 24
FLAG_KEYFRAME = 0x01

MAX_LINE_BYTES = 64 * 1024
CONTROL_IDLE_TIMEOUT = 15.0   # 秒
ANNOUNCE_INTERVAL = 1.0       # 秒
PING_INTERVAL = 5.0           # 秒

SUBSCRIBE_PREFIX = "SUBSCRIBE "

# 帧头字段偏移（协议 §5.2）
OFF_MAGIC = 0
OFF_VERSION = 4
OFF_FLAGS = 5
OFF_RESERVED = 6
OFF_CAMERA_ID = 8
OFF_PTS_US = 12
OFF_PAYLOAD_LEN = 20

POS_FRONT, POS_REAR, POS_LEFT, POS_RIGHT, POS_INNER, POS_UNKNOWN = (
    "front", "rear", "left", "right", "inner", "unknown")


# ---------------------------------------------------------------- 帧（协议 §5.2）
def build_frame(camera_id, pts_us, keyframe, payload):
    """24 字节大端帧头 + Annex-B 负载。"""
    header = bytearray(HEADER_SIZE)
    header[OFF_MAGIC:OFF_MAGIC + 4] = FRAME_MAGIC
    header[OFF_VERSION] = FRAME_VERSION
    header[OFF_FLAGS] = FLAG_KEYFRAME if keyframe else 0
    header[OFF_RESERVED:OFF_RESERVED + 2] = b"\x00\x00"
    struct.pack_into(">I", header, OFF_CAMERA_ID, camera_id)
    struct.pack_into(">Q", header, OFF_PTS_US, pts_us)
    struct.pack_into(">I", header, OFF_PAYLOAD_LEN, len(payload))
    return bytes(header) + payload


class FrameHeader(object):
    __slots__ = ("camera_id", "flags", "pts_us", "payload_len")

    def __init__(self, camera_id, flags, pts_us, payload_len):
        self.camera_id = camera_id
        self.flags = flags
        self.pts_us = pts_us
        self.payload_len = payload_len

    @property
    def is_keyframe(self):
        return (self.flags & FLAG_KEYFRAME) != 0

    def __repr__(self):
        return "FrameHeader(cam=%d, key=%s, pts=%d, len=%d)" % (
            self.camera_id, self.is_keyframe, self.pts_us, self.payload_len)


def parse_frame_header(data):
    """data 必须正好 24 字节。魔数或版本不对返回 None。"""
    if len(data) != HEADER_SIZE:
        return None
    if bytes(data[OFF_MAGIC:OFF_MAGIC + 4]) != FRAME_MAGIC:
        return None
    if data[OFF_VERSION] != FRAME_VERSION:
        return None
    return FrameHeader(
        camera_id=struct.unpack_from(">I", data, OFF_CAMERA_ID)[0],
        flags=data[OFF_FLAGS],
        pts_us=struct.unpack_from(">Q", data, OFF_PTS_US)[0],
        payload_len=struct.unpack_from(">I", data, OFF_PAYLOAD_LEN)[0],
    )


# ---------------------------------------------------------------- Annex-B
START_CODE = b"\x00\x00\x00\x01"


def split_annexb(data):
    """按起始码切出所有 NAL（不含起始码）。与两端源码的 splitNalUnits 同一套逻辑。"""
    out = []
    i = 0
    n = len(data)
    codes = []
    while i + 2 < n:
        if data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1:
            four = i > 0 and data[i - 1] == 0
            codes.append((i - 1 if four else i, 4 if four else 3))
            i += 3
        else:
            i += 1
    for idx, (pos, ln) in enumerate(codes):
        start = pos + ln
        end = codes[idx + 1][0] if idx + 1 < len(codes) else n
        if end > start:
            out.append(bytes(data[start:end]))
    return out


def nal_type(nal):
    """NAL 头字节的低 5 位。7=SPS 8=PPS 5=IDR 1=非IDR"""
    return nal[0] & 0x1F if nal else -1


def nal_type_name(t):
    return {1: "non-IDR", 5: "IDR", 6: "SEI", 7: "SPS", 8: "PPS",
            9: "AUD"}.get(t, "type%d" % t)


# ---------------------------------------------------------------- announce（协议 §2.1）
def make_announce(name, cameras, port=SERVICE_PORT):
    return json.dumps({
        "t": "announce",
        "v": FRAME_VERSION,
        "name": name,
        "port": port,
        "cameras": [
            {"id": c["id"], "name": c["name"], "pos": c["pos"],
             "w": c["w"], "h": c["h"]} for c in cameras
        ],
        "caps": ["h264"],
    }, ensure_ascii=False)


def parse_announce(line):
    try:
        root = json.loads(line)
    except ValueError:
        return None
    if not isinstance(root, dict) or root.get("t") != "announce":
        return None
    if "v" in root and root["v"] > FRAME_VERSION:
        return None
    if not root.get("name") or "port" not in root:
        return None
    cams = []
    for c in root.get("cameras") or []:
        if "id" not in c:
            continue
        cams.append({
            "id": c["id"],
            "name": c.get("name") or ("camera-%d" % c["id"]),
            "pos": c.get("pos") or POS_UNKNOWN,
            "w": c.get("w") or 0,
            "h": c.get("h") or 0,
        })
    cams.sort(key=lambda c: (
        {POS_FRONT: 0, POS_REAR: 1, POS_LEFT: 2, POS_RIGHT: 3,
         POS_INNER: 4}.get(c["pos"], 5), c["id"]))
    return {"name": root["name"], "port": root["port"], "cameras": cams}


# ---------------------------------------------------------------- 控制消息（协议 §4）
def ctl_hello():
    return json.dumps({"t": "hello", "role": "phone", "v": FRAME_VERSION})


def ctl_list():
    return json.dumps({"t": "list"})


def ctl_subscribe(camera_id):
    return json.dumps({"t": "subscribe", "camera": camera_id})


def ctl_unsubscribe(camera_id):
    return json.dumps({"t": "unsubscribe", "camera": camera_id})


def ctl_keyframe(camera_id):
    return json.dumps({"t": "keyframe", "camera": camera_id})


def ctl_stats():
    return json.dumps({"t": "stats"})


def ctl_ping(i):
    return json.dumps({"t": "ping", "id": i})


CTL_BYE = json.dumps({"t": "bye"})


def ctl_type(line):
    try:
        return json.loads(line).get("t")
    except ValueError:
        return None


def ctl_cameras(line):
    """从 welcome / cameras 消息里取摄像头列表。"""
    try:
        root = json.loads(line)
    except ValueError:
        return None
    if "cameras" not in root:
        return None
    out = []
    for c in root["cameras"]:
        if "id" not in c:
            continue
        out.append({"id": c["id"], "name": c.get("name") or "",
                    "pos": c.get("pos") or POS_UNKNOWN,
                    "w": c.get("w") or 0, "h": c.get("h") or 0})
    return out


# ---------------------------------------------------------------- socket 助手
def read_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(min(65536, n - len(buf)))
        if not chunk:
            raise ConnectionError("peer closed (wanted %d, got %d)" % (n, len(buf)))
        buf.extend(chunk)
    return bytes(buf)


def read_line(sock, max_bytes=MAX_LINE_BYTES):
    """读到 \n 为止，返回不含换行的 str。"""
    buf = bytearray()
    while len(buf) < max_bytes:
        b = sock.recv(1)
        if not b:
            raise ConnectionError("peer closed mid-line")
        if b == b"\n":
            break
        if b != b"\r":
            buf.extend(b)
    return buf.decode("utf-8", "replace")


def write_all(sock, data):
    sock.sendall(data)


def write_line(sock, text):
    sock.sendall((text + "\n").encode("utf-8"))

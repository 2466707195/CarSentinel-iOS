"""CarSentinel 360 假车机端 —— 供本机自测 protocol-probe.py 用。

它**不产生真实画面**：发的是一组合成 H.264 NAL（SPS/PPS/IDR 结构正确，
但切片数据是占位的）。它的价值在于验证**协议层**：
  · announce 广播 / DISCOVER 应答
  · TCP 首字节分流
  · 控制通道全部消息
  · 24 字节帧头 + Annex-B 负载
  · 每个 IDR 前重带 SPS+PPS（协议 §5.3）

要验真实编码输出，请用 protocol-probe.py 去探真的 Android 车机端。

用法：
    python tools/fake-carunit.py                 # 前台跑
    python tools/fake-carunit.py --fps 30 --port 45678
"""
import argparse
import json
import os
import socket
import struct
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import csproto as P  # noqa: E402

# 合成 NAL：NAL 头字节的低 5 位决定类型，后面的字节是占位数据
SPS = bytes([0x67, 0x42, 0x00, 0x0A, 0xF8, 0x41, 0xA2])          # type 7
PPS = bytes([0x68, 0xCE, 0x3C, 0x80])                            # type 8
IDR = bytes([0x65, 0x88, 0x80, 0x40, 0x00, 0x00, 0x1E, 0x40])    # type 5
NONIDR = bytes([0x41, 0x9A, 0x20, 0x18, 0x40])                   # type 1
SEI = bytes([0x06, 0x01, 0x02])                                  # type 6


class CarUnit(object):
    def __init__(self, host="0.0.0.0", port=P.SERVICE_PORT, name="FakeCar360",
                 cameras=None, fps=30, announce_to=P.BROADCAST_ADDR):
        self.host = host
        self.port = port
        self.name = name
        self.cameras = cameras or [
            {"id": 0, "name": "前视", "pos": "front", "w": 1280, "h": 720},
            {"id": 1, "name": "后视", "pos": "rear", "w": 1280, "h": 720},
        ]
        self.fps = fps
        self.announce_to = announce_to
        self._stop = threading.Event()
        self._threads = []
        self._started_at = time.time()

    # ------------------------------------------------------------ 生命周期
    def start(self):
        t = threading.Thread(target=self._announce_loop, daemon=True)
        t.start()
        self._threads.append(t)
        t = threading.Thread(target=self._discover_loop, daemon=True)
        t.start()
        self._threads.append(t)
        t = threading.Thread(target=self._tcp_loop, daemon=True)
        t.start()
        self._threads.append(t)

    def serve_forever(self):
        self.start()
        while not self._stop.is_set():
            self._stop.wait(0.5)

    def stop(self):
        self._stop.set()

    # ------------------------------------------------------------ UDP 广播（协议 §2.1）
    def _announce_loop(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        msg = P.make_announce(self.name, self.cameras, self.port).encode("utf-8")
        while not self._stop.is_set():
            try:
                sock.sendto(msg, (self.announce_to, P.ANNOUNCE_PORT))
            except OSError:
                pass
            self._stop.wait(P.ANNOUNCE_INTERVAL)
        sock.close()

    # ------------------------------------------------------------ DISCOVER（协议 §2.2）
    def _discover_loop(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("0.0.0.0", P.PROBE_PORT))
        except OSError:
            return
        sock.settimeout(0.5)
        msg = P.make_announce(self.name, self.cameras, self.port).encode("utf-8")
        while not self._stop.is_set():
            try:
                data, addr = sock.recvfrom(1024)
            except socket.timeout:
                continue
            except OSError:
                return
            if data.strip() == b"DISCOVER":
                try:
                    sock.sendto(msg, addr)      # 单播回来源，不是广播
                except OSError:
                    pass
        sock.close()

    # ------------------------------------------------------------ TCP（协议 §3）
    def _tcp_loop(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((self.host, self.port))
        srv.listen(16)
        srv.settimeout(0.5)
        while not self._stop.is_set():
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()
        srv.close()

    def _handle(self, conn):
        try:
            first = conn.recv(1)
            if not first:
                conn.close()
                return
            if first == b"{":
                # _rest_of_line 返回 str，所以这里也要用 str 拼
                self._control(conn, "{" + self._rest_of_line(conn))
            elif first == b"S":
                rest = self._rest_of_line(conn)
                self._video(conn, ("S" + rest).strip())
            else:
                conn.close()
        except OSError:
            try:
                conn.close()
            except OSError:
                pass

    @staticmethod
    def _rest_of_line(conn, limit=P.MAX_LINE_BYTES):
        buf = bytearray()
        while len(buf) < limit:
            b = conn.recv(1)
            if not b or b == b"\n":
                break
            if b != b"\r":
                buf.extend(b)
        return bytes(buf).decode("utf-8", "replace")

    # ------------------------------------------------------------ 控制（协议 §4）
    def _control(self, conn, first_line):
        # 连上就先推 welcome（真车机端就是这么做的）
        self._send(conn, {"t": "welcome", "v": P.FRAME_VERSION,
                          "name": self.name, "cameras": self.cameras})
        conn.settimeout(P.CONTROL_IDLE_TIMEOUT)
        while not self._stop.is_set():
            try:
                line = self._rest_of_line(conn)
            except (socket.timeout, OSError):
                break
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                self._send(conn, {"t": "error", "code": 400, "msg": "bad json"})
                continue
            t = msg.get("t")
            if t == "hello":
                self._send(conn, {"t": "welcome", "v": P.FRAME_VERSION,
                                  "name": self.name, "cameras": self.cameras})
            elif t == "list":
                self._send(conn, {"t": "cameras", "cameras": self.cameras})
            elif t == "subscribe":
                cid = msg.get("camera")
                if any(c["id"] == cid for c in self.cameras):
                    self._send(conn, {"t": "subscribed", "camera": cid})
                else:
                    self._send(conn, {"t": "error", "code": 404,
                                      "msg": "no such camera"})
            elif t == "unsubscribe":
                self._send(conn, {"t": "unsubscribed", "camera": msg.get("camera")})
            elif t == "keyframe":
                self._send(conn, {"t": "ok"})
            elif t == "stats":
                self._send(conn, {"t": "stats", "cpu": 0.12,
                                  "netKbps": 6400,
                                  "uptimeSec": int(time.time() - self._started_at)})
            elif t == "ping":
                self._send(conn, {"t": "pong", "id": msg.get("id")})
            elif t == "bye":
                break
            else:
                self._send(conn, {"t": "error", "code": 400,
                                  "msg": "unknown message %s" % t})
        try:
            conn.close()
        except OSError:
            pass

    def _send(self, conn, obj):
        conn.sendall(json.dumps(obj, ensure_ascii=False).encode("utf-8") + b"\n")

    # ------------------------------------------------------------ 视频（协议 §5）
    def _video(self, conn, first_line):
        parts = first_line.split()
        if not parts or parts[0] != "SUBSCRIBE":
            conn.sendall(b"ERR 400 expected SUBSCRIBE <id>\n")
            conn.close()
            return
        try:
            cid = int(parts[1])
        except (IndexError, ValueError):
            conn.sendall(b"ERR 400 bad camera id\n")
            conn.close()
            return
        cam = next((c for c in self.cameras if c["id"] == cid), None)
        if cam is None:
            conn.sendall(b"ERR 404 no such camera\n")
            conn.close()
            return

        conn.sendall(("OK %d %d %d %s\n"
                      % (cam["w"], cam["h"], self.fps, "h264")).encode("ascii"))
        conn.settimeout(None)

        frame_interval = 1.0 / max(self.fps, 1)
        idx = 0
        pts_us = 0
        while not self._stop.is_set():
            key = (idx % self.fps) == 0        # 每秒一个 IDR
            if key:
                payload = P.START_CODE + SPS + P.START_CODE + PPS + \
                    P.START_CODE + SEI + P.START_CODE + IDR
            else:
                payload = P.START_CODE + NONIDR
            frame = P.build_frame(cid, pts_us, key, payload)
            try:
                conn.sendall(frame)
            except OSError:
                break
            idx += 1
            pts_us += int(1_000_000 / max(self.fps, 1))
            time.sleep(frame_interval)
        try:
            conn.close()
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser(description="CarSentinel 360 假车机端（协议自测用）")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=P.SERVICE_PORT)
    ap.add_argument("--name", default="FakeCar360")
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--announce-to", default=P.BROADCAST_ADDR,
                    help="announce 发往哪里；本机自测填 127.0.0.1")
    args = ap.parse_args()

    unit = CarUnit(host=args.host, port=args.port, name=args.name,
                   fps=args.fps, announce_to=args.announce_to)
    print("假车机端启动：TCP %s:%d，announce -> %s:%d，%d 路摄像头，%d fps"
          % (args.host, args.port, args.announce_to, P.ANNOUNCE_PORT,
             len(unit.cameras), args.fps))
    print("Ctrl-C 退出")
    try:
        unit.serve_forever()
    except KeyboardInterrupt:
        unit.stop()
        print("\n已停止")


if __name__ == "__main__":
    main()

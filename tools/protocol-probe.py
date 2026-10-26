"""CarSentinel 360 协议探针 —— 伪装成手机端，去探真实的 Android 车机端。

解决的问题：App 装上了但是没画面，到底是谁的锅？
  跑一遍本脚本，就能把「车机端 / 网络 / 手机端」三者分开：
    · discover 不到            → UDP 广播被路由器挡了，或车机服务没开
    · 连上但 hello 没响应      → 车机 TCP 服务异常
    · 握手 OK 但没有帧         → 摄像头没打开 / 编码器没起来
    · 有帧但第一个关键帧没 SPS → 手机端必然花屏（车机端拼帧有问题）
    · 全绿                     → 车机端没问题，去查 iOS 端

用法：
    python tools/protocol-probe.py                     # 自动发现（UDP 广播）
    python tools/protocol-probe.py --host 192.168.1.23 # 直连指定车机
    python tools/protocol-probe.py --camera 0 --seconds 5
    python tools/protocol-probe.py --selftest          # 本机自测（不需要车机）

⚠️ 探针发出去的 H.264 相关请求是真实的，但它自己不解码 —— 它只验协议。
"""
import argparse
import json
import os
import socket
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import csproto as P  # noqa: E402


# ---------------------------------------------------------------- 发现
def discover(timeout=3.0):
    """被动听 45677 广播 + 主动往 45676 发 DISCOVER。返回 {host: announce}"""
    found = {}
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("0.0.0.0", P.ANNOUNCE_PORT))
    except OSError as e:
        print("  [warn] 绑定 UDP %d 失败：%s（被动收听不可用，只靠主动探测）"
              % (P.ANNOUNCE_PORT, e))
    sock.settimeout(0.4)

    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    probe.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    try:
        probe.sendto(b"DISCOVER\n", (P.BROADCAST_ADDR, P.PROBE_PORT))
    except OSError as e:
        print("  [warn] 发送 DISCOVER 失败：%s" % e)
    finally:
        probe.close()

    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            data, addr = sock.recvfrom(4096)
        except socket.timeout:
            continue
        except OSError:
            break
        ann = P.parse_announce(data.decode("utf-8", "replace"))
        if ann:
            found[addr[0]] = ann
    sock.close()
    return found


# ---------------------------------------------------------------- 控制通道
def open_control(host, port, timeout=5.0):
    s = socket.create_connection((host, port), timeout=timeout)
    s.settimeout(timeout)
    # 车机端连上就会先推一条 welcome；也主动发 hello 兜底
    P.write_line(s, P.ctl_hello())
    line = P.read_line(s)
    cams = P.ctl_cameras(line)
    return s, line, cams


# ---------------------------------------------------------------- 视频通道
def probe_camera(host, port, camera_id, seconds, want_keyframe=True):
    """订阅一路，收 seconds 秒的帧，返回统计。"""
    s = socket.create_connection((host, port), timeout=5.0)
    s.settimeout(10.0)
    P.write_line(s, "%s%d" % (P.SUBSCRIBE_PREFIX, camera_id))
    reply = P.read_line(s)
    parts = reply.split()
    if not parts or parts[0] != "OK":
        s.close()
        return {"ok": False, "reply": reply,
                "error": "握手被拒：%s" % reply}

    w = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
    h = int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else 0
    fps = int(parts[3]) if len(parts) > 3 and parts[3].isdigit() else 0
    codec = parts[4] if len(parts) > 4 else "?"

    st = {
        "ok": True, "reply": reply, "w": w, "h": h, "fps": fps, "codec": codec,
        "frames": 0, "keyframes": 0, "bytes": 0,
        "first_key_has_sps_pps": None, "nal_hist": {},
        "bad_header": 0, "errors": [],
    }

    deadline = time.time() + seconds
    while time.time() < deadline:
        s.settimeout(max(0.2, deadline - time.time()))
        try:
            hdr = P.read_exact(s, P.HEADER_SIZE)
        except (socket.timeout, ConnectionError) as e:
            if isinstance(e, ConnectionError):
                st["errors"].append("连接中断：%s" % e)
                break
            continue
        fh = P.parse_frame_header(hdr)
        if fh is None:
            st["bad_header"] += 1
            st["errors"].append("帧头魔数/版本不对 —— 流已错位")
            break
        try:
            payload = P.read_exact(s, fh.payload_len)
        except ConnectionError as e:
            st["errors"].append("读负载失败：%s" % e)
            break

        st["frames"] += 1
        st["bytes"] += len(payload)
        nals = P.split_annexb(payload)
        types = [P.nal_type(n) for n in nals]
        for t in types:
            st["nal_hist"][t] = st["nal_hist"].get(t, 0) + 1

        if fh.is_keyframe:
            st["keyframes"] += 1
            if st["first_key_has_sps_pps"] is None:
                # 协议 §5.3 硬要求：每个 IDR 前必须重带 SPS+PPS
                has = 7 in types and 8 in types
                st["first_key_has_sps_pps"] = has
                if not has:
                    st["errors"].append(
                        "关键帧里没有 SPS/PPS（NAL 类型 %s）—— 手机端此时必然花屏"
                        % [P.nal_type_name(t) for t in types])

        if fh.camera_id != camera_id:
            st["errors"].append("收到 cameraId=%d 的帧，订阅的是 %d"
                                % (fh.camera_id, camera_id))
    s.close()
    return st


# ---------------------------------------------------------------- 输出
def hr(title):
    print("")
    print("=" * 66)
    print(title)
    print("=" * 66)


def main():
    ap = argparse.ArgumentParser(description="CarSentinel 360 协议探针")
    ap.add_argument("--host", help="车机 IP；不给则自动发现")
    ap.add_argument("--port", type=int, default=P.SERVICE_PORT)
    ap.add_argument("--camera", type=int, default=None, help="只探这一路")
    ap.add_argument("--seconds", type=float, default=4.0, help="每路收流时长")
    ap.add_argument("--selftest", action="store_true", help="本机自测")
    args = ap.parse_args()

    if args.selftest:
        return selftest(args)

    hr("步骤 1/3 · 发现车机")
    host = args.host
    ann = None
    if not host:
        found = discover()
        if not found:
            print("  ✗ 3 秒内没收到任何 announce。")
            print("    排查：车机端服务是否打开？两端是否同一 WiFi？")
            print("    路由器是否挡了 UDP 广播？→ 用 --host <车机IP> 直连试试")
            return 2
        for h, a in sorted(found.items()):
            print("  ✓ %s  %s  (%d 路摄像头)" % (h, a["name"], len(a["cameras"])))
        host = sorted(found)[0]
        ann = found[host]
        print("  → 选 %s" % host)
    else:
        print("  直连 %s:%d" % (host, args.port))

    hr("步骤 2/3 · 控制通道")
    try:
        cs, welcome, cams = open_control(host, args.port)
    except (OSError, ConnectionError) as e:
        print("  ✗ 连不上 %s:%d —— %s" % (host, args.port, e))
        return 3
    print("  ✓ TCP 已连接")
    print("    首条消息 t=%s" % P.ctl_type(welcome))
    if cams:
        print("    车机报告 %d 路摄像头：" % len(cams))
        for c in cams:
            print("      [%d] %-8s %-8s %sx%s"
                  % (c["id"], c["name"], c["pos"], c["w"], c["h"]))
    else:
        print("  ✗ 没能从 welcome 里解析出摄像头列表")
        cs.close()
        return 4

    # 顺带验一下 ping/pong 和 stats
    try:
        P.write_line(cs, P.ctl_ping(1))
        t0 = time.time()
        pong = P.read_line(cs)
        rtt = (time.time() - t0) * 1000
        if P.ctl_type(pong) == "pong":
            print("  ✓ ping/pong 正常 (%.1f ms)" % rtt)
        else:
            print("  ! ping 的回复不是 pong：%s" % pong[:80])
    except (OSError, ConnectionError) as e:
        print("  ! ping 失败：%s" % e)

    try:
        P.write_line(cs, P.ctl_stats())
        line = P.read_line(cs)
        if P.ctl_type(line) == "stats":
            d = json.loads(line)
            print("  ✓ stats：cpu=%s netKbps=%s uptime=%ss"
                  % (d.get("cpu"), d.get("netKbps"), d.get("uptimeSec")))
    except (OSError, ConnectionError, ValueError):
        pass
    P.write_line(cs, P.CTL_BYE)
    cs.close()

    hr("步骤 3/3 · 视频通道")
    targets = [args.camera] if args.camera is not None else [c["id"] for c in cams]
    worst = 0
    for cid in targets:
        print("")
        print("  --- 摄像头 %d ---" % cid)
        try:
            st = probe_camera(host, args.port, cid, args.seconds)
        except (OSError, ConnectionError) as e:
            print("    ✗ 订阅失败：%s" % e)
            worst = max(worst, 5)
            continue
        if not st["ok"]:
            print("    ✗ %s" % st["error"])
            worst = max(worst, 5)
            continue
        print("    ✓ 握手：%s" % st["reply"])
        dur = max(st["frames"], 1)
        print("    ✓ 收到 %d 帧 / %d 关键帧，%d 字节"
              % (st["frames"], st["keyframes"], st["bytes"]))
        print("      实测约 %.1f fps，%.0f kbps"
              % (st["frames"] / max(args.seconds, 0.1),
                 st["bytes"] * 8 / 1000.0 / max(args.seconds, 0.1)))
        hist = ", ".join("%s×%d" % (P.nal_type_name(t), n)
                         for t, n in sorted(st["nal_hist"].items()))
        print("      NAL 构成：%s" % (hist or "(无)"))
        if st["frames"] == 0:
            print("    ✗ 一帧都没收到 —— 摄像头没打开或编码器没起来")
            worst = max(worst, 5)
        if st["bad_header"]:
            print("    ✗ %d 个坏帧头" % st["bad_header"])
            worst = max(worst, 5)
        if st["first_key_has_sps_pps"] is False:
            print("    ✗ 关键帧缺 SPS/PPS（违反协议 §5.3）→ 手机端必然花屏")
            worst = max(worst, 5)
        elif st["first_key_has_sps_pps"] is True:
            print("    ✓ 关键帧带 SPS+PPS（协议 §5.3 满足）")
        for e in st["errors"]:
            print("    ! %s" % e)

    hr("结论")
    if worst == 0:
        print("  车机端协议侧全部正常。没画面的话问题在 iOS 端或网络质量。")
        print("  建议：看手机端「诊断」Tab 的每路帧数/码率，和这里的数字对比。")
        return 0
    print("  车机端协议侧有问题（见上面 ✗ 项）。先修车机端。")
    return 1


# ---------------------------------------------------------------- 本机自测
def selftest(args):
    """不起真车机，用 fake-carunit 的逻辑在进程内跑一遍，验证探针自身 + 协议实现。"""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import fake_carunit as F

    hr("本机自测（不起真车机）")
    port = P.SERVICE_PORT
    srv = F.CarUnit(host="127.0.0.1", port=port,
                    name="SelftestCar",
                    cameras=[{"id": 0, "name": "前视", "pos": "front", "w": 1280, "h": 720},
                             {"id": 1, "name": "后视", "pos": "rear", "w": 1280, "h": 720}])
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    time.sleep(0.3)
    rc = 0
    try:
        cs, welcome, cams = open_control("127.0.0.1", port)
        ok_cams = bool(cams)
        print("  控制通道 welcome t=%s，摄像头 %d 路 %s"
              % (P.ctl_type(welcome), len(cams or []), "✓" if ok_cams else "✗"))
        if not ok_cams:
            rc = 1
        P.write_line(cs, P.CTL_BYE)
        cs.close()

        for cid in (0, 1):
            st = probe_camera("127.0.0.1", port, cid, 1.0)
            good = (st["ok"] and st["frames"] > 0
                    and st["first_key_has_sps_pps"] is True
                    and st["bad_header"] == 0 and not st["errors"])
            print("  摄像头 %d：%d 帧 / %d 关键帧，SPS+PPS %s → %s"
                  % (cid, st["frames"], st["keyframes"],
                     "有" if st["first_key_has_sps_pps"] else "无",
                     "✓" if good else "✗"))
            if st["errors"]:
                for e in st["errors"]:
                    print("      ! %s" % e)
            if not good:
                rc = 1

        # 协议自洽性：build_frame → parse_frame_header 往返
        payload = b"\x00\x00\x00\x01\x67\x42\x00\x0a\x00\x00\x00\x01\x68\xce\x3c\x80"
        raw = P.build_frame(3, 123456, True, payload)
        fh = P.parse_frame_header(raw[:P.HEADER_SIZE])
        round_ok = (fh is not None and fh.camera_id == 3 and fh.is_keyframe
                    and fh.payload_len == len(payload)
                    and raw[P.HEADER_SIZE:] == payload)
        print("  帧编解码往返：%s" % ("✓" if round_ok else "✗"))
        if not round_ok:
            rc = 1

        nals = P.split_annexb(payload)
        types = sorted(set(P.nal_type(n) for n in nals))
        annexb_ok = types == [7, 8]
        print("  Annex-B 切分（SPS=7 PPS=8）：%s %s"
              % ("✓" if annexb_ok else "✗", types))
        if not annexb_ok:
            rc = 1
    finally:
        srv.stop()

    hr("自测结论")
    print("  %s" % ("探针与协议实现自洽，可以拿去探真车机了"
                   if rc == 0 else "自测未通过，先修 tools/ 下的 Python"))
    return rc


if __name__ == "__main__":
    sys.exit(main())

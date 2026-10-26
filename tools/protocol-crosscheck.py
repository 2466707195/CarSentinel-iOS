import io, os, re, sys

ROOT = r"C:\Users\24667\Documents\deepseek-harness\default-workspace\CarSentinel360"
KT = os.path.join(ROOT, "android/app/src/main/java/com/carsentinel/carunit/net/Protocol.kt")
SW = os.path.join(ROOT, "ios/CarSentinel/Net/Protocol.swift")
KT_JSON = os.path.join(ROOT, "android/app/src/main/java/com/carsentinel/carunit/net/Json.kt")
SW_JSON = os.path.join(ROOT, "ios/CarSentinel/Net/JsonLite.swift")

problems = []


def read(p):
    with io.open(p, "r", encoding="utf-8") as f:
        return f.read()


kt, sw = read(KT), read(SW)
kt_json, sw_json = read(KT_JSON), read(SW_JSON)


def kotlin_const(name, pattern):
    m = re.search(pattern, kt)
    return m.group(1) if m else None


def swift_const(name, pattern):
    m = re.search(pattern, sw)
    return m.group(1) if m else None


print("=== 1. 端口 ===")
kt_tcp = kotlin_const("TCP_PORT", r'const val TCP_PORT\s*=\s*(\d+)')
sw_tcp = swift_const("servicePort", r'static let servicePort:\s*Int\s*=\s*(\d+)')
kt_ann = kotlin_const("UDP_ANNOUNCE_PORT", r'const val UDP_ANNOUNCE_PORT\s*=\s*(\d+)')
sw_ann = swift_const("announcePort", r'static let announcePort:\s*Int\s*=\s*(\d+)')
kt_dis = kotlin_const("UDP_DISCOVER_PORT", r'const val UDP_DISCOVER_PORT\s*=\s*(\d+)')
sw_dis = swift_const("probePort", r'static let probePort:\s*Int\s*=\s*(\d+)')
for label, a, b in [("TCP 服务端口", kt_tcp, sw_tcp),
                    ("UDP 广播端口", kt_ann, sw_ann),
                    ("UDP 探测端口", kt_dis, sw_dis)]:
    same = a == b
    print("  %-14s android=%-6s ios=%-6s %s" % (label, a, b, "OK" if same else "不一致!"))
    if not same:
        problems.append("端口不一致 %s: android=%s ios=%s" % (label, a, b))

print("")
print("=== 2. 帧魔数 CS60 ===")
kt_magic = re.search(r'val MAGIC\s*=\s*byteArrayOf\(([^)]+)\)', kt)
sw_magic = re.search(r'static let frameMagic:\s*\[UInt8\]\s*=\s*\[([^\]]+)\]', sw)
kt_bytes = [int(x.strip(), 0) for x in kt_magic.group(1).split(",")] if kt_magic else None
sw_bytes = [int(x.strip(), 0) for x in sw_magic.group(1).split(",")] if sw_magic else None
print("  android = %s  (%s)" % (kt_bytes, bytes(kt_bytes) if kt_bytes else "?"))
print("  ios     = %s  (%s)" % (sw_bytes, bytes(sw_bytes) if sw_bytes else "?"))
if kt_bytes != sw_bytes:
    problems.append("帧魔数不一致: android=%s ios=%s" % (kt_bytes, sw_bytes))

print("")
print("=== 3. 帧头大小 / 关键帧标志 ===")
kt_hs = kotlin_const("HEADER_SIZE", r'const val HEADER_SIZE\s*=\s*(\d+)')
sw_hs = swift_const("frameHeaderSize", r'static let frameHeaderSize\s*=\s*(\d+)')
kt_kf = kotlin_const("FLAG_KEYFRAME", r'const val FLAG_KEYFRAME\s*=\s*(0x[0-9A-Fa-f]+|\d+)')
sw_kf = swift_const("flagKeyFrame", r'static let flagKeyFrame:\s*UInt8\s*=\s*(0x[0-9A-Fa-f]+|\d+)')
for label, a, b in [("帧头字节数", kt_hs, sw_hs), ("关键帧标志", kt_kf, sw_kf)]:
    same = a == b
    print("  %-12s android=%-5s ios=%-5s %s" % (label, a, b, "OK" if same else "不一致!"))
    if not same:
        problems.append("%s 不一致: android=%s ios=%s" % (label, a, b))

print("")
print("=== 4. 帧头字段偏移（android buildFrame vs ios FrameOffset）===")
# android: putU32(out, 8, cameraId) / putU64(out, 12, ptsUs) / putU32(out, 20, payloadLen)
kt_off = {
    "cameraId": re.search(r'putU32\(out,\s*(\d+),\s*cameraId', kt),
    "ptsUs": re.search(r'putU64\(out,\s*(\d+),\s*ptsUs', kt),
    "payloadLen": re.search(r'putU32\(out,\s*(\d+),\s*payload\.size', kt),
}
kt_ver = re.search(r'out\[4\]\s*=\s*Protocol\.VERSION', kt) is not None
kt_flg = re.search(r'out\[5\]\s*=\s*if \(keyframe\)', kt) is not None
kt_rsv = re.search(r'out\[6\]\s*=\s*0', kt) is not None and re.search(r'out\[7\]\s*=\s*0', kt) is not None

sw_off = {
    "cameraId": re.search(r'static let cameraId\s*=\s*(\d+)', sw),
    "ptsUs": re.search(r'static let ptsUs\s*=\s*(\d+)', sw),
    "payloadLen": re.search(r'static let payloadLen\s*=\s*(\d+)', sw),
}
sw_ver = re.search(r'static let version\s*=\s*4', sw) is not None
sw_flg = re.search(r'static let flags\s*=\s*5', sw) is not None
sw_rsv = re.search(r'static let reserved\s*=\s*6', sw) is not None

for k in ("cameraId", "ptsUs", "payloadLen"):
    a = kt_off[k].group(1) if kt_off[k] else None
    b = sw_off[k].group(1) if sw_off[k] else None
    same = a == b
    print("  %-11s android=%-3s ios=%-3s %s" % (k, a, b, "OK" if same else "不一致!"))
    if not same:
        problems.append("帧头偏移 %s 不一致: android=%s ios=%s" % (k, a, b))
for label, a, b in [("version@4", kt_ver, sw_ver), ("flags@5", kt_flg, sw_flg), ("reserved@6-7", kt_rsv, sw_rsv)]:
    print("  %-11s android=%-5s ios=%-5s %s" % (label, a, b, "OK" if (a and b) else "不一致!"))
    if not (a and b):
        problems.append("帧头 %s 有一端没对上" % label)

print("")
print("=== 5. 超时 / 行上限 ===")
# Kotlin 数字字面量允许下划线分隔：15_000
def kt_int(pattern):
    m = re.search(pattern, kt)
    return int(m.group(1).replace("_", "")) if m else None

kt_line = kt_int(r'const val MAX_LINE_BYTES\s*=\s*([\d_]+)')
sw_line = swift_const("maxControlLineBytes", r'static let maxControlLineBytes\s*=\s*(\d+)')
kt_idle_ms = kt_int(r'const val CONTROL_IDLE_TIMEOUT_MS\s*=\s*([\d_]+)')
sw_idle = swift_const("controlIdleTimeout", r'static let controlIdleTimeout:\s*TimeInterval\s*=\s*([\d.]+)')
same = int(kt_line) == int(sw_line)
print("  单行上限(KB) android=%-8s ios=%-8s %s" % (kt_line, sw_line, "OK" if same else "不一致!"))
if not same:
    problems.append("单行上限不一致")
try:
    b_ms = int(float(sw_idle) * 1000)
    same = kt_idle_ms == b_ms
    print("  控制空闲超时 android=%-8s ios=%-8s %s" % (kt_idle_ms, b_ms, "OK" if same else "不一致!"))
    if not same:
        problems.append("控制空闲超时不一致: %d vs %d" % (kt_idle_ms, b_ms))
except Exception as e:
    problems.append("超时解析失败: %s" % e)

print("")
print("=== 6. JSON 键名对账：一端发的，另一端必须都读 ===")
ANN = os.path.join(ROOT, "android/app/src/main/java/com/carsentinel/carunit/net/Announcer.kt")
CS = os.path.join(ROOT, "android/app/src/main/java/com/carsentinel/carunit/net/ControlSession.kt")
SV = os.path.join(ROOT, "android/app/src/main/java/com/carsentinel/carunit/service/StreamService.kt")
CC = os.path.join(ROOT, "ios/CarSentinel/Net/CarClient.swift")

kt_src = "\n".join(read(p) for p in (ANN, CS, SV, KT_JSON))
sw_src = "\n".join(read(p) for p in (SW_JSON, CC))

# android 发出去的键
kt_emit = set(re.findall(r'\.put\("(\w+)"', kt_src))
# android 读进来的键
kt_read = set(re.findall(r'msg\.get(?:String|Int|Long|Double|Boolean)\("(\w+)"', kt_src))
# ios 发出去的键：只看 JsonLite.encode([...]) 里的字典字面量键。
# 注意不要把 "t": "hello" 的值（消息类型名）也抓进来 —— 那是另一件事，见第 8 节。
sw_emit = set()
for m in re.finditer(r'try encode\(\[(.*?)\]\)', sw_src, re.S):
    sw_emit |= set(re.findall(r'"(\w+)"\s*:', m.group(1)))
# ios 读进来的键
sw_read = set(re.findall(r'\["(\w+)"\]', sw_src)) | set(re.findall(r'JsonLite\.\w+Field\(\w+,\s*"(\w+)"', sw_src))

print("  android 发 (%2d): %s" % (len(kt_emit), ", ".join(sorted(kt_emit))))
print("  ios     读 (%2d): %s" % (len(sw_read), ", ".join(sorted(sw_read))))
print("  ios     发 (%2d): %s" % (len(sw_emit), ", ".join(sorted(sw_emit))))
print("  android 读 (%2d): %s" % (len(kt_read), ", ".join(sorted(kt_read))))

gap1 = kt_emit - sw_read
gap2 = sw_emit - kt_read

# 这些键是「只写给对面看、对面不需要读」的信息性字段，协议里就是这么定的：
#   caps     announce 里声明编码能力，但手机端从 OK 握手行就已经知道是 h264
#   level    log 消息的级别，手机端只显示 msg 文本
#   role/v   hello 里的身份和版本，车机端只按 t 分发，不关心内容
INFORMATIONAL = {"caps", "level", "role", "v"}
real_gap1 = gap1 - INFORMATIONAL
real_gap2 = gap2 - INFORMATIONAL
if gap1 - INFORMATIONAL or gap2 - INFORMATIONAL:
    pass
print("  （信息性字段，对面有意不读）: %s" % ", ".join(sorted(gap1 & INFORMATIONAL | gap2 & INFORMATIONAL)))

if real_gap1:
    problems.append("android 发了但 iOS 不读的键: %s" % ", ".join(sorted(real_gap1)))
    print("  !! android 发 / iOS 不读: %s" % ", ".join(sorted(real_gap1)))
if real_gap2:
    problems.append("iOS 发了但 android 不读的键: %s" % ", ".join(sorted(real_gap2)))
    print("  !! iOS 发 / android 不读: %s" % ", ".join(sorted(real_gap2)))
if not real_gap1 and not real_gap2:
    print("  OK：双向键名完全闭合（除信息性字段外）")

print("")
print("=== 7. announce 摄像头字段 ===")
kt_cam = set(re.findall(r'\.put\("(\w+)",\s*c\.', read(ANN)))
sw_cam = set(re.findall(r'c\["(\w+)"\]', sw_json))
print("  android: %s" % ", ".join(sorted(kt_cam)))
print("  ios    : %s" % ", ".join(sorted(sw_cam)))
if kt_cam != sw_cam:
    problems.append("announce 摄像头字段不一致: android=%s ios=%s" % (sorted(kt_cam), sorted(sw_cam)))

print("")
print("=== 8. 控制消息类型（t 字段）双向对账 ===")
# android 发出哪些 t
kt_tx = set(re.findall(r'\.put\("t",\s*"(\w+)"', kt_src))
kt_tx |= set(re.findall(r'Json\.Obj\(\)\.put\("t",\s*"(\w+)"', kt_src))
kt_tx |= set(re.findall(r'\.put\("t",\s*"(\w+)"\)', kt_src))
# android 认识哪些 t
kt_rx = set(re.findall(r'"(\w+)"\s*->', read(CS)))
# ios 发出哪些 t
sw_tx = set(re.findall(r'"t"\s*:\s*"(\w+)"', sw_src))
# ios 认识哪些 t：CarClient 的 switch + DiscoveryService 的 announce 判定 + JsonLite
DS = os.path.join(ROOT, "ios/CarSentinel/Net/DiscoveryService.swift")
sw_rx_files = "\n".join(read(p) for p in (CC, DS, SW_JSON))
sw_rx = set(re.findall(r'case\s+"(\w+)"', sw_rx_files))          # case "x" / case "a", "b"
sw_rx |= set(re.findall(r'case\s+"\w+",\s*"(\w+)"', sw_rx_files))  # 多标签的第二个
sw_rx |= set(re.findall(r'\)\s*==\s*"(\w+)"', sw_rx_files))       # (root["t"] as? String) == "announce"

print("  android 发: %s" % ", ".join(sorted(kt_tx)))
print("  ios     识: %s" % ", ".join(sorted(sw_rx)))
print("  ios     发: %s" % ", ".join(sorted(sw_tx)))
print("  android 识: %s" % ", ".join(sorted(kt_rx)))

# iOS 发了就不等应答的消息（fire-and-forget）：协议里车机端会回 ok/subscribed/
# unsubscribed，但手机端按设计不阻塞等待，忽略这些回执是有意的。
FIRE_AND_FORGET = {"ok", "subscribed", "unsubscribed"}
miss_a = kt_tx - sw_rx - FIRE_AND_FORGET
miss_b = sw_tx - kt_rx
if miss_a:
    problems.append("android 会发这些消息类型但 iOS 不认: %s" % ", ".join(sorted(miss_a)))
    print("  !! android 发 / iOS 不认: %s" % ", ".join(sorted(miss_a)))
if miss_b:
    problems.append("iOS 会发这些消息类型但 android 不认: %s" % ", ".join(sorted(miss_b)))
    print("  !! iOS 发 / android 不认: %s" % ", ".join(sorted(miss_b)))
if not miss_a and not miss_b:
    print("  OK：消息类型双向闭合")
    print("     （iOS 有意忽略车机端的 ok/subscribed/unsubscribed 回执 —— 发了不等）")

print("")
print("=" * 66)
if problems:
    print("发现 %d 个问题:" % len(problems))
    for p in problems:
        print("  - %s" % p)
    sys.exit(1)
print("两端协议常量与字段名完全一致")

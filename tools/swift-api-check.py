import io, os, re, sys

ROOT = r"C:\Users\24667\Documents\deepseek-harness\default-workspace\CarSentinel360"
IOS = os.path.join(ROOT, "ios/CarSentinel")

# 资产文件（Aurora UI 现成组件）—— 声明在这里面
ASSETS = [
    "UI/Common/AuroraComponents.swift",
    "UI/Common/AuroraButtons.swift",
    "UI/Common/AuroraScreen.swift",
    "UI/Common/AuroraTextField.swift",
    "UI/Common/WeightedHStack.swift",
    "UI/Components/AuroraTabView.swift",
    "UI/Components/AuroraGlass.swift",
    "UI/Components/AuroraToolbar.swift",
]
# 我写的调用方
CALLERS = [
    "App/CarSentinelApp.swift",
    "Screens/LiveGridScreen.swift",
    "Screens/SingleCameraScreen.swift",
    "Screens/DevicesScreen.swift",
    "Screens/DiagnosticsScreen.swift",
    "UI/Components/VideoSurfaceView.swift",
    "Net/CarClient.swift",
    "Net/DiscoveryService.swift",
    "Net/JsonLite.swift",
]


def read(p):
    with io.open(os.path.join(IOS, p), "r", encoding="utf-8") as f:
        return f.read()


# ---------------------------------------------------------------- 1. 抽声明
def struct_body(src, name):
    """取 struct/enum name ... 的第一个 {...} 块（按大括号配平）。"""
    m = re.search(r'\b(?:struct|enum)\s+%s\s*(?:<[^>]*>)?\s*(?::\s*[\w.,\s<>=]+)?\s*\{' % re.escape(name), src)
    if not m:
        return None
    i = m.end() - 1
    depth = 0
    start = i
    while i < len(src):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[start + 1:i]
        i += 1
    return None


def property_names(body):
    """存储属性名。排除计算属性（有 { 的 var）和 body。"""
    names = set()
    for m in re.finditer(r'(?m)^\s*(?:@\w+\s+)*(?:private\s+|fileprivate\s+|public\s+|internal\s+)?(let|var)\s+(\w+)\s*:', body):
        names.add(m.group(2))
    return names


def init_labels(body):
    """显式 init 的参数标签集合。"""
    labels = set()
    for m in re.finditer(r'\binit\s*\(([^)]*)\)', body, re.S):
        for part in split_top(m.group(1)):
            pm = re.match(r'\s*(?:_\s*)?(\w+)\s*:', part)
            if pm:
                labels.add(pm.group(1))
    return labels


def split_top(s):
    """按顶层逗号切分（忽略 <> [] () 里的逗号）。"""
    parts, depth, cur = [], 0, []
    for c in s:
        if c in "<([{":
            depth += 1
        elif c in ">)]}":
            depth -= 1
        if c == "," and depth == 0:
            parts.append("".join(cur)); cur = []
        else:
            cur.append(c)
    if cur:
        parts.append("".join(cur))
    return parts


# 收集所有资产里声明的类型
decls = {}   # name -> set of allowed labels
asset_src = "\n".join(read(p) for p in ASSETS)
for m in re.finditer(r'\b(?:struct|enum)\s+(\w+)\s*(?:<[^>]*>)?\s*(?::\s*[\w.,\s<>=]+)?\s*\{', asset_src):
    name = m.group(1)
    body = struct_body(asset_src, name)
    if body is None:
        continue
    labels = property_names(body) | init_labels(body)
    if labels:
        decls[name] = labels

# ---------------------------------------------------------------- 2. 抽调用
def call_labels(src, name):
    """找出所有 `name(...)` 调用，返回 [(labels, snippet)]。"""
    out = []
    for m in re.finditer(r'(?<![.\w])%s\s*\(' % re.escape(name), src):
        i = m.end() - 1
        depth = 0
        start = i
        while i < len(src):
            if src[i] == "(":
                depth += 1
            elif src[i] == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        if i >= len(src):
            continue
        args = src[start + 1:i]
        # 尾随闭包（@ViewBuilder content）不算参数标签
        labels = set()
        for part in split_top(args):
            pm = re.match(r'\s*(\w+)\s*:', part)
            if pm and pm.group(1) not in ("case", "default"):
                labels.add(pm.group(1))
        out.append((labels, src[m.start():m.start() + 60].replace("\n", " ")))
    return out


print("=== Aurora 组件 API 对账 ===")
print("（声明来自技能资产 %d 个文件；调用来自我写的 %d 个文件）" % (len(ASSETS), len(CALLERS)))
print("")

problems = []
checked = 0
for name in sorted(decls):
    allowed = decls[name]
    for caller in CALLERS:
        src = read(caller)
        for labels, snippet in call_labels(src, name):
            checked += 1
            bad = labels - allowed
            if bad:
                problems.append((name, caller, sorted(bad), sorted(allowed), snippet))

print("检查了 %d 处调用，覆盖 %d 个 Aurora 类型" % (checked, len(decls)))
print("")

if problems:
    print("!! 参数标签对不上 (%d 处):" % len(problems))
    for name, caller, bad, allowed, snip in problems:
        print("  %s  <- %s" % (name, caller))
        print("      用了但不存在的标签: %s" % ", ".join(bad))
        print("      可用标签: %s" % ", ".join(sorted(allowed)))
        print("      调用: %s…" % snip[:70])
    sys.exit(1)
else:
    print("全部调用的参数标签都在声明范围内")

# ---------------------------------------------------------------- 3. 顺带查自定义组件
print("")
print("=== 我自定义的组件/类型的调用 ===")
custom = {}
for p in ["UI/Components/VideoSurfaceView.swift"]:
    src = read(p)
    for m in re.finditer(r'\b(?:struct|final\s+class|class)\s+(\w+)', src):
        body = struct_body(src, m.group(1)) if re.search(r'\bstruct\s+%s' % m.group(1), src) else None
        labels = set()
        if body:
            labels = property_names(body) | init_labels(body)
        # 类的显式 init
        for im in re.finditer(r'\binit\s*\(([^)]*)\)', src):
            for part in split_top(im.group(1)):
                pm = re.match(r'\s*(?:_\s*)?(\w+)\s*:', part)
                if pm:
                    labels.add(pm.group(1))
        if labels:
            custom[m.group(1)] = labels

for name, allowed in sorted(custom.items()):
    hits = 0
    for caller in CALLERS:
        src = read(caller)
        for labels, snippet in call_labels(src, name):
            hits += 1
            bad = labels - allowed
            if bad:
                problems.append((name, caller, sorted(bad), sorted(allowed), snippet))
                print("  !! %s <- %s 用了不存在的标签 %s（可用 %s）" % (name, caller, bad, sorted(allowed)))
    print("  %-22s %d 处调用，可用标签: %s" % (name, hits, ", ".join(sorted(allowed)) or "(无)"))

if problems:
    sys.exit(1)

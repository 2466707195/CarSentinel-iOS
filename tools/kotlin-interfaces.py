import io, os, re, sys, collections

ROOT = r"C:\Users\24667\Documents\deepseek-harness\default-workspace\CarSentinel360"
SRC = os.path.join(ROOT, "android/app/src/main/java")

files = []
for dirpath, dirnames, filenames in os.walk(SRC):
    for fn in filenames:
        if fn.endswith(".kt"):
            files.append(os.path.join(dirpath, fn))
files.sort()

texts = {}
for p in files:
    with io.open(p, "r", encoding="utf-8") as f:
        texts[p] = f.read()
allsrc = "\n".join(texts.values())


def block(src, open_idx):
    """从 open_idx（'{' 位置）按配平取到匹配的 '}'，返回块内容。"""
    depth = 0
    i = open_idx
    while i < len(src):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[open_idx + 1:i]
        i += 1
    return ""


# ---------------------------------------------------------------- 1. 接口成员
# 嵌套接口要按「外层.内层」记录，否则 CameraFeeder.Listener 和 LogBus.Listener
# 撞短名会互相污染。
interfaces = {}   # "CameraFeeder.Listener" -> set of member names

# 1a. 顶层 / 类外的 interface
for m in re.finditer(r'\binterface\s+([\w.]+)\s*(?:<[^>]*>)?\s*(?::\s*[^{]+)?\{', allsrc):
    name = m.group(1)
    body = block(allsrc, m.end() - 1)
    members = set(re.findall(r'\bfun\s+(\w+)\s*\(', body))
    members |= set(re.findall(r'\b(?:val|var)\s+(\w+)\s*:', body))
    if members:
        interfaces[name] = members

# 1b. 嵌套在 class/object 里的 interface：记成 Outer.Inner
for om in re.finditer(r'\b(?:class|object)\s+(\w+)\s*(?:<[^>]*>)?\s*(?:\([^)]*\))?\s*(?::\s*[^{]+)?\{', allsrc):
    outer = om.group(1)
    obody = block(allsrc, om.end() - 1)
    for im in re.finditer(r'\binterface\s+(\w+)\s*(?:<[^>]*>)?\s*(?::\s*[^{]+)?\{', obody):
        inner = im.group(1)
        ibody = block(obody, im.end() - 1)
        members = set(re.findall(r'\bfun\s+(\w+)\s*\(', ibody))
        members |= set(re.findall(r'\b(?:val|var)\s+(\w+)\s*:', ibody))
        if members:
            interfaces["%s.%s" % (outer, inner)] = members

print("=== 接口（%d 个）===" % len(interfaces))
for k, v in sorted(interfaces.items()):
    print("  %-30s %s" % (k, ", ".join(sorted(v))))

# ---------------------------------------------------------------- 2. 类声明与实现
print("")
print("=== 类的接口实现 ===")
problems = []
impls = []
for p in files:
    src = texts[p]
    for m in re.finditer(r'\b(?:data\s+|sealed\s+|abstract\s+|open\s+|final\s+)*class\s+(\w+)\s*(?:<[^>]*>)?\s*(?:\([^)]*\))?\s*:\s*([^{]+)\{', src):
        cls = m.group(1)
        supers = [s.strip() for s in m.group(2).split(",") if s.strip()]
        # 剥掉构造调用参数，只留类型名
        clean = []
        for s in supers:
            s = re.sub(r'\(.*', '', s).strip()
            if s and re.fullmatch(r'[\w.]+', s):
                clean.append(s)
        if not clean:
            continue
        impls.append((cls, clean, p))
        print("  %-22s : %s" % (cls, ", ".join(clean)))

# ---------------------------------------------------------------- 3. 成员覆盖检查
print("")
print("=== 成员覆盖检查 ===")
for cls, supers, p in impls:
    src = texts[p]
    # 类体
    m = re.search(r'\bclass\s+%s\s*(?:<[^>]*>)?\s*(?:\([^)]*\))?\s*:\s*[^{]+\{' % re.escape(cls), src)
    body = block(src, m.end() - 1) if m else ""
    have = set(re.findall(r'\b(?:override\s+)?fun\s+(\w+)\s*\(', body))
    have |= set(re.findall(r'\b(?:override\s+)?(?:val|var)\s+(\w+)\s*:', body))
    # 伴生对象里的不算类成员，但伴生成员也满足不了接口，忽略

    for sup in supers:
        needed = interfaces.get(sup)
        if not needed:
            # 短名回退：仅当唯一匹配时才用，避免两个同名嵌套接口互相污染
            cands = [mem for full, mem in interfaces.items() if full.split(".")[-1] == sup.split(".")[-1]]
            if len(cands) == 1:
                needed = cands[0]
        if not needed:
            continue
        missing = needed - have
        if missing:
            problems.append("%s 没实现 %s 的成员: %s" % (cls, sup, ", ".join(sorted(missing))))
            print("  !! %-20s 缺 %-26s -> %s" % (cls, sup, ", ".join(sorted(missing))))
        else:
            print("  ok %-20s 实现 %-26s (%d 个成员)" % (cls, sup, len(needed)))

# ---------------------------------------------------------------- 4. 回调注册一致性
print("")
print("=== 委托/监听器是否真的被接线 ===")
# 右边可能是 this，也可能是 lambda { ... }，所以不能只认 \w+
for prop in ("delegate", "listener", "sinkProvider"):
    assigns = re.findall(r'\.%s\s*=\s*(\{|\w+)' % prop, allsrc)
    if assigns:
        print("  .%-14s = %s" % (prop, ", ".join(assigns)))
    else:
        print("  .%-14s = (从未赋值!)" % prop)
        problems.append("%s 从未被赋值" % prop)

print("")
print("=" * 66)
if problems:
    print("发现 %d 个问题:" % len(problems))
    for x in problems:
        print("  - %s" % x)
    sys.exit(1)
print("接口实现完整，委托都已接线")

import io, os, re, sys, json

ROOT = r"C:\Users\24667\Documents\deepseek-harness\default-workspace\CarSentinel360"
fails, warns = [], []


def fail(msg):
    fails.append(msg)


def warn(msg):
    warns.append(msg)


# ---------------------------------------------------------------- 1. YAML 解析
def parse_yaml(path):
    """无第三方库的极简 YAML 检查：只验证「能被解析成结构化数据」不现实，
    所以退而求其次：检查缩进一致性、无 tab、无未闭合引号、块结构完整。"""
    with io.open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()
    problems = []
    in_block = False
    block_indent = 0
    for i, raw in enumerate(lines, 1):
        line = raw.rstrip("\n")
        if "\t" in line:
            problems.append((i, "含 tab 字符"))
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if in_block:
            if indent > block_indent:
                continue
            in_block = False
        if stripped.endswith(":") and not stripped.startswith("-"):
            in_block = True
            block_indent = indent
            continue
        # key: value 行，检查引号配平
        m = re.match(r'^(\s*)(?:-\s+)?([\w.\-/]+)\s*:\s*(.*)$', line)
        if m:
            v = m.group(3)
            if v.count('"') % 2 != 0:
                problems.append((i, "双引号不配平: %s" % v[:50]))
            if v.count("'") % 2 != 0:
                problems.append((i, "单引号不配平: %s" % v[:50]))
    return problems


yaml_files = []
for dirpath, dirnames, filenames in os.walk(ROOT):
    dirnames[:] = [d for d in dirnames if d not in ("build", ".gradle", "Assets.xcassets")]
    for fn in filenames:
        if fn.endswith((".yml", ".yaml")):
            yaml_files.append(os.path.join(dirpath, fn))
yaml_files.sort()
print("=== YAML 文件 (%d) ===" % len(yaml_files))
for p in yaml_files:
    rel = os.path.relpath(p, ROOT)
    probs = parse_yaml(p)
    if probs:
        fail("YAML %s: %s" % (rel, probs[:3]))
        print("  FAIL %-34s %s" % (rel, probs[:2]))
    else:
        print("  ok   %s" % rel)

# ---------------------------------------------------------------- 2. project.yml 路径交叉验证
print("")
print("=== project.yml 引用的路径 ===")
with io.open(os.path.join(ROOT, "project.yml"), "r", encoding="utf-8") as f:
    spec = f.read()

m = re.search(r'^\s*name:\s*(\S+)\s*$', spec, re.M)
app_name = m.group(1) if m else None
print("  app name (name:)          -> %s" % app_name)
if not app_name:
    fail("project.yml 读不到 name:")

src = re.search(r'^\s*- path:\s*(\S+)\s*$', spec, re.M)
src_path = src.group(1) if src else None
if src_path:
    full = os.path.join(ROOT, src_path)
    ok = os.path.isdir(full)
    print("  sources path              -> %s  [%s]" % (src_path, "OK" if ok else "MISSING"))
    if not ok:
        fail("project.yml sources 路径不存在: %s" % src_path)
else:
    fail("project.yml 没有 sources path")

info = re.search(r'^\s*path:\s*(\S+Info\.plist)\s*$', spec, re.M)
if info:
    p = os.path.join(ROOT, info.group(1))
    # Info.plist 由 xcodegen 生成，本地不该存在；但父目录必须在
    parent = os.path.dirname(p)
    ok = os.path.isdir(parent)
    print("  info.plist 父目录          -> %s  [%s]" % (os.path.relpath(parent, ROOT), "OK" if ok else "MISSING"))
    if not ok:
        fail("Info.plist 父目录不存在: %s" % parent)
    if os.path.exists(p):
        warn("Info.plist 已存在且会被 publish 脚本按名排除，确认这是有意的")

scheme = re.search(r'^schemes:\s*\n\s+(\S+):', spec, re.M)
print("  scheme                    -> %s" % (scheme.group(1) if scheme else "<none>"))
if not scheme:
    fail("project.yml 没有 schemes（xcodebuild -scheme 会失败）")
elif scheme.group(1) != app_name:
    fail("scheme 名 %s 与 target 名 %s 不一致" % (scheme.group(1), app_name))

# 资产目录
for asset in ["AppIcon.appiconset/AppIcon-1024.png",
              "AppIcon.appiconset/Contents.json",
              "AccentColor.colorset/Contents.json",
              "LaunchBackground.colorset/Contents.json"]:
    p = os.path.join(ROOT, "ios/CarSentinel/Resources/Assets.xcassets", asset)
    ok = os.path.isfile(p)
    print("  asset %-38s [%s]" % (asset, "OK" if ok else "MISSING"))
    if not ok:
        fail("缺资产: %s" % asset)

# ---------------------------------------------------------------- 3. CI 引用的脚本存在性
print("")
print("=== .github/workflows/build.yml 引用的脚本 ===")
with io.open(os.path.join(ROOT, ".github/workflows/build.yml"), "r", encoding="utf-8") as f:
    wf = f.read()
for s in sorted(set(re.findall(r'bash scripts/([\w.\-]+)', wf))):
    p = os.path.join(ROOT, "scripts", s)
    ok = os.path.isfile(p)
    print("  scripts/%-26s [%s]" % (s, "OK" if ok else "MISSING"))
    if not ok:
        fail("workflow 引用了不存在的脚本: scripts/%s" % s)

for s in sorted(set(re.findall(r'path:\s*\n?\s*(build/\S+)', wf))):
    print("  artifact path             -> %s" % s)

# ---------------------------------------------------------------- 4. publish-github.ps1 的选文件逻辑复刻
print("")
print("=== publish-github.ps1 实际上传的文件清单（复刻其过滤逻辑）===")
exclude_dirs = {"build", "DerivedData", ".git", "%s.xcodeproj" % app_name}
exclude_files = {"Info.plist"}
pushed, excluded = [], []
for dirpath, dirnames, filenames in os.walk(ROOT):
    dirnames[:] = [d for d in dirnames if d not in exclude_dirs]
    for fn in filenames:
        full = os.path.join(dirpath, fn)
        rel = os.path.relpath(full, ROOT).replace("\\", "/")
        parts = rel.split("/")
        if any(p in exclude_dirs for p in parts):
            excluded.append(rel)
            continue
        if fn in exclude_files:
            excluded.append(rel)
            continue
        pushed.append(rel)
pushed.sort()
print("  将上传 %d 个文件" % len(pushed))
for rel in pushed:
    print("    %s" % rel)
if excluded:
    print("  被排除 %d 个:" % len(excluded))
    for rel in sorted(excluded):
        print("    - %s" % rel)

# 关键源码一个都不能少
must_have = [
    "project.yml", ".github/workflows/build.yml",
    "ios/CarSentinel/App/CarSentinelApp.swift",
    "ios/CarSentinel/Net/H264Decoder.swift",
    "ios/CarSentinel/Net/CarClient.swift",
    "android/app/src/main/AndroidManifest.xml",
    "android/app/src/main/java/com/carsentinel/carunit/MainActivity.kt",
    "android/app/build.gradle.kts",
    "scripts/build-android.sh", "scripts/build-unsigned-ipa.sh",
    "scripts/publish-github.ps1",
]
for rel in must_have:
    if rel not in pushed:
        fail("关键文件不会被上传: %s" % rel)

# ---------------------------------------------------------------- 5. .sh 脚本健全性
print("")
print("=== shell 脚本 ===")
sh_files = sorted(os.path.join(ROOT, "scripts", f) for f in os.listdir(os.path.join(ROOT, "scripts")) if f.endswith(".sh"))
def quote_balance(text):
    """数双引号是否配平，跳过转义序列 \\" 和单引号字符串里的内容。"""
    n = 0
    i = 0
    in_single = False
    while i < len(text):
        c = text[i]
        if in_single:
            if c == "'":
                in_single = False
            i += 1
            continue
        if c == "\\" and i + 1 < len(text):
            i += 2          # 跳过 \" \\ \n 等转义
            continue
        if c == "'":
            in_single = True
            i += 1
            continue
        if c == '"':
            n += 1
        i += 1
    return n % 2 == 0


for p in sh_files:
    rel = os.path.relpath(p, ROOT)
    with io.open(p, "r", encoding="utf-8") as f:
        txt = f.read()
    issues = []
    if not txt.startswith("#!"):
        issues.append("缺 shebang")
    if "set -euo pipefail" not in txt and "set -e" not in txt:
        issues.append("没有 set -e")
    if not quote_balance(txt):
        issues.append("双引号不配平")
    if issues:
        fail("shell %s: %s" % (rel, issues))
        print("  FAIL %-30s %s" % (rel, issues))
    else:
        print("  ok   %-30s %d 行" % (rel, txt.count("\n")))

# ---------------------------------------------------------------- 6. .ps1 必须带 BOM
# PS 5.1 按 ANSI(GBK) 读无 BOM 的 UTF-8 文件，中文全变乱码，
# 进而把双引号串里合法的 & 暴露成裸运算符，报一堆莫名其妙的语法错误。
# 注意：edit 类工具改写文件时会抹掉 BOM，所以每次改完 .ps1 都要重跑本检查。
print("")
print("=== .ps1 BOM 检查 ===")
for dirpath, dirnames, filenames in os.walk(ROOT):
    dirnames[:] = [d for d in dirnames if d not in ("build", ".gradle")]
    for fn in sorted(filenames):
        if not fn.endswith(".ps1"):
            continue
        p = os.path.join(dirpath, fn)
        raw = open(p, "rb").read()
        has = raw[:3] == b"\xef\xbb\xbf"
        print("  %-6s %s" % ("BOM" if has else "no-bom", os.path.relpath(p, ROOT)))
        if not has:
            fail(".ps1 缺 UTF-8 BOM（PS 5.1 会按 GBK 读，中文乱码 + 语法错）: %s" % fn)

# ---------------------------------------------------------------- 汇总
print("")
print("=" * 64)
if fails:
    print("FAIL (%d):" % len(fails))
    for f in fails:
        print("  - %s" % f)
else:
    print("全部通过")
if warns:
    print("WARN (%d):" % len(warns))
    for w in warns:
        print("  - %s" % w)
print("=" * 64)
sys.exit(1 if fails else 0)

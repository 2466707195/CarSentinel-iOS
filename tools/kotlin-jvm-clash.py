"""扫 Kotlin 里「JVM 签名相同」的重载 —— 泛型擦除后撞车。

⚠️ 已知局限：类切分不精确，<toplevel> 段会把嵌套类的方法重复计入，
   所以目前有一定误报率。真正的价值是「同一类内同名+同擦除签名」那一类，
   那一定是真冲突（本仓库的 put/putObjects/putStrings/putCameras 就是抓出来的）。
   看到报警时先人工确认是不是不同类，别盲目改。

为什么专门做这个：Json.kt 里
    fun put(key: String, value: List<Obj>)
    fun put(key: String, value: List<String>)
Kotlin 源码层面是不同的重载，但编译到 JVM 后泛型擦除，两个都变成
    put(Ljava/lang/String; Ljava/util/List;)L...;
编译器直接报 Platform declaration clash。这个坑在 Aurora UI 自带的 Json.kt 里
原本就存在，只是没人编译过它。

用法：python tools/kotlin-jvm-clash.py   （手动跑，不进 preflight）
"""
import io, os, re, sys, collections

ROOT = r"C:\Users\24667\Documents\deepseek-harness\default-workspace\CarSentinel360"
SRC = os.path.join(ROOT, "android")

files = []
for dirpath, dirnames, filenames in os.walk(SRC):
    dirnames[:] = [d for d in dirnames if d not in ("build", ".gradle")]
    for fn in filenames:
        if fn.endswith(".kt"):
            files.append(os.path.join(dirpath, fn))
files.sort()

# 匹配 fun 名(参数...)，参数里可能跨行。跳过 override（那是实现父类/接口方法，
# 不是重载，不可能冲突）
FUN = re.compile(r'\bfun\s+(?:<[^>]*>\s+)?(\w+)\s*\(', re.S)
OVERRIDE_BEFORE = re.compile(r'override\s*$')


def is_override(src, start):
    """看这个 fun 前面是不是跟着 override 修饰符。"""
    prefix = src[max(0, start - 60):start]
    return bool(re.search(r'\boverride\s+(?:internal\s+|private\s+|public\s+)*fun\s+\w+\s*\(?\s*$', prefix)
                or re.search(r'override\s+fun\s+\w+\s*$', prefix))


def split_params(s):
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
    if "".join(cur).strip():
        parts.append("".join(cur))
    return parts


def erase(typ):
    """把 List<Obj> / Map<String, Int> 归一成 List / Map（模拟 JVM 擦除）。"""
    t = typ.strip()
    # 去掉所有 <...>
    out, depth = [], 0
    for c in t:
        if c == "<":
            depth += 1
            continue
        if c == ">":
            depth -= 1
            continue
        if depth == 0:
            out.append(c)
    return "".join(out).strip()


problems = []
for p in files:
    with io.open(p, "r", encoding="utf-8") as f:
        src = f.read()
    # 按顶层类/对象切分，避免把嵌套类的方法和外层类的方法混在一起
    # （不同类里的同名方法不是冲突）
    segments = []   # (类名, 起始, 结束)
    for cm in re.finditer(r'\b(?:data\s+|sealed\s+|abstract\s+|open\s+|final\s+|private\s+|internal\s+)*(?:class|object|interface)\s+(\w+)', src):
        name = cm.group(1)
        brace = src.find("{", cm.end())
        if brace < 0:
            continue
        depth, i = 0, brace
        while i < len(src):
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        segments.append((name, brace, i + 1))
    # 文件顶层（不在任何类里的部分）也算一段
    segments.append(("<toplevel>", 0, len(src)))

    for seg_name, s0, s1 in segments:
        seg_src = src[s0:s1]
        for m in FUN.finditer(seg_src):
            if is_override(seg_src, m.start()):
                continue
            name = m.group(1)
            i = m.end() - 1
            depth = 0
            while i < len(seg_src):
                if seg_src[i] == "(":
                    depth += 1
                elif seg_src[i] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            if i >= len(seg_src):
                continue
            args = seg_src[m.end():i]
            after = seg_src[i + 1:i + 200].lstrip()
            if not after.startswith("{"):
                continue    # 抽象声明，不算重载候选
            sig = []
            for part in split_params(args):
                part = part.strip()
                if not part:
                    continue
                mm = re.match(r'(?:_\s*)?(\w+)\s*:\s*(.+)$', part, re.S)
                if not mm:
                    continue
                typ = mm.group(2).split("=")[0].strip().replace("vararg", "").strip()
                sig.append(erase(typ))
            problems.append((os.path.relpath(p, ROOT).replace("\\", "/"),
                             "%s.%s" % (seg_name, name), (name, tuple(sig)), sig))

# 按「文件 + 类」分组：只有同一个类里的同名且擦除后签名相同才算冲突
by_file = collections.defaultdict(list)
for rel, qualified, key, sig in problems:
    by_file[(rel, qualified.rsplit(".", 1)[0])].append((key, sig))

clashes = []
for (rel, cls), items in by_file.items():
    seen = collections.defaultdict(list)
    for key, sig in items:
        seen[key].append(sig)
    for key, occurrences in seen.items():
        if len(occurrences) > 1:
            clashes.append((rel, cls, key[0], key[1], len(occurrences)))

if not clashes:
    print("干净：没有 JVM 签名冲突的重载（扫了 %d 个 .kt）" % len(files))
    sys.exit(0)

print("发现 %d 组 JVM 签名冲突：" % len(clashes))
for rel, cls, name, sig, n in clashes:
    print("  %s  (%s)" % (rel, cls))
    print("      fun %s(%s)  —— %d 个重载擦除后相同" % (name, ", ".join(sig), n))
print("")
print("修法：给它们不同的方法名（如 put / putObjects / putStrings / putCameras），")
print("      不能靠 Kotlin 重载 —— JVM 上看它们是同一个方法。")
sys.exit(1)

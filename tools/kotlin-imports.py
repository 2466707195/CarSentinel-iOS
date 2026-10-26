import io, os, re, sys, collections

ROOT = r"C:\Users\24667\Documents\deepseek-harness\default-workspace\CarSentinel360"
SRC = os.path.join(ROOT, "android/app/src/main/java")

files = []
for dirpath, dirnames, filenames in os.walk(SRC):
    for fn in filenames:
        if fn.endswith(".kt"):
            files.append(os.path.join(dirpath, fn))
files.sort()


def strip_noise(t):
    """剥掉注释和字符串字面量，避免把注释里的词当成代码符号。"""
    out = []
    i, n = 0, len(t)
    while i < n:
        c = t[i]
        if c == "/" and i + 1 < n and t[i + 1] == "/":
            while i < n and t[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and t[i + 1] == "*":
            i += 2
            nest = 1
            while i < n and nest > 0:
                if t[i] == "/" and i + 1 < n and t[i + 1] == "*":
                    nest += 1; i += 2; continue
                if t[i] == "*" and i + 1 < n and t[i + 1] == "/":
                    nest -= 1; i += 2; continue
                i += 1
            out.append(" ")
            continue
        if t[i:i + 3] == '"""':
            i += 3
            while i < n and t[i:i + 3] != '"""':
                i += 1
            i += 3
            out.append(' "" ')
            continue
        if c == '"':
            i += 1
            while i < n:
                if t[i] == "\\":
                    i += 2; continue
                if t[i] == '"':
                    i += 1; break
                i += 1
            out.append(' "" ')
            continue
        if c == "'":
            i += 1
            while i < n:
                if t[i] == "\\":
                    i += 2; continue
                if t[i] == "'":
                    i += 1; break
                i += 1
            out.append(" '' ")
            continue
        out.append(c)
        i += 1
    return "".join(out)


# ---- 同包顶层声明 ----
declared = set()
for p in files:
    with io.open(p, "r", encoding="utf-8") as f:
        t = strip_noise(f.read())
    for m in re.finditer(r'\b(?:class|object|interface|enum\s+class)\s+(\w+)', t):
        declared.add(m.group(1))
    # 枚举成员：enum class Screen { Status, Log } 里的 Status / Log 不需要 import
    for m in re.finditer(r'enum\s+class\s+\w+\s*(?:\([^)]*\))?\s*\{(.*?)\}', t, re.S):
        for entry in m.group(1).split(","):
            nm = entry.strip().split("(")[0].strip()
            if re.fullmatch(r'\w+', nm):
                declared.add(nm)
    for m in re.finditer(r'^\s*(?:val|var|fun)\s+(?:<[^>]+>\s+)?(\w+)', t, re.M):
        declared.add(m.group(1))
    for m in re.finditer(r'\btypealias\s+(\w+)', t):
        declared.add(m.group(1))

# ---- Kotlin 默认导入 + java.lang（都不需要显式 import）----
BUILTIN = set("""
String Int Long Boolean Double Float Byte Short Char Unit Any Nothing List MutableList Map MutableMap Set MutableSet
Array ArrayList MutableList HashMap HashSet LinkedHashMap ArrayDeque Pair Triple Regex StringBuilder Exception
Throwable RuntimeException IllegalStateException IllegalArgumentException SecurityException InterruptedException
Comparable Number Sequence Result Lazy ByteArray IntArray BooleanArray LongArray CharArray Object System Thread
Runnable Iterable Iterator MutableIterable MutableIterator Collection MutableCollection Charsets Suppress Deprecated
JvmStatic Volatile Synchronized OptIn Composable Immutable T R E K V
Math Integer Character CharSequence Cloneable Enum Void Class Comparable Appendable Process Runtime
""".split())

report = collections.OrderedDict()
for p in files:
    with io.open(p, "r", encoding="utf-8") as f:
        raw = f.read()
    t = strip_noise(raw)

    imported = set()
    for m in re.finditer(r'^import\s+([\w.]+)(?:\s+as\s+(\w+))?$', t, re.M):
        imported.add(m.group(2) or m.group(1).split(".")[-1])

    local = set()
    for m in re.finditer(r'\b(?:class|object|interface|enum\s+class|fun|val|var)\s+(\w+)', t):
        local.add(m.group(1))
    for m in re.finditer(r'<([A-Za-z,:\s]+)>', t):
        for part in m.group(1).split(","):
            nm = part.strip().split(":")[0].strip().split(" ")[-1]
            if nm:
                local.add(nm)

    # 关键：只数「前面不是点、不是单词字符」的裸用法 —— 全限定名 foo.Bar 不算
    used = set()
    for m in re.finditer(r'(?<![.\w$])([A-Z]\w{2,})\b', t):
        used.add(m.group(1))

    missing = []
    for name in sorted(used):
        if name in imported or name in BUILTIN or name in declared or name in local:
            continue
        if name.isupper():
            continue
        missing.append(name)
    if missing:
        report[os.path.relpath(p, SRC).replace("\\", "/")] = missing

print("同包顶层声明 %d 个，Kotlin 文件 %d 个" % (len(declared), len(files)))
if not report:
    print("")
    print("干净：所有裸用的类型都有 import、同包声明、或是标准库/默认导入")
else:
    print("")
    print("候选（人工确认）:")
    for f, names in report.items():
        print("  %s" % f)
        print("      %s" % ", ".join(names))

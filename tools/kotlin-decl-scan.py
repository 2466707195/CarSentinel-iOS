"""扫 Kotlin 里 `val x: Type(...)` 这种漏了 `=` 的声明。

为什么专门做这个：Aurora UI 资产里带过来一个
    val warningContainer: Color(0xFFFFEDCB)
少个 `=`，导致整个 data class 解析失败，进而 AppTheme.colors.* 全部
unresolved —— 一个等号炸出 14 个编译错。括号配平检查器对此完全无感
（括号是配平的），所以单独扫一遍。
"""
import io, os, re, sys

ROOT = r"C:\Users\24667\Documents\deepseek-harness\default-workspace\CarSentinel360"
SRC = os.path.join(ROOT, "android")

# val/var NAME: Type(   —— 声明属性时类型后面直接跟左圆括号，说明漏了 `=`
PAT = re.compile(r'\b(?:val|var)\s+(\w+)\s*:\s*([A-Za-z_][\w.]*(?:<[^>]*>)?)\s*\(')

problems = []
files = []
for dirpath, dirnames, filenames in os.walk(SRC):
    dirnames[:] = [d for d in dirnames if d not in ("build", ".gradle")]
    for fn in filenames:
        if fn.endswith(".kt"):
            files.append(os.path.join(dirpath, fn))
files.sort()

for p in files:
    with io.open(p, "r", encoding="utf-8") as f:
        for i, line in enumerate(f, 1):
            stripped = line.strip()
            # 跳过注释行：注释里提到旧代码会造成误报
            if stripped.startswith("//") or stripped.startswith("*") or stripped.startswith("/*"):
                continue
            m = PAT.search(line)
            if m:
                problems.append((os.path.relpath(p, ROOT).replace("\\", "/"), i,
                                 m.group(1), m.group(2), line.strip()))

if not problems:
    print("干净：没有漏 `=` 的属性声明（扫了 %d 个 .kt）" % len(files))
    sys.exit(0)

print("发现 %d 处可疑声明：" % len(problems))
for rel, ln, name, typ, text in problems:
    print("  %s:%d" % (rel, ln))
    print("      %s" % text)
print("")
print("修法：`val %s: %s = %s(...)` —— 补上等号。"
      % (problems[0][2], problems[0][3], problems[0][3]))
sys.exit(1)

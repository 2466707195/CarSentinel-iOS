import io, os, sys

ROOTS = [
    r"C:\Users\24667\Documents\deepseek-harness\default-workspace\CarSentinel360\android",
    r"C:\Users\24667\Documents\deepseek-harness\default-workspace\CarSentinel360\ios",
]
EXTS = (".kt", ".swift", ".kts")


def scan(path):
    """极简 Kotlin/Swift 扫描器：跳过注释与字符串字面量，统计括号配平。"""
    with io.open(path, "r", encoding="utf-8") as f:
        src = f.read()

    i, n = 0, len(src)
    depth = {"(": 0, "{": 0, "[": 0}
    pairs = {")": "(", "}": "{", "]": "["}
    stack = []
    problems = []
    line = 1

    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
            continue

        # 行注释
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
            continue

        # 块注释（Kotlin 可嵌套）
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            nest = 1
            while i < n and nest > 0:
                if src[i] == "\n":
                    line += 1
                if src[i] == "/" and i + 1 < n and src[i + 1] == "*":
                    nest += 1
                    i += 2
                    continue
                if src[i] == "*" and i + 1 < n and src[i + 1] == "/":
                    nest -= 1
                    i += 2
                    continue
                i += 1
            continue

        # 三引号字符串（Swift/Kotlin 都有）
        if c == '"' and src[i:i + 3] == '"""':
            i += 3
            while i < n and src[i:i + 3] != '"""':
                if src[i] == "\n":
                    line += 1
                i += 1
            i += 3
            continue

        # 普通字符串 / 字符字面量
        if c == '"' or c == "'":
            quote = c
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == "\n":
                    line += 1
                    if quote == "'":
                        problems.append((line, "字符字面量跨行"))
                    i += 1
                    continue
                if src[i] == quote:
                    i += 1
                    break
                i += 1
            continue

        # 字符串插值 \(...) / \(...) —— 里面的括号也要数，但先按普通括号算
        if c in "({[":
            stack.append((c, line))
            i += 1
            continue
        if c in ")}]":
            if not stack:
                problems.append((line, "多余的 " + c))
            else:
                op, ol = stack.pop()
                if op != pairs[c]:
                    problems.append((line, "括号不匹配：%s (行%d) 对 %s" % (c, line, op)))
            i += 1
            continue

        i += 1

    if stack:
        for op, ol in stack[-4:]:
            problems.append((ol, "未闭合的 " + op))
    return problems, len(src)


def main():
    files = []
    for root in ROOTS:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in ("build", ".gradle", "Assets.xcassets")]
            for fn in filenames:
                if fn.endswith(EXTS):
                    files.append(os.path.join(dirpath, fn))
    files.sort()

    bad = 0
    for p in files:
        problems, size = scan(p)
        rel = os.path.relpath(p, os.path.dirname(ROOTS[0]))
        if problems:
            bad += 1
            print("FAIL  %-70s %6d B" % (rel, size))
            for ln, msg in problems[:6]:
                print("        行 %-5d %s" % (ln, msg))
        else:
            print("ok    %-70s %6d B" % (rel, size))

    print("")
    print("文件数: %d    有问题: %d" % (len(files), bad))


main()

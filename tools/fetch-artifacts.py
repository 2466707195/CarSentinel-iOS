"""下载指定 run 的 artifact 到 build/（日志或产物包）。

job logs 端点（/actions/jobs/<id>/logs）在某些网络下会 SSL 断流，
但 artifact zip 走的是同样受支持的对象存储，更稳。所以优先用 artifact。
"""
import argparse
import io
import json
import os
import sys
import urllib.error
import urllib.request
import zipfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
API = "https://api.github.com"


def req(token, url, binary=False):
    r = urllib.request.Request(url, headers={
        "Authorization": "Bearer " + token,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "carsentinel-artifact-fetcher",
    })
    with urllib.request.urlopen(r, timeout=180) as resp:
        data = resp.read()
        return data if binary else json.loads(data.decode("utf-8"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--run", type=int, required=True)
    ap.add_argument("--token", default=os.environ.get("GITHUB_TOKEN", ""))
    ap.add_argument("--out", default=os.path.join(ROOT, "build"))
    ap.add_argument("--name", default="", help="只下这一个 artifact；不给则全下")
    args = ap.parse_args()
    if not args.token:
        print("需要 token"); return 1

    arts = req(args.token, "%s/repos/%s/actions/runs/%d/artifacts"
               % (API, args.repo, args.run))
    if not arts.get("artifacts"):
        print("没有 artifact")
        return 1

    if not os.path.isdir(args.out):
        os.makedirs(args.out)

    for a in arts["artifacts"]:
        if args.name and a["name"] != args.name:
            continue
        print("下载 %-22s %6.1f KB ..." % (a["name"], a["size_in_bytes"] / 1024.0))
        try:
            blob = req(args.token, a["url"] + "/zip", binary=True)
        except Exception as e:
            print("   !! 失败：%s" % e)
            continue
        # 日志类 artifact 直接摊到 build/logs/<name>/，产物类摊到 build/
        is_log = a["name"].endswith("-log")
        dest = os.path.join(args.out, "logs", a["name"]) if is_log else args.out
        if not os.path.isdir(dest):
            os.makedirs(dest)
        with io.BytesIO(blob) as bio:
            with zipfile.ZipFile(bio) as z:
                z.extractall(dest)
        for f in sorted(os.listdir(dest)):
            p = os.path.join(dest, f)
            if os.path.isfile(p):
                print("   -> %s (%.1f KB)" % (p, os.path.getsize(p) / 1024.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())

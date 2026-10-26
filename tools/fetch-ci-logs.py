"""把 GitHub Actions 上失败的 job 日志拉到本地 build/logs/。

为什么需要这个：本机浏览器常常连不上 GitHub，而 publish-github.ps1 在构建失败时
以前会直接 exit、跳过 artifact 下载。这个脚本是独立兜底，不依赖发布脚本。

用法：
    python tools/fetch-ci-logs.py --repo 2466707195/CarSentinel-iOS --run 40314124721
    python tools/fetch-ci-logs.py --repo owner/name          # 自动取最近一次 run
"""
import argparse
import io
import json
import os
import sys
import urllib.error
import urllib.request

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
OUT = os.path.join(ROOT, "build", "logs")

API = "https://api.github.com"


def gh(token, path):
    req = urllib.request.Request(
        API + path,
        headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "carsentinel-log-fetcher",
        },
    )
    with urllib.request.urlopen(req, timeout=90) as r:
        return r.read()


def gh_json(token, path):
    return json.loads(gh(token, path).decode("utf-8"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="owner/name")
    ap.add_argument("--run", type=int, default=0, help="run id；不给则取最近一次")
    ap.add_argument("--token", default=os.environ.get("GITHUB_TOKEN", ""))
    args = ap.parse_args()

    if not args.token:
        print("需要 token：--token ghp_xxx 或设环境变量 GITHUB_TOKEN")
        return 1

    base = "/repos/" + args.repo
    if not args.run:
        runs = gh_json(args.token, base + "/actions/runs?per_page=5")
        if not runs.get("workflow_runs"):
            print("这个仓库还没有任何 workflow run")
            return 1
        args.run = runs["workflow_runs"][0]["id"]
        print("自动取最近一次 run：%d（%s / %s）"
              % (args.run, runs["workflow_runs"][0]["name"],
                 runs["workflow_runs"][0]["conclusion"]))

    run = gh_json(args.token, "%s/actions/runs/%d" % (base, args.run))
    print("run %d：%s / %s" % (args.run, run["status"], run.get("conclusion")))
    print("  %s" % run.get("html_url", ""))

    jobs = gh_json(args.token, "%s/actions/runs/%d/jobs" % (base, args.run))
    if not os.path.isdir(OUT):
        os.makedirs(OUT)

    print("")
    for j in jobs.get("jobs", []):
        safe = "".join(c if (c.isalnum() or c in "-_") else "-" for c in j["name"])
        print("  job %-28s %-10s %s" % (j["name"], j.get("conclusion"), j["status"]))
        path = os.path.join(OUT, safe + ".log")
        try:
            raw = gh(args.token, "/repos/%s/actions/jobs/%d/logs" % (args.repo, j["id"]))
            with io.open(path, "wb") as f:
                f.write(raw)
            print("      -> %s (%.1f KB)" % (safe + ".log", len(raw) / 1024.0))
        except urllib.error.HTTPError as e:
            print("      !! 拉日志失败 HTTP %d（日志可能已过期，GitHub 只保留约 1 年）"
                  % e.code)
        except Exception as e:
            print("      !! %s" % e)

    # 同时把 run 级 artifact 列出来
    arts = gh_json(args.token, "%s/actions/runs/%d/artifacts" % (base, args.run))
    print("")
    if arts.get("total_count", 0) == 0:
        print("  artifact：(无)")
    else:
        print("  artifact：")
        for a in arts["artifacts"]:
            print("    %-24s %6.1f KB  %s"
                  % (a["name"], a["size_in_bytes"] / 1024.0, a.get("expired") and "(已过期)" or ""))
    print("")
    print("日志目录：%s" % OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())

import io, os, sys, json, time, urllib.request, urllib.error

TOK = os.environ.get("GITHUB_TOKEN", "")
REPO = "2466707195/CarSentinel-iOS"
API = "https://api.github.com"


def gh(path):
    r = urllib.request.Request(API + path, headers={
        "Authorization": "Bearer " + TOK,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "cs-status",
    })
    # 某些网络下 Python 的 SSL 握手会断，重试几次再放弃
    last = None
    for _ in range(4):
        try:
            with urllib.request.urlopen(r, timeout=60) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except Exception as e:
            last = e
            time.sleep(2)
    raise last


def main():
    if not TOK:
        print("需要 GITHUB_TOKEN"); return 1
    run_id = int(sys.argv[1]) if len(sys.argv) > 1 else None
    if not run_id:
        runs = gh("/repos/%s/actions/runs?per_page=1" % REPO)
        run_id = runs["workflow_runs"][0]["id"]
    run = gh("/repos/%s/actions/runs/%d" % (REPO, run_id))
    jobs = gh("/repos/%s/actions/runs/%d/jobs" % (REPO, run_id))
    print("run %d  %s / %s   %s" % (run_id, run["status"], run.get("conclusion"),
                                    run.get("html_url", "")))
    print("  started %s" % run.get("run_started_at", ""))
    for j in jobs.get("jobs", []):
        print("")
        print("  job: %s" % j["name"])
        print("    status=%s conclusion=%s" % (j["status"], j.get("conclusion")))
        for s in j.get("steps", []):
            mark = {"success": "[ok]", "failure": "[X]", "in_progress": "[..]",
                    "queued": "[  ]", "skipped": "[--]"}.get(s["status"], "[??]")
            extra = ""
            if s.get("conclusion"):
                extra = " -> " + s["conclusion"]
            print("      %s %-34s %s%s" % (mark, s["name"], s["status"], extra))
    return 0


if __name__ == "__main__":
    sys.exit(main())

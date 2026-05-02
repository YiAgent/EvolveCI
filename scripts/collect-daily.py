#!/usr/bin/env python3
"""
collect-daily.py — aggregate 24h CI stats across onboarded repos into a JSON
the /daily-report agent renders into a markdown body.

The agent (CLAUDE LLM) shouldn't be querying gh / counting runs / computing
percentages — that's deterministic work. This script does it once, the
agent ingests the JSON and writes prose.

Schema (daily-stats.json):
{
  "schema_version": 1,
  "generated_at":   "2026-05-02T01:00:00+00:00",
  "window":         "24h",
  "since":          "2026-05-01T01:00:00+00:00",
  "repos":          ["YiAgent/EvolveCI", "YiAgent/OpenCI", ...],
  "totals": {
    "runs":     483,
    "success":  401,
    "failure":   76,
    "cancelled": 6,
    "success_rate": 0.83,
    "flaky_rate":   0.05
  },
  "top_failing_workflows": [
    {"repo": "YiAgent/OpenCI", "workflow": "issue-comment.yml", "fails": 18}
  ],
  "triage": {
    "new":       {"count": 4, "samples": [{"number": 42, "title": "...", "category": "flaky"}]},
    "open_24h":  {"count": 1, "samples": [...]},
    "patterns_added": {"count": 2, "samples": [...]}
  },
  "circuit": {"active": false, "tripped_at": null}
}

Usage:
    python3 scripts/collect-daily.py --out daily-stats.json
    python3 scripts/collect-daily.py --since 24h --out daily-stats.json
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def parse_window(spec: str) -> dt.timedelta:
    m = re.fullmatch(r"(\d+)([mhd])", spec)
    if not m:
        raise SystemExit(f"bad window {spec!r}; use 30m / 24h / 7d")
    qty, unit = int(m.group(1)), m.group(2)
    return {"m": dt.timedelta(minutes=qty),
            "h": dt.timedelta(hours=qty),
            "d": dt.timedelta(days=qty)}[unit]


def gh(args: list[str], *, check: bool = False) -> str:
    try:
        return subprocess.check_output(["gh", *args], text=True, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as e:
        if check:
            sys.stderr.write(f"gh {' '.join(args)} failed: {e.stderr}\n")
            raise
        return ""


def load_repos(path: Path) -> list[dict]:
    import yaml
    with path.open() as f:
        return (yaml.safe_load(f) or {}).get("repos", [])


def runs_for(repo: str, since: dt.datetime, *, exclude_files: set[str]) -> list[dict]:
    """All runs (any conclusion) within window. Filtered by exclude list."""
    raw = gh([
        "run", "list", "--repo", repo, "--limit", "300",
        "--json", "databaseId,name,workflowName,workflowDatabaseId,createdAt,conclusion,event",
        "--created", f">{since.strftime('%Y-%m-%dT%H:%M:%SZ')}",
    ])
    runs = json.loads(raw) if raw else []

    if not exclude_files:
        return runs

    wf_raw = gh(["api", f"repos/{repo}/actions/workflows", "--paginate",
                 "--jq", "[.workflows[] | {id: (.id|tostring), path: .path}]"])
    wf_paths = {row["id"]: row["path"].rsplit("/", 1)[-1]
                for row in (json.loads(wf_raw) if wf_raw else [])}

    return [
        r for r in runs
        if wf_paths.get(str(r.get("workflowDatabaseId", "")), "") not in exclude_files
    ]


def gh_issues_json(args: list[str]) -> list[dict]:
    raw = gh(args)
    return json.loads(raw) if raw else []


def main() -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").split("\n", 1)[0])
    ap.add_argument("--repos-file", default="data/onboarded-repos.yml")
    ap.add_argument("--since", default="24h")
    ap.add_argument("--out", default="daily-stats.json")
    ap.add_argument("--dedup-repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    args = ap.parse_args()

    delta = parse_window(args.since)
    since = dt.datetime.now(dt.timezone.utc) - delta
    since_iso = since.strftime("%Y-%m-%dT%H:%M:%SZ")

    repos = load_repos(Path(args.repos_file))
    repo_names: list[str] = [r["name"] for r in repos]

    # ── Aggregate run totals across repos ──────────────────────────────────
    totals: dict[str, int | float] = {"runs": 0, "success": 0, "failure": 0, "cancelled": 0}
    failing_workflows: dict[tuple[str, str], int] = {}

    for repo in repos:
        runs = runs_for(
            repo["name"], since,
            exclude_files=set(repo.get("exclude") or []),
        )
        totals["runs"] += len(runs)
        for run in runs:
            concl = run.get("conclusion") or "running"
            if concl == "success":
                totals["success"] += 1
            elif concl == "failure":
                totals["failure"] += 1
                wf = run.get("workflowName") or run.get("name") or "?"
                key = (repo["name"], wf)
                failing_workflows[key] = failing_workflows.get(key, 0) + 1
            elif concl in ("cancelled", "skipped"):
                totals["cancelled"] += 1

    completed = totals["success"] + totals["failure"]
    totals["success_rate"] = round(totals["success"] / completed, 3) if completed else 0.0

    top_failing = [
        {"repo": repo, "workflow": wf, "fails": n}
        for (repo, wf), n in sorted(failing_workflows.items(),
                                    key=lambda kv: kv[1], reverse=True)[:5]
    ]

    # ── Issue-derived signals (triage / patterns / circuit) ────────────────
    dedup_repo = args.dedup_repo or repo_names[0] if repo_names else ""

    new_triage = gh_issues_json([
        "issue", "list", "--repo", dedup_repo,
        "--label", "evolveci/triage", "--state", "all",
        "--search", f"created:>{since_iso}", "-L", "200",
        "--json", "number,title,labels,createdAt",
    ])
    open_old_triage = gh_issues_json([
        "issue", "list", "--repo", dedup_repo,
        "--label", "evolveci/triage", "--state", "open", "-L", "200",
        "--search", f"created:<{since_iso}",
        "--json", "number,title,labels,createdAt",
    ])
    new_patterns = gh_issues_json([
        "issue", "list", "--repo", dedup_repo,
        "--label", "evolveci/pattern", "--state", "all",
        "--search", f"created:>{since_iso}", "-L", "100",
        "--json", "number,title,createdAt",
    ])

    def issue_summary(items: list[dict], k: int = 5) -> list[dict]:
        out: list[dict] = []
        for it in items[:k]:
            cats = [lbl["name"].removeprefix("category:")
                    for lbl in it.get("labels", []) or []
                    if lbl["name"].startswith("category:")]
            out.append({
                "number": it["number"],
                "title": it["title"],
                "category": cats[0] if cats else None,
            })
        return out

    flaky_count = sum(
        1 for it in new_triage
        if any(lbl["name"] == "category:flaky"
               for lbl in (it.get("labels") or []))
    )
    flaky_rate = (flaky_count / completed) if completed else 0.0
    totals["flaky_rate"] = round(flaky_rate, 3)

    # Circuit breaker state.
    circ_raw = gh_issues_json([
        "issue", "list", "--repo", dedup_repo,
        "--label", "evolveci/circuit", "--state", "all", "-L", "1",
        "--json", "body",
    ])
    circuit = {"active": False, "tripped_at": None}
    if circ_raw:
        try:
            circuit_state = json.loads(circ_raw[0].get("body") or "{}")
            circuit = {
                "active": bool(circuit_state.get("active", False)),
                "tripped_at": circuit_state.get("tripped_at"),
            }
        except json.JSONDecodeError:
            pass

    out = {
        "schema_version": 1,
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "window": args.since,
        "since": since.isoformat(timespec="seconds"),
        "repos": repo_names,
        "totals": totals,
        "top_failing_workflows": top_failing,
        "triage": {
            "new": {"count": len(new_triage), "samples": issue_summary(new_triage)},
            "open_old": {"count": len(open_old_triage), "samples": issue_summary(open_old_triage)},
            "patterns_added": {"count": len(new_patterns), "samples": issue_summary(new_patterns)},
        },
        "circuit": circuit,
        "no_data": totals["runs"] == 0,
    }
    Path(args.out).write_text(json.dumps(out, indent=2, ensure_ascii=False))
    sys.stderr.write(f"Wrote {args.out} — {totals['runs']} runs, {totals['failure']} failures across {len(repos)} repos\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""
collect-weekly.py — aggregate 7d CI stats + DORA metrics for the
/weekly-report agent. Reuses the daily collector's logic and adds
per-day breakdown, top patterns, and MTTR/lead-time on triage issues.

Schema (weekly-stats.json):
{
  "schema_version": 1,
  "window": "7d",
  "iso_week": "2026-W18",
  "since": "...",
  "until": "...",
  "totals":   {<same shape as daily>},
  "by_day":   [{"date": "2026-05-01", "runs": 80, "failures": 12}, ...],
  "top_failing_workflows": [...],
  "triage": {
     "new":               {"count": N, "samples": [...]},
     "closed":            {"count": N, "samples": [...]},
     "open_at_week_end":  {"count": N, "samples": [...]},
     "patterns_added":    {"count": N, "samples": [...]},
     "mttr_hours_p50":    4.2,
     "mttr_hours_p95":    18.7
  },
  "dora": {
     "deployment_frequency_per_day": 1.2,
     "change_failure_rate":          0.07,
     "mttr_hours":                   4.2
  },
  "circuit_history": [{"tripped_at": "...", "recovered_at": "..."}]
}

Usage:
    python3 scripts/collect-weekly.py --out weekly-stats.json
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import statistics
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DAYS = 7

# Reuse daily helpers via direct import (avoid duplication).
sys.path.insert(0, str(REPO_ROOT / "scripts"))
import importlib.util
_spec = importlib.util.spec_from_file_location(
    "_collect_daily", REPO_ROOT / "scripts" / "collect-daily.py"
)
assert _spec and _spec.loader
_daily = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_daily)
gh = _daily.gh
load_repos = _daily.load_repos
runs_for = _daily.runs_for
gh_issues_json = _daily.gh_issues_json


def _percentile(values: list[float], q: float) -> float | None:
    if not values:
        return None
    return round(statistics.quantiles(values, n=100, method="inclusive")[int(q) - 1], 2) \
        if len(values) > 1 else round(values[0], 2)


def main() -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").split("\n", 1)[0])
    ap.add_argument("--repos-file", default="data/onboarded-repos.yml")
    ap.add_argument("--out", default="weekly-stats.json")
    ap.add_argument("--dedup-repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    args = ap.parse_args()

    until = dt.datetime.now(dt.timezone.utc)
    since = until - dt.timedelta(days=DAYS)
    since_iso = since.strftime("%Y-%m-%dT%H:%M:%SZ")
    iso_year, iso_week, _ = until.isocalendar()

    repos = load_repos(Path(args.repos_file))
    repo_names: list[str] = [r["name"] for r in repos]
    dedup_repo = args.dedup_repo or (repo_names[0] if repo_names else "")

    # ── totals + by-day ──────────────────────────────────────────────────
    totals: dict[str, int | float] = {"runs": 0, "success": 0, "failure": 0, "cancelled": 0}
    failing_workflows: dict[tuple[str, str], int] = {}
    deploy_runs: list[dict] = []  # for DORA deployment_frequency / CFR
    by_day_buckets: dict[str, dict[str, int]] = {}

    for repo in repos:
        for run in runs_for(repo["name"], since,
                            exclude_files=set(repo.get("exclude") or [])):
            totals["runs"] += 1
            wf = run.get("workflowName") or run.get("name") or "?"
            concl = run.get("conclusion") or "running"
            day_key = (run.get("createdAt") or "")[:10] or "unknown"
            bucket = by_day_buckets.setdefault(
                day_key, {"runs": 0, "failures": 0, "success": 0}
            )
            bucket["runs"] += 1
            if concl == "success":
                totals["success"] += 1
                bucket["success"] += 1
            elif concl == "failure":
                totals["failure"] += 1
                bucket["failures"] += 1
                failing_workflows[(repo["name"], wf)] = \
                    failing_workflows.get((repo["name"], wf), 0) + 1
            elif concl in ("cancelled", "skipped"):
                totals["cancelled"] += 1

            if any(kw in wf.lower() for kw in
                   ("deploy", "release", "publish")):
                deploy_runs.append({"workflow": wf, "conclusion": concl})

    completed = totals["success"] + totals["failure"]
    totals["success_rate"] = round(totals["success"] / completed, 3) if completed else 0.0

    by_day = sorted(
        ({"date": k, **v} for k, v in by_day_buckets.items()),
        key=lambda r: r["date"],
    )

    top_failing = [
        {"repo": r, "workflow": wf, "fails": n}
        for (r, wf), n in sorted(failing_workflows.items(),
                                 key=lambda kv: kv[1], reverse=True)[:10]
    ]

    # ── triage: new / closed / still-open / MTTR ─────────────────────────
    new_triage = gh_issues_json([
        "issue", "list", "--repo", dedup_repo,
        "--label", "evolveci/triage", "--state", "all",
        "--search", f"created:>{since_iso}", "-L", "300",
        "--json", "number,title,createdAt,closedAt,labels,state",
    ])
    closed_triage = [t for t in new_triage if t.get("state") == "CLOSED"]
    open_at_week_end = [t for t in new_triage if t.get("state") == "OPEN"]

    mttr_hours: list[float] = []
    for t in closed_triage:
        c = t.get("createdAt"); cl = t.get("closedAt")
        if not c or not cl:
            continue
        try:
            d_open = dt.datetime.fromisoformat(c.replace("Z", "+00:00"))
            d_close = dt.datetime.fromisoformat(cl.replace("Z", "+00:00"))
            mttr_hours.append((d_close - d_open).total_seconds() / 3600.0)
        except ValueError:
            continue

    mttr_p50 = _percentile(mttr_hours, 50)
    mttr_p95 = _percentile(mttr_hours, 95)

    new_patterns = gh_issues_json([
        "issue", "list", "--repo", dedup_repo,
        "--label", "evolveci/pattern", "--state", "all",
        "--search", f"created:>{since_iso}", "-L", "100",
        "--json", "number,title,createdAt",
    ])

    # ── DORA derivatives ─────────────────────────────────────────────────
    deploy_completed = [r for r in deploy_runs if r["conclusion"] in ("success", "failure")]
    deploy_failures = sum(1 for r in deploy_completed if r["conclusion"] == "failure")
    dora = {
        "deployment_frequency_per_day": round(len(deploy_completed) / DAYS, 2),
        "change_failure_rate":
            round(deploy_failures / len(deploy_completed), 3) if deploy_completed else None,
        "mttr_hours": mttr_p50,
    }

    def issue_summary(items: list[dict], k: int = 8) -> list[dict]:
        out: list[dict] = []
        for it in items[:k]:
            cats = [lbl["name"].removeprefix("category:")
                    for lbl in (it.get("labels") or [])
                    if lbl["name"].startswith("category:")]
            out.append({
                "number": it["number"], "title": it["title"],
                "category": cats[0] if cats else None,
            })
        return out

    out = {
        "schema_version": 1,
        "iso_week": f"{iso_year}-W{iso_week:02d}",
        "window": f"{DAYS}d",
        "generated_at": until.isoformat(timespec="seconds"),
        "since": since.isoformat(timespec="seconds"),
        "until": until.isoformat(timespec="seconds"),
        "repos": repo_names,
        "totals": totals,
        "by_day": by_day,
        "top_failing_workflows": top_failing,
        "triage": {
            "new":               {"count": len(new_triage), "samples": issue_summary(new_triage)},
            "closed":            {"count": len(closed_triage), "samples": issue_summary(closed_triage)},
            "open_at_week_end":  {"count": len(open_at_week_end), "samples": issue_summary(open_at_week_end)},
            "patterns_added":    {"count": len(new_patterns), "samples": issue_summary(new_patterns)},
            "mttr_hours_p50":    mttr_p50,
            "mttr_hours_p95":    mttr_p95,
        },
        "dora": dora,
        "no_data": totals["runs"] == 0,
    }
    Path(args.out).write_text(json.dumps(out, indent=2, ensure_ascii=False))
    sys.stderr.write(
        f"Wrote {args.out} — {totals['runs']} runs / {totals['failure']} failures, "
        f"{len(new_triage)} triage issues, MTTR p50={mttr_p50}h\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

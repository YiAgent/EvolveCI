#!/usr/bin/env python3
"""
build-triage-input.py — collect failures from onboarded repos, run Tier 1
(regex catalogue) + Tier 2 (heuristics) classification, emit a single JSON
artifact the agent consumes.

The agent (/triage) reads this JSON and only does Tier 3 reasoning on entries
where neither tier produced a high-confidence answer.

The composite actions in actions/observability/analyzers/* implement the same
classification logic for one log at a time. This script is the batch
counterpart — it streams many failures through the same regex / heuristic
rules without spawning a job per failure.

Usage:
    python3 scripts/build-triage-input.py \
        --repos-file data/onboarded-repos.yml \
        --since 30m \
        --out triage-input.json

    # Read from local seed file instead of evolveci/pattern issues:
    PATTERNS_SOURCE=seed python3 scripts/build-triage-input.py ...

Environment:
    GH_TOKEN              required
    PATTERNS_SOURCE       'issues' (default) or 'seed' (read seed file)
    SEED_PATTERNS_PATH    seed JSON path (default: data/known-patterns.seed.json)
    DEDUP_REPO            repo to query for existing fingerprint: labels (default: GITHUB_REPOSITORY)
    LOG_TAIL              last N log lines per failure (default: 100)
    MAX_FAILURES          cap per run (default: 10)
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

# ─── Tier 2 heuristic rules (mirror analyzers/classify-heuristic) ──────────
# (regex, category, severity, confidence, auto_rerun, notify)
HEURISTIC_RULES: list[tuple[str, str, str, str, bool, bool]] = [
    (r"ECONNREFUSED|ENOTFOUND|EAI_AGAIN|ETIMEDOUT|ReadTimeoutError|context deadline exceeded",
     "flaky", "info", "high", True, False),
    (r"rate.?limit|429|too many requests|toomanyrequests",
     "flaky", "info", "high", True, False),
    (r"runner.*did not connect|runner.*failed to start|No space left on device",
     "flaky", "warning", "medium", True, False),
    (r"Permission denied|403 Forbidden|authentication failed|unauthorized",
     "infra", "critical", "high", False, True),
    (r"npm ERR!|pip install.*error|go:.*module.*not found|resolve.*version.*conflict",
     "dependency", "warning", "medium", False, True),
    (r"FAIL|AssertionError|SyntaxError|TypeError|Compilation failed|Test failed",
     "code", "warning", "medium", False, True),
    (r"docker.*daemon|OOM|Cannot allocate memory|CrashLoopBackOff|ImagePullBackOff",
     "infra", "critical", "medium", False, True),
]

REPO_ROOT = Path(__file__).resolve().parent.parent
REDACT_SH = REPO_ROOT / "lib" / "redact-log.sh"


def parse_window(spec: str) -> dt.datetime:
    m = re.fullmatch(r"(\d+)([mhd])", spec)
    if not m:
        raise SystemExit(f"bad window {spec!r}; use 30m / 24h / 7d")
    qty, unit = int(m.group(1)), m.group(2)
    delta = {"m": dt.timedelta(minutes=qty),
             "h": dt.timedelta(hours=qty),
             "d": dt.timedelta(days=qty)}[unit]
    return dt.datetime.now(dt.timezone.utc) - delta


def gh(args: list[str], *, check: bool = True) -> str:
    """Run gh and return stdout. Returns "" on failure when check=False."""
    try:
        return subprocess.check_output(["gh", *args], text=True, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as e:
        if check:
            sys.stderr.write(f"gh {' '.join(map(shlex.quote, args))} failed: {e.stderr}\n")
            raise
        return ""


def load_repos(path: Path) -> list[dict]:
    import yaml  # only needed when loading
    with path.open() as f:
        return (yaml.safe_load(f) or {}).get("repos", [])


def load_patterns(source: str, seed_path: Path, dedup_repo: str | None) -> list[dict]:
    """Pattern catalogue source: 'issues' (live) or 'seed' (local file)."""
    if source == "seed":
        return json.loads(seed_path.read_text())

    out = gh(["issue", "list",
              "--repo", dedup_repo or os.environ["GITHUB_REPOSITORY"],
              "--label", "evolveci/pattern", "--state", "all", "-L", "200",
              "--json", "body", "--jq", ".[].body"], check=False)
    patterns: list[dict] = []
    for body in (out or "").splitlines():
        # The body may itself contain newlines; gh --jq above flattens to one
        # line per body when the body is a single string field. If the issue
        # body has internal newlines this becomes multiple lines; recombine
        # by re-querying JSON-form below if needed.
        pass
    # Safer: re-query with raw JSON.
    raw = gh(["issue", "list",
              "--repo", dedup_repo or os.environ["GITHUB_REPOSITORY"],
              "--label", "evolveci/pattern", "--state", "all", "-L", "200",
              "--json", "body"], check=False)
    if not raw:
        return []
    for issue in json.loads(raw):
        body = issue.get("body", "")
        m = re.search(r"```json\s*\n(.*?)\n```", body, flags=re.DOTALL)
        if not m:
            continue
        try:
            patterns.append(json.loads(m.group(1)))
        except json.JSONDecodeError:
            sys.stderr.write(f"WARN: pattern issue body has invalid JSON; skipping\n")
    return patterns


def run_redact(text: str) -> str:
    """Pipe through lib/redact-log.sh; fall back to identity if missing."""
    if not REDACT_SH.exists():
        return text
    proc = subprocess.run(["bash", str(REDACT_SH)], input=text,
                          capture_output=True, text=True)
    return proc.stdout if proc.returncode == 0 else text


def fingerprint(redacted: str, step_name: str) -> str:
    error_lines = "\n".join(
        line for line in redacted.splitlines()
        if re.search(r"error|fail|fatal|panic|exception", line, re.I)
    )[-1000:]
    composite = f"{step_name}::{error_lines}"
    return hashlib.sha256(composite.encode("utf-8")).hexdigest()[:12]


def match_tier1(log: str, patterns: list[dict]) -> dict:
    for p in patterns:
        regex = p.get("match")
        if not regex:
            continue
        try:
            if re.search(regex, log):
                return {
                    "matched": True,
                    "pattern_id": p.get("id"),
                    "category": p.get("category", "unknown"),
                    "severity": p.get("severity", "info"),
                    "auto_rerun": bool(p.get("auto_rerun", False)),
                    "notify": bool(p.get("notify", False)),
                    # action_suggestion is the v5.1 field; fall back to legacy
                    # fix_hint for patterns that haven't been re-rendered yet.
                    "action_suggestion": p.get("action_suggestion") or p.get("fix_hint", ""),
                    "description": p.get("description", ""),
                }
        except re.error:
            sys.stderr.write(f"WARN: invalid regex in pattern {p.get('id')}: {regex!r}\n")
    return {"matched": False}


def match_tier2(log: str) -> dict:
    for regex, cat, sev, conf, rerun, notify in HEURISTIC_RULES:
        if re.search(regex, log, re.I):
            return {
                "classified": True, "category": cat, "severity": sev,
                "confidence": conf, "auto_rerun": rerun, "notify": notify,
            }
    return {
        "classified": False, "category": "unknown", "severity": "warning",
        "confidence": "low", "auto_rerun": False, "notify": True,
    }


def fetch_failures(repo: str, since: dt.datetime, *,
                   exclude_files: set[str], log_tail: int,
                   limit: int) -> list[dict]:
    """Pull recent failures, drop excludes, attach failed-step + redacted log tail."""
    runs_raw = gh([
        "run", "list", "--repo", repo,
        "--status", "failure", "--limit", str(limit * 3),
        "--json", "databaseId,name,workflowName,workflowDatabaseId,createdAt,event,headBranch,url",
        "--created", f">{since.strftime('%Y-%m-%dT%H:%M:%SZ')}",
    ], check=False)
    runs = json.loads(runs_raw) if runs_raw else []

    # Build workflowDatabaseId → file basename map.
    wf_raw = gh(["api", f"repos/{repo}/actions/workflows", "--paginate",
                 "--jq", "[.workflows[] | {id: (.id|tostring), path: .path}]"],
                check=False)
    wf_paths = {row["id"]: row["path"].rsplit("/", 1)[-1]
                for row in (json.loads(wf_raw) if wf_raw else [])}

    out: list[dict] = []
    for run in runs:
        if len(out) >= limit:
            break
        wf_file = wf_paths.get(str(run.get("workflowDatabaseId", "")), "")
        if wf_file and wf_file in exclude_files:
            continue

        run_id = run["databaseId"]

        # Failed jobs + steps.
        jobs_raw = gh(["run", "view", str(run_id), "--repo", repo, "--json", "jobs"],
                      check=False)
        failed_step = ""
        if jobs_raw:
            jobs = json.loads(jobs_raw).get("jobs", [])
            for job in jobs:
                if job.get("conclusion") == "failure":
                    for step in job.get("steps", []):
                        if step.get("conclusion") == "failure":
                            failed_step = f"{job.get('name', '?')} / {step.get('name', '?')}"
                            break
                    if failed_step:
                        break

        # Last N lines of failed-job log.
        log_proc = subprocess.run(
            ["gh", "run", "view", str(run_id), "--repo", repo, "--log-failed"],
            capture_output=True, text=True, check=False,
        )
        raw_tail = "\n".join(log_proc.stdout.splitlines()[-log_tail:])
        redacted = run_redact(raw_tail) if raw_tail else ""

        out.append({
            "run_id": run_id,
            "repo": repo,
            "workflow_name": run.get("workflowName") or run.get("name", ""),
            "workflow_file": wf_file,
            "branch": run.get("headBranch", ""),
            "event": run.get("event", ""),
            "url": run.get("url", ""),
            "created_at": run.get("createdAt"),
            "failed_step": failed_step,
            "redacted_tail": redacted,
        })
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").split("\n", 1)[0])
    ap.add_argument("--repos-file", default="data/onboarded-repos.yml")
    ap.add_argument("--since", default="30m")
    ap.add_argument("--out", default="triage-input.json")
    ap.add_argument("--max-failures", type=int,
                    default=int(os.environ.get("MAX_FAILURES", 10)))
    args = ap.parse_args()

    since = parse_window(args.since)
    repos = load_repos(Path(args.repos_file))

    patterns = load_patterns(
        os.environ.get("PATTERNS_SOURCE", "issues"),
        REPO_ROOT / os.environ.get("SEED_PATTERNS_PATH", "data/known-patterns.seed.json"),
        os.environ.get("DEDUP_REPO"),
    )

    dedup_repo = os.environ.get("DEDUP_REPO") or os.environ.get("GITHUB_REPOSITORY", "")

    log_tail = int(os.environ.get("LOG_TAIL", 100))

    entries: list[dict] = []
    per_repo_processed: dict[str, int] = {}
    remaining = args.max_failures

    # High-priority repos first.
    repos_sorted = sorted(repos, key=lambda r: 0 if r.get("priority") == "high" else 1)
    for repo in repos_sorted:
        if remaining <= 0:
            break
        name = repo["name"]
        excludes = set(repo.get("exclude") or [])
        failures = fetch_failures(
            name, since,
            exclude_files=excludes, log_tail=log_tail,
            limit=min(remaining, args.max_failures),
        )
        per_repo_processed[name] = len(failures)
        for entry in failures:
            log = entry["redacted_tail"] or ""
            fp = fingerprint(log, entry["failed_step"]) if log else ""
            tier1 = match_tier1(log, patterns) if log else {"matched": False}
            tier2 = match_tier2(log) if log else {
                "classified": False, "category": "unknown",
                "severity": "warning", "confidence": "low",
                "auto_rerun": False, "notify": True,
            }

            # Existing-fingerprint check (dedup signal for the agent).
            existing = ""
            if fp and dedup_repo:
                resp = gh([
                    "issue", "list", "--repo", dedup_repo,
                    "--label", f"fingerprint:{fp}", "--state", "open", "-L", "1",
                    "--json", "number", "--jq", ".[0].number // empty"
                ], check=False).strip()
                existing = resp

            entries.append({
                **entry,
                "fingerprint": fp,
                "existing_issue": existing or None,
                "tier1": tier1,
                "tier2": tier2,
                "needs_tier3": (
                    not tier1.get("matched", False)
                    and tier2.get("confidence") in ("low", "medium")
                    and not existing
                ),
            })
        remaining -= len(failures)

    out = {
        "schema_version": 1,
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "since": since.isoformat(timespec="seconds"),
        "repos_processed": per_repo_processed,
        "patterns_count": len(patterns),
        "entries": entries,
    }
    Path(args.out).write_text(json.dumps(out, indent=2, ensure_ascii=False))
    sys.stderr.write(
        f"Wrote {args.out} — {len(entries)} entries, {sum(1 for e in entries if e['needs_tier3'])} need Tier 3\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

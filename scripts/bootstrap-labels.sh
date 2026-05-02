#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# bootstrap-labels.sh — idempotently create the EvolveCI label scheme.
# ─────────────────────────────────────────────────────────────────────────────
# Run once per monitored repo (or per agent-target repo) before the first
# /heartbeat. Safe to re-run — `gh label create --force` updates colour /
# description for existing labels and creates only the ones that are missing.
#
# The scheme is documented in docs/MEMORY-MODEL.md. Keep this file and that
# doc in sync.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO="${1:-${GITHUB_REPOSITORY:-}}"
if [ -z "$REPO" ]; then
  echo "usage: $0 <owner/repo>" >&2
  exit 2
fi

ensure() {
  local name="$1" colour="$2" description="$3"
  gh label create "$name" --color "$colour" --description "$description" \
    --repo "$REPO" --force >/dev/null
  echo "  ✓ $name"
}

echo "Creating EvolveCI labels in $REPO..."

# ── Type labels (mutually exclusive per issue) ───────────────────────────────
ensure "evolveci/triage"    "d73a4a" "EvolveCI agent — CI failure observation (one issue per fingerprint)"
ensure "evolveci/heartbeat" "fbca04" "EvolveCI agent — active health alert (≤1 open at a time)"
ensure "evolveci/daily"     "0e8a16" "EvolveCI agent — daily report (one per calendar date)"
ensure "evolveci/pattern"   "1d76db" "EvolveCI agent — known failure pattern (Tier 1 catalogue)"
ensure "evolveci/circuit"   "5319e7" "EvolveCI agent — circuit-breaker state (≤1 open at a time)"

# ── Severity labels ─────────────────────────────────────────────────────────
ensure "severity/critical"  "b60205" "Severity — critical: blocks pipelines or risks data"
ensure "severity/warning"   "fbca04" "Severity — warning: degrades but not blocking"
ensure "severity/info"      "c2e0c6" "Severity — informational"

# ── Category labels (failure taxonomy used by triage) ───────────────────────
ensure "category:flaky"      "fef2c0" "Category — flaky / non-deterministic"
ensure "category:infra"      "fef2c0" "Category — runner / infrastructure issue"
ensure "category:code"       "fef2c0" "Category — code defect"
ensure "category:dependency" "fef2c0" "Category — dependency / package issue"
ensure "category:unknown"    "fef2c0" "Category — needs deeper investigation"

# ── Status labels ────────────────────────────────────────────────────────────
ensure "status/recovered"    "0e8a16" "Status — auto-recovered by the agent"

echo "Done. fingerprint:* and repo:* labels are created on demand by triage."

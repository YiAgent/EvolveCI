#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# weekly-pr.sh — open a `weekly: <iso-week> deep dive` PR.
# ─────────────────────────────────────────────────────────────────────────────
# Designed for /weekly-report: cuts ~10 turns of git fiddling into one bash
# call. The agent only has to:
#   1. render its markdown report
#   2. compute the one-line CLAUDE.md update
#   3. invoke this script with both as inputs
#
# Usage:
#   bash scripts/weekly-pr.sh \
#     --report-file /tmp/weekly-report.md \
#     --learning-line "2026-05-02: _no new patterns this week_"
#
# Outputs (one JSON line):
#   {"status":"ok","branch":"weekly/2026-W18","pr":"https://...","week":"2026-W18"}
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPORT_FILE=""
LEARNING_LINE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --report-file)   REPORT_FILE="$2"; shift 2 ;;
    --learning-line) LEARNING_LINE="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

[ -n "$REPORT_FILE" ]   || { echo "--report-file required" >&2; exit 2; }
[ -f "$REPORT_FILE" ]   || { echo "report file not found: $REPORT_FILE" >&2; exit 2; }
[ -n "$LEARNING_LINE" ] || { echo "--learning-line required" >&2; exit 2; }

WEEK=$(date -u +%G-W%V)
BR="weekly/${WEEK}"

# Configure git identity for the agent's commit.
git config user.name  "evolveci-agent"
git config user.email "evolveci-agent@users.noreply.github.com"

# Branch off main.
git fetch origin main --quiet
git switch -c "$BR" origin/main

# Append the learning line under the "## 近期学习" header in CLAUDE.md.
python3 - "$LEARNING_LINE" <<'PY'
import sys, pathlib
line = sys.argv[1]
p = pathlib.Path("CLAUDE.md")
text = p.read_text()
marker = "## 近期学习（由 /weekly-report 维护）"
if marker not in text:
    raise SystemExit(f"marker not found in CLAUDE.md: {marker!r}")
header_end = text.index(marker) + len(marker)
nl = text.index("\n", header_end) + 1
# Skip the comment block right under the header
while text[nl:nl+5] == "<!--" or text[nl:nl+1] == "<":
    nl = text.index("\n", nl) + 1
# Skip placeholder
if text[nl:nl+2] == "_(":
    nl = text.index("\n", nl) + 1
# Insert the new line
new_text = text[:nl] + f"- {line}\n" + text[nl:]
p.write_text(new_text)
print(f"appended to CLAUDE.md: {line}")
PY

git add CLAUDE.md data/known-patterns.seed.json
git commit -m "weekly(${WEEK}): deep dive"
git push -u origin "$BR"

PR_URL=$(gh pr create \
  --base main --head "$BR" \
  --title "weekly: ${WEEK} deep dive" \
  --body-file "$REPORT_FILE")

printf '{"status":"ok","branch":"%s","pr":"%s","week":"%s"}\n' "$BR" "$PR_URL" "$WEEK"

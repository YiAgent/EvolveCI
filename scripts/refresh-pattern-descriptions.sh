#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# refresh-pattern-descriptions.sh — re-render existing evolveci/pattern issues
#                                   from the current seed JSON. Use after
#                                   updating descriptions / fix_hints in the
#                                   seed file.
# ─────────────────────────────────────────────────────────────────────────────
# Idempotent: matches issues by title `pattern: <id>`, edits the body in place.
# Issues whose ID isn't in the seed are left alone (might be agent-learned).
#
# Usage:
#   bash scripts/refresh-pattern-descriptions.sh                    # default repo
#   bash scripts/refresh-pattern-descriptions.sh YiAgent/EvolveCI   # explicit
#   DRY_RUN=1 bash scripts/refresh-pattern-descriptions.sh          # preview only
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO="${1:-${GITHUB_REPOSITORY:-}}"
SEED_FILE="${2:-data/known-patterns.seed.json}"
DRY_RUN="${DRY_RUN:-0}"

if [ -z "$REPO" ]; then
  echo "usage: $0 <owner/repo> [seed-json-path]" >&2
  exit 2
fi
if [ ! -f "$SEED_FILE" ]; then
  echo "seed file not found: $SEED_FILE" >&2
  exit 2
fi

UPDATED=0
SKIPPED=0
TOTAL=$(jq length "$SEED_FILE")

jq -c '.[]' "$SEED_FILE" | while IFS= read -r pattern; do
  ID=$(echo "$pattern" | jq -r .id)
  TITLE="pattern: $ID"

  ISSUE_NUM=$(gh issue list --repo "$REPO" \
    --label evolveci/pattern --state all -L 200 \
    --search "in:title \"$TITLE\"" \
    --json number,title \
    --jq ".[] | select(.title == \"$TITLE\") | .number" | head -1)

  if [ -z "$ISSUE_NUM" ]; then
    echo "{\"status\":\"skip\",\"reason\":\"no issue found\",\"id\":\"$ID\"}"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  BODY=$(printf '%s' "$pattern" | bash "$(dirname "$0")/render-pattern.sh")

  if [ "$DRY_RUN" = "1" ]; then
    echo "{\"status\":\"would_update\",\"id\":\"$ID\",\"issue\":$ISSUE_NUM}"
  else
    gh issue edit "$ISSUE_NUM" --repo "$REPO" --body "$BODY" >/dev/null
    echo "{\"status\":\"updated\",\"id\":\"$ID\",\"issue\":$ISSUE_NUM}"
  fi
  UPDATED=$((UPDATED + 1))
done

echo "{\"status\":\"done\",\"total\":$TOTAL,\"dry_run\":$DRY_RUN}"

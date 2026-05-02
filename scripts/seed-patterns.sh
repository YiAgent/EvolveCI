#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# seed-patterns.sh — port data/known-patterns.seed.json into evolveci/pattern
#                    Issues. Idempotent: skipped entirely if any
#                    evolveci/pattern issue already exists.
# ─────────────────────────────────────────────────────────────────────────────
# Run by /heartbeat probe 2 when the catalogue is empty. Safe to run by hand:
#   bash scripts/seed-patterns.sh YiAgent/EvolveCI
#
# Outputs one JSON line per created pattern + a final summary line.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO="${1:-${GITHUB_REPOSITORY:-}}"
SEED_FILE="${2:-data/known-patterns.seed.json}"

if [ -z "$REPO" ]; then
  echo "usage: $0 <owner/repo> [seed-json-path]" >&2
  exit 2
fi
if [ ! -f "$SEED_FILE" ]; then
  echo "seed file not found: $SEED_FILE" >&2
  exit 2
fi

# Idempotency check — skip when any pattern issue already exists.
EXISTING=$(gh issue list --repo "$REPO" --label evolveci/pattern --state all -L 1 \
  --json number --jq 'length')
if [ "$EXISTING" -gt 0 ]; then
  echo "{\"status\":\"skipped\",\"reason\":\"$EXISTING evolveci/pattern issues already exist\"}"
  exit 0
fi

CREATED=0
TOTAL=$(jq length "$SEED_FILE")
echo "{\"status\":\"seeding\",\"total\":$TOTAL,\"repo\":\"$REPO\"}"

# Iterate over each pattern in the seed file.
jq -c '.[]' "$SEED_FILE" | while IFS= read -r pattern; do
  ID=$(echo "$pattern"   | jq -r .id)
  RAW_SEV=$(echo "$pattern"  | jq -r '.severity // "info"')
  CAT=$(echo "$pattern"  | jq -r '.category // "unknown"')

  # Normalise seed-file severity (low / medium / high) into the bootstrap
  # label scheme (info / warning / critical).
  case "$RAW_SEV" in
    low)            SEV="info" ;;
    medium|warning) SEV="warning" ;;
    high|critical)  SEV="critical" ;;
    *)              SEV="info" ;;
  esac

  if [ -z "$ID" ] || [ "$ID" = "null" ]; then
    echo "{\"status\":\"warn\",\"reason\":\"pattern missing id\",\"pattern\":$pattern}" >&2
    continue
  fi

  # category: label uses category:foo (with colon), already created by bootstrap
  # severity/info etc., already created by bootstrap. We only auto-create
  # category labels we don't recognise.
  case "$CAT" in
    flaky|infra|code|dependency|unknown) ;;
    *)
      gh label create "category:$CAT" --color "fef2c0" \
        --description "Failure category" --force --repo "$REPO" >/dev/null
      ;;
  esac

  URL=$(gh issue create \
    --repo "$REPO" \
    --title "pattern: $ID" \
    --label "evolveci/pattern,severity/$SEV,category:$CAT" \
    --body "$pattern")
  CREATED=$((CREATED + 1))
  echo "{\"status\":\"created\",\"id\":\"$ID\",\"severity\":\"$SEV\",\"category\":\"$CAT\",\"url\":\"$URL\"}"
done

# (Final summary line — outer loop variable doesn't survive the pipe in bash,
# so re-count from the API.)
FINAL=$(gh issue list --repo "$REPO" --label evolveci/pattern --state all -L 200 \
  --json number --jq 'length')
echo "{\"status\":\"done\",\"created\":$FINAL,\"expected\":$TOTAL}"

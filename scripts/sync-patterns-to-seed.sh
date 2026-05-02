#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# sync-patterns-to-seed.sh — sync evolveci/pattern issues back to seed file
#                            + lifecycle management (dormant/retire)
#                            + confidence inference for agent-learned patterns
# ─────────────────────────────────────────────────────────────────────────────
# Usage:
#   bash scripts/sync-patterns-to-seed.sh [owner/repo] [seed-json-path]
#
# Called by /weekly-report before opening the PR.
# Idempotent — safe to run multiple times.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO="${1:-${GITHUB_REPOSITORY:-}}"
SEED_FILE="${2:-data/known-patterns.seed.json}"
CONFIG_FILE="${CONFIG_FILE:-config.yml}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SEED_FILE="${REPO_ROOT}/${SEED_FILE}"

if [ -z "$REPO" ]; then
  echo "usage: $0 <owner/repo> [seed-json-path]" >&2
  exit 2
fi

# ── 读取生命周期配置 ─────────────────────────────────────────────────────────
DORMANT_DAYS=30
RETIRE_DAYS=90
if [[ -f "$REPO_ROOT/$CONFIG_FILE" ]]; then
  DORMANT_DAYS=$(python3 -c "
import yaml, sys
c = yaml.safe_load(open('$REPO_ROOT/$CONFIG_FILE'))
print(c.get('pattern_lifecycle', {}).get('dormant_days', 30))
" 2>/dev/null || echo 30)
  RETIRE_DAYS=$(python3 -c "
import yaml, sys
c = yaml.safe_load(open('$REPO_ROOT/$CONFIG_FILE'))
print(c.get('pattern_lifecycle', {}).get('retire_days', 90))
" 2>/dev/null || echo 90)
fi

NOW_EPOCH=$(date +%s)
NOW_DATE=$(date -u +%Y-%m-%d)

# ── 拉取所有 open 的 pattern issues ──────────────────────────────────────────
ISSUES_JSON=$(gh issue list --repo "$REPO" --label evolveci/pattern --state open \
  -L 200 --json number,body,title 2>/dev/null || echo "[]")

ISSUE_COUNT=$(echo "$ISSUES_JSON" | jq length)
if [ "$ISSUE_COUNT" -eq 0 ]; then
  echo '{"status":"skip","reason":"no open pattern issues found"}'
  exit 0
fi

# ── 逐条处理：提取 JSON + 生命周期检查 + confidence 推断 ──────────────────────
PATTERNS="[]"
DORMANT_COUNT=0
RETIRE_COUNT=0
CONFIDENCE_UPDATED=0

echo "$ISSUES_JSON" | jq -c '.[]' | while IFS= read -r issue; do
  ISSUE_NUM=$(echo "$issue" | jq -r .number)
  BODY=$(echo "$issue" | jq -r .body)
  [[ -z "$BODY" ]] && continue

  # 提取 fenced JSON block（复用 collect-triage-data.sh 的 awk 逻辑）
  PATTERN_JSON=$(printf '%s\n' "$BODY" \
    | awk '/^```json[[:space:]]*$/{flag=1;next} /^```[[:space:]]*$/{flag=0} flag' \
    | jq -c . 2>/dev/null) || true
  if [[ -z "$PATTERN_JSON" ]]; then
    # fallback：整个 body 当 JSON
    PATTERN_JSON=$(printf '%s\n' "$BODY" | jq -c . 2>/dev/null) || true
  fi
  [[ -z "$PATTERN_JSON" ]] && continue

  PATTERN_ID=$(echo "$PATTERN_JSON" | jq -r '.id // empty')
  [[ -z "$PATTERN_ID" ]] && continue

  # ── 生命周期检查 ───────────────────────────────────────────────────────
  LAST_SEEN=$(echo "$PATTERN_JSON" | jq -r '.last_seen // "1970-01-01"')
  LAST_SEEN_EPOCH=$(date -d "$LAST_SEEN" +%s 2>/dev/null || echo 0)
  DAYS_SINCE=$(( (NOW_EPOCH - LAST_SEEN_EPOCH) / 86400 ))

  if [ "$DAYS_SINCE" -ge "$RETIRE_DAYS" ]; then
    # 90 天未命中 → 关闭 issue + 标记 retired
    gh issue close "$ISSUE_NUM" --repo "$REPO" \
      --comment "Auto-retired: ${DAYS_SINCE} days since last match (threshold: ${RETIRE_DAYS}d)" 2>/dev/null || true
    gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-label "status/retired" 2>/dev/null || true
    echo "{\"action\":\"retired\",\"id\":\"$PATTERN_ID\",\"days\":$DAYS_SINCE}" >&2
    RETIRE_COUNT=$((RETIRE_COUNT + 1))
    continue  # 不写入 seed
  fi

  if [ "$DAYS_SINCE" -ge "$DORMANT_DAYS" ]; then
    # 30 天未命中 → 标记 dormant
    gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-label "status/dormant" 2>/dev/null || true
    echo "{\"action\":\"dormant\",\"id\":\"$PATTERN_ID\",\"days\":$DAYS_SINCE}" >&2
    DORMANT_COUNT=$((DORMANT_COUNT + 1))
  fi

  # ── confidence 推断（仅 agent-learned pattern）─────────────────────────
  SOURCE=$(echo "$PATTERN_JSON" | jq -r '.source // "seed"')
  if [ "$SOURCE" = "agent-learned" ]; then
    SEEN=$(echo "$PATTERN_JSON" | jq -r '.seen_count // 0')
    OLD_CONF=$(echo "$PATTERN_JSON" | jq -r '.confidence // "unverified"')
    NEW_CONF="unverified"
    if [ "$SEEN" -ge 10 ]; then
      NEW_CONF="high"
    elif [ "$SEEN" -ge 3 ]; then
      NEW_CONF="medium"
    fi
    if [ "$NEW_CONF" != "$OLD_CONF" ]; then
      PATTERN_JSON=$(echo "$PATTERN_JSON" | jq --arg c "$NEW_CONF" '.confidence = $c')
      CONFIDENCE_UPDATED=$((CONFIDENCE_UPDATED + 1))
      # 同步更新 issue body 中的 confidence
      NEW_BODY=$(printf '%s' "$PATTERN_JSON" | bash "$SCRIPT_DIR/render-pattern.sh")
      gh issue edit "$ISSUE_NUM" --repo "$REPO" --body "$NEW_BODY" 2>/dev/null || true
      echo "{\"action\":\"confidence_updated\",\"id\":\"$PATTERN_ID\",\"from\":\"$OLD_CONF\",\"to\":\"$NEW_CONF\"}" >&2
    fi
  fi

  # ── 添加到 seed 数组 ─────────────────────────────────────────────────
  PATTERNS=$(echo "$PATTERNS" | jq --argjson p "$PATTERN_JSON" '. + [$p]')
done

# ── 计数（子 shell 中的变量不传到外层，重新计数）─────────────────────────────
FINAL_COUNT=$(echo "$PATTERNS" | jq length)

# ── 原子写入 seed 文件 ──────────────────────────────────────────────────────
TMP=$(mktemp "${SEED_FILE}.XXXXXX")
echo "$PATTERNS" | jq '.' > "$TMP"
mv "$TMP" "$SEED_FILE"

echo "{\"status\":\"synced\",\"count\":$FINAL_COUNT,\"file\":\"$SEED_FILE\",\"dormant\":$DORMANT_COUNT,\"retired\":$RETIRE_COUNT,\"confidence_updated\":$CONFIDENCE_UPDATED}"

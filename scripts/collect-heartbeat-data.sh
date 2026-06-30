#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# collect-heartbeat-data.sh — 5 个探针的数据收集（零 AI 成本）
#
# 在 heartbeat agent 启动前运行，输出结构化 JSON。
# Agent 只做判定 + 写 issue / 关闭 issue。
#
# 用法：
#   bash scripts/collect-heartbeat-data.sh
#
# 输出：stdout（JSON），可重定向到 /tmp/heartbeat-context.json
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log()  { echo "::notice::$*" >&2; }
warn() { echo "::warning::$*" >&2; }

# safe_jq: run jq on potentially-empty/invalid input without killing the script.
# Usage: safe_jq <input-string> <jq-filter> [fallback]
# Always outputs valid result; on parse failure, outputs fallback (default: "").
safe_jq() {
  local input="$1" filter="$2" fallback="${3:-}"
  local result
  if result=$(echo "$input" | jq -e "$filter" 2>/dev/null); then
    echo "$result"
  else
    echo "$fallback"
  fi
}

# safe_gh_jq: run gh command, pipe to jq; on any failure output fallback.
# Usage: safe_gh_jq <jq-filter> <fallback> <gh-args...>
safe_gh_jq() {
  local filter="$1" fallback="$2"; shift 2
  local raw result
  raw=$(gh "$@" 2>&3 || true)
  if result=$(echo "$raw" | jq -e "$filter" 2>/dev/null); then
    echo "$result"
  else
    warn "gh command failed or returned non-JSON: gh $*"
    echo "$fallback"
  fi
}

NOW=$(date -u +%FT%TZ)
SINCE_24H=$(date -u -d '24 hours ago' +%FT%TZ 2>/dev/null || date -u -v-24H +%FT%TZ)
SINCE_48H=$(date -u -d '48 hours ago' +%FT%TZ 2>/dev/null || date -u -v-48H +%FT%TZ)

# 控制器仓库（heartbeat 跑在它自己的 repo 里）
SELF_REPO="${GITHUB_REPOSITORY:-}"

# ── 探针 1：agent-triage workflow 24h 运行健康 ───────────────────────────────

probe1_runs="[]"
if [ -n "$SELF_REPO" ]; then
  probe1_runs=$(gh run list -R "$SELF_REPO" -w agent-triage.yml --limit 100 \
    --json status,conclusion,createdAt,url 2>/dev/null || echo "[]")
  # 验证 probe1_runs 是有效 JSON，否则回退
  if ! echo "$probe1_runs" | jq -e 'type == "array"' >/dev/null 2>&1; then
    warn "probe1: gh run list returned non-array, falling back to []"
    probe1_runs="[]"
  fi
fi

probe1_total=$(safe_jq "$probe1_runs" "[.[] | select(.createdAt > \"$SINCE_24H\")] | length" "0")
probe1_success=$(safe_jq "$probe1_runs" "[.[] | select(.createdAt > \"$SINCE_24H\" and .conclusion == \"success\")] | length" "0")
probe1_failure=$(safe_jq "$probe1_runs" "[.[] | select(.createdAt > \"$SINCE_24H\" and .conclusion == \"failure\")] | length" "0")
probe1_latest_fail_url=$(safe_jq "$probe1_runs" "[.[] | select(.createdAt > \"$SINCE_24H\" and .conclusion == \"failure\")][0].url // empty" "")

# ── 探针 2：pattern issue 数 ──────────────────────────────────────────────────

probe2_raw=$(gh issue list --label evolveci/pattern --state all -L 100 \
  --json number 2>/dev/null || echo "[]")
probe2_count=$(safe_jq "$probe2_raw" "length" "0")

# ── 探针 3：最新 daily issue 新鲜度 ───────────────────────────────────────────

probe3_raw=$(gh issue list --label evolveci/daily --state all -L 1 \
  --search "sort:updated-desc" --json updatedAt,number 2>/dev/null || echo "[]")
probe3_obj=$(safe_jq "$probe3_raw" ".[0] // {}" "{}")
probe3_updated_at=$(safe_jq "$probe3_obj" ".updatedAt // empty" "")
probe3_number=$(safe_jq "$probe3_obj" ".number // empty" "")

# 计算距今小时数（找不到时输出 null）
if [ -n "$probe3_updated_at" ] && [ "$probe3_updated_at" != "null" ]; then
  probe3_age_h=$(python3 -c "
from datetime import datetime, timezone
u = datetime.fromisoformat('$probe3_updated_at'.replace('Z','+00:00'))
n = datetime.now(timezone.utc)
print(round((n - u).total_seconds() / 3600, 1))
" 2>/dev/null || echo "null")
else
  probe3_age_h="null"
fi

# ── 探针 4：circuit issue 状态 ────────────────────────────────────────────────

probe4_raw=$(gh issue list --label evolveci/circuit --state all -L 1 \
  --json body 2>/dev/null || echo "[]")
probe4_body=$(safe_jq "$probe4_raw" -r ".[0].body // empty" "")

if [ -n "$probe4_body" ]; then
  probe4_exists=true
  probe4_active=$(safe_jq "$probe4_body" -r ".active // false" "false")
  probe4_tripped_at=$(safe_jq "$probe4_body" -r ".tripped_at // empty" "")
else
  probe4_exists=false
  probe4_active=false
  probe4_tripped_at=""
fi

# ── 探针 5：标签完整性（API 失败时降级为 SKIP） ───────────────────────────────

if probe5_raw=$(gh label list --limit 100 --json name 2>/dev/null); then
  probe5_count=$(safe_jq "$probe5_raw" '[.[].name | select(startswith("evolveci/"))] | length' "0")
  probe5_available=true
else
  probe5_count=0
  probe5_available=false
fi

# ── 组装输出 ─────────────────────────────────────────────────────────────────

jq -n \
  --arg now "$NOW" \
  --arg since "$SINCE_24H" \
  --argjson p1_total "$probe1_total" \
  --argjson p1_success "$probe1_success" \
  --argjson p1_failure "$probe1_failure" \
  --arg     p1_url "$probe1_latest_fail_url" \
  --argjson p2_count "$probe2_count" \
  --arg     p3_updated_at "$probe3_updated_at" \
  --argjson p3_age_h "${probe3_age_h:-null}" \
  --arg     p3_number "$probe3_number" \
  --argjson p4_exists "$probe4_exists" \
  --argjson p4_active "$probe4_active" \
  --arg     p4_tripped_at "$probe4_tripped_at" \
  --argjson p5_count "$probe5_count" \
  --argjson p5_available "$probe5_available" \
  '{
    generated_at: $now,
    window_since: $since,
    probe1: {
      name: "agent-triage workflow 24h health",
      total_runs:    $p1_total,
      success_runs:  $p1_success,
      failure_runs:  $p1_failure,
      success_rate:  (if $p1_total == 0 then null
                      else ($p1_success / $p1_total) end),
      latest_failure_url: (if $p1_url == "" then null else $p1_url end)
    },
    probe2: {
      name: "pattern library",
      pattern_count: $p2_count,
      threshold: 10
    },
    probe3: {
      name: "daily-report freshness",
      latest_daily_updated_at: (if $p3_updated_at == "" then null else $p3_updated_at end),
      latest_daily_number:     (if $p3_number == "" then null else $p3_number end),
      stale_hours:             $p3_age_h,
      threshold_hours:         48
    },
    probe4: {
      name: "circuit breaker",
      exists:     $p4_exists,
      active:     $p4_active,
      tripped_at: (if $p4_tripped_at == "" then null else $p4_tripped_at end)
    },
    probe5: {
      name: "label completeness",
      label_count: $p5_count,
      threshold:   5,
      available:   $p5_available
    }
  }'

log "heartbeat data collected (probe1: $probe1_success/$probe1_total, probe2: $probe2_count, probe3: ${probe3_age_h}h, probe4: active=$probe4_active, probe5: count=$probe5_count avail=$probe5_available)"

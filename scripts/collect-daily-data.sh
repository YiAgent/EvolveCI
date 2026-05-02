#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# collect-daily-data.sh — 聚合最近 24h 的 CI 数据（零 AI 成本）
#
# 在 daily-report agent 启动前运行，输出结构化 JSON。
# Agent 只负责解读数据 + 写人类可读报告。
#
# 用法：
#   bash scripts/collect-daily-data.sh [repos-yml]
#
# 输出：stdout（JSON），可重定向到 /tmp/daily-context.json
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPOS_YML="${1:-data/onboarded-repos.yml}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { echo "::notice::$*" >&2; }
warn() { echo "::warning::$*" >&2; }

# ── 时间计算 ──────────────────────────────────────────────────────────────────

TODAY=$(date -u +%Y-%m-%d)
NOW=$(date -u +%FT%TZ)
SINCE_24H=$(date -u -d '24 hours ago' +%FT%TZ 2>/dev/null || date -u -v-24H +%FT%TZ)
SINCE_48H=$(date -u -d '48 hours ago' +%FT%TZ 2>/dev/null || date -u -v-48H +%FT%TZ)

# ── 解析仓库列表 ──────────────────────────────────────────────────────────────

repos=()
if [ -f "$REPOS_YML" ]; then
  while IFS= read -r repo; do
    repos+=("$repo")
  done < <(yq '.repos[].name' "$REPOS_YML" 2>/dev/null || \
           python3 -c "import yaml,sys; [print(r['name']) for r in yaml.safe_load(open('$REPOS_YML'))['repos']]" 2>/dev/null || \
           echo "")
fi

if [ ${#repos[@]} -eq 0 ]; then
  warn "No repos found in $REPOS_YML"
  echo '{"error":"no repos configured"}'
  exit 0
fi

log "Collecting daily data for: ${repos[*]}"

# ── 收集 Runs ─────────────────────────────────────────────────────────────────

all_runs="[]"
for repo in "${repos[@]}"; do
  [ -z "$repo" ] && continue
  log "Querying runs for $repo..."

  runs=$(gh run list --repo "$repo" --created ">=$SINCE_24H" \
    --json databaseId,name,workflowName,status,conclusion,createdAt,updatedAt,headBranch \
    --limit 200 2>/dev/null || echo "[]")

  # 排除 agent workflows
  runs=$(echo "$runs" | jq '[.[] | select(.workflowName | test("Agent —") | not)]')

  # 添加 repo 字段
  runs=$(echo "$runs" | jq --arg repo "$repo" '[.[] | . + {repo: $repo}]')
  all_runs=$(echo "$all_runs" | jq --argjson new "$runs" '. + $new')

  log "  Found $(echo "$runs" | jq length) runs"
done

# ── 计算指标 ──────────────────────────────────────────────────────────────────

total=$(echo "$all_runs" | jq length)
successes=$(echo "$all_runs" | jq '[.[] | select(.conclusion == "success")] | length')
failures=$(echo "$all_runs" | jq '[.[] | select(.conclusion == "failure")] | length')
cancelled=$(echo "$all_runs" | jq '[.[] | select(.conclusion == "cancelled")] | length')
other=$((total - successes - failures - cancelled))

# 成功率
if [ "$total" -gt 0 ]; then
  rate=$(echo "scale=1; $successes * 100 / $total" | bc 2>/dev/null || echo "N/A")
else
  rate="N/A"
fi

# Top 失败 workflows
top_failures=$(echo "$all_runs" | jq '
  [.[] | select(.conclusion == "failure")]
  | group_by(.workflowName)
  | map({workflow: .[0].workflowName, repo: .[0].repo, count: length,
         last_failure: (sort_by(.createdAt) | last | .createdAt)})
  | sort_by(-.count)
  | .[0:5]')

# 按仓库统计
by_repo=$(echo "$all_runs" | jq '
  group_by(.repo)
  | map({repo: .[0].repo,
         total: length,
         success: ([.[] | select(.conclusion == "success")] | length),
         failure: ([.[] | select(.conclusion == "failure")] | length)})')

# 按 workflow 统计
by_workflow=$(echo "$all_runs" | jq '
  group_by(.workflowName)
  | map({workflow: .[0].workflowName, repo: .[0].repo,
         total: length,
         success: ([.[] | select(.conclusion == "success")] | length),
         failure: ([.[] | select(.conclusion == "failure")] | length),
         failure_rate: (if length > 0 then
           (([.[] | select(.conclusion == "failure")] | length) * 100 / length | . * 10 | round / 10)
         else 0 end)})
  | sort_by(-.failure_rate)')

# ── 查询 Issues ───────────────────────────────────────────────────────────────

log "Querying issues..."

# Triage issues
triage_open=$(gh issue list --label evolveci/triage --state open --json number 2>/dev/null | jq length || echo 0)
triage_new=$(gh issue list --label evolveci/triage --search "created:>$SINCE_24H" --json number 2>/dev/null | jq length || echo 0)
triage_closed_today=$(gh issue list --label evolveci/triage --search "closed:>$SINCE_24H" --json number 2>/dev/null | jq length || echo 0)

# 新增 triage issues 详情
triage_issues=$(gh issue list --label evolveci/triage \
  --search "created:>$SINCE_24H" \
  --json number,title,labels,createdAt,body 2>/dev/null || echo "[]")
# 只保留摘要字段
triage_issues=$(echo "$triage_issues" | jq '[.[] | {
  number, title, created_at: .createdAt,
  labels: [.labels[].name],
  category: ([.labels[].name | select(startswith("category:"))] | first // "unknown"),
  severity: ([.labels[].name | select(startswith("severity/"))] | first // "unknown")
}]')

# Pattern issues
pattern_total=$(gh issue list --label evolveci/pattern --state all --json number 2>/dev/null | jq length || echo 0)
pattern_new=$(gh issue list --label evolveci/pattern --search "created:>$SINCE_24H" --json number 2>/dev/null | jq length || echo 0)

# Circuit breaker
circuit_state=$(gh issue list --label evolveci/circuit --state all -L 1 \
  --json body --jq '.[0].body // "{}"' 2>/dev/null || echo "{}")
circuit_active=$(echo "$circuit_state" | jq -r '.active // false')

# Daily reports (前一份)
prev_daily=$(gh issue list --label evolveci/daily -L 2 \
  --json number,title,body,createdAt 2>/dev/null || echo "[]")

# ── 构建 top failures 的日志摘要 ─────────────────────────────────────────────

# 对 top 3 失败获取日志摘要
top3_runs=$(echo "$all_runs" | jq '
  [.[] | select(.conclusion == "failure")]
  | sort_by(.createdAt) | reverse | .[0:3]')

top3_with_logs="[]"
for i in $(seq 0 $(($(echo "$top3_runs" | jq length) - 1))); do
  run_id=$(echo "$top3_runs" | jq -r ".[$i].databaseId")
  repo=$(echo "$top3_runs" | jq -r ".[$i].repo")

  log_tail=$(gh run view "$run_id" --repo "$repo" --log-failed 2>/dev/null | tail -20 || echo "（无法获取日志）")
  failed_step=$(gh run view "$run_id" --repo "$repo" --json jobs \
    --jq '.jobs[] | select(.conclusion == "failure") | .steps[] | select(.conclusion == "failure") | .name' 2>/dev/null | head -1 || echo "unknown")

  entry=$(echo "$top3_runs" | jq ".[$i]" | jq \
    --arg log_tail "$log_tail" \
    --arg failed_step "$failed_step" \
    '. + {log_tail: $log_tail, failed_step: $failed_step}')

  top3_with_logs=$(echo "$top3_with_logs" | jq --argjson e "$entry" '. + [$e]')
done

# ── 输出 ──────────────────────────────────────────────────────────────────────

jq -nc \
  --arg date "$TODAY" \
  --arg generated_at "$NOW" \
  --argjson repos_checked "$(printf '%s\n' "${repos[@]}" | jq -R . | jq -s .)" \
  --argjson total "$total" \
  --argjson success "$successes" \
  --argjson failure "$failures" \
  --argjson cancelled "$cancelled" \
  --arg rate "$rate" \
  --argjson top_failures "$top_failures" \
  --argjson by_repo "$by_repo" \
  --argjson by_workflow "$by_workflow" \
  --argjson triage_open "$triage_open" \
  --argjson triage_new "$triage_new" \
  --argjson triage_closed_today "$triage_closed_today" \
  --argjson triage_issues "$triage_issues" \
  --argjson pattern_total "$pattern_total" \
  --argjson pattern_new "$pattern_new" \
  --argjson circuit_active "$circuit_active" \
  --argjson top3_with_logs "$top3_with_logs" \
  --argjson prev_daily "$prev_daily" \
  '{
    date: $date,
    generated_at: $generated_at,
    repos_checked: $repos_checked,
    runs: {
      total: $total,
      success: $success,
      failure: $failure,
      cancelled: $cancelled,
      success_rate: $rate
    },
    top_failures: $top_failures,
    by_repo: $by_repo,
    by_workflow: $by_workflow,
    triage: {
      open: $triage_open,
      new_today: $triage_new,
      closed_today: $triage_closed_today,
      new_issues: $triage_issues
    },
    patterns: {
      total: $pattern_total,
      new_today: $pattern_new
    },
    circuit: {
      active: $circuit_active
    },
    top3_failures_with_logs: $top3_with_logs,
    prev_daily: $prev_daily
  }'

log "Done: $total runs ($successes success, $failures failure), triage: $triage_open open / $triage_new new"

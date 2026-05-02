#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# collect-triage-data.sh — 确定性数据收集（零 AI 成本）
#
# 在 agent 启动前运行，输出结构化 JSON 供 agent 直接消费。
# Agent 不再自己查询 CI 数据，只做决策和执行。
#
# 用法：
#   bash scripts/collect-triage-data.sh [window] [repos-yml]
#
# 示例：
#   bash scripts/collect-triage-data.sh 30m
#   bash scripts/collect-triage-data.sh 1h config.yml
#
# 输出：stdout（JSON），可重定向到 /tmp/triage-context.json
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

WINDOW="${1:-30m}"
CONFIG_FILE="${2:-config.yml}" 
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REDACT_SCRIPT="$REPO_ROOT/lib/redact-log.sh"
PATTERNS_CACHE="/tmp/evolveci-patterns.jsonl"

# ── 工具函数 ──────────────────────────────────────────────────────────────────

log() { echo "::notice::$*" >&2; }
warn() { echo "::warning::$*" >&2; }
err() { echo "::error::$*" >&2; }

# 解析时间窗口为 gh 兼容的日期格式
parse_since() {
  local now_epoch delta
  now_epoch=$(date +%s)
  case "$WINDOW" in
    *m) delta=$(( ${WINDOW%m} * 60 )) ;;
    *h) delta=$(( ${WINDOW%h} * 3600 )) ;;
    *d) delta=$(( ${WINDOW%d} * 86400 )) ;;
    *)  err "Invalid window format: $WINDOW (use 30m, 1h, 7d)"; exit 1 ;;
  esac
  date -u -d "@$((now_epoch - delta))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
    date -u -r "$((now_epoch - delta))" +%Y-%m-%dT%H:%M:%SZ
}

# 生成 fingerprint: sha256(error_lines + step_name)[:12]
fingerprint() {
  local error_lines="$1" step_name="$2"
  printf '%s|%s' "$error_lines" "$step_name" | sha256sum | cut -c1-12
}

# 脱敏日志（fail-closed：缺失脱敏脚本时直接退出，避免明文日志外流）
redact() {
  if [[ ! -f "$REDACT_SCRIPT" ]]; then
    err "Missing redact script: $REDACT_SCRIPT (refusing to pass raw logs downstream)"
    exit 1
  fi
  bash "$REDACT_SCRIPT"
}

# ── 加载已知 patterns ─────────────────────────────────────────────────────────

load_patterns() {
  : > "$PATTERNS_CACHE"

  # 优先从 evolveci/pattern issues 加载（最新数据）。
  # body 可能是纯 JSON，也可能是 markdown 包裹的 ```json fenced block；
  # 我们先尝试提取 fenced block，否则把整个 body 当 JSON 解析，
  # 都失败则跳过。这样可以正确处理含 `{...}` 嵌套的 regex。
  if command -v gh &>/dev/null; then
    while IFS= read -r body; do
      [[ -z "$body" ]] && continue
      {
        printf '%s\n' "$body" \
          | awk '/^```json[[:space:]]*$/{flag=1;next} /^```[[:space:]]*$/{flag=0} flag' \
          | jq -c . 2>/dev/null \
          || printf '%s\n' "$body" | jq -c . 2>/dev/null
      } >> "$PATTERNS_CACHE" || true
    done < <(gh issue list --label evolveci/pattern --state all -L 100 \
              --json body --jq '.[].body' 2>/dev/null)
  fi

  # Fallback：从 seed 文件加载
  if [[ ! -s "$PATTERNS_CACHE" ]] && [[ -f "$REPO_ROOT/data/known-patterns.seed.json" ]]; then
    jq -c '.[]' "$REPO_ROOT/data/known-patterns.seed.json" > "$PATTERNS_CACHE" 2>/dev/null || true
  fi
}

# Tier 1: 正则匹配已知 patterns
match_pattern() {
  local log="$1"
  if [[ ! -s "$PATTERNS_CACHE" ]]; then
    echo "null"
    return
  fi

  while IFS= read -r pattern_json; do
    local id match_re category severity auto_rerun notify confidence rerun_success_rate
    id=$(echo "$pattern_json" | jq -r '.id // empty')
    match_re=$(echo "$pattern_json" | jq -r '.match // empty')
    category=$(echo "$pattern_json" | jq -r '.category // "unknown"')
    severity=$(echo "$pattern_json" | jq -r '.severity // "info"')
    auto_rerun=$(echo "$pattern_json" | jq -r '.auto_rerun // false')
    notify=$(echo "$pattern_json" | jq -r '.notify // false')
    confidence=$(echo "$pattern_json" | jq -r '.confidence // "high"')
    rerun_success_rate=$(echo "$pattern_json" | jq -r '.rerun_success_rate // "null"')

    if [[ -n "$match_re" ]] && echo "$log" | grep -qE "$match_re" 2>/dev/null; then
      jq -nc \
        --arg id "$id" \
        --arg category "$category" \
        --arg severity "$severity" \
        --argjson auto_rerun "$auto_rerun" \
        --argjson notify "$notify" \
        --arg confidence "$confidence" \
        --argjson rerun_success_rate "$rerun_success_rate" \
        '{pattern_id:$id, category:$category, severity:$severity,
          auto_rerun:$auto_rerun, notify:$notify,
          confidence:$confidence, rerun_success_rate:$rerun_success_rate}'
      return
    fi
  done < "$PATTERNS_CACHE"

  echo "null"
}

# Tier 2: 启发式关键词匹配
classify_heuristic() {
  local log="$1"
  local category severity confidence should_rerun should_notify

  # 规则顺序：先匹配先返回
  if echo "$log" | grep -qiE 'ECONNREFUSED|ENOTFOUND|EAI_AGAIN|ETIMEDOUT|ReadTimeoutError|context deadline exceeded|connection timed out|network unreachable'; then
    category="flaky"; severity="low"; confidence="high"; should_rerun="true"; should_notify="false"
  elif echo "$log" | grep -qiE 'rate.?limit|429|too many requests|toomanyrequests'; then
    category="flaky"; severity="low"; confidence="high"; should_rerun="true"; should_notify="false"
  elif echo "$log" | grep -qiE 'No space left on device|disk full'; then
    category="infra"; severity="high"; confidence="high"; should_rerun="false"; should_notify="true"
  elif echo "$log" | grep -qiE 'permission denied|403 Forbidden|unauthorized'; then
    category="infra"; severity="medium"; confidence="high"; should_rerun="false"; should_notify="true"
  elif echo "$log" | grep -qiE 'OOMKilled|out of memory'; then
    category="infra"; severity="high"; confidence="high"; should_rerun="false"; should_notify="true"
  elif echo "$log" | grep -qiE 'npm ERR! code E404|package not found|ModuleNotFoundError'; then
    category="dependency"; severity="medium"; confidence="high"; should_rerun="false"; should_notify="true"
  elif echo "$log" | grep -qiE 'compilation error|syntax error|build failed|Cannot connect to the Docker daemon'; then
    category="code"; severity="medium"; confidence="medium"; should_rerun="false"; should_notify="true"
  elif echo "$log" | grep -qiE 'SDK execution error|Reached maximum number of turns'; then
    category="infra"; severity="medium"; confidence="high"; should_rerun="false"; should_notify="true"
  elif echo "$log" | grep -qiE 'socket connection.*closed|API Error.*socket'; then
    category="flaky"; severity="low"; confidence="medium"; should_rerun="true"; should_notify="false"
  else
    category="unknown"; severity="medium"; confidence="low"; should_rerun="false"; should_notify="true"
  fi

  jq -nc \
    --arg category "$category" \
    --arg severity "$severity" \
    --arg confidence "$confidence" \
    --argjson should_rerun "$should_rerun" \
    --argjson should_notify "$should_notify" \
    '{category:$category, severity:$severity, confidence:$confidence,
      should_rerun:$should_rerun, should_notify:$should_notify}'
}

# ── 主流程 ────────────────────────────────────────────────────────────────────

main() {
  local since
  since=$(parse_since)
  log "Collecting triage data since $since (window: $WINDOW)"

  # 加载 patterns
  load_patterns
  local pattern_count=0
  if [[ -s "$PATTERNS_CACHE" ]]; then
    pattern_count=$(wc -l < "$PATTERNS_CACHE")
  fi
  log "Loaded $pattern_count known patterns"

  # 解析仓库列表 + per-repo `exclude` 配置
  # 输出 JSON 数组：[{"name":"...", "exclude":["a.yml","b.yml"]}, ...]
  local repos_config="[]"
  if [[ -f "$REPOS_YML" ]]; then
    repos_config=$(yq -o=json '[.repos[] | {name: .name, exclude: (.exclude // [])}]' "$REPOS_YML" 2>/dev/null \
      || python3 -c "import yaml,json,sys
data = yaml.safe_load(open('$REPOS_YML'))
print(json.dumps([{'name': r['name'], 'exclude': r.get('exclude', [])} for r in data['repos']]))" 2>/dev/null \
      || echo "[]")
  fi

  local repos=()
  while IFS= read -r repo; do
    [[ -n "$repo" ]] && repos+=("$repo")
  done < <(echo "$repos_config" | jq -r '.[].name')

  if [[ ${#repos[@]} -eq 0 ]]; then
    warn "No repos found in $REPOS_YML"
    echo '{"failures":[],"summary":{"total_failures":0,"error":"no repos configured"}}'
    return
  fi

  log "Checking repos: ${repos[*]}"

  # 收集所有失败
  local all_failures="[]"
  local total_runs=0 total_failures=0

  for repo in "${repos[@]}"; do
    [[ -z "$repo" ]] && continue
    log "Querying $repo..."

    # 查询失败 runs
    local runs_json
    runs_json=$(gh run list --repo "$repo" --status failure \
      --created ">=$since" --json databaseId,name,workflowName,workflowDatabaseId,conclusion,createdAt,updatedAt,headBranch \
      --limit 20 2>/dev/null || echo "[]")

    local run_count
    run_count=$(echo "$runs_json" | jq length)
    total_runs=$((total_runs + run_count))
    log "  Found $run_count failed runs in $repo"

    # 取该 repo 的 exclude 文件名列表（来自 onboarded-repos.yml）
    local repo_excludes
    repo_excludes=$(echo "$repos_config" | jq -c --arg n "$repo" '[.[] | select(.name == $n) | .exclude // []] | first // []')

    # 解析为 workflowDatabaseId 集合：拉取该 repo 的 workflow 列表，
    # 取 path basename 与 exclude 列表匹配的 workflow id。
    local excluded_ids="[]"
    if [[ "$(echo "$repo_excludes" | jq 'length')" -gt 0 ]]; then
      local wf_list
      wf_list=$(gh workflow list --repo "$repo" --all --json id,name,path --limit 100 2>/dev/null || echo "[]")
      excluded_ids=$(echo "$wf_list" | jq --argjson ex "$repo_excludes" \
        '[.[] | select((.path | split("/") | last) as $base | $ex | index($base)) | .id]')
    fi

    # 应用 per-repo exclude（按 workflowDatabaseId）+ 兜底排除 agent 自身 workflows（按显示名）
    runs_json=$(echo "$runs_json" | jq --argjson ex "$excluded_ids" \
      '[.[] | select((.workflowDatabaseId as $id | $ex | index($id)) | not)
            | select(.workflowName | test("Agent —") | not)]')
    run_count=$(echo "$runs_json" | jq length)

    # 对每条失败获取日志
    for i in $(seq 0 $((run_count - 1))); do
      local run_id workflow_name created_at
      run_id=$(echo "$runs_json" | jq -r ".[$i].databaseId")
      workflow_name=$(echo "$runs_json" | jq -r ".[$i].workflowName")
      created_at=$(echo "$runs_json" | jq -r ".[$i].createdAt")

      # 获取失败 job 的日志
      local log_raw=""
      local failed_step=""
      log_raw=$(gh run view "$run_id" --repo "$repo" --log-failed 2>/dev/null | tail -100 || echo "")
      failed_step=$(gh run view "$run_id" --repo "$repo" --json jobs \
        --jq '.jobs[] | select(.conclusion == "failure") | .steps[] | select(.conclusion == "failure") | .name' 2>/dev/null | head -1 || echo "unknown")

      # 脱敏
      local log_redacted
      log_redacted=$(echo "$log_raw" | redact)

      # 生成 fingerprint
      local fp
      fp=$(fingerprint "$log_redacted" "$failed_step")

      # 检查是否已有对应 issue（evolveci/* 状态都存在 controller repo 而非 failing repo）
      local state_repo="${GITHUB_REPOSITORY:-}"
      local existing_issue=""
      if [[ -n "$state_repo" ]]; then
        existing_issue=$(gh issue list --repo "$state_repo" --label "fingerprint:${fp}" --state open -L 1 \
          --json number --jq '.[0].number // empty' 2>/dev/null || echo "")
      else
        existing_issue=$(gh issue list --label "fingerprint:${fp}" --state open -L 1 \
          --json number --jq '.[0].number // empty' 2>/dev/null || echo "")
      fi

      # Tier 1: pattern 匹配
      local tier1_result
      tier1_result=$(match_pattern "$log_redacted")

      # Tier 2: 启发式分类
      local tier2_result
      tier2_result=$(classify_heuristic "$log_redacted")

      # 确定建议动作
      local suggested_action="tier3_analysis"
      local tier1_matched=false
      local tier2_confidence=""
      tier2_confidence=$(echo "$tier2_result" | jq -r '.confidence // "low"')

      if [[ "$tier1_result" != "null" ]]; then
        suggested_action="use_pattern"
        tier1_matched=true
      elif [[ "$tier2_confidence" == "high" ]]; then
        suggested_action="use_heuristic"
      fi

      # 保留日志最后 N 行（从 config.yml 读取，默认 50）
      local tail_lines
      tail_lines=$(yq '.collect.log_tail_lines // 50' "$CONFIG_FILE" 2>/dev/null || echo 50)
      local log_tail
      log_tail=$(echo "$log_redacted" | tail -"$tail_lines")

      # 构建 failure 对象
      local failure_obj
      failure_obj=$(jq -nc \
        --arg run_id "$run_id" \
        --arg repo "$repo" \
        --arg workflow "$workflow_name" \
        --arg failed_step "$failed_step" \
        --arg fingerprint "$fp" \
        --arg created_at "$created_at" \
        --arg log_tail "$log_tail" \
        --argjson tier1_match "$tier1_result" \
        --argjson tier2_match "$tier2_result" \
        --arg existing_issue "$existing_issue" \
        --arg suggested_action "$suggested_action" \
        '{run_id:$run_id, repo:$repo, workflow:$workflow,
          failed_step:$failed_step, fingerprint:$fp, created_at:$created_at,
          log_tail:$log_tail, tier1_match:$tier1_match, tier2_match:$tier2_match,
          existing_issue: (if $existing_issue == "" then null else $existing_issue end),
          suggested_action:$suggested_action}')

      all_failures=$(echo "$all_failures" | jq --argjson f "$failure_obj" '. + [$f]')
      total_failures=$((total_failures + 1))
    done
  done

  # 统计
  local tier1_matched tier2_matched needs_agent
  tier1_matched=$(echo "$all_failures" | jq '[.[] | select(.tier1_match != null)] | length')
  tier2_matched=$(echo "$all_failures" | jq '[.[] | select(.tier2_match.confidence == "high")] | length')
  needs_agent=$(echo "$all_failures" | jq '[.[] | select(.suggested_action == "tier3_analysis")] | length')

  # 输出最终 JSON
  jq -nc \
    --arg window "$WINDOW" \
    --arg collected_at "$(date -u +%FT%TZ)" \
    --argjson repos_checked "$(printf '%s\n' "${repos[@]}" | jq -R . | jq -s .)" \
    --argjson failures "$all_failures" \
    --argjson total_failures "$total_failures" \
    --argjson tier1_matched "$tier1_matched" \
    --argjson tier2_matched "$tier2_matched" \
    --argjson needs_agent "$needs_agent" \
    --argjson known_patterns "$pattern_count" \
    '{window:$window, collected_at:$collected_at, repos_checked:$repos_checked,
      failures:$failures,
      summary:{total_failures:$total_failures, tier1_matched:$tier1_matched,
               tier2_matched:$tier2_matched, needs_agent:$needs_agent,
               known_patterns:$known_patterns}}'

  log "Done: $total_failures failures collected (tier1: $tier1_matched, tier2: $tier2_matched, agent: $needs_agent)"
}

main "$@"

#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# migrate-patterns.sh — 迁移现有 pattern issue 为人类可读格式
#
# 读取 data/known-patterns.seed.json 中的 description/human_explanation 字段，
# 更新对应的 evolveci/pattern issue body。
#
# 用法：
#   bash scripts/migrate-patterns.sh [repo]
#
# 幂等：跳过已有 "## 模式" 标记的 issue。
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO="${1:-${GITHUB_REPOSITORY:-}}"
SEED_FILE="data/known-patterns.seed.json"

if [ -z "$REPO" ]; then
  echo "usage: $0 <owner/repo>" >&2
  exit 2
fi

echo '{"status":"migrating","repo":"'"$REPO"'"}'

# 读取 seed 文件中的描述信息
declare -A DESCRIPTIONS
declare -A EXPLANATIONS
declare -A ACTIONS

while IFS= read -r pattern; do
  id=$(echo "$pattern" | jq -r '.id')
  desc=$(echo "$pattern" | jq -r '.description // .id')
  explain=$(echo "$pattern" | jq -r '.human_explanation // "暂无说明"')
  action=$(echo "$pattern" | jq -r '.action_suggestion // "请人工检查"')

  DESCRIPTIONS["$id"]="$desc"
  EXPLANATIONS["$id"]="$explain"
  ACTIONS["$id"]="$action"
done < <(jq -c '.[]' "$SEED_FILE")

# 遍历所有 pattern issues
MIGRATED=0
SKIPPED=0

gh issue list --repo "$REPO" --label evolveci/pattern --state all -L 100 \
  --json number,title,body | jq -c '.[]' | while IFS= read -r issue; do

  number=$(echo "$issue" | jq -r .number)
  title=$(echo "$issue" | jq -r .title)
  body=$(echo "$issue" | jq -r .body)

  # 跳过已迁移的
  if echo "$body" | grep -q "## 模式"; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # 从 title 提取 pattern id（格式：pattern: xxx）
  id=$(echo "$title" | sed 's/^pattern: //')

  # 获取描述（fallback 到 id）
  desc="${DESCRIPTIONS[$id]:-$id}"
  explain="${EXPLANATIONS[$id]:-暂无说明}"
  action_sug="${ACTIONS[$id]:-请人工检查}"

  # 从现有 body 提取 JSON 字段
  category=$(echo "$body" | jq -r '.category // "unknown"' 2>/dev/null || echo "unknown")
  severity=$(echo "$body" | jq -r '.severity // "info"' 2>/dev/null || echo "info")
  auto_rerun=$(echo "$body" | jq -r '.auto_rerun // false' 2>/dev/null || echo "false")
  notify=$(echo "$body" | jq -r '.notify // false' 2>/dev/null || echo "false")
  match_re=$(echo "$body" | jq -r '.match // ""' 2>/dev/null || echo "")
  seen_count=$(echo "$body" | jq -r '.seen_count // 0' 2>/dev/null || echo "0")
  last_seen=$(echo "$body" | jq -r '.last_seen // "unknown"' 2>/dev/null || echo "unknown")

  # 构建新 body
  NEW_BODY="## 模式：${id}

**一句话说明**：${desc}
**分类**：${category} | **严重度**：${severity}
**自动重跑**：${auto_rerun} | **通知**：${notify}
**历史出现**：${seen_count} 次 | **最近一次**：${last_seen}

### 匹配规则
\`\`\`
${match_re}
\`\`\`

### 通俗解释
${explain}

### 建议操作
${action_sug}

---
<details><summary>机器元数据（JSON）</summary>

\`\`\`json
${body}
\`\`\`
</details>"

  gh issue edit "$number" --repo "$REPO" --body "$NEW_BODY"
  echo "{\"migrated\":$number,\"id\":\"$id\"}"
  MIGRATED=$((MIGRATED + 1))
done

echo "{\"status\":\"done\",\"migrated\":$MIGRATED,\"skipped\":$SKIPPED}"

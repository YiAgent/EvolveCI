#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# render-pattern.sh — render a pattern JSON object as a human-readable
#                     markdown issue body (with the JSON kept in a fenced
#                     code block at the bottom for triage to parse back).
# ─────────────────────────────────────────────────────────────────────────────
# Usage:
#   echo '{"id":"foo","match":"bar",...}' | bash scripts/render-pattern.sh
#
# Used by:
#   scripts/seed-patterns.sh
#   .claude/commands/learn-pattern.md
#
# Triage extracts the JSON back via:
#   gh issue view <num> --json body --jq .body \
#     | awk '/^```json$/{f=1;next}/^```$/{f=0}f'
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PATTERN=$(cat)

ID=$(printf '%s' "$PATTERN" | jq -r .id)
MATCH=$(printf "%s" "$PATTERN" | jq -r .match)
CAT=$(printf "%s" "$PATTERN" | jq -r '.category // "unknown"')
SEV=$(printf "%s" "$PATTERN" | jq -r '.severity // "info"')
AUTO=$(printf "%s" "$PATTERN" | jq -r '.auto_rerun // false')
NOTIFY=$(printf "%s" "$PATTERN" | jq -r '.notify // false')
DESCR=$(printf "%s" "$PATTERN" | jq -r '.description // ""')
FIX_HINT=$(printf "%s" "$PATTERN" | jq -r '.fix_hint // ""')
SEEN_COUNT=$(printf "%s" "$PATTERN" | jq -r '.seen_count // 0')
LAST_SEEN=$(printf "%s" "$PATTERN" | jq -r '.last_seen // "never"')
SOURCE=$(printf "%s" "$PATTERN" | jq -r '.source // "agent-learned"')

# Map raw severity → friendly Chinese label.
case "$SEV" in
  low|info)            SEV_FRIENDLY="低 / 信息（info）" ;;
  medium|warning)      SEV_FRIENDLY="中 / 警告（warning）" ;;
  high|critical)       SEV_FRIENDLY="高 / 严重（critical）" ;;
  *)                   SEV_FRIENDLY="未分类（$SEV）" ;;
esac

# Map raw category → friendly Chinese label + recommended action.
case "$CAT" in
  flaky)
    CAT_FRIENDLY="flaky（不稳定 / 偶发）"
    ACTION="自动重跑；若同一 fingerprint 24h 内 ≥3 次 → 升级为正式 incident。"
    ;;
  infra)
    CAT_FRIENDLY="infra（基础设施）"
    ACTION="通知 oncall；不自动重跑（避免基础设施压力放大）；考虑触发熔断器。"
    ;;
  code)
    CAT_FRIENDLY="code（代码缺陷）"
    ACTION="不自动重跑；通知 PR 作者；附带失败堆栈与建议修复点。"
    ;;
  dependency)
    CAT_FRIENDLY="dependency（依赖问题）"
    ACTION="通知；检查 lockfile / 镜像源；不自动重跑。"
    ;;
  unknown|*)
    CAT_FRIENDLY="unknown（待人工分类）"
    ACTION="进入 Tier 3 深度分析；agent 给出分类后归并到对应类别。"
    ;;
esac

AUTO_LINE=$([ "$AUTO" = "true"   ] && echo "✅ 是" || echo "❌ 否")
NOTIFY_LINE=$([ "$NOTIFY" = "true" ] && echo "🔔 是" || echo "🔕 否")

cat <<MARKDOWN
# pattern: ${ID}

**类别**: ${CAT_FRIENDLY}
**严重度**: ${SEV_FRIENDLY}
**自动重跑**: ${AUTO_LINE}
**通知**: ${NOTIFY_LINE}

## 描述

${DESCR:-_（暂无描述。可以由 /weekly-report 或人工补充。）_}

## 匹配规则

正则（length ≤200，禁止嵌套量词，已通过校验）：

\`\`\`regex
${MATCH}
\`\`\`

## 推荐处理

${ACTION}

## 修复建议

${FIX_HINT:-_（暂无修复建议。可由 /weekly-report 或人工补充。）_}

## 已观察

| 项目 | 值 |
|------|----|
| 累计次数 | ${SEEN_COUNT} |
| 最近一次 | ${LAST_SEEN} |
| 来源 | ${SOURCE} |

## 机器可读（triage 通过此块解析，请勿手工修改）

\`\`\`json
${PATTERN}
\`\`\`
MARKDOWN

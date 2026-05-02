# /triage — 实时 CI 故障分诊（基于预处理数据）

**触发方式**：由 `agent-triage.yml` 每 15 分钟调用，或通过 `workflow_dispatch` 手动触发。

> **v5.1 变更**：数据收集已由 `collect-triage-data.sh` 脚本完成（零 AI 成本），
> agent 不再自己查询 CI 数据，只做决策和执行。预处理后的数据通过
> `DATA_CONTEXT` JSON 注入。

## 执行步骤

### 步骤 1：解析输入数据

读取预处理数据文件（路径：`{{data_file}}`）：

```bash
CONTEXT=$(cat '{{data_file}}')
```

`$CONTEXT` 是一个 JSON 对象，包含：

- `failures[]` — 每条失败的详情：
  - `repo`, `workflow`, `failed_step`, `fingerprint`, `created_at`
  - `log_tail` — 脱敏后的最后 50 行日志
  - `tier1_match` — 已知 pattern 匹配结果（null 表示未匹配）
  - `tier2_match` — 启发式分类结果（category, severity, confidence）
  - `existing_issue` — 已有的去重 issue 编号（null 表示无）
  - `suggested_action` — 建议动作（use_pattern / use_heuristic / tier3_analysis）
- `summary` — 汇总：total_failures, tier1_matched, tier2_matched, needs_agent

快速检查 summary（`{{summary}}`）：如果 `total_failures == 0`，直接输出"本轮无失败"后退出。

### 步骤 2：检查熔断器

```bash
BODY=$(gh issue list --label evolveci/circuit --state all -L 1 \
        --json body --jq '.[0].body // empty')
ACTIVE=$(echo "$BODY" | jq -r '.active // false')
TRIPPED=$(echo "$BODY" | jq -r '.tripped_at // empty')
```

- `active=true` 且距 `tripped_at` < 24h → 输出警告后退出，不执行任何动作。
- `active=true` 且 ≥ 24h → 自动恢复（编辑 issue body 把 `active` 设为 `false`，
  追加一条 `gh issue comment` 记录恢复时间），然后继续。

### 步骤 3：逐条处理 failures

对 `failures[]` 中每条记录，根据 `suggested_action` 分流：

#### Case A：`use_pattern`（tier1_match != null）

已由脚本匹配到已知 pattern，直接执行：
- 读取 `tier1_match.auto_rerun`、`tier1_match.notify`、`tier1_match.severity`
- 读取 `tier1_match.confidence` 和 `tier1_match.rerun_success_rate`
- **置信度检查**：如果 `confidence == "unverified"` → 保守策略，不执行 auto_rerun，改为创建 issue
- **成功率检查**：如果 `rerun_success_rate` 不为 null 且 < 0.5 → auto_rerun 降级为 false，改为创建 issue
- `auto_rerun=true` → 检查熔断器 + 预算后执行 `gh run rerun`
- `notify=true` → 创建 evolveci/triage issue（如 `existing_issue` 为 null）
- **更新 pattern 统计**：Tier 1 命中后，更新 pattern issue 的 `seen_count` +1 和 `last_seen` 为今天：

```bash
PATTERN_ISSUE=$(gh issue list --label evolveci/pattern --state open \
  --search "in:title \"pattern: ${PATTERN_ID}\"" -L 1 \
  --json number,body --jq '.[0]' 2>/dev/null || echo "")
if [ -n "$PATTERN_ISSUE" ]; then
  ISSUE_NUM=$(echo "$PATTERN_ISSUE" | jq -r .number)
  BODY=$(echo "$PATTERN_ISSUE" | jq -r .body)
  UPDATED_JSON=$(printf '%s\n' "$BODY" \
    | awk '/^```json[[:space:]]*$/{flag=1;next} /^```[[:space:]]*$/{flag=0} flag' \
    | jq -c --arg today "$(date -u +%Y-%m-%d)" \
      '.seen_count = ((.seen_count // 0) + 1) | .last_seen = $today')
  NEW_BODY=$(printf '%s' "$UPDATED_JSON" | bash scripts/render-pattern.sh)
  gh issue edit "$ISSUE_NUM" --body "$NEW_BODY"
fi
```

#### Case B：`use_heuristic`（tier2_match.confidence == "high"）

启发式高置信度，按 `tier2_match.category` 执行：
- `flaky` → 自动重跑
- `infra` / `code` / `dependency` → 创建 issue（含人类可读摘要）

#### Case C：`tier3_analysis`（需要深度推理）

这是 agent 真正需要工作的部分。用我的推理能力分析 `log_tail`：

1. 读取 `log_tail`，判断失败根因
2. 输出分类：category + severity + root_cause（2-3 句）+ fix_suggestion
3. 如果发现可复用 pattern → 调用 `/learn-pattern`
4. 创建 evolveci/triage issue

### 步骤 4：去重处理

对每条 failure，如果 `existing_issue` 不为 null：
```bash
N=$(gh issue view "$EXISTING" --json body --jq .body \
    | grep -oE '^occurrences: [0-9]+' | head -1 | awk '{print $2}')
N=$((${N:-1} + 1))
# 编辑 body 中的 occurrences 计数
gh issue edit "$EXISTING" --body "$(...)";  # 更新计数
gh issue comment "$EXISTING" --body "再次发生于 $(date -u +%FT%TZ)"
```

### 步骤 5：创建新 issue（如有需要）

```bash
REPO_LABEL="repo:$(echo "$REPO" | tr '/' '-')"
gh label create "$REPO_LABEL" --color "ededed" \
  --description "Repo facet" --force >/dev/null
gh label create "fingerprint:${FP}" --color "ededed" \
  --description "Fingerprint dedup" --force >/dev/null

gh issue create \
  --title "${REPO} · ${WORKFLOW} · ${STEP} failure" \
  --label "evolveci/triage,severity/${SEVERITY},category:${CATEGORY},${REPO_LABEL},fingerprint:${FP}" \
  --body "## 🔴 CI 失败：${REPO} / ${WORKFLOW} / ${STEP}

**时间**：${CREATED_AT} UTC
**指纹**：\`${FP}\`

### 失败摘要
${AGENT_SUMMARY}

### 日志片段（已脱敏）
\`\`\`
${LOG_TAIL}
\`\`\`

### 分类
- **类别**：${CATEGORY}
- **严重度**：${SEVERITY}
- **建议操作**：${FIX_SUGGESTION}

---
fingerprint: ${FP}
occurrences: 1
last_seen: $(date -u +%FT%TZ)"
```

### 步骤 6：执行重跑（如有 flaky failures）

检查熔断器 + 当日预算后：
```bash
gh run rerun "$RUN_ID" --repo "$REPO" --failed
```

### 步骤 7：输出总结

打印本轮摘要：X 条失败处理，Y 条自动重跑，Z 条新建 issue，W 条更新已有 issue。
category: ${CATEGORY}
severity: ${SEVERITY}
pattern_id: ${PATTERN_ID:-none}
run: {{run_url}}

## 摘要

${SUMMARY}

## 根因猜测

${ROOT_CAUSE}

## 修复建议

${FIX_SUGGESTION}

## 脱敏日志摘要

\`\`\`
${REDACTED_TAIL}
\`\`\`
EOF
)"
  ```

### 步骤 6：累计计数（可选 Slack）

`severity/critical` 或 `category:infra` 的告警建议同时发送 Slack 通知（如
`SLACK_WEBHOOK_URL` 存在）。

## 不做什么

- 不写 `memory/incidents/`、`memory/fingerprints/`、`memory/counters/`
- 不 git commit
- 不 push 任何分支

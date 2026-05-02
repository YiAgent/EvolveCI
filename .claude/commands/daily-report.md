# /daily-report — 生成每日 CI 健康报告（基于预处理数据）

**触发方式**：由 `agent-daily.yml` 工作日 UTC 01:00 调用，或通过 `workflow_dispatch` 手动触发。

> **v5.1 变更**：数据收集已由 `collect-daily-data.sh` 脚本完成（零 AI 成本），
> agent 不再自己查询 CI 数据，只负责解读数据 + 写人类可读报告。
> 预处理后的数据通过 `DATA_CONTEXT` JSON 注入。

## ⚠️ 强制契约（不可违反）

**每次运行必须以 `gh issue create` 或 `gh issue edit` 结束**——即使 24 小时内
没有任何数据可报告。这是任务的**成功条件**：没有 issue 写入 = 任务失败。

## 执行步骤

### 步骤 1：读取预处理数据

解析 workflow 注入的 `DATA_CONTEXT` JSON。它包含：

- `runs` — 统计：total, success, failure, cancelled, success_rate
- `top_failures` — Top 5 失败 workflow（含 count、last_failure 时间）
- `by_repo` — 按仓库统计
- `by_workflow` — 按 workflow 统计（含 failure_rate）
- `triage` — issue 统计：open, new_today, closed_today, new_issues[]
- `patterns` — pattern 统计：total, new_today
- `circuit` — 熔断器状态：active
- `top3_failures_with_logs` — Top 3 失败的日志摘要（含 failed_step、log_tail）
- `prev_daily` — 前一份 daily report 的 issue（用于对比退化）

如果 `runs.total == 0`，跳到步骤 5（无数据模板）。

### 步骤 2：检测退化

读取 `prev_daily` 中最近一份 report 的 body，提取关键指标：
- 成功率变化 ≥20% → 标为退化
- triage open 数量增长 ≥50% → 标为退化

如果没有 prev_daily，跳过此步。

### 步骤 3：生成报告

使用下方模板，填入 JSON 数据。特别注意：
- `top_failures` → 写入"当日新增 triage"section
- `top3_failures_with_logs` → 用 agent 推理能力为每条失败写一句摘要
- `by_workflow` 中 failure_rate ≥ 50% 的 → 标红警告

### 步骤 4：Upsert issue（必做）

```bash
TODAY=$(date -u +%Y-%m-%d)
TITLE="Daily Report — ${TODAY}"

EXISTING=$(gh issue list --label evolveci/daily \
            --search "in:title \"${TITLE}\"" -L 1 \
            --json number --jq '.[0].number // empty')

if [ -n "$EXISTING" ]; then
  gh issue edit "$EXISTING" --body "$REPORT_BODY"
else
  gh issue create --title "$TITLE" \
    --label "evolveci/daily,severity/info" --body "$REPORT_BODY"
fi
```

### 步骤 5（可选）：Slack 摘要

若有 ≥1 项关键指标恶化，向 `SLACK_WEBHOOK_URL` 发送一条短摘要 + Issue 链接。

## 报告模板

```markdown
# Daily Report — {{date}}

**生成时间**: {{generated_at}} UTC
**监控仓库**: {{repos_count}} 个

## 总览

| 指标 | 今日 | 趋势 |
|------|------|------|
| run 总数 | {{total}} | — |
| 成功率 | {{rate}}% | — |
| 失败数 | {{failure}} | — |
| 仍 open 的 triage | {{triage.open}} | — |
| 今日新增 triage | {{triage.new_today}} | — |

## Top 失败 Workflows

{{#each top_failures}}
- **{{workflow}}** ({{repo}}) — 失败 {{count}} 次，最近：{{last_failure}}
{{/each}}

（若无：`_过去 24 小时无失败。_`）

## 失败详情（Top 3）

{{#each top3_failures_with_logs}}
### {{workflow}} — {{failed_step}}
- **仓库**: {{repo}}
- **Run ID**: {{run_id}}
- **Agent 摘要**: {{一句人类可读的失败原因}}

{{/each}}

（若无：`_无失败需要分析。_`）

## 按仓库统计

| 仓库 | 总数 | 成功 | 失败 |
|------|------|------|------|
{{#each by_repo}}
| {{repo}} | {{total}} | {{success}} | {{failure}} |
{{/each}}

## 学习

- 已知 pattern 数：{{patterns.total}}
- 今日新增 pattern：{{patterns.new_today}}
- 熔断器状态：{{#if circuit.active}}🔴 已触发{{else}}✅ 正常{{/if}}
```

无数据时：

```markdown
# Daily Report — {{date}}

**no_data**: true
**生成时间**: {{generated_at}} UTC

检查了仓库 {{repos_list}}，过去 24 小时内没有 workflow runs。可能原因：
- 仓库配置有误（请检查 data/onboarded-repos.yml）
- CI 在静默期（节假日、冻结）
- API token 权限不足以读取 actions

# /daily-report — 24h CI 健康日报（v5.1 agent-when-needed）

**触发**：`agent-daily.yml` 工作日 UTC 01:00，或 `workflow_dispatch`。

> **数据已注入** — workflow 的 `collect:` job 已经跑过 `scripts/collect-daily.py`，
> 把 24h 总览 + Top 失败 + Top-3 失败的日志 + 前一份 daily issue 通过 prompt 中
> 的 `DATA_CONTEXT:` 段传给我。我不再自己查 gh / 算指标 — 我只负责把 JSON 渲
> 染成中文 markdown，然后 upsert 到 `evolveci/daily` issue。

## ⚠️ 强制契约

**每次运行必须以 `gh issue create` 或 `gh issue edit` 结束**。哪怕 `runs.total=0`，
仍然写一条 `no_data: true` issue — 这是发现"agent 跑了但啥都没做"的唯一信号。

## 步骤

### 1. 读取 DATA_CONTEXT

```bash
sed -n '/^DATA_CONTEXT:/,$p' <<< "$PROMPT_BODY" | sed '1d' > /tmp/daily-stats.json
```

字段（节选）：

- `totals.{runs,success,failure,cancelled,success_rate,flaky_rate}`
- `top_failing_workflows[]` — Top 5 失败 workflow（含 repo / fails / last_failure）
- `top3_failures_with_logs[]` — Top 3 最近失败，含 `failed_step` + `redacted_tail`
- `triage.{new,open_old,patterns_added}` — 各自有 count + samples
- `circuit.{active,tripped_at}`
- `prev_daily` — 上一份 daily issue body（用于趋势对比）
- `no_data` — 24h 内 0 run

### 2. 检测退化（与上一份 daily 对比）

```bash
PREV=$(jq -r '.prev_daily.body // empty' /tmp/daily-stats.json)
```

如果有 PREV，从中抽出关键数字（成功率 / 失败数 / open triage），与今日对比，
≥20% 劣化标 ⚠️。如无 PREV，跳过此步。

### 3. 渲染 markdown

#### 有数据时

```markdown
# Daily Report — {{today}}

**生成时间**: {{generated_at}} UTC
**监控仓库**: {{repos | length}} 个

## 总览

| 指标 | 今日 | 趋势 vs 昨日 |
|------|------|-------------|
| run 总数 | {{totals.runs}} | {{trend_runs}} |
| 成功率 | {{success_rate_pct}}% | {{trend_success}} |
| 失败数 | {{totals.failure}} | {{trend_failure}} |
| flaky 率 | {{flaky_rate_pct}}% | — |
| 仍 open 的 triage | {{triage.open_old.count + triage.new.count}} | — |

## Top 失败 Workflows

（来自 `top_failing_workflows[]` — 5 行 list）
- **{{repo}} · {{workflow}}** × {{fails}} 次
- ...

## 失败详情（Top 3）

（来自 `top3_failures_with_logs[]`，对每条用 agent 推理写一句中文摘要）

### {{repo}} · {{workflow}} · {{failed_step}}

- Run: {{url}}
- 失败摘要：{{我从 redacted_tail 推断的 1-2 句中文}}

## 当日新增 triage

（来自 `triage.new.samples`）
- #{{number}} {{title}} (category: {{category}})

（若无：`_当日无新增 triage issue。_`）

## 仍 open 的 triage（昨日及之前）

（来自 `triage.open_old.samples`）

（若无：`_无超期 triage issue。_`）

## 学习

- 新增 `evolveci/pattern` × {{triage.patterns_added.count}}
- 熔断器: active = {{circuit.active}}{{ if circuit.tripped_at }} (tripped at {{circuit.tripped_at}}){{ /if }}
```

#### `no_data=true` 时

```markdown
# Daily Report — {{today}}

**生成时间**: {{generated_at}} UTC
**no_data**: true

过去 24 小时内没有任何 workflow run（已检查仓库 {{repos | join ", "}}）。可能原因：
- 仓库当日静默（节假日 / 冻结）
- onboarded-repos.yml 配置错误
- API token 权限不足
```

### 4. Upsert issue

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
    --label "evolveci/daily,severity/info" \
    --body "$REPORT_BODY"
fi
```

### 5. Slack（可选）

`success_rate < 70%` 或 `failure > 50` 或 `circuit.active = true` → 短摘要 +
Issue URL 到 `SLACK_CI_WEBHOOK`。

## 不做什么

- 不调用 `python3 scripts/collect-daily.py` — 数据已经在 DATA_CONTEXT 里
- 不写本地文件（`/tmp/*` 例外）
- 不 git commit / push

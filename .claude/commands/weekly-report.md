# /weekly-report — 7d 深度复盘（提交 PR）

**触发**：`agent-weekly.yml` 周一 UTC 02:00，或 `workflow_dispatch`。

> **数据已注入** — workflow 的 `collect:` job 已经跑过 `scripts/collect-weekly.py`，
> 7d 总览 + DORA + MTTR + by-day 全部通过 prompt 中的 `DATA_CONTEXT:` 段传给我。
> 我**只**负责渲染中文 markdown 报告 + 决定 CLAUDE.md 学习行内容 + 调用
> `weekly-pr.sh` 开 PR。
>
> 这是四个 agent 中**唯一**会动 git 的命令。

## ⚠️ 强制契约

**每次运行必须以 `gh pr create` 结束**。哪怕本周零 incident，仍然开一个标注
`no_data: true` 的 PR — 这是发现"agent 跑了但啥都没做"的唯一信号。

## 步骤

### 1. 读取 DATA_CONTEXT

```bash
sed -n '/^DATA_CONTEXT:/,$p' <<< "$PROMPT_BODY" | sed '1d' > /tmp/weekly-stats.json
```

字段（节选）：

- `totals.{runs,success,failure,success_rate,flaky_rate}`
- `by_day[]` — 每天的 runs / success / failures
- `top_failing_workflows[]` — Top 10
- `triage.{new,closed,open_at_week_end,patterns_added,mttr_hours_p50,mttr_hours_p95}`
- `dora.{deployment_frequency_per_day,change_failure_rate,mttr_hours}`
- `iso_week`、`since`、`until`、`no_data`

### 2. 归档过期 incident

7 天前已 close、未 reopen 的 `evolveci/triage` issue → 加 `status/recovered` 标签：

```bash
SINCE=$(date -u -d '7 days ago' +%FT%TZ 2>/dev/null || date -u -v-7d +%FT%TZ)
gh issue list --label evolveci/triage --state closed \
  --search "closed:<${SINCE} -label:status/recovered" \
  --json number --jq '.[].number' | while read -r n; do
    gh issue edit "$n" --add-label status/recovered
  done
```

### 3. 渲染报告 markdown

#### 有数据时

```markdown
# Weekly Deep Dive — {{iso_week}}

**周期**: {{since}} → {{until}} UTC
**监控仓库**: {{repos | length}}

## 总览

| 指标 | 本周 |
|------|------|
| run 总数 | {{totals.runs}} |
| 成功率 | {{success_rate_pct}}% |
| flaky 率 | {{flaky_rate_pct}}% |

## DORA

| 指标 | 本周 |
| --- | --- |
| Deployment frequency | {{dora.deployment_frequency_per_day}} /day |
| Change failure rate | {{dora.change_failure_rate}} |
| MTTR (p50) | {{triage.mttr_hours_p50}} h |
| MTTR (p95) | {{triage.mttr_hours_p95}} h |

## 每日趋势

（渲染 `by_day` 数组成迷你表格）

## 本周关键 incidents (Top 5)

（来自 `triage.new.samples`，挑 severity/critical 优先）

## 学习模式

（来自 `triage.patterns_added.samples`）

## 行动建议

（这是我推理的部分 — 1-3 句话）
```

#### `no_data=true` 时

```markdown
# Weekly Deep Dive — {{iso_week}}

**no_data**: true

本周（{{since}} → {{until}}）零 workflow run。原因可能：
- 监控仓库当周静默
- 配置异常（请检查 data/onboarded-repos.yml）
```

### 4. 决定 CLAUDE.md 学习行

```bash
PATTERN_COUNT=$(jq '.triage.patterns_added.count' /tmp/weekly-stats.json)
TODAY=$(date -u +%Y-%m-%d)

if [ "$PATTERN_COUNT" -gt 0 ]; then
  TOP_PATTERN=$(jq -r '.triage.patterns_added.samples[0].title' /tmp/weekly-stats.json)
  LEARNING="$TODAY: ${TOP_PATTERN#pattern: } — <一句话评价>"
else
  LEARNING="$TODAY: _本周无新模式_"
fi
```

### 5. 同步 pattern 知识回 seed 文件

```bash
bash scripts/sync-patterns-to-seed.sh "$GITHUB_REPOSITORY"
```

输出 JSON: `{"status":"synced","count":N,"file":"data/known-patterns.seed.json",...}`

这确保 seed 文件始终反映最新 pattern 状态。脚本同时执行：
- 生命周期检查（dormant/retire 过期 pattern）
- agent-learned pattern 的 confidence 自动推断

### 6. 开 PR

```bash
echo "$REPORT_MARKDOWN" > /tmp/weekly-report.md

bash scripts/weekly-pr.sh \
  --report-file /tmp/weekly-report.md \
  --learning-line "$LEARNING"
# 输出: {"status":"ok","branch":"weekly/2026-W18","pr":"https://github.com/..."}
```

PR 由人评审后 squash-merge。**不**自动 admin merge。

## Slack（可选）

发送本周 5 个关键数字 + PR URL 到 `SLACK_WEBHOOK_URL`。

## 不做什么

- 不调用 `python3 scripts/collect-weekly.py` — 数据已经在 DATA_CONTEXT 里
- 不直接 push 到 main
- 不 close 仍 open 的 `evolveci/triage`（除非 `status/recovered` 已存在 ≥7 天）

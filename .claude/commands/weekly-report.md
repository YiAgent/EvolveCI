# /weekly-report — 7d 深度复盘（提交 PR）

**触发**：`agent-weekly.yml` 周一 UTC 02:00，或 `workflow_dispatch`。

> 这是四个 agent 中**唯一**会动 git 的命令：在新分支上更新 `CLAUDE.md` 的
> "近期学习"章节，并打开 PR。
>
> 数据收集由 `scripts/collect-weekly.py` 一步完成；我（agent）只负责渲染
> 中文 markdown 报告 + 决定 CLAUDE.md 学习行内容 + 调用 `weekly-pr.sh` 开 PR。

## ⚠️ 强制契约

**每次运行必须以 `gh pr create` 结束**。哪怕本周零 incident，仍然开一个标注
`no_data: true` 的 PR — 这是发现"agent 跑了但啥都没做"的唯一信号。

## 步骤

### 1. 预处理

```bash
pip install --user --quiet pyyaml >/dev/null 2>&1 || python3 -m pip install --user --quiet pyyaml >/dev/null 2>&1
python3 scripts/collect-weekly.py --out /tmp/weekly-stats.json
```

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

读 `/tmp/weekly-stats.json`，套用模板：

```markdown
# Weekly Deep Dive — {{iso_week}}

**周期**: {{since}} → {{until}} UTC
**监控仓库**: {{repos | length}}

## 总览

| 指标 | 本周 |
|------|------|
| run 总数 | {{totals.runs}} |
| 成功率 | {{totals.success_rate * 100}}% |
| flaky 率 | {{totals.flaky_rate * 100}}% |

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

`no_data=true` 时的退化版本：

```markdown
# Weekly Deep Dive — {{iso_week}}

**no_data**: true

本周（{{since}} → {{until}}）零 workflow run。原因可能：
- 监控仓库当周静默
- 配置异常（请检查 data/onboarded-repos.yml）
```

### 4. 决定 CLAUDE.md 学习行

```bash
# 有新 pattern → 取最值得记的那条；否则用占位
PATTERN_COUNT=$(jq '.triage.patterns_added.count' /tmp/weekly-stats.json)
TODAY=$(date -u +%Y-%m-%d)

if [ "$PATTERN_COUNT" -gt 0 ]; then
  TOP_PATTERN=$(jq -r '.triage.patterns_added.samples[0].title' /tmp/weekly-stats.json)
  LEARNING="$TODAY: ${TOP_PATTERN#pattern: } — <一句话评价>"
else
  LEARNING="$TODAY: _本周无新模式_"
fi
```

### 5. 开 PR

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

- 不直接 push 到 main
- 不 close 仍 open 的 `evolveci/triage`（除非 `status/recovered` 已存在 ≥7 天）
- 不在 prompt 中再查 gh — 用 `/tmp/weekly-stats.json`

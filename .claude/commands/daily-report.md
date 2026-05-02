# /daily-report — 生成每日 CI 健康报告（Issue 内存模型）

**触发方式**：由 `agent-daily.yml` 工作日 UTC 01:00 调用，或通过 `workflow_dispatch` 手动触发。

> 内存模型：每天一个 `evolveci/daily` Issue。同日重跑 → 编辑 body 而非新建。
> 详见 `docs/MEMORY-MODEL.md`。

## 执行步骤

### 步骤 1：聚合最近 24 小时数据

通过 `mcp__github_ci__*` 与 `gh api` 收集（覆盖 `data/onboarded-repos.yml` 中
全部仓库）：

- 总 workflow run 数、成功率、失败率
- 按 workflow 维度的 top-5 失败
- 平均运行时长、p95 运行时长
- flaky run 比例（用 `evolveci/triage` + `category:flaky` 过滤）
- 当日新建 / 仍 open 的 `evolveci/triage` 数量
- 当日 auto-rerun 触发次数、新增 `evolveci/pattern` 数量

### 步骤 2：检测退化（与上一工作日对比）

```bash
PREV=$(gh issue list --label evolveci/daily -L 5 --json number,title,body \
        --jq '.[] | select(.title | startswith("Daily Report — "))')
```

取前一份与当前的关键指标对比，标出 ≥20% 的劣化项。

### 步骤 3：在 issue 上 upsert

```bash
TODAY=$(date -u +%Y-%m-%d)
TITLE="Daily Report — ${TODAY}"

# 是否已有今天的 issue？通过标题前缀搜索（in:title）
EXISTING=$(gh issue list --label evolveci/daily \
            --search "in:title \"${TITLE}\"" -L 1 \
            --json number --jq '.[0].number // empty')

REPORT_BODY=$(render-report)  # 渲染 markdown 报告

if [ -n "$EXISTING" ]; then
  gh issue edit "$EXISTING" --body "$REPORT_BODY"
else
  gh issue create \
    --title "$TITLE" \
    --label "evolveci/daily,severity/info" \
    --body "$REPORT_BODY"
fi
```

### 步骤 4（可选）：Slack 摘要

若有 ≥1 项关键指标恶化，向 `SLACK_WEBHOOK_URL` 发送一条短摘要 + Issue 链接。

## 报告 markdown 模板

```markdown
# Daily Report — {{today}}

**生成时间**: {{generated_at}} UTC

## 总览

| 指标 | 今日 | 昨日 | 趋势 |
|------|------|------|------|
| run 总数 | … | … | ↑/↓/→ |
| 成功率 | …% | …% | … |
| flaky 比例 | …% | …% | … |
| MTTR (h) | … | … | … |

## 当日新增 triage

- #1234 `repo · workflow · step` (severity/critical, category:infra)
- #1235 …

## 仍 open 的 triage（>24h）

…

## 学习

- 新增 `evolveci/pattern` × N
- auto-rerun 触发 × N
- 熔断器状态：active=…
```

## 不做什么

- 不写 `memory/stats/daily/<date>.json`
- 不 git commit
- 不 push 任何分支

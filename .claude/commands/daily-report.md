# /daily-report — 生成每日 CI 健康报告

**触发方式**：由 `agent-daily.yml` 工作日 UTC 01:00 调用，或通过 `workflow_dispatch` 手动触发。

## 执行步骤

### 步骤 1：采集 24 小时数据

- 读取 `data/onboarded-repos.yml` 获取监控仓库列表
- 对每个仓库，用 GitHub MCP 工具查询过去 24 小时内所有 workflow runs（all status）
- 按 `repo/workflow` 分组，计算：
  - `total_runs`：总次数
  - `failed_runs`：失败次数
  - `success_runs`：成功次数
  - `failure_rate`：失败率（%）
  - `timed_out_runs`：超时次数

### 步骤 2：检测退化

- 读取 `memory/stats/daily/` 最近 7 天的 JSON 快照
- 对每个 workflow，计算 7 天平均失败率
- 若今日失败率比 7 天均值高 **≥10 个百分点** → 标记为退化（`degraded: true`）
- 若某 workflow 今日出现但 7 天历史中无记录 → 标记为新 workflow

### 步骤 3：生成报告内容

使用我自己的分析能力生成中文日报（参考 `prompts/observability/daily-report.md` 的格式要求）：

报告结构：
```markdown
## CI 日报 — YYYY-MM-DD

### TL;DR
<2-3 句话总结今日 CI 健康状况，高亮最重要的问题>

### 关键指标

| 指标 | 数值 |
|------|------|
| 监控仓库数 | N |
| 总 workflow 运行次数 | N |
| 失败次数 | N |
| 整体失败率 | N% |
| 自动重跑次数 | N |

### 退化预警 ⚠️
<列出失败率显著上升的 workflow，含今日 vs 7 天均值对比>

### Top Flaky Workflows
<失败率最高的前 5 个 workflow>

### 建议行动项
<基于今日数据的 2-5 条具体建议>
```

### 步骤 4：持久化与发布

1. 写入 `memory/stats/daily/<今日日期>.json`（原始数据快照）
2. 通过 GitHub MCP 创建 GitHub Issue：
   - 标题：`CI 日报 - YYYY-MM-DD`
   - 标签：`daily-report`、`ci-health`
   - 正文：步骤 3 生成的 markdown 报告
3. 若有 `severity=critical` 的退化 → 同时发送 Slack 通知

### 步骤 5：提交记忆

```bash
git add memory/stats/daily/
git commit -m "memory: daily-report — health snapshot YYYY-MM-DD, failure_rate=N%"
git push origin main
```

## 每日统计 JSON 格式

`memory/stats/daily/YYYY-MM-DD.json`：
```json
{
  "date": "YYYY-MM-DD",
  "total_runs": 127,
  "total_failures": 14,
  "failure_rate": 11,
  "trend": "stable",
  "trend_delta": 2,
  "workflows": [
    {"key": "org/repo/ci.yml", "total": 45, "failed": 3, "failure_rate": 6}
  ],
  "degradations": [
    {"key": "org/repo/pr.yml", "current": 13, "avg_7day": 5, "delta": 8}
  ]
}
```

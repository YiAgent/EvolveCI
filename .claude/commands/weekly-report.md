# /weekly-report — 生成每周 CI 深度分析报告

**触发方式**：由 `agent-weekly.yml` 每周一 UTC 02:00 调用，或通过 `workflow_dispatch` 手动触发。

## 执行步骤

### 步骤 1：采集 7 天数据

- 合并 `memory/stats/daily/` 最近 7 天的 JSON 快照
- 读取上周的 `memory/stats/weekly/<上周Week>.json` 用于对比
- 读取本周所有 `memory/incidents/<YYYY-MM>/<date>.jsonl` 统计 Tier 分布

### 步骤 2：深度分析

计算以下指标：

**DORA 指标估算**：
- 变更失败率：过去 7 天 CI 总失败率
- MTTR（平均恢复时间）：从失败到下次成功的平均时间间隔（读取 incidents 数据）
- 部署频率：成功运行的 `deploy`/`release` workflow 次数（估算）

**模式分析**：
- Top 5 最频繁指纹（从 `memory/fingerprints/` 统计 `count`）
- 本周新增 pattern 数（`source: "agent-learned"` 且 `last_seen` 在本周内的）
- Tier 1 命中率：本周 incidents 中 `tier: 1` 的比例 vs 上周

**趋势分析**：
- 各仓库健康排名（按失败率升序）
- 本周 vs 上周对比（失败率、重跑次数、新 Issue 数）

### 步骤 3：自我进化评估

- 统计本周新学习的 pattern 数和 Tier 1 命中率变化
- 若 Tier 1 命中率提升 ≥5 个百分点 → 在报告中高亮
- 更新 `CLAUDE.md` 的"近期学习"章节（最近 3-5 条新 pattern）

### 步骤 4：生成报告

使用我自己的分析能力生成中文周报（参考 `prompts/observability/weekly-deep-dive.md`）：

报告结构：
```markdown
## CI 周报 — YYYY-Www（YYYY-MM-DD ~ YYYY-MM-DD）

### 执行摘要
<3-5 句话，本周 CI 健康状况、最重要发现、建议优先级>

### 关键指标对比

| 指标 | 本周 | 上周 | 趋势 |
|------|------|------|------|
| 总运行次数 | | | |
| 失败率 | | | |
| 自动重跑次数 | | | |
| Tier 1 命中率 | | | |
| 新增 Pattern 数 | | | |

### DORA 指标
- 变更失败率：N%（评级：Elite/High/Medium/Low）
- MTTR：N 小时
- 部署频率：N 次/周

### 仓库健康排名
<表格，含各仓库本周失败率>

### Top 5 高频问题
<按指纹出现次数排序，含 pattern_id/category/count/建议>

### 自我进化报告
- 本周新学习 Pattern：N 条
- Tier 1 命中率：N%（上周：N%，变化：+/-N%）
- [新 pattern 列表]

### 建议行动项
<基于本周分析的 3-5 条具体建议，含优先级>
```

### 步骤 5：持久化、发布、更新记忆

1. 写入 `memory/stats/weekly/<YYYY-Www>.json`
2. 更新 `CLAUDE.md` 的"近期学习"章节
3. 通过 GitHub MCP 创建 GitHub Issue：
   - 标题：`CI 周报 - YYYY-Www`
   - 标签：`weekly-report`、`ci-health`
4. 提交变更：
```bash
git add memory/stats/weekly/ CLAUDE.md
git commit -m "memory: weekly-report — week YYYY-Www, Tier1 rate=N%, N new patterns"
git push origin main
```

### 步骤 6：归档旧数据（月初运行时）

若当前是每月 1 号（根据当前日期判断）：
- 检查 `memory/incidents/` 中超过 90 天的月份目录
- 将其中所有 `.jsonl` 文件合并为 `<YYYY-MM>-archived.jsonl.gz`（通过 Bash gzip 命令）
- 提交归档变更

## 每周统计 JSON 格式

`memory/stats/weekly/YYYY-Www.json`：
```json
{
  "week": "YYYY-Www",
  "start_date": "YYYY-MM-DD",
  "end_date": "YYYY-MM-DD",
  "total_runs": 892,
  "total_failures": 98,
  "failure_rate": 11,
  "rerun_count": 23,
  "tier1_hit_rate": 73,
  "new_patterns": 3,
  "mttr_hours": 2.4,
  "repos": [
    {"repo": "org/repo-a", "failure_rate": 6, "rank": 1},
    {"repo": "org/repo-b", "failure_rate": 18, "rank": 2}
  ]
}
```

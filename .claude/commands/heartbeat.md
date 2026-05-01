# /heartbeat — 自我健康监控

**触发方式**：由 `agent-heartbeat.yml` 每 6 小时调用。

## 执行步骤

依次执行以下 5 个探针，任一关键探针失败则触发告警。

### 探针 1：Triage 活跃度（关键）

检查 `memory/incidents/` 目录：
- 找到最新的 `.jsonl` 文件（按文件名/路径排序）
- 读取最后一行，检查 `ts` 字段的 ISO8601 时间戳
- 若距今 > 24h → **失败**：triage 超过 24 小时未运行

**预期**：每 15 分钟 triage 一次，24h 内至少有 1 条记录。

### 探针 2：模式库健康（关键）

读取 `memory/patterns/known-patterns.json`：
- 统计条目数
- 若 < 10 条 → **失败**：模式库条目过少（可能文件损坏）
- 验证 JSON 格式是否有效（通过 `jq . memory/patterns/known-patterns.json` 检查）

### 探针 3：统计数据新鲜度（警告）

读取 `memory/stats/daily/` 目录：
- 找到最新的 `.json` 文件
- 检查文件的 `date` 字段
- 若距今 > 48h → **警告**：daily-report 超过 48 小时未运行

### 探针 4：熔断器状态检查（信息）

读取 `memory/circuit/state.json`：
- 若 `active: true` 且 `tripped_at` 距今 > 24h：
  - 自动恢复（参考 `/check-circuit` 命令）
  - 记录为警告而非失败
- 若 `active: true` 且 < 24h：
  - 记录为信息（熔断器正常工作中，不视为故障）

### 探针 5：目录完整性（关键）

检查以下目录是否存在：
- `memory/patterns/`
- `memory/incidents/`
- `memory/stats/daily/`
- `memory/stats/weekly/`
- `memory/fingerprints/`
- `memory/circuit/`
- `memory/counters/`

若任一不存在 → **失败**：内存目录结构损坏。

## 告警决策

| 状态 | 条件 | 动作 |
|------|------|------|
| 全部健康 | 所有关键探针通过 | 仅输出日志，无动作 |
| 警告 | 仅非关键探针失败 | 记录警告日志 |
| 故障 | 任一关键探针失败 | 创建 GitHub Issue + Slack 通知 |

### 故障 Issue 格式

- 标题：`[EvolveCI 健康告警] <探针名称> 失败`
- 标签：`heartbeat-alert`、`severity/high`
- 正文：说明失败探针、期望值、实际值、可能原因、建议修复步骤

## 无需提交记忆

Heartbeat 本身不产生需要持久化的状态（它是只读探针），**不需要 git commit**。
若触发了熔断器自动恢复，恢复逻辑本身会在 `/check-circuit` 中处理提交。

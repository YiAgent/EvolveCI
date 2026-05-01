# /check-circuit — 熔断器状态检查与管理

**触发方式**：由 `/triage` 在每次运行开始时调用，或手动执行以查看熔断器状态。

## 熔断器状态文件

`memory/circuit/state.json` 格式：
```json
{
  "active": false,
  "reason": "",
  "tripped_at": null,
  "tripped_dimension": null,
  "auto_recover_at": null,
  "history": []
}
```

## 执行步骤

### 查询状态（默认操作）

读取 `memory/circuit/state.json` 并输出当前状态：

- `active: false` → 输出"熔断器正常，可执行自动操作"
- `active: true` → 输出详细信息：
  - 触发时间
  - 触发维度（workflow/pattern/repo）
  - 触发原因
  - 预计自动恢复时间（`tripped_at` + 24h）
  - 相关 GitHub Issue 链接（从 `reason` 中提取）

### 自动恢复检查

若 `active: true` 且 `tripped_at` 距今 ≥ 24h：

1. 将 `active` 设为 `false`，清空 `reason`/`tripped_at`/`tripped_dimension`
2. 在 `history` 数组追加恢复记录：
   ```json
   {
     "tripped_at": "<原触发时间>",
     "recovered_at": "<当前ISO8601时间>",
     "reason": "<原触发原因>",
     "recovered_by": "auto"
   }
   ```
3. 在对应 GitHub Issue（通过 `reason` 字段中的 Issue 编号找到）添加 comment：
   ```
   熔断器已自动恢复（24小时超时）。EvolveCI 将恢复自动分诊。
   ```
4. 写回 `memory/circuit/state.json`
5. 提交：`memory: circuit-recover — auto-recovered after 24h`

### 触发熔断（由 triage 内部调用）

当重跑计数超过预算时：

1. 读取计数器确认维度和原因
2. 更新 `memory/circuit/state.json`：
   ```json
   {
     "active": true,
     "reason": "<维度>超限：<repo>/<workflow> 今日已重跑 <N> 次",
     "tripped_at": "<当前ISO8601时间>",
     "tripped_dimension": "<workflow|pattern|repo>",
     "auto_recover_at": "<tripped_at + 24h>"
   }
   ```
3. 通过 GitHub MCP 创建 Issue：
   - 标题：`[熔断器] <repo>/<workflow> - <维度>预算超限`
   - 标签：`ci:circuit-broken`、`severity/critical`
   - 正文说明触发原因、预算配置来源（`data/circuit-config.yml`）、手动恢复方法
4. 发送 Slack 通知（若配置了 webhook）
5. 提交：`memory: circuit-trip — <维度> budget exceeded for <repo>/<workflow>`

## 手动恢复方法

若需人工干预恢复熔断器，可通过 `workflow_dispatch` 触发并在 prompt 中说明：
```
/check-circuit recover
```
这会强制将 `active` 设为 `false` 并记录 `recovered_by: "manual"`。

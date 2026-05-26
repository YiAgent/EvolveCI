# /heartbeat — 自我健康监控（基于 Issue 内存模型）

**触发方式**：由 `agent-heartbeat.yml` 每 6 小时调用。

> 内存模型：所有持久化状态都存放在带 `evolveci/*` 前缀标签的 Issue 中。
> 详见 `docs/MEMORY-MODEL.md`。
>
> **v5.1**：所有探针数据由 `collect-heartbeat-data.sh` 预收集，通过
> `{{data_file}}` 注入。Agent 只做判定 + 上报，不再自己查 gh。

## ⚠️ 强制契约（不可违反）

每次运行**必须**以下面两种动作之一结束：

1. **任一关键探针失败时** — 必须执行 `gh issue comment` 或 `gh issue create`
   往 `evolveci/heartbeat` 标签的 Issue 上写入本轮 5 个探针的结果。
2. **全部通过时** — 必须执行 `gh issue close` 关闭任何尚处 open 的
   `evolveci/heartbeat` Issue（带恢复 comment + `status/recovered` 标签）。

不允许"探针都跑完了但什么都没写"。**下方的 bash 代码是你必须执行的命令，
不是示例。**

## 步骤 1：读取预处理数据

```bash
DATA_CONTEXT=$(cat '{{data_file}}')
```

`$DATA_CONTEXT` 是 JSON 对象，五个 probe 子对象的字段见下方判定规则。

## 步骤 2：判定每个探针

### 探针 1 — agent-triage workflow 24h 运行健康（critical）

读 `probe1`: `total_runs / success_runs / failure_runs / success_rate / latest_failure_url`

- `total_runs == 0` → **FAIL**（critical）：24h 内一次都没跑。cron 被禁 /
  Actions 配额耗尽 / workflow 被 disable。报告里附 EvolveCI Actions 页 URL。
- `success_runs == 0` 且 `total_runs > 0` → **FAIL**（critical）：跑了但全
  失败。报告附 `latest_failure_url`。
- `success_rate < 0.5` → **WARN**（非 critical）：间歇性故障。
- 否则 → **PASS**，报告写 "agent-triage 24h: $success/$total ok"。

> 不再读 `evolveci/triage` issue 活跃度——那个数受被监控仓库失败数影响，
> 不能代理 workflow 自身健康。

### 探针 2 — 模式库（critical + 自愈）

读 `probe2.pattern_count`。

- `pattern_count == 0` → **必须立即执行**（不是示例，不要跳过）：
  ```bash
  bash scripts/seed-patterns.sh "$GITHUB_REPOSITORY"
  ```
  种入后**重新跑** `collect-heartbeat-data.sh` 取最新计数。
- `pattern_count < 10` → **FAIL**：种入失败 / seed 文件损坏。
- 否则 → **PASS**。

### 探针 3 — daily-report 新鲜度（warning）

读 `probe3.stale_hours`（距上次 daily issue 更新的小时数）。

- `stale_hours == null` → **WARN**：没找到任何 daily issue（部署初期？）。
- `stale_hours > 48` → **WARN**：daily-report 超过 48h 未运行。
- 否则 → **PASS**。

非 critical，不计入 `failed_critical`。

### 探针 4 — 熔断器状态（info）

读 `probe4.exists / active / tripped_at`。

- `exists == false` → 立即创建 issue：
  ```bash
  gh issue create --title "evolveci circuit state" \
    --label evolveci/circuit \
    --body '{"active":false,"history":[]}'
  ```
  本探针记为 **INFO**（不计入 failed_critical）。
- `active == true` 且距 `tripped_at` > 24h → **WARN**：可自动恢复，参考
  `/check-circuit`。
- `active == true` 且 < 24h → **INFO**：熔断器正常工作中。
- 否则（`active == false`） → **PASS**。

### 探针 5 — 标签完整性（info，可降级）

读 `probe5.available / label_count`。

- `available == false` → **SKIP**：API 拒绝。标签是部署期一次性配置，运行
  期不会消失，不值得用 critical 频繁告警。报告写 "probe-5 skipped: label
  API unavailable"。
- `label_count >= 5` → **PASS**。
- `label_count < 5` → **FAIL**：未初始化。提示运行
  `bash scripts/bootstrap-labels.sh <owner/repo>`。

## 步骤 3：上报（强制契约）

收集 `failed_critical` 列表——只包含探针 1、2 的 FAIL 状态。其他探针的
WARN / INFO / SKIP **不**触发 critical 告警。

```bash
REPORT="## 心跳报告 — $(date -u +%FT%TZ)

- 探针 1（triage workflow 健康）: <status> — <p1 detail>
- 探针 2（模式库健康）: <status> — <p2 detail>
- 探针 3（数据新鲜度）: <status> — <p3 detail>
- 探针 4（熔断器状态）: <status> — <p4 detail>
- 探针 5（标签完整性）: <status> — <p5 detail>

failed_critical: <list 或 none>

[run]({{run_url}})"
```

**情况 A — failed_critical 非空**：累加到现有 issue，否则新建。

```bash
EXISTING=$(gh issue list --label evolveci/heartbeat --state open -L 1 \
            --json number --jq '.[0].number // empty')

if [ -n "$EXISTING" ]; then
  gh issue comment "$EXISTING" --body "$REPORT"
else
  gh issue create \
    --title "EvolveCI heartbeat alert — $(date -u +%Y-%m-%d)" \
    --label evolveci/heartbeat,severity/critical \
    --body "$REPORT"
fi
```

**情况 B — failed_critical 为空**：关闭所有 open heartbeat issue（带
恢复 comment + `status/recovered` 标签）。

```bash
EXISTING=$(gh issue list --label evolveci/heartbeat --state open -L 1 \
            --json number --jq '.[0].number // empty')
if [ -n "$EXISTING" ]; then
  gh issue comment "$EXISTING" --body "$REPORT

全部关键探针在 $(date -u +%FT%TZ) 恢复正常。"
  gh issue edit "$EXISTING" --add-label status/recovered
  gh issue close "$EXISTING"
fi
```

## 步骤 4（可选）：Slack 通知

`failed_critical` 非空且 `SLACK_WEBHOOK_URL` 存在 → 发送一条摘要消息
（标题 + 失败探针名 + Issue URL）。

## 不做什么

- 不写本地文件
- 不 git commit
- 不 push 任何分支
- **不再直接 `gh run list / gh issue list`** —— 数据来自 `{{data_file}}`

# /heartbeat — 自我健康监控（基于 Issue 内存模型）

**触发方式**：由 `agent-heartbeat.yml` 每 6 小时调用。

> 内存模型：所有持久化状态都存放在带 `evolveci/*` 前缀标签的 Issue 中。
> 详见 `docs/MEMORY-MODEL.md`。

## ⚠️ 强制契约（不可违反）

每次运行**必须**以下面两种动作之一结束：

1. **任一关键探针失败时** — 必须执行 `gh issue comment` 或 `gh issue create`
   往 `evolveci/heartbeat` 标签的 Issue 上写入本轮 5 个探针的结果。
2. **全部通过时** — 必须执行 `gh issue close` 关闭任何尚处 open 的
   `evolveci/heartbeat` Issue（带恢复 comment + `status/recovered` 标签）。

不允许"探针都跑完了但什么都没写"。这是任务的成功条件——没有 issue 写入或
close = 任务失败，即使所有命令都执行了。**下方的 bash 代码是你必须执行的
命令，不是示例。**

## 执行步骤

依次执行以下 5 个探针，最后**根据强制契约写 issue**。

### 探针 1：Triage 活跃度（关键）

查询近 24 小时内被更新的 triage Issue：

```bash
SINCE=$(date -u -d '24 hours ago' +%FT%TZ 2>/dev/null || date -u -v-24H +%FT%TZ)
COUNT=$(gh issue list --label evolveci/triage --state all \
  --search "updated:>${SINCE}" --json number -L 1 | jq length)
```

`COUNT == 0` → **失败**：triage 超过 24 小时未运行。

### 探针 2：模式库健康（关键 + 自愈）

```bash
COUNT=$(gh issue list --label evolveci/pattern --state all -L 100 --json number | jq length)
```

如果 `COUNT == 0` → **必须立即执行**（不是示例代码，不要跳过）：

```bash
bash scripts/seed-patterns.sh "$GITHUB_REPOSITORY"
```

该脚本是幂等的：如果已经有任何 `evolveci/pattern` Issue 存在，它会立即跳过；
否则把 `data/known-patterns.seed.json` 全部种入为 Issue。运行后再次查询 COUNT。

`COUNT < 10` → **失败**：种入失败或 seed 文件损坏。否则 → **PASS**。

### 探针 3：统计数据新鲜度（警告）

近 48 小时内是否有更新过的 `evolveci/daily` Issue：

```bash
SINCE=$(date -u -d '48 hours ago' +%FT%TZ 2>/dev/null || date -u -v-48H +%FT%TZ)
COUNT=$(gh issue list --label evolveci/daily --state all \
  --search "updated:>${SINCE}" --json number -L 1 | jq length)
```

`COUNT == 0` → **警告**：daily-report 超过 48 小时未运行。

### 探针 4：熔断器状态（信息）

读取唯一 `evolveci/circuit` Issue 的 body（JSON），检查 `active` 与 `tripped_at`：

```bash
BODY=$(gh issue list --label evolveci/circuit --state all -L 1 --json body --jq '.[0].body // empty')
ACTIVE=$(echo "$BODY" | jq -r '.active // false')
TRIPPED=$(echo "$BODY" | jq -r '.tripped_at // empty')
```

- `active=true` 且距 `tripped_at` > 24h → 自动恢复（参考 `/check-circuit`），记为**警告**而非失败。
- `active=true` 且 < 24h → 记为**信息**（熔断器正常工作中）。
- 没有 `evolveci/circuit` Issue → 创建一个，body 为 `{"active":false,"history":[]}`。

### 探针 5：标签完整性（关键）

```bash
gh label list --limit 100 --json name --jq '.[].name' | grep -c '^evolveci/'
```

返回 `< 5` → **失败**：标签未初始化。提示运行 `bash scripts/bootstrap-labels.sh <owner/repo>`。

## 上报：累加到现有 heartbeat Issue 或新建

任一关键探针失败时：

```bash
EXISTING=$(gh issue list --label evolveci/heartbeat --state open -L 1 \
            --json number --jq '.[0].number // empty')

REPORT="## 心跳报告 — $(date -u +%FT%TZ)

- 探针 1（triage 活跃度）: <status>
- 探针 2（模式库健康）: <status>
- 探针 3（数据新鲜度）: <status>
- 探针 4（熔断器状态）: <status>
- 探针 5（标签完整性）: <status>

failed_critical: <list>

[run]({{run_url}})"

if [ -n "$EXISTING" ]; then
  gh issue comment "$EXISTING" --body "$REPORT"
else
  gh issue create \
    --title "EvolveCI heartbeat alert — $(date -u +%Y-%m-%d)" \
    --label evolveci/heartbeat,severity/critical \
    --body "$REPORT"
fi
```

## 全部通过时：关闭现有 heartbeat Issue

```bash
EXISTING=$(gh issue list --label evolveci/heartbeat --state open -L 1 \
            --json number --jq '.[0].number // empty')
if [ -n "$EXISTING" ]; then
  gh issue comment "$EXISTING" --body "全部探针在 $(date -u +%FT%TZ) 恢复正常。"
  gh issue edit "$EXISTING" --add-label status/recovered
  gh issue close "$EXISTING"
fi
```

## Slack 通知（可选）

任何 `severity/critical` 探针失败时，且 `SLACK_WEBHOOK_URL` 存在 → 发送一条
摘要消息（标题 + 失败探针名 + Issue URL）。

## 不做什么

- 不写本地文件
- 不 git commit
- 不 push 任何分支

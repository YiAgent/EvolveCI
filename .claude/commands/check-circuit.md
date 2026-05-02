# /check-circuit — 熔断器状态（Issue 内存模型）

**触发方式**：由 `/triage` / `/heartbeat` 在每次运行开始时调用，或手动执行查看状态。

> 内存模型：单一 `evolveci/circuit` Issue 持有熔断器 JSON state。本命令的全部
> 操作都在该 issue 上完成（编辑 body / 追加 comment）。详见 `docs/MEMORY-MODEL.md`。

## 状态结构

```json
{
  "active": false,
  "tripped_at": null,
  "tripped_reason": null,
  "tripped_by": null,
  "history": [
    { "ts": "...", "event": "tripped|recovered", "reason": "..." }
  ]
}
```

## 读取

```bash
ISSUE=$(gh issue list --label evolveci/circuit --state all -L 1 \
        --json number --jq '.[0].number // empty')

if [ -z "$ISSUE" ]; then
  # 首次运行 — 创建带默认 state 的 issue
  gh issue create \
    --title "EvolveCI circuit breaker" \
    --label "evolveci/circuit,severity/info" \
    --body '{"active":false,"tripped_at":null,"tripped_reason":null,"tripped_by":null,"history":[]}'
  ISSUE=$(gh issue list --label evolveci/circuit --state all -L 1 \
            --json number --jq '.[0].number')
fi

STATE=$(gh issue view "$ISSUE" --json body --jq .body)
```

## 跳闸 (trip)

由 publisher 在超出预算时调用：

```bash
NEW=$(echo "$STATE" | jq --arg ts "$(date -u +%FT%TZ)" \
                         --arg reason "$REASON" \
                         --arg by "$TRIGGER_RUN_URL" \
  '.active=true | .tripped_at=$ts | .tripped_reason=$reason | .tripped_by=$by
   | .history += [{ts:$ts, event:"tripped", reason:$reason}]')

gh issue edit "$ISSUE" --body "$NEW"
gh issue comment "$ISSUE" --body "🔴 熔断器跳闸：${REASON} ([触发 run](${TRIGGER_RUN_URL}))"
```

## 自动恢复 (recover)

`/triage` 或 `/heartbeat` 发现 `active=true` 且 `tripped_at` ≥24h：

```bash
NEW=$(echo "$STATE" | jq --arg ts "$(date -u +%FT%TZ)" \
  '.active=false | .tripped_at=null | .tripped_reason=null | .tripped_by=null
   | .history += [{ts:$ts, event:"recovered", reason:"auto-recover (>24h)"}]')

gh issue edit "$ISSUE" --body "$NEW"
gh issue comment "$ISSUE" --body "🟢 自动恢复于 $(date -u +%FT%TZ)（已停留 ≥24h）"
```

## 手动检查

显示当前 state 摘要，不修改任何东西。

## 不做什么

- 不写 `memory/circuit/state.json`
- 不 git commit

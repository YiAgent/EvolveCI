# /triage — 失败分诊（v5.1 agent-when-needed）

**触发**：`agent-triage.yml` 每 15 分钟，或 `workflow_dispatch`。

> 我（agent）**不直接** `gh run list` / 算 fingerprint / 读日志。
> 这些都由 `scripts/build-triage-input.py` 一步做完，结果写入 JSON。
> 我只负责：(a) 触发预处理，(b) 对 `needs_tier3=true` 的条目做推理，
> (c) 把决策写成 `evolveci/triage` issue。

## 步骤

### 1. 检查熔断器

```bash
BODY=$(gh issue list --label evolveci/circuit --state all -L 1 \
        --json body --jq '.[0].body // empty')
ACTIVE=$(echo "$BODY" | jq -r '.active // false' 2>/dev/null || echo false)
TRIPPED=$(echo "$BODY" | jq -r '.tripped_at // empty' 2>/dev/null || echo)
```

- `active=true` 且距 `tripped_at` < 24h → **直接退出**，不预处理也不写 issue。
- `active=true` 且 ≥24h → 编辑 issue body 设 `active=false`，加一条 comment 记录恢复时间，继续。

### 2. 预处理：收集 + Tier 1 + Tier 2

执行：

```bash
pip install --user --quiet pyyaml >/dev/null 2>&1 || python3 -m pip install --user --quiet pyyaml >/dev/null 2>&1
python3 scripts/build-triage-input.py \
  --since 30m \
  --max-failures 10 \
  --out /tmp/triage-input.json
```

读取结果：

```bash
ENTRIES=$(jq '.entries | length' /tmp/triage-input.json)
T3=$(jq '[.entries[] | select(.needs_tier3)] | length' /tmp/triage-input.json)
echo "preprocessor: $ENTRIES entries, $T3 need Tier 3"
```

如果 `ENTRIES=0` → 退出，没有失败需要处理。

### 3. 对每个条目执行决策

```bash
jq -c '.entries[]' /tmp/triage-input.json | while read -r e; do
  # ... see decision matrix below ...
done
```

对每条 entry，按下表决定动作：

| `existing_issue` | `tier1.matched` | `tier2.confidence` | `needs_tier3` | 我的动作 |
|---|---|---|---|---|
| 非空 | — | — | false | **去重**：在 existing_issue 上 `gh issue comment` 累加，更新 body 里的 `occurrences:` |
| null | true | — | false | **Tier 1 命中**：按 pattern 字段执行（auto_rerun / notify），创建 issue 引用 pattern_id |
| null | false | high | false | **Tier 2 命中**：按 tier2 字段执行 |
| null | false | low/medium | true | **Tier 3 推理**：以下我自己分析 |

#### Tier 1 / Tier 2 直通时的 issue 模板

```bash
REPO_LABEL="repo:$(echo "$REPO" | tr '/' '-')"
gh label create "$REPO_LABEL"        --color ededed --description "Repo facet"      --force >/dev/null
gh label create "fingerprint:$FP"    --color ededed --description "Fingerprint dedup" --force >/dev/null

gh issue create \
  --title "$REPO · $WORKFLOW · $FAILED_STEP failure" \
  --label "evolveci/triage,severity/$SEVERITY,category:$CATEGORY,$REPO_LABEL,fingerprint:$FP" \
  --body "$(cat <<EOF
fingerprint: $FP
occurrences: 1
last_seen: $(date -u +%FT%TZ)
category: $CATEGORY
severity: $SEVERITY
pattern_id: ${PATTERN_ID:-none}
run: $RUN_URL

## 摘要

${SUMMARY:-Tier 1/2 自动分类，详见 fix_hint.}

## 修复建议

${FIX_HINT:-参见对应 evolveci/pattern issue.}

## 脱敏日志摘要

\`\`\`
$REDACTED_TAIL
\`\`\`
EOF
)"
```

#### Tier 3 推理（仅 `needs_tier3=true` 时）

我读 `redacted_tail` 字段，分析：

1. **类别** (flaky / infra / code / dependency / unknown) — 一句话理由
2. **严重度** (info / warning / critical)
3. **根因猜测** — 1-3 句
4. **修复建议** — 可执行步骤
5. （可选）**新 pattern** — 如果这个失败模式可能复现，调用 `/learn-pattern` 写入新的
   `evolveci/pattern` issue。正则必须 ≤200 字符且无嵌套量词。

输出格式见 `prompts/observability/classify-failure-sonnet.md`。然后用上面的 issue 模板写入。

### 4. 重跑（可选）

仅当 `auto_rerun=true` 且失败的 workflow 不含 `deploy/release/security/scan/sign/publish` 关键词，且当日预算未超 (`circuit-config.yml`)：

```bash
gh run rerun "$RUN_ID" --repo "$REPO" --failed
```

超预算 → 调用 `/check-circuit` 让它判断是否需要触发熔断器。

### 5. Slack（可选）

`severity/critical` 或 `category:infra` 且有 `SLACK_WEBHOOK_URL` → 发一条短摘要 + Issue URL。

## 不做什么

- 不写本地文件（`/tmp/triage-input.json` 例外，用完即弃）
- 不 git commit / push
- 不在 prompt 中再次调用 gh run list / 自己解日志 — 用 preprocessor 的输出

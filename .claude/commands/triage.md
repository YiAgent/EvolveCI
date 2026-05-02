# /triage — 实时 CI 故障分诊（基于 Issue 内存模型）

**触发方式**：由 `agent-triage.yml` 每 15 分钟调用，或通过 `workflow_dispatch` 手动触发。

> 内存模型：fingerprints / 已知 patterns / 历史 incidents 都是带 `evolveci/*`
> 标签的 GitHub Issue。详见 `docs/MEMORY-MODEL.md`。

## 执行步骤

### 步骤 1：检查熔断器

读取唯一 `evolveci/circuit` Issue 的 body：

```bash
BODY=$(gh issue list --label evolveci/circuit --state all -L 1 \
        --json body --jq '.[0].body // empty')
ACTIVE=$(echo "$BODY" | jq -r '.active // false')
TRIPPED=$(echo "$BODY" | jq -r '.tripped_at // empty')
```

- `active=true` 且距 `tripped_at` < 24h → 输出警告后退出，不执行任何动作。
- `active=true` 且 ≥ 24h → 自动恢复（编辑 issue body 把 `active` 设为 `false`，
  追加一条 `gh issue comment` 记录恢复时间），然后继续。

### 步骤 2：加载上下文

- `data/onboarded-repos.yml` — 监控仓库列表（仍是文件）。
- 已知 patterns（替换原 `memory/patterns/known-patterns.json`）：每个 pattern
  issue 的 body 是 markdown，机器可读 JSON 嵌在末尾的 \`\`\`json 代码块里。
  用 awk 提取：

  ```bash
  gh issue list --label evolveci/pattern --state all -L 100 \
    --json body --jq '.[].body' | awk '
      /^```json$/ { in_block=1; next }
      /^```$/     { in_block=0; next }
      in_block    { print }
    ' > /tmp/patterns.jsonl
  ```

- 当日重跑计数器：放在内存（无需持久化文件）；超出预算时通过 step 4d 在
  `evolveci/circuit` issue 上记录。

### 步骤 3：查询失败

对每个监控仓库通过 GitHub MCP 查询最近 30 分钟内 `failure` / `timed_out` 的
workflow runs；合并所有仓库结果，按时间倒序排列，**最多取 10 条**处理。

### 步骤 4：逐条分析

对每条失败 run 依次执行：

#### a. 获取日志

通过 GitHub MCP 获取失败步骤的最后 100 行；用
`echo "$LOG" | bash lib/redact-log.sh` 脱敏。

#### b. 生成指纹

```bash
FP=$(printf '%s' "${ERROR_LINES}|${STEP_NAME}" | sha256sum | cut -c1-12)
```

#### c. 去重检查（基于 issue 标签）

```bash
EXISTING=$(gh issue list --label "fingerprint:${FP}" --state open -L 1 \
            --json number --jq '.[0].number // empty')

if [ -n "$EXISTING" ]; then
  # 在已有 issue 上累加
  CURRENT=$(gh issue view "$EXISTING" --json body --jq .body)
  N=$(echo "$CURRENT" | grep -oE '^occurrences: [0-9]+' | head -1 | awk '{print $2}')
  N=$((${N:-1} + 1))
  NEW_BODY=$(echo "$CURRENT" | sed "s/^occurrences: .*$/occurrences: $N/")
  gh issue edit "$EXISTING" --body "$NEW_BODY"
  gh issue comment "$EXISTING" --body "再次发生于 $(date -u +%FT%TZ) — [run]({{run_url}})"
  # 跳到下一条 failure
  continue
fi
```

#### d. Tier 1 — 正则匹配

逐条用 `/tmp/patterns.jsonl` 的 `match` 字段对脱敏日志做正则匹配。
命中 → 使用该 pattern 的 `auto_rerun` / `notify` / `severity` / `category`，
记录 `pattern_id`，跳到步骤 5。

#### e. Tier 2 — 启发式关键词

按 `CLAUDE.md` 中"Tier 2 启发式规则"表格逐条匹配。

#### f. Tier 3 — 深度推理

我用自己的推理能力分析脱敏日志（参考 `prompts/observability/classify-failure-sonnet.md`）。
若发现可复用正则模式，调用 `/learn-pattern` 命令把它写入新的 `evolveci/pattern` Issue。

### 步骤 5：执行动作

根据分类与置信度：

- **flaky** → 自动重跑（受熔断器/预算约束），不建 Issue 通知。
- **infra/code/dependency/unknown** → 在第 4c 步未命中已有 issue 时新建一条：

  ```bash
  REPO_LABEL="repo:$(echo "$REPO" | tr '/' '-')"
  # 自动确保 repo: 标签存在（label create --force 是幂等的）
  gh label create "$REPO_LABEL" --color "ededed" \
    --description "Repo facet" --force >/dev/null

  gh label create "fingerprint:${FP}" --color "ededed" \
    --description "Fingerprint dedup" --force >/dev/null

  gh issue create \
    --title "${REPO} · ${WORKFLOW} · ${STEP} failure" \
    --label "evolveci/triage,severity/${SEVERITY},category:${CATEGORY},${REPO_LABEL},fingerprint:${FP}" \
    --body "$(cat <<EOF
fingerprint: ${FP}
occurrences: 1
last_seen: $(date -u +%FT%TZ)
category: ${CATEGORY}
severity: ${SEVERITY}
pattern_id: ${PATTERN_ID:-none}
run: {{run_url}}

## 摘要

${SUMMARY}

## 根因猜测

${ROOT_CAUSE}

## 修复建议

${FIX_SUGGESTION}

## 脱敏日志摘要

\`\`\`
${REDACTED_TAIL}
\`\`\`
EOF
)"
  ```

### 步骤 6：累计计数（可选 Slack）

`severity/critical` 或 `category:infra` 的告警建议同时发送 Slack 通知（如
`SLACK_WEBHOOK_URL` 存在）。

## 不做什么

- 不写 `memory/incidents/`、`memory/fingerprints/`、`memory/counters/`
- 不 git commit
- 不 push 任何分支

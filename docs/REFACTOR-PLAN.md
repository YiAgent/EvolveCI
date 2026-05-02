# EvolveCI v5.1 重构方案 — "Agent-When-Needed"

> 日期：2026-05-02
> 目标：让闭环跑通、降低 agent 成本、提升 issue 可读性

---

## 一、问题诊断（数据驱动）

### 1.1 Workflow 失败分析

最近 20 次运行中 3 次失败，全部是 agent 问题：

| 失败 | 根因 | 影响 |
|------|------|------|
| Weekly Deep Dive | turn 耗尽（80 轮用完） | 报告没生成 |
| Daily Report ×2 | turn 耗尽（40 轮）+ API socket 断开 | 报告没生成 |

**根因**：agent 同时负责"收集数据"和"写报告"，glm-5.1 在用 gh CLI 逐条查询时浪费大量 turn。

### 1.2 Issue 可读性分析

- 10 个 pattern issue（#18-#27）：纯机器 JSON，无人类摘要
- 0 个 triage issue：闭环从未跑通
- 1 个 daily report（#31）：内容丰富但 200 个 run 压缩在一个 issue 里
- 所有 issue 零评论：没有交互痕迹

### 1.3 记忆模型现状

- `evolveci/pattern` = 10 个 seed，0 个 learned
- `evolveci/triage` = 0 个
- `memory/` 目录 = 只读废弃，但 CLAUDE.md 没明确标注

---

## 二、架构变更：Agent-When-Needed

### 核心思想

```
当前（Agent-First）：
  Agent 做所有事：查数据 → 分析 → 决策 → 执行 → 写报告
  问题：turn 消耗高、不可靠、难 debug

目标（Agent-When-Needed）：
  确定性 pipeline 做 90%：脚本收集数据 → Actions 分类 → 生成结构化 JSON
  Agent 做 10%：解读 JSON → 写人类可读报告 → 学习新 pattern
```

### 2.1 新增：`scripts/collect-triage-data.sh`

**作用**：在 agent 启动前，用脚本完成所有数据收集和预处理，输出结构化 JSON。

```bash
#!/usr/bin/env bash
# collect-triage-data.sh — 确定性数据收集（零 AI 成本）
#
# 输入：data/onboarded-repos.yml
# 输出：/tmp/triage-context.json（agent 直接消费）
#
# 做的事：
#   1. 查询所有监控仓库最近 N 分钟的失败 runs
#   2. 获取失败步骤的日志（最后 100 行）
#   3. 脱敏（redact-log.sh）
#   4. 生成 fingerprint
#   5. 匹配已知 patterns（从 evolveci/pattern issues 读取）
#   6. 启发式分类
#   7. 输出结构化 JSON
#
# Agent 拿到 JSON 后只需要：
#   - 对未分类的失败做 Tier 3 深度分析
#   - 执行动作（创建 issue、重跑）
#   - 学习新 pattern

set -euo pipefail

WINDOW="${1:-30m}"  # 默认查最近 30 分钟
REPOS=$(yq '.repos[].name' data/onboarded-repos.yml | tr '\n' ',')

# Step 1: 查询失败 runs
RUNS=$(gh run list --repo "$repo" --status failure \
  --created ">=${WINDOW}" --json databaseId,name,workflowName,createdAt \
  --limit 10 2>/dev/null || echo "[]")

# Step 2-6: 对每条失败做预处理
# ...（详见下方完整实现）

# Step 7: 输出 JSON
cat /tmp/triage-context.json
```

**输出格式**（`/tmp/triage-context.json`）：

```json
{
  "window": "30m",
  "collected_at": "2026-05-02T03:00:00Z",
  "repos_checked": ["YiAgent/EvolveCI", "YiAgent/OpenCI"],
  "failures": [
    {
      "run_id": "25243111945",
      "repo": "YiAgent/EvolveCI",
      "workflow": "Agent — CI Weekly Deep Dive",
      "failed_step": "Run claude-harness composite",
      "fingerprint": "a1b2c3d4e5f6",
      "log_tail": "...(脱敏后的最后 50 行)...",
      "tier1_match": null,
      "tier2_match": {
        "category": "unknown",
        "confidence": "low",
        "reason": "SDK execution error - no keyword match"
      },
      "existing_issue": null,
      "suggested_action": "tier3_analysis"
    }
  ],
  "summary": {
    "total_failures": 1,
    "tier1_matched": 0,
    "tier2_matched": 1,
    "needs_agent_analysis": 1,
    "existing_issues_found": 0
  }
}
```

### 2.2 新增：`scripts/collect-daily-data.sh`

**作用**：替代 agent 的步骤 1（聚合 24h 数据），输出结构化 JSON。

```bash
#!/usr/bin/env bash
# collect-daily-data.sh — 聚合最近 24h 的 CI 数据
#
# 输出：/tmp/daily-context.json
# 包含：run 总数、成功率、top 失败、triage issue 统计、pattern 统计

set -euo pipefail

TODAY=$(date -u +%Y-%m-%d)
YESTERDAY=$(date -u -d '1 day ago' +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)

# 1. 查询所有仓库的 runs
for repo in $(yq '.repos[].name' data/onboarded-repos.yml); do
  gh run list --repo "$repo" --created ">=24h" \
    --json databaseId,name,workflowName,status,conclusion,createdAt,updatedAt \
    --limit 200
done | jq -s 'add' > /tmp/daily-runs.json

# 2. 计算指标
TOTAL=$(jq length /tmp/daily-runs.json)
SUCCESSES=$(jq '[.[] | select(.conclusion == "success")] | length' /tmp/daily-runs.json)
FAILURES=$(jq '[.[] | select(.conclusion == "failure")] | length' /tmp/daily-runs.json)
RATE=$(echo "scale=1; $SUCCESSES * 100 / $TOTAL" | bc 2>/dev/null || echo "N/A")

# 3. 查询 triage/pattern issues
TRIAGE_OPEN=$(gh issue list --label evolveci/triage --state open --json number | jq length)
TRIAGE_NEW=$(gh issue list --label evolveci/triage --search "created:>$(date -u -d '24 hours ago' +%FT%TZ)" --json number | jq length)
PATTERNS=$(gh issue list --label evolveci/pattern --state all --json number | jq length)

# 4. 输出
jq -nc \
  --arg date "$TODAY" \
  --argjson total "$TOTAL" \
  --argjson success "$SUCCESSES" \
  --argjson failure "$FAILURES" \
  --arg rate "$RATE" \
  --argjson triage_open "$TRIAGE_OPEN" \
  --argjson triage_new "$TRIAGE_NEW" \
  --argjson patterns "$PATTERNS" \
  '{date:$date, runs:{total:$total, success:$success, failure:$failure, rate:$rate},
    triage:{open:$triage_open, new_today:$triage_new}, patterns:$patterns}' \
  > /tmp/daily-context.json
```

### 2.3 修改：`agent-triage.yml`

**变更**：在 agent 启动前先跑数据收集脚本，把结果作为 context 注入。

```yaml
jobs:
  triage:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # Phase 1: 确定性数据收集（零 AI 成本，~30s）
      - name: Collect triage data
        id: data
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          bash scripts/collect-triage-data.sh 30m > /tmp/triage-context.json
          # 把 JSON 内容作为 step output（agent 消费）
          echo "context<<EOF" >> "$GITHUB_OUTPUT"
          cat /tmp/triage-context.json >> "$GITHUB_OUTPUT"
          echo "EOF" >> "$GITHUB_OUTPUT"

      # Phase 2: Agent 只做决策和执行（大幅减少 turn 消耗）
      - name: Agent triage
        uses: YiAgent/OpenCI/.github/workflows/claude-harness.yml@main
        with:
          task: triage
          prompt: |
            /triage
            ---
            DATA_CONTEXT:
            ${{ steps.data.outputs.context }}
          max-turns: 15   # 从 30 降到 15（数据已预处理）
          timeout-minutes: 10
        secrets: inherit
```

### 2.4 修改：`agent-daily.yml`

同理，数据收集脚本化：

```yaml
jobs:
  daily:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Collect daily data
        id: data
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          bash scripts/collect-daily-data.sh > /tmp/daily-context.json
          echo "context<<EOF" >> "$GITHUB_OUTPUT"
          cat /tmp/daily-context.json >> "$GITHUB_OUTPUT"
          echo "EOF" >> "$GITHUB_OUTPUT"

      - name: Agent daily report
        uses: YiAgent/OpenCI/.github/workflows/claude-harness.yml@main
        with:
          task: daily-report
          prompt: |
            /daily-report
            ---
            DATA_CONTEXT:
            ${{ steps.data.outputs.context }}
          max-turns: 20   # 从 60 降到 20
          timeout-minutes: 10
        secrets: inherit
```

### 2.5 修改：`.claude/commands/triage.md`

**变更**：agent 不再自己查数据，只消费预处理好的 JSON。

```markdown
# /triage — 实时 CI 故障分诊

**输入**：workflow 会注入 `DATA_CONTEXT` JSON（由 collect-triage-data.sh 生成）。

## 执行步骤

### 步骤 1：解析输入数据

读取 `DATA_CONTEXT` JSON。它包含：
- `failures[]` — 每条失败的详情（repo、workflow、step、日志、fingerprint）
- `failures[].tier1_match` — 已知 pattern 匹配结果（可能为 null）
- `failures[].tier2_match` — 启发式分类结果
- `failures[].existing_issue` — 是否已有对应 issue
- `summary` — 汇总统计

### 步骤 2：检查熔断器

```bash
BODY=$(gh issue list --label evolveci/circuit --state all -L 1 \
        --json body --jq '.[0].body // empty')
ACTIVE=$(echo "$BODY" | jq -r '.active // false')
```

`active=true` 且距 `tripped_at` < 24h → 输出警告后退出。

### 步骤 3：逐条处理

对 `failures[]` 中每条记录：

#### 已有 pattern 匹配（tier1_match != null）
→ 直接按 pattern 的 auto_rerun/notify/severity 执行。

#### 启发式匹配（tier2_match.confidence == "high"）
→ 按分类执行动作。

#### 需要深度分析（suggested_action == "tier3_analysis"）
→ 用我的推理能力分析 `log_tail`，输出：
  - category + severity
  - root_cause（2-3 句）
  - fix_suggestion
  - 是否可复用为新 pattern（如果是，调用 /learn-pattern）

### 步骤 4：执行动作

- **flaky** → 自动重跑（检查熔断器 + 预算）
- **infra/code/dependency** → 创建 evolveci/triage issue（含人类可读摘要）
- **新 pattern** → 调用 /learn-pattern

### 步骤 5：输出总结

打印本轮处理摘要（X 条失败，Y 条自动重跑，Z 条新建 issue）。
```

### 2.6 修改：`.claude/commands/daily-report.md`

```markdown
# /daily-report — 生成每日 CI 健康报告

**输入**：workflow 会注入 `DATA_CONTEXT` JSON（由 collect-daily-data.sh 生成）。

## ⚠️ 强制契约

每次运行必须以 `gh issue create` 或 `gh issue edit` 结束。

## 执行步骤

### 步骤 1：读取数据

解析 `DATA_CONTEXT` JSON，它包含：
- runs 统计（total, success, failure, rate）
- triage issue 统计（open, new_today）
- pattern 数量

### 步骤 2：检测退化

```bash
PREV=$(gh issue list --label evolveci/daily -L 5 --json number,title,body \
        --jq '.[] | select(.title | startswith("Daily Report — "))')
```

与前一日对比，标出 ≥20% 劣化项。

### 步骤 3：查询当日新增 triage

```bash
gh issue list --label evolveci/triage \
  --search "created:>$(date -u -d '24 hours ago' +%FT%TZ)" \
  --json number,title,labels,body
```

### 步骤 4：生成报告并 upsert issue

使用下方模板渲染，然后：
```bash
TODAY=$(date -u +%Y-%m-%d)
TITLE="Daily Report — ${TODAY}"
EXISTING=$(gh issue list --label evolveci/daily \
            --search "in:title \"${TITLE}\"" -L 1 \
            --json number --jq '.[0].number // empty')
if [ -n "$EXISTING" ]; then
  gh issue edit "$EXISTING" --body "$REPORT_BODY"
else
  gh issue create --title "$TITLE" \
    --label "evolveci/daily,severity/info" --body "$REPORT_BODY"
fi
```

## 报告模板

（保持现有模板不变，但数据来自 JSON 而非实时查询）
```

---

## 三、Issue 可读性改造

### 3.1 Pattern Issue 模板

**当前问题**：pattern issue body 是纯 JSON，人类看不懂。

**修改 `scripts/seed-patterns.sh`**：在 JSON 前加人类可读摘要。

```bash
# 在创建 issue 时，body 格式改为：
BODY="## 模式：${ID}

**一句话说明**：${DESCRIPTION}
**分类**：${CATEGORY} | **严重度**：${SEVERITY}
**自动重跑**：${AUTO_RERUN} | **通知**：${NOTIFY}
**历史出现**：${SEEN_COUNT} 次 | **最近一次**：${LAST_SEEN}

### 匹配规则
\`\`\`
${MATCH_REGEX}
\`\`\`

### 通俗解释
${HUMAN_EXPLANATION}

### 建议操作
${ACTION_SUGGESTION}

---
<details><summary>机器元数据（JSON）</summary>

\`\`\`json
${PATTERN_JSON}
\`\`\`
</details>"
```

**每个 seed pattern 需要补充的字段**（在 `known-patterns.seed.json` 中）：

```json
{
  "id": "npm-eai-again",
  "match": "EAI_AGAIN.*registry\\.npmjs\\.org|ENOTFOUND.*registry\\.npmjs\\.org",
  "category": "flaky",
  "severity": "low",
  "description": "npm 注册表 DNS 解析失败",
  "human_explanation": "npm 官方 registry (registry.npmjs.org) 的 DNS 解析临时失败。通常是网络波动或 DNS 服务器问题，不是代码 bug。",
  "action_suggestion": "自动重跑即可。如果 24h 内出现 ≥3 次，升级为 incident 检查 runner 网络环境。",
  "auto_rerun": true,
  "notify": false,
  "seen_count": 47,
  "last_seen": "2026-04-28",
  "source": "seed"
}
```

### 3.2 Triage Issue 模板

**新建 triage issue 时的 body 格式**：

```markdown
## 🔴 CI 失败：{repo} / {workflow} / {step}

**时间**：{timestamp} UTC
**指纹**：`{fingerprint}`
**出现次数**：1

### 失败摘要
{agent 生成的 2-3 句人类可读分析}

### 日志片段（已脱敏）
```
{最后 30 行关键日志}
```

### 分类
- **类别**：{category}
- **严重度**：{severity}
- **建议操作**：{fix_suggestion}

### 关联
- Workflow run：[链接]
- 匹配 pattern：{pattern_id 或 "无"}

---
<details><summary>技术详情</summary>

- fingerprint: {fp}
- tier1_match: {result}
- tier2_match: {result}
- tier3_analysis: {result}
</details>
```

---

## 四、记忆模型清理

### 4.1 删除废弃的 memory/ 目录

```bash
# 在一个清理 PR 中删除
git rm -r memory/
```

### 4.2 更新 CLAUDE.md

在"记忆 / 状态规则"部分添加：

```markdown
- **`memory/` 目录已完全废弃**。该目录是 v3/v4 时代的遗留，所有文件均为只读历史。
  任何代码都不应读取 `memory/` 下的文件。如果 agent 在运行时发现需要读 `memory/`，
  说明配置有误——请检查 `docs/MEMORY-MODEL.md`。
```

### 4.3 简化 CLAUDE.md 的 agent 上下文

**当前问题**：CLAUDE.md 有 105 行，agent 每次启动都要读全部，但大部分 workflow 只需要其中一小部分。

**方案**：保持 CLAUDE.md 为核心身份 + 安全规则，把 workflow-specific 的细节移回各自的 slash command。

具体来说，从 CLAUDE.md 中移除：
- "Tier 2 启发式规则"表格 → 已在 classify-heuristic action 中实现，agent 不需要重复
- "快速参考" section → agent 通过 DATA_CONTEXT 获取数据，不需要手动查

---

## 五、实施计划

### Phase 1：让闭环跑通（1-2 天）

| # | 任务 | 文件 | 优先级 |
|---|------|------|--------|
| 1.1 | 加入 aicert 到 onboarded-repos.yml | `data/onboarded-repos.yml` | P0 |
| 1.2 | 实现 `collect-triage-data.sh` | `scripts/collect-triage-data.sh` (新建) | P0 |
| 1.3 | 修改 `agent-triage.yml` 注入数据 | `.github/workflows/agent-triage.yml` | P0 |
| 1.4 | 精简 `triage.md` 为数据消费模式 | `.claude/commands/triage.md` | P0 |
| 1.5 | 手动触发验证闭环 | - | P0 |

### Phase 2：日报 + 可读性（2-3 天）

| # | 任务 | 文件 | 优先级 |
|---|------|------|--------|
| 2.1 | 实现 `collect-daily-data.sh` | `scripts/collect-daily-data.sh` (新建) | P1 |
| 2.2 | 修改 `agent-daily.yml` 注入数据 | `.github/workflows/agent-daily.yml` | P1 |
| 2.3 | 精简 `daily-report.md` | `.claude/commands/daily-report.md` | P1 |
| 2.4 | 给 seed pattern 加人类可读字段 | `data/known-patterns.seed.json` | P1 |
| 2.5 | 修改 seed-patterns.sh 支持新格式 | `scripts/seed-patterns.sh` | P1 |
| 2.6 | 清理现有 pattern issues | 手动或脚本 | P1 |

### Phase 3：清理 + 优化（1 天）

| # | 任务 | 文件 | 优先级 |
|---|------|------|--------|
| 3.1 | 删除 memory/ 目录 | `memory/` | P2 |
| 3.2 | 精简 CLAUDE.md | `CLAUDE.md` | P2 |
| 3.3 | 更新 MEMORY-MODEL.md 文档 | `docs/MEMORY-MODEL.md` | P2 |
| 3.4 | 调整 turn 预算（triage: 15, daily: 20） | workflow YAMLs | P2 |

### Phase 4：自进化闭环（后续）

| # | 任务 | 说明 |
|---|------|------|
| 4.1 | 监控 tier3 分类结果 | 观察 agent 是否能发现可复用 pattern |
| 4.2 | 优化 learn-pattern 流程 | 确保新 pattern 能被 tier1 匹配 |
| 4.3 | 周报脚本化 | collect-weekly-data.sh |

---

## 六、预期效果

| 指标 | 当前 | Phase 1 后 | Phase 2 后 |
|------|------|-----------|-----------|
| triage 闭环 | ❌ 从未跑通 | ✅ 能处理真实失败 | ✅ |
| triage issue 数 | 0 | ≥1 | 持续增长 |
| daily report 成功率 | ~50% | - | ≥90% |
| agent turn 消耗（triage） | 30（经常耗尽） | ~10 | ~10 |
| agent turn 消耗（daily） | 60（经常耗尽） | - | ~15 |
| issue 可读性 | 纯机器 JSON | - | 人类可读 + 机器元数据 |
| 每次运行 AI 成本 | ~$0.01-0.05 | ~$0.003 | ~$0.003 |

---

## 七、风险和缓解

| 风险 | 概率 | 缓解 |
|------|------|------|
| collect-triage-data.sh 查询超时 | 中 | 加 timeout + 错误处理，超时返回空 JSON |
| glm-5.1 不理解注入的 JSON | 低 | JSON 格式简单，prompt 中明确说明字段含义 |
| onboarded-repos 加入 aicert 后 issue 暴增 | 低 | 先只监控 test.yml，排除 agent workflows |
| 现有 pattern issue 格式迁移 | 中 | 写一个迁移脚本批量更新 body |

# EvolveCI v5.1 重构方案 — Agent-When-Needed

> 日期：2026-05-02
> 状态：实施中（PR #39 — 合并自 PR #38）
> 目标：让闭环跑通、降低 agent turn 消耗、提升 issue 可读性、删除遗留 memory/

---

## 一、问题诊断（数据驱动）

### 1.1 Workflow 失败现状

最近 24h 内 142 条真实失败（35 EvolveCI / 83 OpenCI / 24 aicert），但
`evolveci/triage` issue 数 = 0；闭环从未跑通过一次。Agent workflow 自身也在失败：

| 失败 | 根因 | 影响 |
|------|------|------|
| Weekly Deep Dive | turn 耗尽（80 / 120 轮） | 报告没生成 |
| Daily Report ×N | turn 耗尽（40-60 轮）+ socket 断开 | 报告没生成 |
| Triage | 完成但写出 0 issue（数据查询路径有 bug） | 闭环断了 |

**根因**：agent 同时负责"收集数据"和"决策/写作"。glm-5.1 在用 gh CLI
逐条查询时浪费大量 turn，prompt 加 CLAUDE.md 长度也让模型迷失。

### 1.2 Issue 可读性

- 10 个 pattern issue (#18-#27)：纯机器 JSON、无人类摘要、无修复建议
- 0 个 triage issue：闭环从未跑通
- 1 个 daily report (#31)：内容丰富但所有数据塞在一个 issue 里
- 所有 issue 零评论：没有交互痕迹

### 1.3 记忆模型现状

- `evolveci/pattern` = 10 个 seed，0 个 learned
- `evolveci/triage` = 0 个
- `memory/` 目录 = 应在 v5.0 删除但仍存在

---

## 二、架构变更：Agent-When-Needed

### 核心思想

```
当前 (Agent-First)
  Agent 做所有事：查数据 → 分析 → 决策 → 执行 → 写报告
  问题：turn 消耗高、不可靠、难 debug

v5.1 (Agent-When-Needed)
  确定性 pipeline 做 90%：
    脚本/composite action 收集数据 → Tier 1 regex → Tier 2 启发式 →
    生成结构化 JSON
  Agent 做 10%：
    解读 JSON → Tier 3 推理 → 写人类可读报告 → 学习新 pattern
```

### 数据流（DATA_CONTEXT injection）

每个 agent workflow 现在是两个 job：

```yaml
jobs:
  collect:           # 确定性步骤：~30s，零 LLM
    runs-on: ubuntu-latest
    outputs: {context: ${{ steps.data.outputs.context }}}
    steps:
      - python3 scripts/build-triage-input.py --out /tmp/x.json
      - echo "context<<EOF\n$(cat /tmp/x.json)\nEOF" >> $GITHUB_OUTPUT
  triage:            # agent 步骤：消费 collect 的 JSON
    needs: collect
    uses: ./.github/workflows/_call-harness.yml
    with:
      prompt: |-
        /triage
        ---
        DATA_CONTEXT:
        ${{ needs.collect.outputs.context }}
```

agent 在它的 prompt body 里看到 `DATA_CONTEXT:` 后面的 JSON，用 `sed +
jq` 解析后做决策。**它不会 install pyyaml、不会跑 python script、不会
调 gh run list**。

---

## 三、文件清单（v5.1 终态）

### 新增（11 个）

| 文件 | 作用 |
|------|------|
| `scripts/build-triage-input.py` | triage 数据收集 (Tier1+Tier2)，输出 triage-input.json |
| `scripts/collect-daily.py` | 24h 聚合 + top3 失败日志 + 前一份 daily |
| `scripts/collect-weekly.py` | 7d 聚合 + DORA + MTTR p50/p95 + by-day |
| `scripts/triage-dry-run.sh` | 诊断：打印 triage *会看到*的失败，不写 issue |
| `scripts/refresh-pattern-descriptions.sh` | 一次性：用最新 seed 字段刷新 evolveci/pattern issue body |
| `.github/ISSUE_TEMPLATE/evolveci-triage.yml` | 结构化 triage issue 模板 |
| `.github/ISSUE_TEMPLATE/evolveci-pattern.yml` | 结构化 pattern issue 模板 |
| `tests/agent-prompts.bats` | 守护契约：禁止 agent prompt 中再出现 gh run list |
| `docs/REFACTOR-PLAN.md` | 本文件 |
| docs/SPEC.md §20 | 文档化 v5.1 契约 + JSON schema |

### 修改（核心）

| 文件 | 变更 |
|------|------|
| `.github/workflows/agent-{triage,daily,weekly}.yml` | 新增 collect job → 注入 DATA_CONTEXT；turn 大幅下调 |
| `.github/workflows/agent-heartbeat.yml` | turn 25→15 |
| `.claude/commands/triage.md` | 不再查 gh，从 prompt 中解析 DATA_CONTEXT JSON |
| `.claude/commands/daily-report.md` | 同上 |
| `.claude/commands/weekly-report.md` | 同上 |
| `CLAUDE.md` | 113→53 行；移除 Tier 2 表格、quick-reference |
| `data/known-patterns.seed.json` | 每条 pattern 加 description / human_explanation / action_suggestion |
| `data/onboarded-repos.yml` | 加入 YiAgent/aicert（priority high, private:true） |
| `scripts/render-pattern.sh` | 渲染新 3 字段 |
| `actions/observability/publishers/trip-circuit-breaker/action.yml` | 不再写 memory/circuit/state.json，改为 upsert evolveci/circuit issue |
| `tests/run-tests.sh` | seed schema 检查替代 memory/ 存在性检查 |

### 删除

- `memory/` 整个目录（v5.0 已宣布废弃，v5.1 实际删除）

---

## 四、Turn 预算变化

| Workflow | 旧 max-turns | 新 max-turns | 原因 |
|----------|------------|------------|------|
| triage | 30 | 15 | 数据已预处理，agent 只处理 needs_tier3 条目 |
| daily | 60 | 20 | DATA_CONTEXT 已含 totals + top3 + prev_daily |
| weekly | 120 | 30 | DATA_CONTEXT 已含 DORA + MTTR + by-day |
| heartbeat | 25 | 15 | 5 个小 gh 查询 + 1 次 issue upsert |

---

## 五、契约（写入 docs/SPEC.md §20）

1. **数据收集与 agent 决策严格分离**。任何 `gh run list` / `gh api repos/.../actions`
   / `mcp__github_ci__*` 必须从 preprocessor 脚本发出，**不能**出现在
   `.claude/commands/*.md` 的 ` ```bash ` fenced block 里。
2. **新 analyzer 优先进 composite action 或 collector 脚本**，再考虑 agent prompt。
3. **Tier 1 / Tier 2 不调用 LLM**；Tier 3 LLM 调用必须配 `max-turns` 上限。
4. **JSON schema 三件套**：`triage-input.json` / `daily-stats.json` / `weekly-stats.json`
   字段在 SPEC.md §20.3-20.5 固化，agent prompt 直接引用字段名。

---

## 六、Issue 可读性改造

### Pattern Issue (3 字段)

每个 `evolveci/pattern` issue body 里有 3 段中文 + 1 段 JSON：

- **`description`** — 一句话标签（如"npm 注册表 DNS 解析失败"）
- **`human_explanation`** — 多句通俗解释（"为什么会发生 / 在什么场景下 / 不是代码 bug"）
- **`action_suggestion`** — 可执行步骤（"重跑 + 长期方案"）
- ` ```json` 块 — triage 通过 awk 抽取此块做正则匹配

`scripts/render-pattern.sh` 渲染时按此 4 段输出；triage 解析依然只读 JSON 块。

### Triage Issue

每条 triage issue body 里：

```markdown
## 🔴 CI 失败：{repo} / {workflow} / {failed_step}

**时间**: {timestamp}
**指纹**: `{fingerprint}`
**Run**: {url}

### 失败摘要
{Tier 1/2/3 给出的 1-2 句中文}

### 修复建议
{action_suggestion 或 agent 推断}

### 脱敏日志摘要
```
{最后 50 行}
```

---
fingerprint: {fp}
occurrences: 1
last_seen: {ts}
category: {cat}
severity: {sev}
pattern_id: {pid|none}
```

`.github/ISSUE_TEMPLATE/evolveci-triage.yml` 强制此结构。

---

## 七、记忆模型清理

- `git rm -r memory/`
- 删除 CLAUDE.md / scripts / commands 中所有 `memory/` 引用（保留版本历史里的）
- `actions/observability/publishers/trip-circuit-breaker` 不再写
  `memory/circuit/state.json`，改为 upsert `evolveci/circuit` issue
- README 重写为 v5.x 描述

---

## 八、与 PR #38 的合并

PR #38 引入了 DATA_CONTEXT injection 范式 + 3 字段 pattern schema +
top3_with_logs / prev_daily 增强；本 PR 在此基础上补全：

- 用 Python 重写 collectors（取代 PR 38 的 bash 版本，更可维护、易扩展周报）
- 加上 weekly + heartbeat 处理
- 加上 issue 模板 / lint / SPEC §20 契约 / memory/ 删除 / triage-dry-run 诊断
- 修正 trip-circuit-breaker 残留的 memory/ 写入

PR #38 的 `scripts/collect-{daily,triage}-data.sh` 由 Python 等价物替代后
不再保留。

---

## 九、验收

1. **闭环跑通** — `gh issue list -R YiAgent/EvolveCI --label evolveci/triage` ≥1 条，含 fingerprint label，重复触发同一失败时 occurrences 增加而不重复开 issue。
2. **Turn 预算** — `gh workflow run agent-daily.yml` / agent-weekly.yml 完成时 conclusion=success，不出现 `Reached maximum number of turns`。
3. **Lint** — `bash tests/run-tests.sh` 60+ 全过；`tests/agent-prompts.bats` 在 commands 中重新引入 `gh run list` 时失败。
4. **Issue 可读性** — `gh issue view 18` 看到 `## 通俗解释` + `## 修复建议（具体步骤）` 都有内容。

---

## 十、后续（v6 范围，本 PR 不实施）

- 自动学习新 pattern 从 Tier 3 输出 → 直接 `/learn-pattern`
- 跨仓 workflow_run trigger 替代 cron pull
- DORA dashboard（数据已在 weekly-stats.json，需要可视化）

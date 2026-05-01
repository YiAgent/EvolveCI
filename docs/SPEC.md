# EvolveCI — CI 控制塔功能规格（SPEC）

**版本**：v2.1（功能规格版，剥离实现代码）
**定位**：独立 meta-repo，观察所有仓库的 CI 流水线，主动汇报 + 实时分诊
**与 OpenCI 关系**：EvolveCI 消费 OpenCI 的 `claude-harness`（workflow 级别调用），不复制其功能

> 本文档只描述**功能、契约、行为**，不包含具体 YAML 实现。每个组件的实现由对应任务在落地阶段完成；本 SPEC 提供可拆解任务的边界。

---

## 变更日志

| 版本 | 日期 | 变更 |
|------|------|------|
| v2.1 | 2026-05-01 | 拆分独立仓库；剥离所有 YAML/bash 实现细节，改为功能契约描述 |
| v2.0 | 2026-05-01 | 完整重构：四层架构、AI 调用提升到 workflow 级别、JSON 替代 YAML 解析、日志脱敏、`_state` 孤儿分支、成本飞轮 |
| v1.0 | 2026-04-XX | 初始版本：三层架构 + 实时分诊 + 自动重跑 + 每日报告 |

---

## 一、设计原则

### 1.1 四层分离

| 层 | 职责 | AI 用量 | 运行频率 |
|---|---|---|---|
| **Sources** | 拉数据（gh CLI / curl） | 零 | 每 15 分钟 / 每日 |
| **Analyzers** | 规则匹配 + 轻量 AI | Haiku $0.001/次，Sonnet $0.01/次 | 每次失败 |
| **State** | 双层持久化（cache + git） | 零 | 每次写入 |
| **Publishers** | 输出（Issue / Slack / rerun） | 零 | 每次需要 |

**关键约束**：90% 的失败在 Analyzers 层被规则拦截（Tier 1 + Tier 2），不调 AI。

### 1.2 状态外部化

所有跨 run 共享的状态（throttle 计数、重跑记录、健康趋势）存储在 `_state` 孤儿分支，不污染 main。Git 历史 = 时间序列数据库。GitHub Actions Cache 作为快速读取层。

### 1.3 安全默认

- 跨 repo 访问用 fine-grained PAT，只授权 `actions:read` + `metadata:read`
- 不需要目标仓库做任何配置变更
- auto-rerun 仅限只读操作（test/lint/build），永不重跑 deploy/security workflow
- 失败日志在传给 AI 前必须脱敏（移除 token、密码、内部 IP）
- 每个 job 第一步加载 `harden-runner`
- 所有第三方 action SHA 固定，通过 `manifest.yml` 集中管理

### 1.4 复用 OpenCI

- AI 调用在 **workflow 级别** 使用 `claude-harness.yml`（reusable workflow），不在 composite action 内部调用
- Slack 通知复用 `your-org/openCI/actions/integrations/slack-notify@v2`
- 第三方 SHA 对齐 OpenCI 的 `manifest.yml`

---

## 二、目录结构

```
evolveCI/
├── .github/
│   └── workflows/
│       ├── triage-failure.yml        # 实时分诊（每 15 分钟扫描）
│       ├── health-ci-daily.yml       # 每日 CI 健康汇总
│       ├── health-ci-weekly.yml      # 每周深度分析
│       └── heartbeat.yml             # 自监控心跳（每 6 小时）
│
├── actions/
│   ├── observability/
│   │   ├── sources/                  # 数据源：只负责"拉"
│   │   │   └── query-github-actions/ # CI 运行数据 → JSON（封装 gh CLI）
│   │   │
│   │   ├── analyzers/                # 分析器：纯计算，零 IO（除 state 读）
│   │   │   ├── match-known-patterns/ # 正则模式匹配（$0，Tier 1）
│   │   │   ├── classify-heuristic/   # 启发式关键词匹配（$0，Tier 2）
│   │   │   ├── classify-ai/          # AI 上下文准备 + 输出解析（Haiku/Sonnet）
│   │   │   ├── compute-flakiness/    # Flaky 度滑动窗口计算
│   │   │   ├── compute-mttr/         # 平均故障恢复时长
│   │   │   └── compute-trends/       # DORA 指标 + 趋势检测
│   │   │
│   │   ├── state/                    # 持久化基础设施
│   │   │   ├── read-state/           # cache 快速路径 + _state 分支回源
│   │   │   ├── write-state/          # _state 分支写入（retry 3 次）+ cache 回填
│   │   │   └── redact-log/           # 日志脱敏（移除敏感信息）
│   │   │
│   │   └── publishers/               # 输出渠道
│   │       ├── post-issue-report/    # 封装 peter-evans/create-issue-from-file
│   │       ├── post-slack-report/    # 复用 OpenCI slack-notify
│   │       ├── auto-rerun/           # gh run rerun --failed + 预算检查
│   │       └── trip-circuit-breaker/ # 熔断告警：gh issue + Slack
│
├── prompts/
│   └── observability/
│       ├── classify-failure-haiku.md    # Tier 3 失败分类（Haiku）
│       ├── classify-failure-sonnet.md   # Tier 4 深度分析（Sonnet）
│       ├── daily-report.md              # 每日报告（Haiku）
│       └── weekly-deep-dive.md          # 每周深度（Sonnet）
│
├── data/                             # 配置文件（main 分支，仅人工编辑）
│   ├── onboarded-repos.yml           # 被监控仓库列表及配置
│   └── circuit-config.yml            # 熔断器配置（维度、阈值、排除列表）
│
├── lib/                              # 2+ action 共用脚本
│   └── redact-log.sh                 # 日志脱敏正则集
│
└── manifest.yml                      # 第三方依赖 SHA（对齐 OpenCI）
```

### 关键说明

- `data/` 目录只存放**配置**（人工编辑），运行时**状态**存放在 `_state` 孤儿分支
- `lib/redact-log.sh` 被 `redact-log` action 和 `classify-ai` 共用
- AI prompt 按 Tier 分文件，与 action 分离（变化频率决定位置）

---

## 三、数据源层（Sources）— 零 AI 成本

### 3.1 query-github-actions

**职责**：列举多个 repo 在时间窗口内的 workflow runs，可选拉取失败 job 的日志摘要。

**输入契约**

| 字段 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `repos` | ✓ | — | 逗号分隔的 `org/repo` 列表 |
| `since` | ✓ | — | 时间窗口，如 `30m` / `24h` / `7d` |
| `status` | ✗ | `all` | `all` \| `failure` \| `success` |
| `include-logs` | ✗ | `false` | 是否抓取失败 job 日志（额外 API 消耗） |
| `log-tail` | ✗ | `100` | 每条失败抓取的日志末尾行数 |
| `token` | ✓ | — | fine-grained PAT，需 `actions:read` |

**输出契约**

| 字段 | 类型 | 说明 |
|---|---|---|
| `runs` | JSON 数组 | 每个 run 含 `databaseId`、`name`、`conclusion`、`createdAt`、`updatedAt`、`event`、`headBranch`、`headSha`、`actor`、`workflowName`、`repo`；当 `include-logs=true` 且 `conclusion=failure` 时附加 `log_base64` 与 `failed_jobs[]` |
| `count` | int | 总 run 数 |
| `failure-count` | int | 失败 run 数 |

**行为要点**
1. 对每个 repo 调用 `gh run list` 抓 runs，限制 ≤100 条
2. 给每条 run 注入 `repo` 字段（gh CLI 不会自带）
3. 按 `status` 过滤
4. 当 `include-logs=true`：对每条失败 run 抓 `gh run view --log-failed` 末尾 N 行（base64 编码）+ `failed_jobs`（仅失败 step 名）
5. 输出经 `EOF` heredoc 写入 `$GITHUB_OUTPUT`，避免 JSON 特殊字符破坏

**性能与配额约束**
- 每 repo 上限 100 条 run
- `include-logs=true` 每个失败 run 额外消耗 2 次 API（仅在 triage 时启用）
- 5 个 repo × 100 条 = 500 条，远低于 GitHub API 5000 次/小时

**任务粒度**：单个 composite action。验收：手动触发，对真实仓库返回非空 JSON 数组且字段齐全。

---

## 四、分析层（Analyzers）

### 4.1 四层递进分类

| Tier | Action | 方法 | 成本 | 预期命中率 |
|---|---|---|---|---|
| 1 | `match-known-patterns` | 正则/字符串匹配（JSON + jq） | $0 | 70% |
| 2 | `classify-heuristic` | 关键词启发式规则 | $0 | 20% |
| 3 | `classify-ai`（Haiku） | AI 分类 | ~$0.001/次 | 8% |
| 4 | `classify-ai`（Sonnet） | AI 深度分析 | ~$0.01/次 | 2% |

**分类流程**

```
失败 run 日志
  ▼
Tier 1: match-known-patterns      ← _state:known-patterns.json
  $0 · ~10ms · 命中即返回
  ▼ miss
Tier 2: classify-heuristic
  $0 · ~50ms · 高置信度即返回
  ▼ low confidence
Tier 3: classify-ai (Haiku)       ← prompts/observability/classify-failure-haiku.md
  ~$0.001 · 日志末 50 行 + 元数据
  → 新 pattern 自动 PR 进 known-patterns
  ▼ unable to classify
Tier 4: classify-ai (Sonnet)      ← prompts/observability/classify-failure-sonnet.md
  ~$0.01 · 完整日志 + 历史上下文
  → category + 修复建议 + 根因分析
```

> **架构铁律**：AI 调用**不在 composite action 内部**执行。`classify-ai` action 只负责**准备输入 + 解析输出**；实际 AI 调用在 workflow 的 `claude-harness` job（reusable workflow）中进行。

### 4.2 match-known-patterns（Tier 1）

**职责**：将日志与 `_state/known-patterns.json` 中的正则数组逐条 grep，命中第一条即返回。

**数据格式**（JSON，避免 bash 手写 YAML 解析的脆弱性）

```json
[
  {
    "id": "npm-eai-again",
    "match": "EAI_AGAIN.*registry\\.npmjs\\.org|ENOTFOUND.*registry\\.npmjs\\.org",
    "category": "flaky",
    "auto_rerun": true,
    "notify": false,
    "severity": "low",
    "seen_count": 47,
    "last_seen": "2026-04-28",
    "source": "seed"
  }
]
```

**输入**：`log`（明文，已脱敏）、`patterns-path`（默认 `known-patterns.json`）。
**输出**：`matched`（bool）、`pattern-id`、`category`、`auto-rerun`、`notify`、`severity`。

**行为**
1. patterns 文件不存在或日志为空 → `matched=false`，立即退出
2. 用 `jq -c '.[]'` 流式遍历，对每个 entry 的 `.match` 调 `grep -qE` 测试日志
3. 第一条命中即写出该条全部字段并退出
4. 全部 miss → `matched=false`

**ReDoS 安全**：写入新 pattern 时（来自 Tier 3 学习）必须长度 ≤200，且禁止嵌套量词模式（`(.*)+` 等）；详见 §7.1 `Learn new pattern` 步骤。

### 4.3 classify-heuristic（Tier 2）

**职责**：纯关键词匹配，对常见失败类型快速归类。零 AI、零状态。

**输入**：`log`、`failed-step`（可选）、`flakiness-score`（默认 0）。
**输出**：`classified`（bool）、`category`、`severity`、`confidence`、`should-rerun`、`should-notify`。

**规则集**（按优先级，第一条命中即返回；`category` 取值见 §4.5）

| 关键词模式 | category | severity | confidence | should-rerun | should-notify |
|---|---|---|---|---|---|
| `ECONNREFUSED` / `ENOTFOUND` / `EAI_AGAIN` / `ETIMEDOUT` / `ReadTimeoutError` / `context deadline exceeded` | flaky | low | high | true | false |
| `rate.?limit` / `429` / `too many requests` / `toomanyrequests` | flaky | low | high | true | false |
| `runner.*did not connect` / `runner.*failed to start` / `No space left on device` | flaky | medium | medium | true | false |
| `Permission denied` / `403 Forbidden` / `authentication failed` / `unauthorized` | security | high | high | false | true |
| `npm ERR!` / `pip install.*error` / `go:.*module.*not found` / `resolve.*version.*conflict` | dependency | medium | medium | false | true |
| `FAIL` / `AssertionError` / `SyntaxError` / `TypeError` / `Compilation failed` / `Test failed` | code | medium | medium | false | true |
| `docker.*daemon` / `OOM` / `Cannot allocate memory` / `CrashLoopBackOff` / `ImagePullBackOff` | infra | high | medium | false | true |

**置信度降级**：若 `flakiness-score > 50` 且分类非 `flaky`，强制 `confidence=low`（交给 AI 兜底）。

**默认值**（无规则命中）：`category=unknown, severity=medium, confidence=low, should-rerun=false, should-notify=true`。

### 4.4 classify-ai（Tier 3 / Tier 4 — 准备 + 解析）

**职责**：为 AI 调用准备结构化上下文 + 选择 prompt 与 model。**不调用 AI**。

**输入**：`log`（已脱敏）、`workflow-name`、`failed-step`、`flakiness-score`、`repo`、`run-id`、`tier`（`3`=Haiku 默认，`4`=Sonnet）。
**输出**：`context`（JSON 字符串，传给 `claude-harness`）、`prompt-path`、`model`。

**行为**
1. 根据 `tier` 选择 prompt 与 model：
   - tier=3 → `prompts/observability/classify-failure-haiku.md`，model `claude-haiku-4-5-20251001`，日志取末 50 行（≤8192 chars）
   - tier=4 → `prompts/observability/classify-failure-sonnet.md`，model `claude-sonnet-4-20250514`，完整日志（≤32768 chars）
2. 构造 JSON：`{ workflow_name, failed_step, flakiness_score, repo, run_id, log_tail }`（`log_tail` 用 `jq -Rs .` 转义）
3. 输出 `context` 给后续 `uses: your-org/openCI/.github/workflows/claude-harness.yml@v2`

**调用约定**：上层 workflow 使用 `with: { task, prompt-path, model, max-turns: 1, context }`。AI 输出 JSON 由 dispatch 步骤解析。

### 4.5 classify-failure prompt（Tier 3 Haiku）

```markdown
你是 CI 流水线分诊助手。看一段 GitHub Actions 失败日志，判断失败类型。

输入：
- workflow: {{workflow_name}}
- 失败 step: {{failed_step}}
- 历史失败率: {{flakiness_score}}%（过去 20 次中失败比例）
- 日志末尾：
{{log_tail}}

严格输出 JSON，不要输出其他内容：
{
  "category": "flaky | infra | code | dependency | security | unknown",
  "severity": "low | medium | high | critical",
  "summary": "15字以内总结",
  "should_notify": true/false,
  "should_rerun": true/false,
  "matched_pattern": "用正则能匹配的失败签名，如 'ECONNREFUSED.*registry.npmjs.org'"
}

分类规则：
- flaky: 网络超时、registry 5xx、runner 启动失败、资源竞争（竞态条件测试）
- infra: K8s 资源不足、runner 磁盘满、Docker daemon 挂了
- code: 测试断言失败、编译错误、lint 错误
- dependency: npm/pip/go mod 安装失败、版本冲突、lockfile 不一致
- security: secret 泄漏、权限拒绝、恶意 action 检测
- unknown: 看不出来

通知规则：
- flaky + low severity → should_notify=false
- security 任何级别 → should_notify=true, severity 至少 high
- 其他 → should_notify=true

重跑规则：
- 只有 category=flaky 才 should_rerun=true
- 其他一律 false

matched_pattern 规则：
- 提取日志中最能唯一标识该失败的字符串模式
- 用正则表达式表示，确保下次能 grep -E 匹配
- 如果无法提取有效模式，返回空字符串
```

### 4.6 classify-failure prompt（Tier 4 Sonnet）

```markdown
你是资深 CI/CD 工程师。一段 GitHub Actions 失败日志经过规则匹配和 Haiku 分类后仍无法确定根因。请进行深度分析。

输入：
- workflow: {{workflow_name}}
- 失败 step: {{failed_step}}
- 历史失败率: {{flakiness_score}}%
- 仓库: {{repo}}
- 完整日志（已脱敏）：
{{log_tail}}

输出严格 JSON：
{
  "category": "flaky | infra | code | dependency | security | unknown",
  "severity": "low | medium | high | critical",
  "summary": "一句话总结",
  "root_cause": "根因分析（2-3 句）",
  "fix_suggestion": "具体修复建议",
  "should_notify": true/false,
  "should_rerun": true/false,
  "matched_pattern": "可复用的失败签名正则"
}
```

### 4.7 compute-flakiness

**职责**：基于最近 N 次 run 计算 `failed/total*100` 作为 flakiness score。

**输入**：`repo`、`workflow-name`、`lookback`（默认 20）、`token`。
**输出**：`flakiness-score`（0–100）、`total-runs`、`failed-runs`、`recent-conclusions`（最近 5 次 conclusion 数组）。

**行为**：调 `gh run list --workflow ... --limit N --json conclusion`；total=0 时 score=0；否则 `floor(failed*100/total)`。

### 4.8 compute-mttr

**职责**：计算 workflow 的平均故障恢复时间（分钟）。

**输入**：`repo`、`workflow-name`、`lookback`（默认 50）、`token`。
**输出**：`mttr-minutes`、`recovery-count`。

**行为**
1. 拉最近 N 条 run，按 `createdAt` 升序
2. 找所有相邻 `failure → success` 配对
3. 计算每对时间差（分钟），取均值
4. 无配对 → `mttr=0, recoveries=0`

### 4.9 compute-trends

**职责**：基于 `_state/workflow-health/*.json` 的历史快照计算趋势 + 占位 DORA 指标。

**输入**：`repo`、`workflow-name`（可选）、`lookback-days`（默认 30）、`current-health-data`（JSON）、`token`。
**输出**：`trend`（`improving` \| `stable` \| `degrading`）、`delta`（百分点）、`dora-section`（markdown 占位）。

**行为**
1. 从 `current-health-data.daily` 提取最近 7 天均值 `CURRENT` 与 14–7 天前均值 `PREVIOUS`
2. `delta = CURRENT - PREVIOUS`
3. `delta > 10` → degrading；`delta < -10` → improving；否则 stable
4. DORA 三件套（部署频率 / 变更前置时间 / 变更失败率 / MTTR）由 workflow 层调 `DeveloperMetrics/*` actions，本 action 仅占位拼接

---

## 五、状态层（State）

### 5.1 双层持久化架构

```
┌─────────────────────────────────────────┐
│           GitHub Actions Cache          │  快速层（毫秒级读取）
│  key: ci-obs:{type}:{scope}:{date}      │  TTL: 7 天未访问自动驱逐
│  内容: 可重建的临时状态                  │  (计数器、dedup 锁)
└──────────────┬──────────────────────────┘
               │ cache miss → 回源
               ▼
┌─────────────────────────────────────────┐
│           _state 孤儿分支                │  持久层（秒级读取）
│  与 main 无共享历史，不触发 CI           │  append-only，长期累积
│  内容: known-patterns / 健康快照 / 计数器│
└─────────────────────────────────────────┘
```

**`_state` 分支结构**

```
_state/
├── known-patterns.json        # 已知失败模式库（AI 自动 PR，人工审核）
├── circuit-breaker-state.json # 活跃熔断状态
├── daily-counters/
│   └── 2026-05-01.json       # 当日重跑/分诊计数
├── workflow-health/
│   └── org-repo-workflow.json # 各 workflow 30 天健康度
└── weekly-snapshots/
    └── 2026-W18.json         # 周级聚合快照
```

**初始化**（手动一次性执行）

```bash
git checkout --orphan _state
git rm -rf .
git commit --allow-empty -m "init: CI observability state branch"
git push origin _state
```

### 5.2 read-state

**职责**：先查 cache，miss 时回源 `_state` 分支并回填 cache。

**输入**：`key`（如 `retries:org/repo:2026-04-30`）、`state-path`（如 `daily-counters/2026-04-30.json`）、`default`（默认 `{}`）。
**输出**：`hit`（bool）、`value`（JSON 字符串）。

**行为**
1. 检查 `.state-cache/data.json` 是否存在 → 存在则 `hit=true`，直接返回
2. 否则 `git fetch origin _state` + `git show origin/_state:<state-path>`
3. 取到值则回填 `.state-cache/data.json`，`hit=true`
4. 取不到则返回 `default`，`hit=false`

### 5.3 write-state

**职责**：双写——本地 cache（快速）+ `_state` 分支（持久），分支写入带 retry。

**输入**：`key`、`state-path`、`value`（JSON）、`merge`（默认 true）。
**输出**：无（副作用：cache 文件 + `_state` 分支 commit）。

**行为**
1. 写 `.state-cache/data.json`（覆盖）
2. 用 `nick-fields/retry@<SHA>` 包裹下列步骤（max_attempts=3，retry_wait=5s，timeout=2min）：
   - `git fetch origin _state` + `git checkout -B _state origin/_state`
   - `mkdir -p $(dirname state-path)`
   - 当 `merge=true` 且目标已存在 → `jq -s '.[0] * .[1]'` 合并；否则覆盖写入
   - `git add . && git commit -m "state: update <key>" || true`（空提交不报错）
   - `git push origin _state`
3. commit 元数据：`user.name="evolveCI bot"` `user.email="bot@evolveci.dev"`

**冲突策略**：retry 内每次都重新 `fetch + checkout -B`，避免长时间 stale。

### 5.4 redact-log

**职责**：在日志进入 AI（或 issue 正文）前，移除常见敏感信息。

**输入**：`log`（base64 编码原始日志）。
**输出**：`redacted`（明文，已脱敏）。

**脱敏正则集**（顺序应用）

| 模式 | 替换为 |
|---|---|
| `token\s*=\s*[a-zA-Z0-9_.-]+` | `token=***REDACTED***` |
| `password\s*=\s*[a-zA-Z0-9_.-]+` | `password=***REDACTED***` |
| `secret\s*=\s*[a-zA-Z0-9_.-]+` | `secret=***REDACTED***` |
| `api[_-]?key\s*=\s*[a-zA-Z0-9_.-]+` | `api_key=***REDACTED***` |
| `Bearer\s+[a-zA-Z0-9_.-]+` | `Bearer ***REDACTED***` |
| `ghp_[a-zA-Z0-9]{36}` | `ghp_***REDACTED***` |
| `gho_[a-zA-Z0-9]{36}` | `gho_***REDACTED***` |
| `sk-[a-zA-Z0-9]{20,}` | `sk-***REDACTED***` |
| `(10\|172\|192)\.[0-9]+\.[0-9]+\.[0-9]+` | `***REDACTED_IP***` |

正则集中维护在 `lib/redact-log.sh`，被 `redact-log` action 与未来需要的其他场景复用。

---

## 六、发布层（Publishers）

### 6.1 auto-rerun

**职责**：在预算允许且 workflow 不在禁用名单时，重跑失败 jobs。

**输入**：`repo`、`run-id`、`workflow-name`、`daily-budget`（默认 3）、`token`。
**输出**：`rerun`（`rerunned` \| `skipped-forbidden` \| ""）、`budget-remaining`。

**行为**
1. **预算检查**：从 `_state/daily-counters/<today>.json` 读 `reruns["{repo}/{wf}/{date}"]`，与 `daily-budget` 比较；超限输出 `::warning` 并 `remaining=0` 跳过
2. **禁用名单**：workflow name 包含 `deploy` / `security` / `scan` / `sign`（任一）→ 直接 `result=skipped-forbidden` + `::notice`
3. **重跑**：`gh run rerun <run-id> --repo <repo> --failed`，输出 `::notice`
4. **递增计数**：写回 `_state/daily-counters/<today>.json`（merge）

> 三维预算（workflow / pattern / repo）由 §11 熔断器在调用前完成检查；本 action 只关心 workflow 维度。

### 6.2 trip-circuit-breaker

**职责**：当任一预算维度超限或检测到异常模式时，开 issue + 通知 Slack，**全局**冻结 triage。

**输入**：`repo`、`workflow-name`、`reason`、`dimension`（`workflow` \| `pattern` \| `repo`）、`history`（JSON 数组）。
**输出**：无（副作用：GitHub Issue + Slack 消息）。

**行为**
1. 创建 Issue（label：`ci:circuit-broken`、`severity/critical`），正文包含维度、原因、近期历史 JSON 与「移除标签恢复」指引
2. 调 `your-org/openCI/actions/integrations/slack-notify@v2`（`continue-on-error: true`）发关键告警
3. `triage-failure.yml` 在每次启动时检查是否存在 open `ci:circuit-broken` issue → 存在则 `skip=true`

### 6.3 post-issue-report

**职责**：将一份 markdown 文件转为 GitHub Issue。

**输入**：`title`、`report-path`（markdown 文件路径）、`labels`（默认 `ci-report`）、`assignees`（可选）。
**实现委托**：`peter-evans/create-issue-from-file@<SHA>`。

### 6.4 post-slack-report

**职责**：复用 OpenCI 的 slack-notify 发结构化消息。

**输入**：`webhook-url`、`title`、`message`、`status`（默认 `info`）。
**实现委托**：`your-org/openCI/actions/integrations/slack-notify@v2`，`continue-on-error: true`（Slack 故障不阻塞 CI）。

---

## 七、实时分诊工作流

### 7.1 triage-failure.yml

**触发**：`schedule: */15 * * * *` + `workflow_dispatch`。
**Concurrency**：`group: ci-triage`，`cancel-in-progress: false`（不打断进行中的 triage）。
**全局权限**：`permissions: {}`（默认拒绝，job 级精确授权）。

**Job 流程图**

```
scan (read-only, 10min)
  ├─ harden-runner
  ├─ checkout
  ├─ Check circuit breaker → 存在 open `ci:circuit-broken` issue → skip
  ├─ Load onboarded repos（yq 读 data/onboarded-repos.yml）
  ├─ query-github-actions(since=30m, status=failure, include-logs=true)
  └─ outputs: runs (JSON 数组), failure-count
  ▼
triage (matrix, contents:write + issues:write, 15min)
  if: failure-count != '0' && fromJson(runs) != []
  matrix: 取 runs 前 10 条，max-parallel=3，fail-fast=false
  steps per failure:
    1. harden-runner + checkout
    2. fetch _state branch + 加载 known-patterns.json
    3. redact-log（base64 日志 → 脱敏明文）
    4. Tier 1: match-known-patterns
    5. Tier 2: classify-heuristic（仅当 T1 miss）
    6. Tier 3 prepare（仅当 T1 miss && T2 confidence=low）→ 上下文 JSON
    7. Tier 3 AI: uses claude-harness.yml@v2（with task/prompt/model/context）
       continue-on-error: true（AI 故障不阻塞）
    8. Dispatch: 按 T1 → T2(高/中) → T3 → 默认 unclassified 优先级聚合 category/severity/should_rerun/should_notify/summary/tier
    9. Auto-rerun（仅 should_rerun=true）→ 调 §6.1
    10. Create issue（should_notify=true && category != flaky）
        - 去重：搜 `label:ci/<cat> "<workflow>" in:title state:open`，存在则 comment 追加，否则新建
        - title: `CI [<cat>]: <workflow> - <summary>`
        - labels: `ci/<cat>,severity/<sev>`
    11. Slack（severity in {critical, high}）→ 调 §6.4
    12. Learn new pattern（仅 Tier 3 有 matched_pattern 时）
        - ReDoS 防护：长度 ≤200，否则 ::warning 跳过
        - id: `ai-<md5(pattern)[0:8]>`
        - 写 /tmp/new-pattern.json
        - peter-evans/create-pull-request：分支 `pattern/<run-id>`，PR 标题含 category；人工审核合并后写入 `_state/known-patterns.json`
```

**关键不变量**
- AI 调用必须在 workflow 层（`uses: ...claude-harness.yml@v2`），不在 composite action 内部
- matrix 防御性写法：`fromJson(needs.scan.outputs.runs || '[]')` 防 `null` / 空字符串
- 任何 Tier 失败都要让流程继续，最终 dispatch 兜底为 `unknown` + `should_notify=true`

**任务粒度建议**
| 子任务 | 依赖 | 说明 |
|---|---|---|
| scan job 主体 | sources/redact-log/state | 先实现单 repo 端到端 |
| Tier 1+2 接入 | analyzers | 独立联调 |
| Tier 3 AI 接入 | OpenCI claude-harness | 验证 prompt → JSON 解析 |
| Issue 去重 + Slack | publishers | 单独一周观察消息频率 |
| Learn pattern PR 流程 | peter-evans/cpr | 必须有 ReDoS 防护测试 |

---

## 八、每日 CI 健康报告

### 8.1 health-ci-daily.yml

**触发**：`schedule: 0 1 * * 1-5`（工作日 UTC 01:00）+ `workflow_dispatch`。
**Concurrency**：`group: ci-health-daily`，`cancel-in-progress: false`。
**全局权限**：`permissions: { contents: read, issues: write }`。

**Job 流程**

```
collect (15min)
  ├─ harden-runner + checkout
  ├─ Load onboarded repos
  ├─ query-github-actions(since=24h, status=all, include-logs=false)
  ├─ Compute per-workflow stats
  │   group_by(repo+'/'+workflow) →
  │   { key, repo, workflow, total, failed, success, failure_rate=floor(failed*100/total) }
  ├─ Detect degradations
  │   对每个 workflow：从 _state/workflow-health/<repo_wf>.json 取最近 7 天均值
  │   delta = current - 7day_avg；delta > 10 → 加入 degradations 列表
  ├─ Update health history → write _state/workflow-health/<key>.json（追加今日 daily[date]=rate）
  └─ Aggregate output
      { total_runs, total_failures, failure_rate, workflows[], degradations[] }
  ▼
synthesize (claude-harness.yml@v2, model=Haiku, max-turns=1)
  uses: prompts/observability/daily-report.md
  context: collect.outputs.stats
  ▼
publish (5min)
  ├─ 写 /tmp/daily-report.md
  ├─ post-issue-report（title `📊 CI Health Report - <date>`，labels `daily-report,ci-health`）
  └─ post-slack-report（webhook = SLACK_CI_WEBHOOK）
```

**关键约束**
- `synthesize` 只在 `collect.outputs.stats != '' && != '{}'` 时运行
- `publish` 只在 `synthesize.outputs.result != ''` 时运行
- 健康历史**append-only**：每日新增一条 `daily[date]`，不删旧条目（30 天后由清理任务 trim，留作 P4）

### 8.2 daily-report prompt

```markdown
你是 CI 健康报告生成器。基于以下统计数据，生成一份简洁的日报。

数据：
{{context}}

输出格式（严格遵循）：

# CI Health Report - {今日日期}

## TL;DR
- 整体健康度: {100 - failure_rate}%（{与昨日对比趋势}）
- {1-2 条最重要的事}

## 关键指标
| 指标 | 今日 | 趋势 |
|------|------|------|
| 总运行 | {total_runs} | - |
| 失败率 | {failure_rate}% | {degradations 有则↑，无则→} |

## 需要关注
{列出 degradations 中的每一项，如果没有则写"无"}

## Top Flaky Workflows
{列出 failure_rate > 20% 的 workflow，按失败率降序，最多 5 个}

## 好消息
{列出 failure_rate = 0 的 workflow，或 failure_rate 明显下降的}

## 建议行动项
{基于数据给出 1-3 条具体可执行的建议}

规则：
- 总长度不超过 500 字
- 不要虚构数据，只基于输入统计
- 如果 total_runs = 0，说明"过去 24h 无运行"
- 使用 Markdown 格式
```

---

## 九、每周深度分析

### 9.1 health-ci-weekly.yml

**触发**：`schedule: 0 2 * * 1`（每周一 UTC 02:00）+ `workflow_dispatch`。
**Concurrency**：`group: ci-health-weekly`，`cancel-in-progress: false`。

**Job 流程**

```
collect (20min)
  ├─ Load repos
  ├─ query-github-actions(since=7d, status=all, include-logs=false)
  ├─ Compute weekly stats
  │   group_by(repo) →
  │   { repo, total, failed, success, workflows: [{ name, total, failed, failure_rate }] }
  ├─ Read previous snapshot from _state/weekly-snapshots/<last_week>.json
  ├─ Save current snapshot to _state/weekly-snapshots/<this_week>.json
  └─ output { current, previous }
  ▼
synthesize (claude-harness.yml@v2, model=Sonnet, max-turns=1)
  uses: prompts/observability/weekly-deep-dive.md
  context: collect.outputs.weekly-data
  ▼
publish
  ├─ post-issue-report（title `📊 CI Weekly Deep Dive - <YYYY-Www>`，labels `weekly-report,ci-health`）
  └─ post-slack-report
```

**周编号约定**：`date +%Y-W%V`（ISO week，跨平台兼容性见 §18 备注）。

### 9.2 weekly-deep-dive prompt

```markdown
你是资深 CI/CD 工程师，负责分析一周的 CI 数据并输出深度报告。

数据：
{{context}}

输出格式：

# CI Weekly Deep Dive - {周}

## Executive Summary
- 2-3 句话总结本周 CI 整体状况

## 关键指标变化
| 指标 | 本周 | 上周 | 变化 |
|------|------|------|------|
| 总运行 | - | - | - |
| 整体失败率 | - | - | - |
| Flaky workflow 数 | - | - | - |

## 仓库维度分析
{每个 repo 一段分析}

## Top 5 问题模式
{基于 failure rate 降序}

## DORA 指标评估
- 部署频率评级
- 变更前置时间评级
- 变更失败率评级
- MTTR 评级

## 趋势预测
{基于 2 周数据预测下周可能的问题}

## 行动建议
{3-5 条具体可执行建议}

规则：
- 不要虚构数据
- 如果 previous 为空，说明"首次周报，无对比数据"
- 总长度不超过 1000 字
```

---

## 十、自监控心跳

### 10.1 heartbeat.yml

**触发**：`schedule: 0 */6 * * *`（每 6 小时）+ `workflow_dispatch`。
**Concurrency**：`group: ci-heartbeat`，`cancel-in-progress: true`（心跳允许取消旧实例）。
**全局权限**：`permissions: { contents: read }`。

**职责**：确定性检查，不调 AI。任一关键探针异常时升级为 workflow failure（GitHub 自动邮件告警 owner）。

**探针清单**

| 探针 | 检测方法 | 异常表现 |
|---|---|---|
| triage-failure 是否在跑 | `gh run list --workflow triage-failure.yml --status success --limit 1`；最近一次成功超过 24h → 视为 down | `::error` + workflow failure |
| triage 从未成功过 | 同上，结果为空 → 视为未启动 | `::warning` |
| 健康数据新鲜度 | `git log -1 --format=%at origin/_state -- workflow-health/`；超过 48h 未更新 | `::warning` |
| known-patterns 健康 | `git show origin/_state:known-patterns.json \| jq length`；< 3 条视为异常 | `::warning` |

**自监控策略**：邮件由 GitHub native 行为承担（workflow failure → 仓库 owner 收件）；不引入额外通知通道，避免与 §6 重复。

---

## 十一、熔断器机制

### 11.1 三个预算维度

| 维度 | Key 格式 | 每日上限 | 作用域 |
|---|---|---|---|
| Workflow | `{repo}/{workflow}/{date}` | 3 | 同一 workflow 同一 repo |
| Pattern | `{pattern-id}/{date}` | 5 | 同一失败模式跨所有 repo |
| Repo | `{repo}/{date}` | 20 | 一个 repo 的所有重跑 |

阈值在 `data/circuit-config.yml` 中可调，提供合理默认。

### 11.2 熔断流程

```
auto-rerun 入口
  ▼
read-state（查三个维度当日计数）
  ▼
任一超限？
  ├─ 是 → trip-circuit-breaker
  │        ├── 创建 GitHub Issue（label: ci:circuit-broken）
  │        ├── Slack @channel 通知
  │        └── triage-failure 检测到 label → 全局跳过
  └─ 否 → 执行重跑 → write-state（递增三个维度计数器）
```

### 11.3 恢复机制

熔断后，**所有** auto 处理停止，直到人工移除 `ci:circuit-broken` label（或在 Issue 中评论 `/resume`，由后续机器人解析——P3 范围）。

### 11.4 安全约束

auto-rerun 仅限只读类 workflow。以下 workflow **永不**自动重跑：

- name 含 `deploy`
- name 含 `security` / `scan` / `sign`
- 在 `data/circuit-config.yml` 的 `no-rerun` 列表中

---

## 十二、Onboarding 新仓库

```yaml
# data/onboarded-repos.yml
repos:
  - name: org/repo-a
    workflows: "*"              # 监控所有 workflow
    priority: high              # high = 失败立刻通知，low = 只进报告

  - name: org/repo-b
    workflows: "pr.yml,ci.yml"  # 只监控指定 workflow
    priority: low

  - name: org/repo-c
    workflows: "*"
    priority: high
    exclude:
      - "stale.yml"
      - "community.yml"
```

**目标仓库零配置变更**。跨 repo 访问通过 fine-grained PAT，仅需 `actions:read` + `metadata:read`。

---

## 十三、已知模式库初始 Seed

`_state/known-patterns.json` 初始 seed（10 条），覆盖最常见的间歇性失败：

| id | category | severity | auto_rerun | notify | match（示意） |
|---|---|---|---|---|---|
| `npm-eai-again` | flaky | low | true | false | `EAI_AGAIN.*registry\.npmjs\.org\|ENOTFOUND.*registry\.npmjs\.org` |
| `pypi-timeout` | flaky | low | true | false | `ReadTimeoutError.*pypi\.org\|HTTPSConnectionPool.*pypi\.org` |
| `ghcr-rate-limit` | flaky | low | true | false | `rate limit exceeded.*ghcr\.io\|toomanyrequests.*ghcr` |
| `runner-disk-full` | infra | high | false | true | `No space left on device\|runner.*disk.*full` |
| `runner-startup-fail` | flaky | low | true | false | `The runner.*did not connect\|runner.*failed to start` |
| `trivy-db-update` | flaky | low | true | false | `FATAL.*failed to download vulnerability DB\|trivy.*db.*download.*fail` |
| `trufflehog-timeout` | flaky | low | true | false | `trufflehog.*timeout\|trufflehog.*context deadline exceeded` |
| `anthropic-rate-limit` | flaky | low | true | false | `rate_limit_error.*anthropic\|429.*too many requests.*claude` |
| `langsmith-timeout` | flaky | low | true | false | `langsmith.*504.*timeout\|langsmith.*gateway timeout` |
| `docker-daemon-fail` | infra | medium | true | true | `Cannot connect to the Docker daemon\|docker.*daemon.*not running` |

每条 seed 至少包含字段：`id, match, category, auto_rerun, notify, severity, seen_count, last_seen, source="seed"`。

完整 JSON 在 `data/known-patterns.seed.json`（落地任务负责），CI 启动时如果 `_state` 分支没有 `known-patterns.json` 则用 seed 初始化。

---

## 十四、成本模型

### 14.1 月度成本估算（5 个 repo）

| 场景 | 频率 | 单价 | 月成本 |
|------|------|------|--------|
| Tier 1: 已知模式匹配 | ~35 次/天 | $0 | $0 |
| Tier 2: 启发式规则 | ~10 次/天 | $0 | $0 |
| Tier 3: Haiku 分类 | ~4 次/天 | $0.001 | $0.12 |
| Tier 4: Sonnet 深度 | ~1 次/天 | $0.01 | $0.30 |
| 每日报告（Haiku） | 22 次/月 | $0.005 | $0.11 |
| 每周深度（Sonnet） | 4 次/月 | $0.10 | $0.40 |
| **总计** | | | **~$0.93/月** |

### 14.2 成本飞轮

每次 Tier 3 分类产生新 pattern → 自动 PR 进 `known-patterns.json`（人工审核）。随时间推移：

- **第 1 个月**：~$0.93（Tier 1 命中率 70%）
- **第 3 个月**：~$0.50（Tier 1 命中率 85%）
- **第 6 个月**：~$0.30（Tier 1 命中率 92%+）

正反馈飞轮：模式库越大 → Tier 1 命中率越高 → AI 调用越少 → 成本越低。

---

## 十五、与 OpenCI 的关系

### 15.1 依赖清单

| 依赖项 | 用途 | 引用方式 |
|---|---|---|
| `claude-harness.yml` | AI 调用入口 | `uses: your-org/openCI/.github/workflows/claude-harness.yml@v2`（**workflow 级别**） |
| `slack-notify` | Slack 通知 | `uses: your-org/openCI/actions/integrations/slack-notify@v2` |
| `manifest.yml` | 第三方 SHA 来源 | EvolveCI 自身 manifest 对齐 OpenCI 版本号 |
| `harden-runner` | 安全加固 | 每个 job 第一步 |

### 15.2 第三方 Actions

| 依赖项 | 版本 | 用途 |
|---|---|---|
| `actions/cache` | v4 | state 快速层 |
| `peter-evans/create-issue-from-file` | v6 | markdown → Issue |
| `peter-evans/create-pull-request` | v7 | known-pattern 自动 PR |
| `nick-fields/retry` | v3 | `_state` 分支写入冲突重试 |
| `DeveloperMetrics/deployment-frequency` | — | DORA 部署频率 |
| `DeveloperMetrics/lead-time-for-changes` | — | DORA 变更前置时间 |

所有第三方 actions 通过 `manifest.yml` 锁定 SHA。

### 15.3 与 OpenCI health-report.yml 的关系

| 工作流 | 数据源 | 触发 | 输出 |
|---|---|---|---|
| OpenCI `health-report.yml` | Sentry/Datadog/PostHog/LangSmith/Axiom | 每日 | **应用**健康日报 |
| EvolveCI `health-ci-daily.yml` | GitHub Actions API | 每日 | **CI** 健康日报 |

初期分开实现降低复杂度。未来可合并为统一日报。

---

## 十六、实施优先级

| 阶段 | 内容 | 验证方式 |
|------|------|---------|
| P0 | `query-github-actions` + `redact-log` + `read-state` + `write-state` | 手动触发，验证 JSON 输出 |
| P0 | `known-patterns.json` 初始 seed（10 个模式） | `grep -E` 验证每个 pattern |
| P0 | `match-known-patterns` + `classify-heuristic`（Tier 1+2） | 端到端测试 20 条真实失败日志 |
| P1 | `triage-failure.yml` 主流程（含 Tier 3 Haiku） | 在 1 个 repo 上运行 1 周 |
| P1 | `auto-rerun` + 三维预算检查 + `trip-circuit-breaker` | 验证重跑计数和熔断触发 |
| P1 | `_state` 孤儿分支初始化 + 双层持久化 | 验证 cache/branch 读写 |
| P2 | `health-ci-daily.yml` + `compute-flakiness` + `compute-trends` | 对比 2 周数据，验证退化检测 |
| P2 | Slack 通知分级（critical/high/medium） | 验证消息内容和频率 |
| P3 | `health-ci-weekly.yml` + Tier 4 Sonnet | 人工审查报告质量 |
| P3 | `heartbeat.yml` 自监控 | 模拟 triage-failure 停止运行 |
| P4 | `compute-mttr` + DORA 三件套集成 | 与手动计算对比验证 |
| P4 | 新 repo onboarding 流程 | 添加第 6 个 repo，验证零配置 |

---

## 十七、权限矩阵

| 工作流 | contents | issues | actions | 说明 |
|---|---|---|---|---|
| triage-failure | write | write | — | 需要 commit `_state` + 创建 issue |
| health-ci-daily | read | write | — | 创建 issue |
| health-ci-weekly | read | write | — | 创建 issue |
| heartbeat | read | — | — | 只读检查 |

全局默认：`permissions: {}` 拒绝所有，job 级别精确授权。

---

## 十八、Timeout 策略

| 工作流/job | timeout-minutes | 说明 |
|---|---|---|
| scan | 10 | API 调用为主 |
| triage (per matrix) | 15 | 含 AI 调用 |
| collect (daily) | 15 | API + 聚合 |
| synthesize | 5 | AI 调用 |
| publish | 5 | 写 issue/slack |
| heartbeat | 5 | 只读检查 |

**跨平台备注**：所有日期/时间格式化（`date -u -d` vs `date -u -v`）必须有 GNU/BSD 双分支兜底，参考 §3.1 的 `since` 解析。

---

## 十九、任务拆解参考

下表把本 SPEC 映射到 P0–P4 的可独立交付任务（每行 ≤ 1 周，含验收）。

| 任务 ID | SPEC 引用 | 交付物 | 依赖 | 验收 |
|---|---|---|---|---|
| EC-001 | §3.1 | `actions/observability/sources/query-github-actions/` | 无 | 对 1 个 repo 输出非空 JSON，含 log_base64 |
| EC-002 | §5.4 | `actions/observability/state/redact-log/` + `lib/redact-log.sh` | 无 | 给定含 `ghp_xxx` 与 `Bearer xxx` 的样本输出 `***REDACTED***` |
| EC-003 | §5.1 | `_state` 分支初始化 + README 说明 | 无 | `git ls-remote origin _state` 非空 |
| EC-004 | §5.2 + §5.3 | `read-state` / `write-state` actions | EC-003 | 写入后回读一致；冲突场景 retry 成功 |
| EC-005 | §13 | `data/known-patterns.seed.json`（10 条） | 无 | 每条 pattern 用对应样本日志 `grep -E` 命中 |
| EC-006 | §4.2 | `match-known-patterns` action | EC-005 | 给定 20 条历史失败，命中率 ≥70% |
| EC-007 | §4.3 | `classify-heuristic` action | 无 | 给定规则表样本，confidence/category 全部正确 |
| EC-008 | §4.4 + §4.5 | `classify-ai` prepare/parse + Haiku prompt | EC-001/EC-002 | 上下文 JSON 通过 `claude-harness` 调用产出合法 JSON |
| EC-009 | §6.1 + §11 | `auto-rerun` + 三维预算检查 | EC-004 | 第 4 次重跑触发 workflow 维度熔断 |
| EC-010 | §6.2 | `trip-circuit-breaker` | EC-009 | label `ci:circuit-broken` issue 创建成功 + Slack 收到 |
| EC-011 | §6.3 / §6.4 | `post-issue-report` / `post-slack-report` | 无 | 一份 fixture markdown 端到端 issue + slack |
| EC-012 | §7.1 | `triage-failure.yml`（先实现 Tier 1+2 + auto-rerun + issue） | EC-006/007/009/011 | 单 repo 灰度 7 天，issue 噪音可接受 |
| EC-013 | §7.1 Tier 3 + Learn pattern | Tier 3 + `peter-evans/create-pull-request` PR 流程 | EC-008/EC-012 | 1 周内自动 PR ≥1 条新 pattern |
| EC-014 | §8 | `health-ci-daily.yml` + Haiku prompt | EC-001/EC-004/EC-011 | 连续 3 天日报无虚构 |
| EC-015 | §4.7 + §4.9 | `compute-flakiness` + `compute-trends` | EC-014 | 对 2 周数据计算 trend，与人工口径一致 |
| EC-016 | §9 | `health-ci-weekly.yml` + Sonnet prompt | EC-014 | 首份周报人工审核通过 |
| EC-017 | §10 | `heartbeat.yml` | EC-012 | 模拟 triage 停跑 25h，触发 workflow failure |
| EC-018 | §4.4 Tier 4 | Sonnet 深度分析接入 triage 兜底 | EC-013 | 月度 Tier 4 调用 ≤2 次 |
| EC-019 | §4.8 | `compute-mttr` + DORA 接入 | EC-016 | 与手动计算偏差 <10% |
| EC-020 | §12 | onboarding 流程文档 + 第 6 个 repo 接入 | EC-014 | 零配置一次成功，一周观察无 false positive 飙升 |

每个任务的实现细节（具体 YAML、bash、jq 表达式）在落地 PR 中给出，与本 SPEC 无需同步——**SPEC 只描述契约、不固化实现**。

---

## 附录 A：术语表

| 术语 | 含义 |
|---|---|
| **Tier** | Analyzer 处理失败的递进层级（1=正则、2=启发式、3=Haiku、4=Sonnet） |
| **Flakiness score** | 最近 N 次 run 中失败比例 ×100，用于触发 AI 兜底与回归告警 |
| **MTTR** | Mean Time To Recovery — 失败到下次成功的平均分钟数 |
| **DORA** | DevOps Research and Assessment 四大指标：部署频率、变更前置时间、变更失败率、MTTR |
| **`_state` 分支** | 与 main 无共享历史的孤儿分支，作为 EvolveCI 的时间序列状态库 |
| **circuit breaker** | 熔断器，预算超限时暂停所有 auto 处理直到人工解除 |
| **claude-harness** | OpenCI 的 reusable workflow，统一 AI 调用入口（限速、密钥、审计） |

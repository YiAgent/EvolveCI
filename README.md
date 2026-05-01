# EvolveCI

**AI Agent 驱动的 CI/CD 自进化监控系统**

EvolveCI 是一个独立的 meta-repo，通过 Claude Code Agent 持续观察组织内所有 GitHub Actions 流水线，自动分诊失败、累积经验、自我进化——系统会随时间变得越来越聪明。

---

## 核心理念

传统 CI 监控工具每次运行都是无状态的。EvolveCI 不同：

> **Claude Code IS 监控代理，不是被调用的工具**

```
传统方案                        EvolveCI v4
─────────────────────────       ─────────────────────────────────
workflow → 调用 AI API     →    workflow → 激活 Claude Agent
         ↓                               ↓
     得到文本输出               Claude 读取 CLAUDE.md（记忆）
         ↓                               ↓
     发布报告                   Claude 通过 GitHub MCP 查询 CI
                                         ↓
                               Claude 分析、执行、学习
                                         ↓
                               Claude commit 新知识到 main 分支
                                         ↓
                               下次运行自动加载这些记忆
```

每次运行后，Agent 将学到的新失败模式、指纹记录、统计快照直接提交回 `memory/` 目录。
15 分钟后的下一次分诊，Claude 带着这些记忆重新出发——**永不遗忘，持续进化**。

---

## 四层架构

```
┌─────────────────────────────────────────────────────────────┐
│  触发层 (GitHub Actions cron)                               │
│  OpenCI claude-harness → claude -p "/triage"               │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│  Agent 层 (Claude Code)                                     │
│  读 CLAUDE.md → 加载 memory/ → GitHub MCP 查询 CI          │
│  → 三级分析(Tier1正则/Tier2启发/Tier3推理)                 │
│  → 执行动作(重跑/建Issue/Slack) → commit 记忆              │
└───────────────────────┬─────────────────────────────────────┘
                        │ git commit to main
                        ▼
┌─────────────────────────────────────────────────────────────┐
│  记忆层 (main 分支 memory/ 目录)                            │
│  patterns/  incidents/  stats/  fingerprints/  circuit/    │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│  输出层                                                     │
│  GitHub Issues | Issue Comments | Slack | git commits      │
└─────────────────────────────────────────────────────────────┘
```

---

## 记忆系统

所有跨运行的状态存储在 `memory/` 目录（main 分支），替代传统的数据库或孤儿分支：

| 目录 | 内容 | 格式 |
|------|------|------|
| `memory/patterns/` | 已知失败模式库（自动学习积累）| JSON |
| `memory/incidents/` | 每次分诊的详细记录 | JSONL（每行一条，支持追加）|
| `memory/stats/daily/` | 每日 CI 健康快照 | JSON |
| `memory/stats/weekly/` | 每周统计汇总 | JSON |
| `memory/fingerprints/` | 错误指纹聚类记录（去重用）| JSON |
| `memory/flaky-tests/` | Flaky 测试注册表 | JSON |
| `memory/circuit/` | 熔断器状态 | JSON |
| `memory/counters/` | 每日重跑计数器 | JSON |

`CLAUDE.md` 是 Agent 的核心记忆文件，包含：
- 行为规则和安全边界
- 快速参考（各记忆文件路径）
- 近期学习摘要（由 `/weekly-report` 维护）

---

## 三级分析流水线

```
失败 Run
   ↓
[Tier 1] 正则匹配 memory/patterns/known-patterns.json
   ↓ 未命中
[Tier 2] 启发式关键词规则（内置，零成本）
   ↓ 低置信度
[Tier 3] Claude 深度推理（使用完整上下文窗口）
   ↓ 发现新模式
[自动学习] 写入 memory/patterns/ → 下次 Tier 1 直接命中
```

---

## 自进化飞轮

随着时间积累，Tier 1 命中率持续提升，AI 深度分析成本持续下降：

```
第 1 个月  ████████████████░░░░░░░░  70% Tier1  ~$0.93/月
第 3 个月  ██████████████████████░░  85% Tier1  ~$0.50/月
第 6 个月  ███████████████████████░  95% Tier1  ~$0.20/月
```

新 pattern 被 Claude 发现后：
- **立即写入** `memory/patterns/known-patterns.json`（无需 PR 审核）
- **15 分钟后**下次分诊自动生效

---

## Slash Commands（Agent 技能）

| 命令 | 触发场景 | 说明 |
|------|---------|------|
| `/triage` | 每 15 分钟 | 扫描并分诊最近 30 分钟内的失败 |
| `/daily-report` | 工作日 01:00 UTC | 生成 24 小时 CI 健康日报 |
| `/weekly-report` | 周一 02:00 UTC | 深度周分析 + DORA 指标 + 更新 CLAUDE.md |
| `/learn-pattern` | triage 内部调用 | 安全验证后记录新失败模式 |
| `/check-circuit` | triage 内部调用 | 熔断器状态查询与管理 |
| `/heartbeat` | 每 6 小时 | 5 项自我健康探针检查 |

---

## 熔断器保护

当某个维度的重跑次数超过预算时，熔断器自动触发：

| 维度 | 每日上限 | 配置来源 |
|------|---------|---------|
| 单个 workflow | 3 次 | `data/circuit-config.yml` |
| 单个 repo | 20 次 | `data/circuit-config.yml` |

- 触发 → 更新 `memory/circuit/state.json` + 创建 GitHub Issue + Slack 通知
- 24 小时后 → 自动恢复
- 手动恢复 → 关闭 Issue 或通过 `workflow_dispatch` 触发

**永远不会自动重跑**的 workflow（含以下关键词）：
`deploy` / `release` / `security` / `scan` / `sign` / `publish`

---

## 接入新仓库

只需编辑 `data/onboarded-repos.yml`，零配置变更目标仓库：

```yaml
repos:
  - name: "org/your-repo"
    workflows: "*"          # "*" 表示所有 workflow，或填逗号分隔的名称
    priority: high          # high: 立即通知 | low: 仅报告
    exclude:                # 排除特定 workflow
      - "docs.yml"
```

---

## Secrets 配置

在本仓库的 Settings → Secrets and variables → Actions 中配置：

| Secret | 必填 | 用途 |
|--------|------|------|
| `ANTHROPIC_API_KEY` | ✅ | Claude Agent 调用 |
| `ANTHROPIC_BASE_URL` | ❌ | 自定义 API 端点（留空使用官方地址）|
| `CROSS_REPO_PAT` | ✅ | 跨仓库读取 GitHub Actions 数据 |
| `SLACK_CI_WEBHOOK` | ❌ | Slack 告警通知 |

`CROSS_REPO_PAT` 所需权限：`actions:read`（只读）

---

## 本地调试

```bash
# 手动触发分诊
claude -p "/triage"

# 生成今日日报
claude -p "/daily-report"

# 检查系统健康
claude -p "/heartbeat"

# 查看熔断器状态
claude -p "/check-circuit"
```

---

## v3 vs v4 对比

| 特性 | v3（原版）| v4（Agent 驱动）|
|------|---------|----------------|
| **状态存储** | `_state` 孤儿分支 | `memory/` 目录（main 分支）|
| **AI 调用方式** | 单次无状态 API 调用 | Claude Agent 闭环多步推理 |
| **模式学习** | 生成 PR → 人工审核 → 合并 | Agent 直接 commit（内置安全验证）|
| **学习延迟** | PR review 时间 + 合并 | 15 分钟（下次 triage）|
| **上下文窗口** | 单次失败 | 跨多个失败 + 历史记忆 |
| **Workflow 复杂度** | 多 job（collect/synthesize/publish）| 单 job（调用 claude-harness）|
| **并发写冲突** | 孤儿分支 push 竞争 | JSONL 追加，无冲突 |
| **调试方式** | 查看 workflow logs | `claude -p "/triage"` 本地运行 |

---

## 项目结构

```
EvolveCI/
├── CLAUDE.md                    # Agent 核心记忆（身份+规则+快速参考）
├── .claude/
│   └── commands/                # Slash commands（Agent 技能）
│       ├── triage.md
│       ├── daily-report.md
│       ├── weekly-report.md
│       ├── learn-pattern.md
│       ├── check-circuit.md
│       └── heartbeat.md
├── .github/workflows/
│   ├── agent-triage.yml         # 每 15 分钟分诊
│   ├── agent-daily.yml          # 每日报告
│   ├── agent-weekly.yml         # 每周深度分析
│   ├── agent-heartbeat.yml      # 每 6 小时自检
│   └── test.yml                 # CI 测试（42 项结构验证）
├── memory/                      # Agent 记忆（git 管理）
│   ├── patterns/known-patterns.json
│   ├── incidents/               # YYYY-MM/YYYY-MM-DD.jsonl
│   ├── stats/daily/             # YYYY-MM-DD.json
│   ├── stats/weekly/            # YYYY-Www.json
│   ├── fingerprints/            # <12hex>.json
│   ├── flaky-tests/             # <org>-<repo>.json
│   ├── circuit/state.json
│   └── counters/                # YYYY-MM-DD.json
├── actions/observability/       # 可复用 composite actions（供 Agent 调用）
├── data/
│   ├── onboarded-repos.yml      # 监控仓库列表
│   └── circuit-config.yml       # 预算配置
├── prompts/observability/       # AI 分析提示模板（Claude 直接参考）
├── lib/redact-log.sh            # 日志脱敏（分析前必须调用）
├── docs/SPEC.md                 # 完整功能规格说明
└── tests/                       # 测试套件
```

---

## 安全设计

- `CROSS_REPO_PAT` 仅需 `actions:read` 只读权限，不可写目标仓库
- 所有日志在 AI 分析前通过 `lib/redact-log.sh` 脱敏（13 种 secret 模式）
- 新学习的正则模式通过安全验证（长度、禁止嵌套量词、语法检查）
- 自动重跑黑名单阻止 deploy/security 等关键 workflow 被自动重跑
- 熔断器机制防止无限重跑

---

## 与 OpenCI 的关系

EvolveCI 复用 [OpenCI](https://github.com/YiAgent/OpenCI) 的以下能力：
- AI Agent 调用：`YiAgent/OpenCI/.github/workflows/claude-harness.yml@main`（限速、密钥、审计统一在 OpenCI 维护）
- Slack 通知：`YiAgent/OpenCI/actions/integrations/slack-notify@v2`

OpenCI 关心**应用**的健康度；EvolveCI 关心**流水线**的健康度。两套系统各司其职。

---

## License

[MIT](LICENSE)

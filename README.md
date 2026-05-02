# EvolveCI

**AI Agent 驱动的 CI/CD 自进化监控系统**

EvolveCI 是一个独立的 meta-repo，通过 Claude Code Agent 持续观察组织内所有
GitHub Actions 流水线，自动分诊失败、累积经验、自我进化 — 系统会随时间变得
越来越聪明。

---

## 核心理念 (v5.1)

> **确定性流水线做 90% 的工作；Agent 只在真正需要判断时介入。**

```
确定性 pipeline (composite actions + scripts)
  ├─ 收集: gh run 数据 → JSON
  ├─ 脱敏: 原始日志 → 安全日志
  ├─ Tier 1: 正则匹配 pattern catalog
  ├─ Tier 2: 关键词启发式 → category + confidence
  └─ 聚合: MTTR / flakiness / trends

Agent (小而专注)
  ├─ /triage     处理 Tier 3 unknown 失败 + 写 issue
  ├─ /daily      读 JSON → 写中文日报
  ├─ /weekly     读 JSON → 开 PR 更新 CLAUDE.md
  └─ /heartbeat  读探针结果 → 维护 1 个 health issue
```

跨运行的状态全部存在 GitHub Issues 里 (label `evolveci/*`)，**不再写本地文件
也不再 git commit 状态**。详见 [`docs/MEMORY-MODEL.md`](./docs/MEMORY-MODEL.md)。

---

## 三级分析流水线

```
失败 Run
   ↓
[Tier 1] 正则匹配 evolveci/pattern issue 库   (零成本，确定性)
   ↓ 未命中
[Tier 2] 启发式关键词规则                     (零成本，确定性)
   ↓ 低置信度
[Tier 3] Agent 深度推理                       (有成本，仅在此层)
   ↓ 发现新模式
[/learn-pattern] 创建新的 evolveci/pattern issue → 下次 Tier 1 直接命中
```

---

## Slash Commands

| 命令 | 触发场景 | 说明 |
|------|---------|------|
| `/triage` | 每 15 分钟 | 扫描并分诊最近 30 分钟内的失败 |
| `/daily-report` | 工作日 01:00 UTC | 24h CI 健康日报 (upsert `evolveci/daily` issue) |
| `/weekly-report` | 周一 02:00 UTC | 深度周分析 + DORA 指标 (开 PR) |
| `/learn-pattern` | triage 内部调用 | 安全验证后记录新失败模式 |
| `/check-circuit` | triage 内部调用 | 熔断器状态查询与管理 |
| `/heartbeat` | 每 6 小时 | 5 项自我健康探针 |

---

## 熔断器保护

| 维度 | 每日上限 | 配置来源 |
|------|---------|---------|
| 单个 workflow | 3 次 | `data/circuit-config.yml` |
| 单个 repo | 20 次 | `data/circuit-config.yml` |

熔断器状态保存在唯一的 `evolveci/circuit` issue 的 body (JSON)，24 小时后自动
恢复。**永远不会自动重跑**含 `deploy` / `release` / `security` / `scan` /
`sign` / `publish` 关键词的 workflow。

---

## 接入新仓库

```yaml
# data/onboarded-repos.yml
repos:
  - name: "org/your-repo"
    workflows: "*"          # "*" 全部 workflow，或填逗号分隔的文件名
    priority: high          # high: 立即通知 | low: 仅报告
    private: true           # 可选 — 私有仓库需要 CROSS_REPO_PAT
    exclude:                # 可选 — 排除特定 workflow 文件名
      - "docs.yml"
```

诊断: `bash scripts/triage-dry-run.sh 24h` — 不写任何 issue，只打印 triage
*会看到*的失败列表，方便快速验证 onboarded-repos.yml 配置。

---

## Secrets 配置

| Secret | 必填 | 用途 |
|--------|------|------|
| `GLM_API_KEY` (或 `ANTHROPIC_API_KEY`) | ✅ | Agent 模型调用 |
| `GLM_BASE_URL` | ❌ | 自定义 API 端点 |
| `CROSS_REPO_PAT` | 跨仓 | 跨仓库读取 Actions / 写 Issues。私有仓必填。 |
| `SLACK_CI_WEBHOOK` | ❌ | Slack 告警通知 |

详见 [`docs/CONFIG.md`](./docs/CONFIG.md)。

---

## 本地调试

```bash
# 看 triage 在当前配置下会处理哪些失败 (不写 issue)
bash scripts/triage-dry-run.sh 24h

# 重建标签 (新 onboard 的 repo 必跑一次)
bash scripts/bootstrap-labels.sh org/repo

# 重新填充 pattern issue 描述/修复建议
bash scripts/refresh-pattern-descriptions.sh org/repo
```

---

## 项目结构

```
EvolveCI/
├── CLAUDE.md                       Agent 身份 + 安全规则
├── .claude/commands/               Slash commands (Agent 技能)
├── .github/workflows/              cron 触发器 (4 个 agent + test)
├── .github/ISSUE_TEMPLATE/         结构化 issue 模板
├── actions/observability/          composite actions
│   ├── sources/                    数据收集 (query-github-actions)
│   ├── analyzers/                  Tier1/Tier2 + 指标计算
│   └── publishers/                 重跑 / 通知 / 熔断
├── data/
│   ├── onboarded-repos.yml         监控仓库列表
│   ├── circuit-config.yml          熔断器配置
│   └── known-patterns.seed.json    Tier 1 pattern 种子
├── prompts/observability/          AI 分析提示模板
├── lib/redact-log.sh               日志脱敏 (调用前必经)
├── scripts/                        辅助脚本 (seed / render / dry-run)
├── docs/SPEC.md                    完整功能规格
├── docs/MEMORY-MODEL.md            Issues-as-memory 契约
├── docs/CONFIG.md                  全部可调旋钮
└── tests/                          测试套件
```

---

## 安全设计

- `CROSS_REPO_PAT` 最小权限：`actions:read` + onboarded 仓库的 `issues:write`
- 所有日志在 AI 分析前通过 `lib/redact-log.sh` 脱敏 (13 种 secret pattern)
- 新学习的正则通过安全验证 (长度 ≤200，禁嵌套量词)
- 自动重跑黑名单阻止 deploy/security 等关键 workflow
- 熔断器机制防止无限重跑

---

## 与 OpenCI 的关系

EvolveCI 复用 [OpenCI](https://github.com/YiAgent/OpenCI):
- AI Agent 调用: `YiAgent/OpenCI/.github/workflows/claude-harness.yml@main`
- Slack 通知: `YiAgent/OpenCI/actions/integrations/slack-notify@v2`

OpenCI 关心**应用**的健康度；EvolveCI 关心**流水线**的健康度。

---

## 版本历史

- **v5.1 (2026-05)**: Agent-When-Needed — 确定性 pipeline 做收集与 Tier 1/2，
  Agent 只处理 Tier 3 + 报告写作。Agent turn 预算大幅下降。
- **v5.0 (2026-05)**: Issues-as-Memory — `memory/` 文件全部迁移到
  `evolveci/*` 标签的 GitHub Issues。git 历史不再被状态写入污染。
- **v4 (2026-05)**: Agent-Driven — Claude 直接持有记忆，commit 到 `memory/`。
- **v3**: Workflow-Driven — 单次 AI 调用 + `_state` 孤儿分支。

---

## License

[MIT](LICENSE)

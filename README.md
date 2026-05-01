# EvolveCI

**CI 控制塔（meta-repo）**：观察组织内所有仓库的 GitHub Actions 流水线，主动汇报、实时分诊、自动恢复。

## 它是什么

EvolveCI 是一个独立的 meta-repo——**自己不部署任何应用**，只用来观察其他仓库的 CI 健康度，并按四层架构处理失败：

| 层 | 责任 | AI 用量 |
|---|---|---|
| **Sources** | 拉取多 repo 的 workflow runs（`gh` CLI / API） | 零 |
| **Analyzers** | 四层递进：正则匹配 → 启发式 → Haiku → Sonnet | 仅 ~10% 失败需要 AI |
| **State** | `_state` 孤儿分支 + Actions Cache 双层持久化 | 零 |
| **Publishers** | GitHub Issue / Slack / `gh run rerun --failed` | 零 |

90% 的失败被规则拦截（Tier 1 + Tier 2），AI 只兜底剩下的 10%；新模式自动 PR 进 `_state/known-patterns.json`，模式库越大成本越低（**成本飞轮**）。

## 与 OpenCI 的关系

EvolveCI **复用** [OpenCI](https://github.com/your-org/openCI)：

- AI 调用走 `your-org/openCI/.github/workflows/claude-harness.yml@v2`（限速、密钥、审计统一在 OpenCI 维护）
- Slack 通知走 `your-org/openCI/actions/integrations/slack-notify@v2`
- 第三方 SHA 对齐 OpenCI 的 `manifest.yml`

OpenCI 关心**应用**的健康度（Sentry / Datadog / PostHog / LangSmith / Axiom）；EvolveCI 关心**流水线**的健康度（GitHub Actions API）。两套日报互不重叠。

## 设计文档

完整功能规格见 [`docs/SPEC.md`](docs/SPEC.md)。文档只描述**契约与行为**，不固化实现细节——便于按 P0–P4 拆解为可独立交付的任务（参考 §19 任务拆解表）。

## 状态

🚧 设计阶段。当前仓库只包含 SPEC，尚无可运行代码。落地节奏见 SPEC §16 实施优先级。

## License

[MIT](LICENSE)

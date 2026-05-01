# /triage — 实时 CI 故障分诊

**触发方式**：由 `agent-triage.yml` 每 15 分钟调用，或通过 `workflow_dispatch` 手动触发。

## 执行步骤

### 步骤 1：检查熔断器

读取 `memory/circuit/state.json`：
- 如果 `active: true` 且 `tripped_at` 距今 < 24h → 停止所有自动动作，输出警告后退出
- 如果 `active: true` 且距今 ≥ 24h → 自动恢复：将 `active` 设为 `false`，更新 `history`，写回文件，在对应 GitHub Issue 添加恢复 comment

### 步骤 2：加载上下文

- 读取 `data/onboarded-repos.yml` 获取监控仓库列表
- 读取 `memory/patterns/known-patterns.json` 加载已知模式（用于 Tier 1）
- 读取 `memory/counters/<今日日期>.json`（不存在则初始化为空计数器）

### 步骤 3：查询失败

对每个监控仓库，使用 GitHub MCP 工具查询最近 30 分钟内状态为 `failure` 或 `timed_out` 的 workflow runs。
- 若仓库配置了 `workflows` 字段（非 `"*"`），只查询指定 workflow
- 合并所有仓库结果，按时间倒序排列，**最多取 10 条**处理

### 步骤 4：逐条分析

对每条失败 run，依次执行：

**a. 获取日志**
- 通过 GitHub MCP 获取失败步骤的日志（优先获取最后 100 行）
- 用 Bash 调用 `lib/redact-log.sh` 脱敏：`echo "$LOG" | bash lib/redact-log.sh`

**b. 生成指纹**
- 提取日志中的错误行（`error:`、`fatal:`、`FAILED`、`Error:` 等关键词所在行）
- 结合失败的 step name，用 Bash 计算：`echo "<错误行+step>" | sha256sum | cut -c1-12`

**c. 去重检查**
- 查找 `memory/fingerprints/<fingerprint>.json` 是否存在
- 若存在且 `linked_issue` 有值：在对应 Issue 添加 comment（记录新发生次数），**跳过**建新 Issue
- 若存在但无 `linked_issue`：继续正常流程
- 若不存在：继续正常流程

**d. Tier 1 — 正则匹配**
- 对脱敏日志逐条测试 `known-patterns.json` 中每条 `match` 正则
- 命中 → 使用该 pattern 的 `auto_rerun`/`notify`/`severity`/`category`，记录 `pattern_id`，跳至步骤 5

**e. Tier 2 — 启发式关键词**（Tier 1 未命中时）
- 按 CLAUDE.md 中"Tier 2 启发式规则"表格逐条匹配
- 高/中置信度 → 决策并记录 `category`/`severity`，跳至步骤 5
- 低置信度 → 进入 Tier 3

**f. Tier 3 — 深度推理**（Tier 1+2 均未高置信命中时）
- 使用我自己的推理能力分析脱敏日志
- 参考 `prompts/observability/classify-failure-sonnet.md` 的分析框架和输出格式
- 输出：`category`、`severity`、`summary`、`root_cause`、`fix_suggestion`
- 若发现可复用正则模式，调用 `/learn-pattern` 命令记录

### 步骤 5：执行动作

根据分析结果：

| 条件 | 动作 |
|------|------|
| `auto_rerun=true` + 未超预算 + workflow 名不含禁止关键词 | `gh run rerun <run_id> --repo <repo> --failed` |
| 重跑后计数器超过 workflow 日限 | 调用 trip-circuit-breaker：更新 `memory/circuit/state.json` + 建 Issue |
| `notify=true` + `category != flaky` | 通过 GitHub MCP 创建 Issue（或更新已有 Issue） |
| `severity` 为 `critical` 或 `high` | 通过 Bash curl 发送 Slack webhook 通知 |

### 步骤 6：写入记忆

处理完所有失败后，更新以下文件并提交：

1. **`memory/fingerprints/<fp>.json`**：新建或更新（`count++`、`last_seen`、追加 `linked_runs`）
2. **`memory/counters/<今日日期>.json`**：更新重跑计数、分诊次数、各 Tier 命中数
3. **`memory/incidents/<YYYY-MM>/<YYYY-MM-DD>.jsonl`**：追加本次每条失败的 incident 记录

Incident 记录格式（每行一个 JSON）：
```json
{"ts":"<ISO8601>","run_id":"<id>","repo":"<org/repo>","workflow":"<name>.yml","fingerprint":"<12hex>","category":"<cat>","severity":"<sev>","tier":<1|2|3>,"action":"<rerun|issue|skip>","pattern_id":"<id或null>","summary":"<一句话>"}
```

提交命令：
```bash
git config user.name "EvolveCI Agent"
git config user.email "evolveci-agent@users.noreply.github.com"
git add memory/
git commit -m "memory: triage — <N> failures processed, <M> new patterns"
git push origin main
```

## 约束

- 单次 triage 最多处理 10 条失败（防止超时）
- 禁止重跑的 workflow 关键词：`deploy`、`release`、`security`、`scan`、`sign`、`publish`
- Tier 3 分析时，日志长度限制 ≤32768 字符（超出则截取最后 32768 字符）

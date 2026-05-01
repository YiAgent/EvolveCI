# /learn-pattern — 学习并记录新失败模式

**触发方式**：由 `/triage` 在 Tier 3 分析中发现可复用模式时内部调用。

## 参数（在 prompt 中以自然语言描述）

- `pattern`：正则表达式字符串
- `category`：`flaky` | `infra` | `code` | `dependency` | `security` | `unknown`
- `severity`：`low` | `medium` | `high` | `critical`
- `run_id`：发现该模式的 run ID
- `repo`：仓库名（org/repo）
- `summary`：一句话描述该模式

## 执行步骤

### 步骤 1：安全验证

在记录模式前，必须通过以下所有检查：

```bash
# 1. 长度检查
[ ${#PATTERN} -le 200 ] || { echo "ERROR: pattern too long"; exit 1; }

# 2. 禁止嵌套量词
echo "$PATTERN" | grep -qE '\(\.\*\)\+|\(\.\+\)\+|\(\[.*\]\)\+' && { echo "ERROR: nested quantifier"; exit 1; }

# 3. 语法有效性
echo "test" | grep -qE "$PATTERN" 2>&1; [ $? -ne 2 ] || { echo "ERROR: invalid regex"; exit 1; }
```

若任一检查失败，记录警告日志并退出（不保存 pattern）。

### 步骤 2：去重检查

读取 `memory/patterns/known-patterns.json`，检查：
- 是否已有 `id` 完全相同的 pattern
- 是否已有 `match` 字段与新 pattern 字符重叠 >80%（简单子串检查即可）

若去重命中 → 输出提示"模式已存在：<existing-id>"，退出（不重复保存）。

### 步骤 3：生成 Pattern ID

根据 summary 生成简短 kebab-case ID，例如：
- "GitHub registry rate limit" → `ghcr-rate-limit-v2`
- "pip install SSL error" → `pip-ssl-error`

检查 ID 是否已存在于 JSON，若冲突则追加 `-v2`、`-v3` 等。

### 步骤 4：追加到模式库

读取 `memory/patterns/known-patterns.json`，追加新条目：

```json
{
  "id": "<生成的ID>",
  "match": "<正则表达式>",
  "category": "<category>",
  "auto_rerun": <flaky/infra时考虑true，code/security时false>,
  "notify": <severity>=high/critical时true，否则false>,
  "severity": "<severity>",
  "seen_count": 1,
  "last_seen": "<今日日期YYYY-MM-DD>",
  "source": "agent-learned",
  "discovered_from": "<run_id>",
  "summary": "<一句话描述>"
}
```

**`auto_rerun` 决策规则**：
- `category=flaky` → `auto_rerun: true`
- `category=infra` + `severity=low/medium` → `auto_rerun: true`
- `category=code` / `category=security` / `severity=high/critical` → `auto_rerun: false`

### 步骤 5：更新 CLAUDE.md（高 severity 时）

若 `severity=high` 或 `severity=critical`，在 CLAUDE.md 的"近期学习"章节追加：
```
<今日日期>: <pattern-id> — <summary>
```

### 步骤 6：提交

```bash
git add memory/patterns/known-patterns.json CLAUDE.md
git commit -m "memory: learn-pattern — <pattern-id> (<category>, <severity>)"
git push origin main
```

## 重要说明

- 不再需要 PR 审核流程——Claude 直接写入 main 分支
- 安全检查（步骤 1）替代了人工审核
- 新 pattern 在下次 triage（15 分钟后）立即生效
- 若对某个模式不确定，宁可不记录（keep Tier 3），避免引入干扰规则

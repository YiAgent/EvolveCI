# /learn-pattern — 学习并记录新失败模式（写入 evolveci/pattern Issue）

**触发方式**：由 `/triage` 在 Tier 3 分析中发现可复用模式时内部调用。

> 内存模型：每个 pattern 是一条带 `evolveci/pattern` 标签的 GitHub Issue，
> body 为 JSON。详见 `docs/MEMORY-MODEL.md`。

## 输入

```json
{
  "id": "kebab-case-id",
  "match": "<regex>",
  "category": "flaky | infra | code | dependency | unknown",
  "severity": "critical | warning | info",
  "auto_rerun": true,
  "notify": false,
  "description": "human-readable",
  "examples": ["sample log line 1", "..."]
}
```

## 安全校验（必做）

按 `CLAUDE.md` 中的规则：

- 长度 ≤200 字符
- 禁止嵌套量词 `(.*)+`、`(.+)+`
- 必须能编译（`echo '<regex>' | python3 -c 'import re,sys; re.compile(sys.stdin.read().strip())'`）
- 不能匹配空字符串

任何一项失败 → 拒绝，不创建 Issue。

## 写入 Issue

Issue body 是 markdown 格式（人可读）+ 末尾 fenced JSON 代码块（triage 解析回来）。
渲染由 `scripts/render-pattern.sh` 完成——把 JSON 喂给它即可。

```bash
PATTERN_JSON=$(jq -nc \
  --arg id "$ID" \
  --arg match "$MATCH" \
  --arg category "$CATEGORY" \
  --arg severity "$SEVERITY" \
  --argjson auto_rerun "$AUTO_RERUN" \
  --argjson notify "$NOTIFY" \
  --arg description "$DESCRIPTION" \
  --argjson examples "$EXAMPLES_JSON_ARRAY" \
  '{id:$id, match:$match, category:$category, severity:$severity,
    auto_rerun:$auto_rerun, notify:$notify, description:$description,
    examples:$examples, source:"agent-learned",
    learned_at: now | strftime("%Y-%m-%dT%H:%M:%SZ")}')

BODY=$(printf '%s' "$PATTERN_JSON" | bash scripts/render-pattern.sh)

# 检查是否已经存在同 id 的 pattern issue
EXISTING=$(gh issue list --label evolveci/pattern --search "in:title pattern: ${ID}" \
            -L 1 --json number --jq '.[0].number // empty')

if [ -n "$EXISTING" ]; then
  # 已有同名 → 视情况编辑（更新描述 / 加 examples）
  gh issue comment "$EXISTING" --body "${ID} 重新学习于 $(date -u +%FT%TZ)"
  gh issue edit "$EXISTING" --body "$BODY"
else
  gh issue create \
    --title "pattern: ${ID}" \
    --label "evolveci/pattern,severity/${SEVERITY},category:${CATEGORY}" \
    --body "$BODY"
fi
```

## 不做什么

- 不写本地文件
- 不 git commit
- 不 push 任何分支
- 永远不要从用户输入直接拼接 regex（必须经过校验）

# /weekly-report — 每周深度复盘（提交 PR）

**触发方式**：由 `agent-weekly.yml` 每周一 UTC 02:00 调用，或通过 `workflow_dispatch` 手动触发。

> 这是四个 agent 中**唯一**会动 git 的命令：它在新分支上更新 `CLAUDE.md`
> 的"近期学习"章节，并打开一个 PR 等待 squash-merge。日报 / 心跳 / triage
> 全部走 Issue。详见 `docs/MEMORY-MODEL.md`。

## 执行步骤

### 步骤 1：聚合 7 天数据

- 列出最近一周更新过的 `evolveci/triage`（含已关闭）：
  ```bash
  SINCE=$(date -u -d '7 days ago' +%FT%TZ 2>/dev/null || date -u -v-7d +%FT%TZ)
  gh issue list --label evolveci/triage --state all \
    --search "updated:>${SINCE}" -L 100 \
    --json number,title,labels,createdAt,closedAt,body
  ```

- 列出本周建立的 `evolveci/pattern`：
  ```bash
  gh issue list --label evolveci/pattern --state all \
    --search "created:>${SINCE}" -L 100 --json number,title,body
  ```

- 收集 7 个工作日的 `evolveci/daily` issue body，提取关键指标用于趋势分析。

### 步骤 2：计算 DORA 指标

- Deployment frequency：识别有 deploy/release 关键字的 workflow runs
- Lead time for changes：commit → 成功 deploy 的中位数
- Change failure rate：deploy run 中失败的比例
- MTTR：`evolveci/triage` 从 created → closed 的中位数

### 步骤 3：归档过期 incident

把 7 天前已 close、未 reopen 的 `evolveci/triage` issue 加 `status/recovered`
标签（如尚无），不再做任何编辑。

### 步骤 4：生成报告 markdown

```markdown
# Weekly Deep Dive — {{iso_week}}

**周期**: {{week_start}} → {{week_end}} UTC

## 总览

…（与上周对比）

## DORA

| 指标 | 本周 | 上周 |
| --- | --- | --- |
| Deployment frequency | … | … |
| Lead time | … | … |
| CFR | … | … |
| MTTR | … | … |

## 本周关键 incidents (Top 5)

- #1234 …

## 学习模式 (新增 evolveci/pattern)

- #1456 …

## 行动建议

…（agent 推理）
```

### 步骤 5：开 PR（不要直接 push 到 main）

```bash
WEEK=$(date -u +%G-W%V)
BR="weekly/${WEEK}"

# 1) 在 ${BR} 分支上更新 CLAUDE.md 的"近期学习"章节
git switch -c "$BR"
python3 -c '...patch CLAUDE.md...' # 把上面 markdown 报告插到对应章节

git add CLAUDE.md
git -c "user.name=evolveci-agent" -c "user.email=evolveci-agent@users.noreply.github.com" \
    commit -m "weekly(${WEEK}): deep dive"
git push -u origin "$BR"

# 2) 开 PR；body 是完整报告
gh pr create \
  --base main --head "$BR" \
  --title "weekly: ${WEEK} deep dive" \
  --body-file <(echo "$REPORT_MARKDOWN")
```

PR 由人评审后 squash-merge。`/weekly-report` **不**自动 admin merge —
留给 owner 决定是否信任后续轮次再切换为 `--auto`。

## Slack 摘要（可选）

发送本周 5 个关键数字 + PR URL 到 `SLACK_WEBHOOK_URL`。

## 不做什么

- 不直接 push 到 main
- 不写 `memory/stats/weekly/`
- 不 close 还在 open 的 `evolveci/triage`（除非 `status/recovered` 已经存在
  且 ≥7 天没新动作）

# /daily-report — 24h CI 健康日报（v5.1 agent-when-needed）

**触发**：`agent-daily.yml` 工作日 UTC 01:00，或 `workflow_dispatch`。

> 我（agent）**不直接**查 gh / 算 success rate / 数 issue 数 — 那是
> `scripts/collect-daily.py` 一步完成的工作。我读它产生的 JSON，按模板渲染
> 中文 markdown，然后 upsert 到 `evolveci/daily` issue。

## ⚠️ 强制契约

**每次运行必须以 `gh issue create` 或 `gh issue edit` 结束**。哪怕收集到 0 数据，
仍然写一条 "no_data: true" issue — 这是发现"agent 跑了但啥都没做"的唯一信号。

## 步骤

### 1. 预处理

```bash
pip install --user --quiet pyyaml >/dev/null 2>&1 || python3 -m pip install --user --quiet pyyaml >/dev/null 2>&1
python3 scripts/collect-daily.py --since 24h --out /tmp/daily-stats.json
```

### 2. 渲染 markdown

读 `/tmp/daily-stats.json`，按下面的模板生成 body。`jq` 取值即可，**不需要再查 gh**。

```bash
S=/tmp/daily-stats.json

TODAY=$(date -u +%Y-%m-%d)
GENERATED=$(jq -r .generated_at "$S")
RUNS=$(jq    .totals.runs        "$S")
SUCC=$(jq    .totals.success     "$S")
FAIL=$(jq    .totals.failure     "$S")
SR=$(jq -r '(.totals.success_rate * 100 | floor)' "$S")
FR=$(jq -r '(.totals.flaky_rate   * 100 | floor)' "$S")
NEW_TRIAGE=$(jq .triage.new.count           "$S")
OPEN_OLD=$(jq   .triage.open_old.count      "$S")
NEW_PATT=$(jq   .triage.patterns_added.count "$S")
CIRC=$(jq -r .circuit.active                 "$S")
NO_DATA=$(jq -r .no_data                      "$S")
```

#### 有数据时

```markdown
# Daily Report — {{TODAY}}

**生成时间**: {{GENERATED}} UTC
**监控仓库**: {{repos}} 个（详见 data/onboarded-repos.yml）

## 总览

| 指标 | 今日 |
|------|------|
| run 总数 | {{RUNS}} |
| 成功 | {{SUCC}} |
| 失败 | {{FAIL}} |
| 成功率 | {{SR}}% |
| flaky 比例 | {{FR}}% |

## Top 失败 workflow

（来自 `top_failing_workflows[:5]`）
- `OpenCI · issue-comment` × 22
- ...

## 当日新增 triage

（来自 `triage.new.samples`）
- #35 `OpenCI · issue-comment · parse-command YAML syntax error` (category: code)
- ...

（若无：`_当日无新增 triage issue。_`）

## 仍 open 的 triage（昨日及之前）

（来自 `triage.open_old.samples`）

（若无：`_无超期 triage issue。_`）

## 学习

- 新增 `evolveci/pattern` × {{NEW_PATT}}
- 熔断器: active = {{CIRC}}
```

#### `no_data=true` 时

```markdown
# Daily Report — {{TODAY}}

**生成时间**: {{GENERATED}} UTC
**no_data**: true

过去 24 小时内没有任何 workflow run（已检查仓库 {{repos_list}}）。可能原因：
- 仓库当日静默（节假日 / 冻结）
- onboarded-repos.yml 配置错误
- API token 权限不足

详见 collect-daily.py 输出。
```

### 3. Upsert issue

```bash
TITLE="Daily Report — ${TODAY}"
EXISTING=$(gh issue list --label evolveci/daily \
            --search "in:title \"${TITLE}\"" -L 1 \
            --json number --jq '.[0].number // empty')

if [ -n "$EXISTING" ]; then
  gh issue edit "$EXISTING" --body "$REPORT_BODY"
else
  gh issue create --title "$TITLE" \
    --label "evolveci/daily,severity/info" \
    --body "$REPORT_BODY"
fi
```

### 4. Slack（可选）

`SR < 70%` 或 `FAIL > 50` 或 `CIRC = true` → 短摘要 + Issue URL 到 `SLACK_CI_WEBHOOK`。

## 不做什么

- 不写本地文件（`/tmp/*` 例外）
- 不 git commit / push
- 不在 prompt 中再查 gh — 用 `/tmp/daily-stats.json`

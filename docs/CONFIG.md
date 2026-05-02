# EvolveCI — Configuration Reference

Single source of truth for everything you can tune in this project. Anything
not listed here is hard-wired in code and changes via PR.

> **Companion doc**: [`docs/MEMORY-MODEL.md`](./MEMORY-MODEL.md) — how agent
> memory lives in GitHub Issues (label scheme, per-task semantics, migration).

> **Contract**: each row tells you the knob, where it lives, the default,
> and how to override. If you change a knob and nothing in the next column
> matches, the change won't take effect.

---

## Layer 1 — Runtime data (`data/`)

What the agent reads at run time. Edit these files directly; commits flow
through normal review.

| File | Purpose | Schema |
|------|---------|--------|
| `data/onboarded-repos.yml` | Which repos `/triage` monitors. Per-repo workflow allow / exclude lists, priority, private flag. | `repos: [{ name, workflows, priority, exclude?, private? }]` |
| `data/circuit-config.yml` | Circuit-breaker rerun budgets and `no_rerun` keyword guard. | `dimensions: { workflow, pattern, repo }`, `no_rerun: [...]` |
| `data/known-patterns.seed.json` | Seed regex catalogue Tier 1 matches against. Seeded into `evolveci/pattern` issues on first run via `scripts/seed-patterns.sh`. | `[{ id, match, category, severity, description, fix_hint, ... }]` |

Live (mutable) state lives entirely in `evolveci/*`-labelled GitHub Issues —
see [`docs/MEMORY-MODEL.md`](./MEMORY-MODEL.md) for the schema. There is no
on-disk state to hand-edit.

---

## Layer 2 — Workflow-call wrapper (`_call-harness.yml`)

Boilerplate shared by every agent workflow. Everything in this file applies
to **all four** agents at once.

| Knob | Resolved from | Default | When to change |
|------|---------------|---------|----------------|
| LLM model | `vars.CLAUDE_MODEL` | `glm-5.1` | Switch the whole project to a different model. Set as a repo or org variable; no code change. |
| API provider | hard-coded | `anthropic` | Bedrock/Vertex/Foundry rollout — edit `_call-harness.yml`. |
| API base URL | `secrets.GLM_BASE_URL` | `https://open.bigmodel.cn/api/anthropic` | Switch endpoint (e.g. `https://api.z.ai/api/anthropic`). |
| API key | `secrets.GLM_API_KEY` | required | Rotate via repo / org secrets. |
| GitHub token (cross-repo) | `secrets.CROSS_REPO_PAT` then `secrets.GITHUB_TOKEN` | falls back automatically | Set `CROSS_REPO_PAT` only when monitored repos live outside this org. |
| Slack webhook | `secrets.SLACK_CI_WEBHOOK` | unset (alerts go silent) | Set to receive Slack alerts. |
| Permissions superset | hard-coded | `contents:write, issues:write, pull-requests:write, actions:read, id-token:write` | Only edit when the harness reusable workflow's permission requirements change. |
| Harness pin | `YiAgent/OpenCI/.github/workflows/claude-harness.yml@main` | tracks main | Pin to a SHA when you want a frozen contract. |

---

## Layer 3 — Per-task knobs (one row per `agent-*.yml`)

Each agent workflow file declares cron, slash command, turn budget, timeout,
and a permissions block. Cron and permissions MUST live in the workflow file
(GitHub workflow_call requires the caller to pre-grant a permissions superset
of what the called workflow declares). The other three live there because
they're naturally read in the same place as the cron — don't hunt for them
elsewhere.

| Workflow | Cron | Prompt | max-turns | timeout-min | Notes |
|----------|------|--------|-----------|-------------|-------|
| `agent-heartbeat.yml` | `0 */6 * * *` | `/heartbeat` | 15 | 10 | 5 health probes |
| `agent-triage.yml` | `*/15 * * * *` | `/triage` | 30 | 20 | manual override via `workflow_dispatch.inputs.prompt`; extra allow-list for `bash lib/redact-log.sh` |
| `agent-daily.yml` | `0 1 * * 1-5` | `/daily-report` | 40 | 25 | aggregate 24h CI data |
| `agent-weekly.yml` | `0 2 * * 1` | `/weekly-report` | 50 | 35 | DORA + CLAUDE.md update |

If a task starts hitting `Reached maximum number of turns`, raise its
`max-turns` (and bump `timeout-minutes` proportionally) — they're the only
knobs you need to touch in the workflow file.

---

## Layer 4 — Slash-command bodies (`.claude/commands/*.md`)

The actual instructions Claude executes. The harness resolves a `/foo` prompt
to `.claude/commands/foo.md` in this repo, applies Mustache substitution
(`{{repo}}`, `{{run_url}}`, etc.), and ships the rendered text to the model.

Edit these to change *what* the agent does, not *when* / *how*.

| File | Used by | What you change here |
|------|---------|----------------------|
| `.claude/commands/heartbeat.md` | `/heartbeat` | Health-probe definitions, severity rules |
| `.claude/commands/triage.md` | `/triage` | Tier 1/2/3 decision tree, action policy |
| `.claude/commands/daily-report.md` | `/daily-report` | Daily report template, what stats to capture |
| `.claude/commands/weekly-report.md` | `/weekly-report` | Weekly aggregation, DORA metrics, archive policy |
| `.claude/commands/check-circuit.md` | `/check-circuit` | Circuit-breaker auto-recovery logic |
| `.claude/commands/learn-pattern.md` | `/learn-pattern` | New-pattern record format |

---

## Layer 5 — Agent persona (`CLAUDE.md`)

Cross-task identity, safety rails, Tier 2 heuristic table, and recent
learnings. Loaded automatically by the harness as part of every Claude
invocation. Edit when the agent's *judgement* or *priorities* should
change repo-wide.

---

## Quick reference — "I want to change X"

| I want to… | Edit |
|-----------|------|
| Add a repo to monitor | `data/onboarded-repos.yml` |
| Lower the daily rerun cap | `data/circuit-config.yml` |
| Switch from GLM to Claude direct | unset `secrets.GLM_BASE_URL`, set `secrets.GLM_API_KEY` to an `sk-ant-…` key, set `vars.CLAUDE_MODEL=claude-sonnet-4-5-20250929` |
| Switch the whole project to a different model | set `vars.CLAUDE_MODEL` |
| Run triage every 5 min instead of 15 | `.github/workflows/agent-triage.yml` (cron) |
| Give weekly more thinking budget | `.github/workflows/agent-weekly.yml` (`max-turns`) |
| Change how `/triage` makes decisions | `.claude/commands/triage.md` |
| Change the agent's safety rules | `CLAUDE.md` |
| Fix a bug in the harness itself | upstream PR to `YiAgent/OpenCI` |

---

## Required org / repo configuration to deploy

Minimum to run:

- **secret** `GLM_API_KEY` (or whichever provider's key) — required.

Optional but recommended:

- **secret** `GLM_BASE_URL` — overrides the hard-coded default endpoint.
- **secret** `CROSS_REPO_PAT` — required if any onboarded repo is private (e.g. `YiAgent/aicert`) or lives outside this repo's `GITHUB_TOKEN` scope. Needs `repo` scope (read+write on issues, read on actions) for every onboarded private repo.
- **secret** `SLACK_CI_WEBHOOK` — without it, Slack alerts fall through silently (workflows still succeed).
- **var** `CLAUDE_MODEL` — pin to a specific model id without editing workflow files.

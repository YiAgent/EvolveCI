# EvolveCI — Memory Model (Issues as memory)

## Why GitHub Issues, not files

Earlier versions wrote agent memory to `memory/*.json` and committed every run.
Result: noisy git history (one commit per heartbeat / triage / daily / pattern),
hard to search, and weekly aggregation contended with concurrent commits.

Issues fix all three: searchable by label / title, naturally append-on-update
via comments, no git-history churn. This file is the contract for *which* issue
holds *what*.

## Label scheme

All EvolveCI labels are prefixed with `evolveci/` so a consumer can filter the
agent's surface from human-authored issues with one query.

### Type labels (mutually exclusive)

| Label | One issue per | Purpose |
|-------|--------------|---------|
| `evolveci/triage` | unique fingerprint | A CI failure observation. New occurrences append to the existing issue. |
| `evolveci/heartbeat` | open at most one | Active health alert. Auto-closed when probes recover. |
| `evolveci/daily` | calendar date | One per day. Re-runs the same day **edit** the body, not append a new issue. |
| `evolveci/pattern` | learned pattern | Replaces `memory/patterns/known-patterns.json`. Body holds the JSON definition. |
| `evolveci/circuit` | open at most one | Circuit breaker state. Body is the JSON state object; comments are the trip / recover history. |

### Faceted labels (any may co-exist)

| Label | Format | Used by |
|-------|--------|---------|
| `severity/critical` `severity/warning` `severity/info` | severity tier | all agents |
| `fingerprint:<12hex>` | sha256 prefix | triage (exact-match dedup key) |
| `repo:<org>-<repo>` | hyphenated repo | triage / daily |
| `category:flaky` `category:infra` `category:code` `category:dependency` `category:unknown` | failure category | triage |
| `status/recovered` | sentinel on close | heartbeat / triage |

### Bootstrapping

Run `scripts/bootstrap-labels.sh` once per repo. The script is idempotent —
re-running creates only missing labels. The agent will also create missing
`fingerprint:` and `repo:` labels on demand (label creation is cheap).

## Per-task semantics

### `/triage` (every 15 min)

Pseudo-flow:

1. compute `fp = sha256(error_lines + step_name)[:12]`
2. `gh issue list --label fingerprint:${fp} --state open` → if any exists, comment on it with the new occurrence (timestamp + run URL) and increment the `occurrences:` counter line in the body
3. otherwise create a new issue with labels `evolveci/triage`, `severity/<x>`, `category:<x>`, `fingerprint:${fp}`, `repo:<org>-<repo>` and the analysis as body

### `/heartbeat` (every 6h)

Probes now query GitHub instead of files:

| Probe | Old (file) | New (issue query) |
|-------|-----------|-------------------|
| 1. Triage activity | newest `memory/incidents/` ≤24h | `gh issue list --label evolveci/triage --state all --search "updated:>$(date -u -v-24H +%FT%TZ)"` returns ≥1 |
| 2. Pattern catalogue health | `≥10 entries` in JSON | `gh issue list --label evolveci/pattern -L 100 --json url` returns ≥10 items |
| 3. Daily-report freshness | newest `memory/stats/daily/` ≤48h | `gh issue list --label evolveci/daily --search "updated:>$(date -u -v-48H +%FT%TZ)"` returns ≥1 |
| 4. Circuit state | read `memory/circuit/state.json` | parse the body of the single `evolveci/circuit` issue |
| 5. Directory integrity | check 7 dirs exist | replaced by "labels exist" check via `gh label list` |

If any probe fails:
- Search for an open `evolveci/heartbeat` issue. If exists → append a comment
  with the failed-probe summary. Else → create one.

If all probes pass:
- Close any open `evolveci/heartbeat` issue with a comment "all probes
  recovered at <ts>" and label `status/recovered`.

### `/daily-report` (workdays UTC 01:00)

Aggregate 24h, then either edit-in-place (re-run same day) or create a new
issue:

- title pattern: `Daily Report — YYYY-MM-DD`
- existing? `gh issue list --label evolveci/daily --search "in:title $(date -u +%Y-%m-%d)"`
- yes → `gh issue edit <num> --body-file -`
- no  → `gh issue create --label evolveci/daily,severity/info`

No more `memory/stats/daily/<date>.json` writes.

### `/weekly-report` (Mon UTC 02:00)

Weekly is the **only** workflow that produces a PR (not an issue). It writes
the long-form report into `CLAUDE.md`'s "近期学习" section and optionally
archives old triage issues by closing them.

Branch name: `weekly/YYYY-Www`. PR title: `weekly: YYYY-Www deep dive`.

PRs are reviewed by humans and squash-merged. (You can flip the agent to
`--admin --auto` once you've audited a few cycles.)

### `/learn-pattern`

A single `gh issue create` writes the pattern as JSON in the body, labeled
`evolveci/pattern`. Triage reads patterns via:

```
gh issue list --label evolveci/pattern -L 100 --json body --jq '.[].body' \
  | while read -r b; do echo "$b" | jq -c .; done
```

### `/check-circuit`

The single `evolveci/circuit` issue's body is a JSON state object:

```json
{ "active": false, "tripped_at": null, "tripped_reason": null, "history": [] }
```

- trip: `gh issue edit` with the new body, plus a `gh issue comment` recording the trigger
- recover: edit body to `active=false`; comment with the recovery time
- if no issue exists, create one with the default body

## Migration

The transition is one-way and incremental:

1. **First run after this change**: each command finds zero matching issues and
   starts populating them. No legacy `memory/` reads required.
2. **Old `memory/` files**: kept as historical archive; not read, not written.
   A future cleanup PR can `git rm -r memory/`.
3. **Labels**: bootstrap by `scripts/bootstrap-labels.sh`, OR auto-created by
   the agent on first use.

## Failure modes & limits

- **Issue search latency**: ~1 API call per command. Acceptable for cron-driven
  workflows.
- **Issue volume**: triage creates ≤1 issue per unique fingerprint. With ~100
  fingerprints in steady state, GitHub list APIs return them in a single page.
- **Rate limits**: every command does ≤5–10 API calls. Even at the 15-min
  cron of triage, that's well under GitHub's per-hour budget.
- **Concurrency**: heartbeat / triage may race on the same `evolveci/heartbeat`
  issue. GitHub's API has no transactional update; the agent uses
  `--state open` + create-if-missing logic, accepting at most one duplicate
  per race.

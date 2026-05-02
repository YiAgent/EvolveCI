#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# triage-dry-run.sh — print what /triage *would* see, without writing issues.
# ─────────────────────────────────────────────────────────────────────────────
# Useful when /triage runs report "success" yet zero evolveci/triage issues
# get created. Either no failures exist, or the agent's gh-query step is
# wrong. This script answers the first question definitively.
#
# Usage:
#   bash scripts/triage-dry-run.sh                 # default: 24h window
#   bash scripts/triage-dry-run.sh 30m             # custom window
#   REPOS_FILE=other/path.yml bash scripts/triage-dry-run.sh
#
# Outputs JSON-lines, one per repo, plus a final summary line.
# Honors the same exclude/private fields as data/onboarded-repos.yml.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

WINDOW="${1:-24h}"
REPOS_FILE="${REPOS_FILE:-data/onboarded-repos.yml}"

if [ ! -f "$REPOS_FILE" ]; then
  echo "{\"error\":\"repos file not found\",\"path\":\"$REPOS_FILE\"}" >&2
  exit 2
fi

# Parse the window (e.g. 30m / 24h / 7d) into a UTC ISO timestamp.
case "$WINDOW" in
  *m) MIN=${WINDOW%m}; SINCE=$(date -u -v-"${MIN}"M +%FT%TZ 2>/dev/null || date -u -d "-${MIN} minutes" +%FT%TZ) ;;
  *h) HR=${WINDOW%h};  SINCE=$(date -u -v-"${HR}"H +%FT%TZ 2>/dev/null  || date -u -d "-${HR} hours" +%FT%TZ) ;;
  *d) DAY=${WINDOW%d}; SINCE=$(date -u -v-"${DAY}"d +%FT%TZ 2>/dev/null  || date -u -d "-${DAY} days" +%FT%TZ) ;;
  *) echo "{\"error\":\"bad window format, use 30m / 24h / 7d\"}" >&2; exit 2 ;;
esac

echo "{\"status\":\"start\",\"window\":\"$WINDOW\",\"since\":\"$SINCE\",\"repos_file\":\"$REPOS_FILE\"}"

# yq is not always present — fall back to a python yaml parser.
parse_repos() {
  if command -v yq >/dev/null 2>&1; then
    yq -o=json '.repos' "$REPOS_FILE"
  else
    python3 -c "
import json, sys, yaml
with open('$REPOS_FILE') as f:
    print(json.dumps(yaml.safe_load(f).get('repos', [])))
"
  fi
}

TOTAL_FAIL=0
REPOS_JSON=$(parse_repos)

echo "$REPOS_JSON" | jq -c '.[]' | while IFS= read -r repo; do
  NAME=$(echo "$repo" | jq -r .name)
  EXCL_JSON=$(echo "$repo" | jq -c '.exclude // []')
  PRIVATE=$(echo "$repo" | jq -r '.private // false')

  # Honor the private flag from data/onboarded-repos.yml: private repos must
  # be queried via CROSS_REPO_PAT, not the default GITHUB_TOKEN, which only
  # has access to the host repo.
  TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [ "$PRIVATE" = "true" ]; then
    if [ -z "${CROSS_REPO_PAT:-}" ]; then
      echo "{\"repo\":\"$NAME\",\"error\":\"private repo requires CROSS_REPO_PAT\"}"
      continue
    fi
    TOKEN="$CROSS_REPO_PAT"
  fi

  # Build a workflowDatabaseId → path map so exclude-by-filename actually works.
  # (gh run list returns the human-friendly workflowName, not the file path,
  # which is what onboarded-repos.yml exclude entries are spelled as.)
  # Surface auth/permission failures explicitly instead of swallowing them
  # into '{}', otherwise a private-repo permission failure looks identical
  # to "no failed runs", which defeats the dry-run.
  WF_ERR=$(mktemp)
  if ! WF_MAP=$(GH_TOKEN="$TOKEN" gh api "repos/$NAME/actions/workflows" --paginate \
    --jq '[.workflows[] | {key: (.id|tostring), value: .path}] | from_entries' 2>"$WF_ERR"); then
    echo "{\"repo\":\"$NAME\",\"error\":\"workflow lookup failed\",\"detail\":$(jq -Rs . <"$WF_ERR")}"
    rm -f "$WF_ERR"
    continue
  fi
  rm -f "$WF_ERR"

  RUN_ERR=$(mktemp)
  if ! RUNS_JSON=$(GH_TOKEN="$TOKEN" gh run list --repo "$NAME" --status failure --limit 100 \
    --json databaseId,name,workflowName,workflowDatabaseId,createdAt,conclusion,event,headBranch,url \
    --created ">$SINCE" 2>"$RUN_ERR"); then
    echo "{\"repo\":\"$NAME\",\"error\":\"run lookup failed\",\"detail\":$(jq -Rs . <"$RUN_ERR")}"
    rm -f "$RUN_ERR"
    continue
  fi
  rm -f "$RUN_ERR"

  # Annotate each run with its workflow file basename, then filter out excludes.
  RUNS_JSON=$(echo "$RUNS_JSON" | jq --argjson map "$WF_MAP" --argjson excl "$EXCL_JSON" '
    [
      .[]
      | . + {workflowFile: ($map[(.workflowDatabaseId|tostring)] // "" | split("/") | last)}
      | select(.workflowFile as $f | ($excl | index($f)) | not)
    ]
  ')

  COUNT=$(echo "$RUNS_JSON" | jq 'length')
  TOTAL_FAIL=$((TOTAL_FAIL + COUNT))

  echo "$RUNS_JSON" | jq -c --arg repo "$NAME" --argjson count "$COUNT" '{
    repo:    $repo,
    count:   $count,
    samples: ([.[] | {id: .databaseId, wf: (.workflowName // .name), file: .workflowFile, at: .createdAt, branch: .headBranch}] | .[0:5])
  }'
done

# Final summary (re-count from the listing because pipe-subshell loses the var).
SUMMARY=$(echo "$REPOS_JSON" | jq -c --arg since "$SINCE" '{
  status:  "done",
  since:   $since,
  repos:   [.[].name]
}')
echo "$SUMMARY"

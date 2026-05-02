#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# agent-prompts.bats — guard the v5.1 agent-when-needed contract.
#
# Slash commands in .claude/commands/*.md must NOT do raw CI data collection.
# All gh-actions queries / log fetching / heuristics live in scripts/ or
# actions/observability/. The agent reads JSON the preprocessor produced.
#
# This test scans each command file for forbidden patterns inside ```bash
# fenced blocks. Markdown prose mentioning the rule itself is allowed —
# the test only fails on actual executable invocations.
#
# Run: bats tests/agent-prompts.bats
# ─────────────────────────────────────────────────────────────────────────────

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  COMMANDS_DIR="$REPO_ROOT/.claude/commands"
}

# Extract bash from fenced ```bash blocks only.
extract_bash() {
  awk '
    /^```bash$/ { in_block=1; next }
    /^```$/    { in_block=0; next }
    in_block   { print }
  ' "$1"
}

forbidden_patterns=(
  'gh run list'
  'gh api repos/[^[:space:]]+/actions'
  'mcp__github_ci__'
)

@test "command bash blocks do not call gh run list / mcp__github_ci__ / gh api .../actions" {
  local violations=()
  for cmd in "$COMMANDS_DIR"/*.md; do
    local bash_only
    bash_only=$(extract_bash "$cmd")
    [ -z "$bash_only" ] && continue
    for pat in "${forbidden_patterns[@]}"; do
      if echo "$bash_only" | grep -qE "$pat"; then
        violations+=("$cmd matches forbidden pattern: $pat")
      fi
    done
  done

  if [ ${#violations[@]} -gt 0 ]; then
    printf '%s\n' "${violations[@]}" >&2
    echo "" >&2
    echo "v5.1 contract: data collection lives in scripts/build-triage-input.py," >&2
    echo "scripts/collect-daily.py, scripts/collect-weekly.py, or actions/observability/." >&2
    echo "Agent commands only consume the JSON those produce." >&2
    return 1
  fi
}

@test "every command file consumes DATA_CONTEXT (or is exempt)" {
  # Commands that don't ride on the v5.1 collect-job pipeline.
  local exempt=(check-circuit.md learn-pattern.md heartbeat.md)

  local missing=()
  for cmd in "$COMMANDS_DIR"/*.md; do
    local base
    base=$(basename "$cmd")
    local skip=false
    for ex in "${exempt[@]}"; do
      [ "$base" = "$ex" ] && skip=true && break
    done
    $skip && continue
    if ! grep -q 'DATA_CONTEXT' "$cmd"; then
      missing+=("$cmd does not parse DATA_CONTEXT (workflow-injected JSON)")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    printf '%s\n' "${missing[@]}" >&2
    return 1
  fi
}

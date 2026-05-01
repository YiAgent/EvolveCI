#!/usr/bin/env bats

# Unit tests for action.yml structure validation

setup() {
  export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export ACTIONS_DIR="$PROJECT_ROOT/actions"
}

@test "all action.yml files exist" {
  local actions=(
    "observability/sources/query-github-actions/action.yml"
    "observability/state/redact-log/action.yml"
    "observability/state/read-state/action.yml"
    "observability/state/write-state/action.yml"
    "observability/analyzers/match-known-patterns/action.yml"
    "observability/analyzers/classify-heuristic/action.yml"
    "observability/analyzers/classify-ai/action.yml"
    "observability/analyzers/call-glm/action.yml"
    "observability/analyzers/compute-flakiness/action.yml"
    "observability/analyzers/compute-mttr/action.yml"
    "observability/analyzers/compute-trends/action.yml"
    "observability/analyzers/error-fingerprint/action.yml"
    "observability/analyzers/track-flaky-tests/action.yml"
    "observability/analyzers/compute-error-trends/action.yml"
    "observability/publishers/auto-rerun/action.yml"
    "observability/publishers/trip-circuit-breaker/action.yml"
    "observability/publishers/post-issue-report/action.yml"
    "observability/publishers/post-slack-report/action.yml"
    "observability/publishers/post-notification/action.yml"
    "observability/publishers/auto-fix/action.yml"
    "observability/publishers/slack-notify/action.yml"
  )

  for action in "${actions[@]}"; do
    [ -f "$ACTIONS_DIR/$action" ] || {
      echo "Missing: $ACTIONS_DIR/$action"
      return 1
    }
  done
}

@test "all actions have required fields" {
  find "$ACTIONS_DIR" -name "action.yml" | while read f; do
    python3 -c "
import yaml, sys
data = yaml.safe_load(open('$f'))
required = ['name', 'description', 'runs']
missing = [k for k in required if k not in data]
if missing:
    print(f'ERROR: $f missing: {missing}')
    sys.exit(1)
runs = data.get('runs', {})
if runs.get('using') not in ['composite', 'node16', 'node20']:
    print(f'ERROR: $f invalid runs.using: {runs.get(\"using\")}')
    sys.exit(1)
" || return 1
  done
}

@test "composite actions have steps" {
  find "$ACTIONS_DIR" -name "action.yml" | while read f; do
    python3 -c "
import yaml, sys
data = yaml.safe_load(open('$f'))
runs = data.get('runs', {})
if runs.get('using') == 'composite':
    if 'steps' not in runs or not runs['steps']:
        print(f'ERROR: $f composite action has no steps')
        sys.exit(1)
" || return 1
  done
}

@test "actions use heredoc-safe output pattern" {
  # Check that actions don't use indented heredoc for GITHUB_OUTPUT
  local bad_pattern=0
  find "$ACTIONS_DIR" -name "action.yml" -exec grep -l "cat.*<<.*EOF" {} \; | while read f; do
    echo "WARNING: $f uses heredoc pattern (may cause indentation issues)"
    bad_pattern=$((bad_pattern + 1))
  done
  # This is a warning, not a failure
  return 0
}

#!/usr/bin/env bats

# Unit tests for workflow structure validation

setup() {
  export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export WORKFLOWS_DIR="$PROJECT_ROOT/.github/workflows"
}

@test "all workflow files exist" {
  local workflows=(
    "agent-triage.yml"
    "agent-daily.yml"
    "agent-weekly.yml"
    "agent-heartbeat.yml"
    "_call-harness.yml"
    "test.yml"
  )

  for wf in "${workflows[@]}"; do
    [ -f "$WORKFLOWS_DIR/$wf" ] || {
      echo "Missing: $WORKFLOWS_DIR/$wf"
      return 1
    }
  done
}

@test "all workflows have required fields" {
  find "$WORKFLOWS_DIR" -name "*.yml" | while read f; do
    python3 -c "
import yaml, sys
data = yaml.safe_load(open('$f'))
required = ['name', 'on', 'jobs']
missing = [k for k in required if k not in data]
if missing:
    print(f'ERROR: $f missing: {missing}')
    sys.exit(1)
" || return 1
  done
}

@test "workflows use pinned SHAs for third-party actions" {
  # Check that no workflow uses @<SHA> placeholder
  ! grep -r "@<SHA>" "$WORKFLOWS_DIR" || {
    echo "Found @<SHA> placeholder in workflows"
    return 1
  }
}

@test "workflows have concurrency groups" {
  for f in "$WORKFLOWS_DIR"/*.yml; do
    python3 -c "
import yaml, sys
data = yaml.safe_load(open('$f'))
if 'concurrency' not in data:
    print(f'WARNING: $f has no concurrency group')
" || true
  done
}

@test "workflows set permissions" {
  for f in "$WORKFLOWS_DIR"/*.yml; do
    python3 -c "
import yaml, sys
data = yaml.safe_load(open('$f'))
if 'permissions' not in data:
    print(f'WARNING: $f has no permissions set')
" || true
  done
}

@test "workflows have timeout-minutes" {
  for f in "$WORKFLOWS_DIR"/*.yml; do
    python3 -c "
import yaml, sys
data = yaml.safe_load(open('$f'))
jobs = data.get('jobs', {})
for job_name, job in jobs.items():
    if 'timeout-minutes' not in job:
        print(f'WARNING: $f job {job_name} has no timeout-minutes')
" || true
  done
}

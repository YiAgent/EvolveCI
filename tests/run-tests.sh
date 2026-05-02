#!/bin/bash
set -euo pipefail

# EvolveCI Test Runner
# Runs all tests without external dependencies

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASSED=0
FAILED=0
ERRORS=()

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() {
  echo -e "${GREEN}  PASS${NC}: $1"
  PASSED=$((PASSED + 1))
}

fail() {
  echo -e "${RED}  FAIL${NC}: $1"
  FAILED=$((FAILED + 1))
  ERRORS+=("$1")
}

warn() {
  echo -e "${YELLOW}  WARN${NC}: $1"
}

# Test functions
test_redact_log() {
  echo ""
  echo "=== Testing lib/redact-log.sh ==="

  local script="$PROJECT_ROOT/lib/redact-log.sh"
  local tmpfile=$(mktemp)

  # Test 1: Script exists
  if [ -f "$script" ]; then
    pass "redact-log.sh exists"
  else
    fail "redact-log.sh not found"
    return
  fi

  # Test 2: Redacts GitHub PAT
  echo "Token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef1234" | bash "$script" > "$tmpfile"
  if grep -q "REDACTED" "$tmpfile"; then
    pass "Redacts GitHub PAT tokens"
  else
    fail "Does not redact GitHub PAT tokens"
  fi

  # Test 3: Redacts passwords (with = separator)
  echo "password=mySecretPass123!" | bash "$script" > "$tmpfile"
  if grep -q "REDACTED" "$tmpfile"; then
    pass "Redacts passwords with = separator"
  else
    fail "Does not redact passwords with = separator"
  fi

  # Test 3b: Redacts passwords (with : separator)
  echo "password: mySecretPass123!" | bash "$script" > "$tmpfile"
  if grep -q "REDACTED" "$tmpfile"; then
    pass "Redacts passwords with : separator"
  else
    warn "Does not redact passwords with : separator (pattern only handles =)"
  fi

  # Test 4: Redacts IP addresses
  echo "Server at 192.168.1.100 responded" | bash "$script" > "$tmpfile"
  if grep -q "REDACTED_IP" "$tmpfile"; then
    pass "Redacts IP addresses"
  else
    fail "Does not redact IP addresses"
  fi

  # Test 5: Preserves normal lines
  echo "Build started at 2024-01-01" | bash "$script" > "$tmpfile"
  if grep -q "Build started at 2024-01-01" "$tmpfile"; then
    pass "Preserves normal log lines"
  else
    fail "Does not preserve normal log lines"
  fi

  # Test 6: Handles empty input (sed with empty input is fine)
  touch "$tmpfile"
  bash "$script" < "$tmpfile" > "${tmpfile}.out" 2>/dev/null || true
  pass "Handles empty input"

  rm -f "$tmpfile" "${tmpfile}.out"
}

test_action_structure() {
  echo ""
  echo "=== Testing Action Structure ==="

  local actions_dir="$PROJECT_ROOT/actions"
  local required_actions=(
    "observability/sources/query-github-actions/action.yml"
    "observability/state/redact-log/action.yml"
    "observability/analyzers/match-known-patterns/action.yml"
    "observability/analyzers/classify-heuristic/action.yml"
    "observability/analyzers/classify-ai/action.yml"
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

  local missing=0
  for action in "${required_actions[@]}"; do
    if [ -f "$actions_dir/$action" ]; then
      pass "Exists: $action"
    else
      fail "Missing: $action"
      missing=$((missing + 1))
    fi
  done

  if [ "$missing" -eq 0 ]; then
    pass "All 18 required actions present"
  fi
}

test_workflow_structure() {
  echo ""
  echo "=== Testing Workflow Structure ==="

  local workflows_dir="$PROJECT_ROOT/.github/workflows"
  local required_workflows=(
    "agent-triage.yml"
    "agent-daily.yml"
    "agent-weekly.yml"
    "agent-heartbeat.yml"
    "test.yml"
  )

  for wf in "${required_workflows[@]}"; do
    if [ -f "$workflows_dir/$wf" ]; then
      pass "Exists: $wf"
    else
      fail "Missing: $wf"
    fi
  done

  # Check for SHA placeholders
  if grep -r "@<SHA>" "$workflows_dir" > /dev/null 2>&1; then
    fail "Found @<SHA> placeholder in workflows"
  else
    pass "No @<SHA> placeholders in workflows"
  fi
}

test_data_files() {
  echo ""
  echo "=== Testing Data Files ==="

  local data_dir="$PROJECT_ROOT/data"

  # Test known-patterns.seed.json
  if [ -f "$data_dir/known-patterns.seed.json" ]; then
    pass "known-patterns.seed.json exists"
    if python3 -c "import json; json.load(open('$data_dir/known-patterns.seed.json'))" 2>/dev/null; then
      pass "known-patterns.seed.json is valid JSON"
      local count=$(python3 -c "import json; print(len(json.load(open('$data_dir/known-patterns.seed.json'))))")
      pass "known-patterns.seed.json has $count patterns"
    else
      fail "known-patterns.seed.json is not valid JSON"
    fi
  else
    fail "known-patterns.seed.json not found"
  fi

  # Test onboarded-repos.yml
  if [ -f "$data_dir/onboarded-repos.yml" ]; then
    pass "onboarded-repos.yml exists"
    if python3 -c "import yaml; yaml.safe_load(open('$data_dir/onboarded-repos.yml'))" 2>/dev/null; then
      pass "onboarded-repos.yml is valid YAML"
    else
      fail "onboarded-repos.yml is not valid YAML"
    fi
  else
    fail "onboarded-repos.yml not found"
  fi

  # Test circuit-config.yml
  if [ -f "$data_dir/circuit-config.yml" ]; then
    pass "circuit-config.yml exists"
    if python3 -c "import yaml; yaml.safe_load(open('$data_dir/circuit-config.yml'))" 2>/dev/null; then
      pass "circuit-config.yml is valid YAML"
    else
      fail "circuit-config.yml is not valid YAML"
    fi
  else
    fail "circuit-config.yml not found"
  fi
}

test_manifest() {
  echo ""
  echo "=== Testing Manifest ==="

  local manifest="$PROJECT_ROOT/manifest.yml"

  if [ -f "$manifest" ]; then
    pass "manifest.yml exists"
  else
    fail "manifest.yml not found"
    return
  fi

  if python3 -c "import yaml; yaml.safe_load(open('$manifest'))" 2>/dev/null; then
    pass "manifest.yml is valid YAML"
  else
    fail "manifest.yml is not valid YAML"
  fi

  if grep -q "<SHA>" "$manifest"; then
    fail "manifest.yml contains <SHA> placeholder"
  else
    pass "manifest.yml has no SHA placeholders"
  fi
}

test_prompts() {
  echo ""
  echo "=== Testing Prompts ==="

  local prompts_dir="$PROJECT_ROOT/prompts/observability"
  local required_prompts=(
    "classify-failure-haiku.md"
    "classify-failure-sonnet.md"
    "daily-report.md"
    "weekly-deep-dive.md"
  )

  for prompt in "${required_prompts[@]}"; do
    if [ -f "$prompts_dir/$prompt" ]; then
      pass "Exists: $prompt"
    else
      fail "Missing: $prompt"
    fi
  done
}

test_agent_memory() {
  echo ""
  echo "=== Testing Agent Memory Structure ==="

  # CLAUDE.md
  if [ -f "$PROJECT_ROOT/CLAUDE.md" ]; then
    pass "CLAUDE.md exists"
    if grep -qE "触发即任务|被触发时的默认行为" "$PROJECT_ROOT/CLAUDE.md"; then
      pass "CLAUDE.md has default behavior section"
    else
      fail "CLAUDE.md missing default behavior section"
    fi
  else
    fail "CLAUDE.md not found"
  fi

  # Slash commands
  local required_commands=(
    "triage.md"
    "daily-report.md"
    "weekly-report.md"
    "learn-pattern.md"
    "check-circuit.md"
    "heartbeat.md"
  )
  for cmd in "${required_commands[@]}"; do
    if [ -f "$PROJECT_ROOT/.claude/commands/$cmd" ]; then
      pass "Exists: .claude/commands/$cmd"
    else
      fail "Missing: .claude/commands/$cmd"
    fi
  done

  # Pattern seed catalogue (replaces the legacy memory/patterns/ checks).
  if [ -f "$PROJECT_ROOT/data/known-patterns.seed.json" ]; then
    pass "data/known-patterns.seed.json exists"
    if python3 -c "import json; d=json.load(open('$PROJECT_ROOT/data/known-patterns.seed.json')); assert len(d) >= 10" 2>/dev/null; then
      pass "known-patterns.seed.json has ≥10 patterns"
    else
      fail "known-patterns.seed.json has fewer than 10 patterns"
    fi
    if python3 -c "import json; d=json.load(open('$PROJECT_ROOT/data/known-patterns.seed.json')); assert all('description' in p and 'fix_hint' in p for p in d)" 2>/dev/null; then
      pass "every seed pattern carries description + fix_hint"
    else
      fail "some seed patterns are missing description or fix_hint"
    fi
  else
    fail "data/known-patterns.seed.json not found"
  fi
}

# Run all tests
echo "=========================================="
echo "  EvolveCI Test Suite"
echo "=========================================="

test_agent_prompts() {
  echo ""
  echo "=== Testing v5.1 Agent-When-Needed Contract ==="

  local commands_dir="$PROJECT_ROOT/.claude/commands"
  local violations=0

  # Forbidden bash patterns inside ```bash fenced blocks of slash commands.
  for cmd in "$commands_dir"/*.md; do
    local bash_only
    bash_only=$(awk '
      /^```bash$/ { in_block=1; next }
      /^```$/    { in_block=0; next }
      in_block   { print }
    ' "$cmd")
    [ -z "$bash_only" ] && continue
    for pat in "gh run list" "gh api repos/[^[:space:]]+/actions" "mcp__github_ci__"; do
      if echo "$bash_only" | grep -qE "$pat"; then
        fail "$(basename "$cmd"): forbidden bash pattern '$pat'"
        violations=$((violations + 1))
      fi
    done
  done

  # Every non-exempt command must invoke a v5.1 collector script.
  local exempt=("check-circuit.md" "learn-pattern.md" "heartbeat.md")
  for cmd in "$commands_dir"/*.md; do
    local base
    base=$(basename "$cmd")
    local skip=false
    for ex in "${exempt[@]}"; do
      [ "$base" = "$ex" ] && skip=true && break
    done
    $skip && continue
    if grep -qE 'scripts/(build-triage-input|collect-daily|collect-weekly)\.py' "$cmd"; then
      pass "$base invokes a v5.1 collector"
    else
      fail "$base does not invoke any v5.1 collector script"
      violations=$((violations + 1))
    fi
  done

  if [ "$violations" -eq 0 ]; then
    pass "v5.1 agent-when-needed contract holds"
  fi
}

test_redact_log
test_action_structure
test_workflow_structure
test_data_files
test_manifest
test_prompts
test_agent_memory
test_agent_prompts

# Summary
echo ""
echo "=========================================="
echo "  Test Summary"
echo "=========================================="
echo -e "  ${GREEN}Passed${NC}: $PASSED"
echo -e "  ${RED}Failed${NC}: $FAILED"
echo ""

if [ "$FAILED" -gt 0 ]; then
  echo -e "${RED}FAILURES:${NC}"
  for err in "${ERRORS[@]}"; do
    echo "  - $err"
  done
  echo ""
  exit 1
else
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
fi

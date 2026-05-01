#!/usr/bin/env bats

# Unit tests for data files validation

setup() {
  export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export DATA_DIR="$PROJECT_ROOT/data"
}

@test "known-patterns.seed.json is valid JSON" {
  python3 -c "import json; json.load(open('$DATA_DIR/known-patterns.seed.json'))"
}

@test "known-patterns have required fields" {
  python3 -c "
import json, sys
patterns = json.load(open('$DATA_DIR/known-patterns.seed.json'))
required = ['id', 'match', 'category', 'auto_rerun', 'notify', 'severity']
for p in patterns:
    missing = [k for k in required if k not in p]
    if missing:
        print(f'ERROR: Pattern {p.get(\"id\", \"unknown\")} missing: {missing}')
        sys.exit(1)
print(f'OK: {len(patterns)} patterns validated')
"
}

@test "onboarded-repos.yml is valid YAML" {
  python3 -c "import yaml; yaml.safe_load(open('$DATA_DIR/onboarded-repos.yml'))"
}

@test "onboarded-repos have required fields" {
  python3 -c "
import yaml, sys
data = yaml.safe_load(open('$DATA_DIR/onboarded-repos.yml'))
repos = data.get('repos', [])
if not repos:
    print('ERROR: No repos defined')
    sys.exit(1)
required = ['name']
for r in repos:
    missing = [k for k in required if k not in r]
    if missing:
        print(f'ERROR: Repo missing: {missing}')
        sys.exit(1)
print(f'OK: {len(repos)} repos validated')
"
}

@test "circuit-config.yml is valid YAML" {
  python3 -c "import yaml; yaml.safe_load(open('$DATA_DIR/circuit-config.yml'))"
}

@test "circuit-config has budget limits" {
  python3 -c "
import yaml, sys
data = yaml.safe_load(open('$DATA_DIR/circuit-config.yml'))
budgets = data.get('budgets', {})
if not budgets:
    print('ERROR: No budgets defined')
    sys.exit(1)
required = ['workflow', 'pattern', 'repo']
missing = [k for k in required if k not in budgets]
if missing:
    print(f'ERROR: Missing budget keys: {missing}')
    sys.exit(1)
print(f'OK: budgets validated')
"
}

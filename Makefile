.PHONY: test test-unit test-integration lint shellcheck yamllint clean install-deps

TEST_DIR := tests
UNIT_DIR := $(TEST_DIR)/unit
INT_DIR := $(TEST_DIR)/integration

# Default target
test: lint test-unit test-integration

# Install test dependencies
install-deps:
	@echo "Installing test dependencies..."
	@command -v bats >/dev/null 2>&1 || npm install -g bats 2>/dev/null || sudo npm install -g bats 2>/dev/null || echo "Install bats manually: npm install -g bats"
	@command -v shellcheck >/dev/null 2>&1 || (apt-get update && apt-get install -y shellcheck) 2>/dev/null || echo "Install shellcheck manually"
	@command -v yamllint >/dev/null 2>&1 || pip3 install yamllint 2>/dev/null || echo "Install yamllint manually: pip3 install yamllint"

# Lint all files
lint: shellcheck yamllint

# ShellCheck for bash scripts
shellcheck:
	@echo "Running ShellCheck..."
	@find . -name "*.sh" -not -path "./node_modules/*" -not -path "./.git/*" | while read f; do \
		echo "  Checking $$f"; \
		shellcheck -e SC1091,SC2086,SC2154 "$$f" || true; \
	done
	@echo "ShellCheck complete."

# YAML lint
yamllint:
	@echo "Running yamllint..."
	@find . -name "*.yml" -o -name "*.yaml" | grep -v node_modules | grep -v .git | while read f; do \
		echo "  Checking $$f"; \
		python3 -c "import yaml; yaml.safe_load(open('$$f'))" 2>&1 || true; \
	done
	@echo "YAML validation complete."

# Unit tests
test-unit:
	@echo "Running unit tests..."
	@if command -v bats >/dev/null 2>&1; then \
		bats $(UNIT_DIR)/*.bats; \
	else \
		echo "bats not found, running bash tests directly..."; \
		for f in $(UNIT_DIR)/*.sh; do \
			echo "Running $$f..."; \
			bash "$$f" || exit 1; \
		done; \
	fi

# Integration tests
test-integration:
	@echo "Running integration tests..."
	@if command -v bats >/dev/null 2>&1; then \
		bats $(INT_DIR)/*.bats; \
	else \
		for f in $(INT_DIR)/*.sh; do \
			echo "Running $$f..."; \
			bash "$$f" || exit 1; \
		done; \
	fi

# Validate all action.yml files have required fields
validate-actions:
	@echo "Validating action.yml structure..."
	@find actions -name "action.yml" | while read f; do \
		echo "  Validating $$f"; \
		python3 -c "\
import yaml, sys; \
data = yaml.safe_load(open('$$f')); \
required = ['name', 'description', 'runs']; \
missing = [k for k in required if k not in data]; \
if missing: \
    print(f'  ERROR: Missing fields: {missing}'); \
    sys.exit(1); \
runs = data.get('runs', {}); \
if runs.get('using') not in ['composite', 'node16', 'node20']: \
    print(f'  ERROR: Invalid runs.using: {runs.get(\"using\")}'); \
    sys.exit(1); \
print(f'  OK: {data[\"name\"]}'); \
" || exit 1; \
	done
	@echo "All actions valid."

# Validate workflow files
validate-workflows:
	@echo "Validating workflow structure..."
	@find .github/workflows -name "*.yml" | while read f; do \
		echo "  Validating $$f"; \
		python3 -c "\
import yaml, sys; \
data = yaml.safe_load(open('$$f')); \
required = ['name', 'on', 'jobs']; \
missing = [k for k in required if k not in data]; \
if missing: \
    print(f'  ERROR: Missing fields: {missing}'); \
    sys.exit(1); \
print(f'  OK: {data[\"name\"]}'); \
" || exit 1; \
	done
	@echo "All workflows valid."

# Clean test artifacts
clean:
	rm -rf $(TEST_DIR)/tmp
	rm -f $(TEST_DIR)/*.log

# Coverage report (for bash scripts)
coverage:
	@echo "Test coverage report:"
	@echo "  Actions: $$(find actions -name 'action.yml' | wc -l) files"
	@echo "  Workflows: $$(find .github/workflows -name '*.yml' | wc -l) files"
	@echo "  Shell scripts: $$(find . -name '*.sh' -not -path './node_modules/*' -not -path './.git/*' | wc -l) files"
	@echo "  Test files: $$(find $(TEST_DIR) -name '*.bats' -o -name '*.sh' 2>/dev/null | wc -l) files"

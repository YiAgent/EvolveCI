#!/usr/bin/env bats

# Integration tests for redaction flow

setup() {
  export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export TEST_DIR="$(mktemp -d)"
  export TEST_INPUT="$TEST_DIR/input.log"
  export TEST_OUTPUT="$TEST_DIR/output.log"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "full redaction pipeline with complex log" {
  cat > "$TEST_INPUT" << 'EOF'
2024-01-01T00:00:00Z INFO Starting build
2024-01-01T00:00:01Z DEBUG Token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef1234
2024-01-01T00:00:02Z ERROR Connection to 10.0.0.1:5432 failed
2024-01-01T00:00:03Z WARN password=supersecret123 in config
2024-01-01T00:00:04Z INFO Webhook: REDACTED_WEBHOOK_URL
2024-01-01T00:00:05Z INFO Build completed
EOF

  bash "$PROJECT_ROOT/lib/redact-log.sh" < "$TEST_INPUT" > "$TEST_OUTPUT"

  # Should preserve timestamps and levels
  grep -q "Starting build" "$TEST_OUTPUT"
  grep -q "Build completed" "$TEST_OUTPUT"

  # Should redact sensitive data
  grep -q "REDACTED" "$TEST_OUTPUT"
  ! grep -q "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef1234" "$TEST_OUTPUT"
  ! grep -q "supersecret123" "$TEST_OUTPUT"
  ! grep -q "10.0.0.1" "$TEST_OUTPUT"

  # Should not contain original sensitive data
  ! grep -q "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef1234" "$TEST_OUTPUT"
  ! grep -q "supersecret123" "$TEST_OUTPUT"
  ! grep -q "10.0.0.1" "$TEST_OUTPUT"
}

@test "redaction preserves JSON structure" {
  cat > "$TEST_INPUT" << 'EOF'
{
  "token": "ghp_1234567890abcdef1234567890abcdef12345678",
  "name": "test-repo",
  "url": "https://github.com/test/repo"
}
EOF

  bash "$PROJECT_ROOT/lib/redact-log.sh" < "$TEST_INPUT" > "$TEST_OUTPUT"

  # Should be valid JSON after redaction
  python3 -c "import json; json.load(open('$TEST_OUTPUT'))"

  # Should redact token but preserve structure
  grep -q "REDACTED_TOKEN" "$TEST_OUTPUT"
  grep -q "test-repo" "$TEST_OUTPUT"
  grep -q "https://github.com/test/repo" "$TEST_OUTPUT"
}

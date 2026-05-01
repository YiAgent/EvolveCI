#!/usr/bin/env bats

# Unit tests for lib/redact-log.sh

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../lib" && pwd)"
  export REDACT_SCRIPT="$SCRIPT_DIR/redact-log.sh"
  export TEST_DIR="$(mktemp -d)"
  export TEST_INPUT="$TEST_DIR/input.log"
  export TEST_OUTPUT="$TEST_DIR/output.log"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "redact-log.sh exists and is executable" {
  [ -f "$REDACT_SCRIPT" ]
  [ -x "$REDACT_SCRIPT" ] || chmod +x "$REDACT_SCRIPT"
}

@test "redacts GitHub PAT tokens" {
  echo "Token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef1234" > "$TEST_INPUT"
  bash "$REDACT_SCRIPT" < "$TEST_INPUT" > "$TEST_OUTPUT"
  grep -q "REDACTED" "$TEST_OUTPUT"
  ! grep -q "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef1234" "$TEST_OUTPUT"
}

@test "redacts generic passwords" {
  echo "password: mySecretPass123!" > "$TEST_INPUT"
  bash "$REDACT_SCRIPT" < "$TEST_INPUT" > "$TEST_OUTPUT"
  grep -q "REDACTED" "$TEST_OUTPUT"
}

@test "redacts IP addresses" {
  echo "Server at 192.168.1.100 responded" > "$TEST_INPUT"
  bash "$REDACT_SCRIPT" < "$TEST_INPUT" > "$TEST_OUTPUT"
  grep -q "REDACTED" "$TEST_OUTPUT"
  ! grep -q "192.168.1.100" "$TEST_OUTPUT"
}

@test "redacts private keys" {
  echo "-----BEGIN RSA PRIVATE KEY-----" > "$TEST_INPUT"
  bash "$REDACT_SCRIPT" < "$TEST_INPUT" > "$TEST_OUTPUT"
  grep -q "REDACTED_KEY" "$TEST_OUTPUT"
}

@test "preserves normal log lines" {
  echo "Build started at 2024-01-01" > "$TEST_INPUT"
  bash "$REDACT_SCRIPT" < "$TEST_INPUT" > "$TEST_OUTPUT"
  grep -q "Build started at 2024-01-01" "$TEST_OUTPUT"
}

@test "handles empty input" {
  touch "$TEST_INPUT"
  bash "$REDACT_SCRIPT" < "$TEST_INPUT" > "$TEST_OUTPUT"
  [ ! -s "$TEST_OUTPUT" ]
}

@test "handles multiline input" {
  cat > "$TEST_INPUT" << 'EOF'
Line 1: Normal log
Line 2: Token ghp_1234567890abcdef1234567890abcdef12345678
Line 3: password=supersecret
Line 4: Normal log again
EOF
  bash "$REDACT_SCRIPT" < "$TEST_INPUT" > "$TEST_OUTPUT"
  grep -q "Normal log" "$TEST_OUTPUT"
  grep -q "REDACTED_TOKEN" "$TEST_OUTPUT"
  grep -q "REDACTED_PASSWORD" "$TEST_OUTPUT"
  ! grep -q "supersecret" "$TEST_OUTPUT"
}

@test "redacts Slack webhook URLs" {
  echo "Webhook: https://hooks.slack.com/services/EXAMPLE/EXAMPLE/XXXXXXXXXXXXXXXXXXXXXXXX" > "$TEST_INPUT"
  bash "$REDACT_SCRIPT" < "$TEST_INPUT" > "$TEST_OUTPUT"
  grep -q "REDACTED" "$TEST_OUTPUT"
}

@test "redacts AWS keys" {
  echo "AKIAIOSFODNN7EXAMPLE" > "$TEST_INPUT"
  bash "$REDACT_SCRIPT" < "$TEST_INPUT" > "$TEST_OUTPUT"
  grep -q "REDACTED_AWS_KEY" "$TEST_OUTPUT"
}

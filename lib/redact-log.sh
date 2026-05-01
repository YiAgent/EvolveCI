#!/usr/bin/env bash
# Log redaction utility — removes sensitive information before AI processing or issue posting.
# Usage: echo "$LOG" | bash lib/redact-log.sh
# Input: stdin (plaintext log)
# Output: stdout (redacted log)

set -euo pipefail

sed -E \
  -e 's/token\s*=\s*[a-zA-Z0-9_.-]+/token=***REDACTED***/g' \
  -e 's/password\s*=\s*[a-zA-Z0-9_.-]+/password=***REDACTED***/g' \
  -e 's/secret\s*=\s*[a-zA-Z0-9_.-]+/secret=***REDACTED***/g' \
  -e 's/api[_-]?key\s*=\s*[a-zA-Z0-9_.-]+/api_key=***REDACTED***/g' \
  -e 's/Bearer\s+[a-zA-Z0-9_.-]+/Bearer ***REDACTED***/g' \
  -e 's/ghp_[a-zA-Z0-9]{36}/ghp_***REDACTED***/g' \
  -e 's/gho_[a-zA-Z0-9]{36}/gho_***REDACTED***/g' \
  -e 's/sk-[a-zA-Z0-9]{20,}/sk-***REDACTED***/g' \
  -e 's/(10|172|192)\.[0-9]+\.[0-9]+\.[0-9]+/***REDACTED_IP***/g'

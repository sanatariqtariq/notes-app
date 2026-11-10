#!/usr/bin/env bash
# Smoke tests for the Notes app.
# Usage: bash scripts/smoke_test.sh http://localhost:8080
set -euo pipefail
BASE="${1:-http://localhost:8080}"
JSON='Content-Type: application/json'

echo "== 1. Waiting for health endpoint"
for i in $(seq 1 30); do
  if curl -fsS "$BASE/api/health" >/dev/null 2>&1; then break; fi
  echo "   waiting ($i/30)..."; sleep 3
  if [ "$i" -eq 30 ]; then echo "FAIL: app not healthy"; exit 1; fi
done
health=$(curl -fsS "$BASE/api/health")
[[ "$health" == *'"db":"up"'* ]] || { echo "FAIL: db not up: $health"; exit 1; }
echo "PASS health: $health"

echo "== 2. Empty note must be rejected (400)"
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/notes" -H "$JSON" -d '{"content":""}')
[ "$code" = "400" ] || { echo "FAIL: expected 400, got $code"; exit 1; }
echo "PASS validation"

echo "== 3. Create note and read it back"
MARK="ci-test-$(date +%s)"
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/notes" -H "$JSON" -d "{\"content\":\"$MARK\"}")
[ "$code" = "201" ] || { echo "FAIL: expected 201, got $code"; exit 1; }
body=$(curl -fsS "$BASE/api/notes")
[[ "$body" == *"$MARK"* ]] || { echo "FAIL: note not found in list"; exit 1; }
echo "PASS create + list"

echo "== 4. SQL injection payload must be stored as plain text"
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/notes" -H "$JSON" -d "{\"content\":\"x'); DROP TABLE notes;--\"}")
[ "$code" = "201" ] || { echo "FAIL: expected 201, got $code"; exit 1; }
body=$(curl -fsS "$BASE/api/notes")
[[ "$body" == *"DROP TABLE"* ]] || { echo "FAIL: payload not stored as text"; exit 1; }
echo "PASS parameterized queries (table still exists)"

echo "ALL TESTS PASSED"

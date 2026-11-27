#!/usr/bin/env bash
# Post-deploy verification. Run against the actual deployment, not localhost:
#   Scripts/smoke.sh https://your-app.vercel.app
#
# Optional:
#   EXPECTED_REVISION=<git sha>   assert /health reports that exact revision
#   SMOKE_EMAIL=user@example.com  exercise the magic-link endpoint
#   SMOKE_ACCESS_TOKEN=<jwt>      exercise a real import end to end
#   SMOKE_IMPORT_URL=<url>        recipe to import (defaults to the bug report)
set -euo pipefail

BASE_URL="${1:-${SMOKE_BASE_URL:-}}"
BASE_URL="${BASE_URL%/}"
if [[ -z "$BASE_URL" ]]; then
  echo "Usage: SMOKE_BASE_URL=https://... Scripts/smoke.sh [base-url]" >&2
  exit 2
fi

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   - $*"; }

json_field() {
  python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"
}

echo "Smoke testing $BASE_URL"

HEALTH="$(curl -sS --fail --max-time 20 "$BASE_URL/health")" || fail "GET /health failed"
[[ "$(json_field status <<<"$HEALTH")" == "ok" ]] || fail "/health status is not ok: $HEALTH"
REVISION="$(json_field revision <<<"$HEALTH")"
[[ -n "$REVISION" ]] || fail "/health does not report a revision"
ok "/health (revision $REVISION)"

if [[ -n "${EXPECTED_REVISION:-}" && "$REVISION" != "$EXPECTED_REVISION" ]]; then
  fail "deployed revision $REVISION != expected $EXPECTED_REVISION"
fi

READY="$(curl -sS --fail --max-time 20 "$BASE_URL/health/ready")" || fail "GET /health/ready failed"
[[ "$(json_field status <<<"$READY")" == "ready" ]] || fail "/health/ready is not ready: $READY"
ok "/health/ready"

ADMIN_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$BASE_URL/admin")"
ADMIN_LOCATION="$(curl -sSI --max-time 20 "$BASE_URL/admin" | tr -d '\r' | awk 'tolower($1)=="location:" {print $2}')"
[[ "$ADMIN_STATUS" == "302" ]] || fail "GET /admin returned $ADMIN_STATUS, expected 302"
[[ "$ADMIN_LOCATION" == */admin/login ]] || fail "GET /admin redirected to '$ADMIN_LOCATION', expected /admin/login"
ok "/admin redirects unauthenticated users to login"

LOGIN_HTML="$(curl -sS --fail --max-time 20 "$BASE_URL/admin/login")"
grep -q "Send magic link" <<<"$LOGIN_HTML" || fail "/admin/login did not render the login form"
ok "/admin/login renders"

if [[ -n "${SMOKE_EMAIL:-}" ]]; then
  MAGIC_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
    -H 'Content-Type: application/json' -H 'X-Client: ios' \
    -d "{\"email\":\"$SMOKE_EMAIL\"}" "$BASE_URL/auth/magic-link")"
  [[ "$MAGIC_STATUS" == "200" ]] || fail "POST /auth/magic-link returned $MAGIC_STATUS"
  ok "magic-link request accepted for $SMOKE_EMAIL"
else
  echo "skip - magic-link request (set SMOKE_EMAIL)"
fi

if [[ -n "${SMOKE_ACCESS_TOKEN:-}" ]]; then
  IMPORT_URL="${SMOKE_IMPORT_URL:-https://verdegusto.it/en/ricette/spring-cutlets-with-arugula-and-tomatoes-spring-recipe}"
  AUTH="Authorization: Bearer $SMOKE_ACCESS_TOKEN"
  STARTED="$(curl -sS --fail --max-time 30 -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"url\":\"$IMPORT_URL\"}" "$BASE_URL/recipes/import")"
  JOB_ID="$(json_field jobID <<<"$STARTED")"
  [[ -n "$JOB_ID" ]] || fail "no jobID from import start: $STARTED"
  RESULT="$(curl -sS --fail --max-time 120 -X POST -H "$AUTH" \
    "$BASE_URL/recipes/import/$JOB_ID/run")"
  STATUS="$(json_field status <<<"$RESULT")"
  [[ "$STATUS" == "succeeded" || "$STATUS" == "duplicate" ]] \
    || fail "import did not succeed: $RESULT"
  ok "import $IMPORT_URL -> $STATUS"
else
  echo "skip - authenticated import (set SMOKE_ACCESS_TOKEN)"
fi

echo "PASS - $BASE_URL @ $REVISION"

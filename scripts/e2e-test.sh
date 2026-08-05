#!/bin/bash
set -euo pipefail

# Rybbit Helm Chart — End-to-End Test
#
# Verifies every piece the chart provisions actually works together:
#
#   Data stores (direct round-trips using the credentials the chart generates):
#     1. Valkey     — AUTH + PING + SET/GET/DEL round-trip on the backend's key
#     2. PostgreSQL — connect with generated superuser creds, migrations applied
#                     (drizzle tables exist in the app database)
#     3. ClickHouse — connect with generated creds, backend-initialized tables
#                     exist, INSERT/SELECT round-trip
#
#   Backend clients (through the HTTP API, real end-to-end paths):
#     4. /api/health responds
#     5. Backend logs show the ioredis clients connected to Valkey
#     6. Sign-up -> user row lands in PostgreSQL (backend -> Postgres write)
#     7. Organization + site created through the API (session-scoped writes)
#     8. /api/track pageview -> event lands in ClickHouse (Postgres lookup +
#        Valkey session + ClickHouse write, the full ingestion path)
#
# Usage:
#   NAMESPACE=<ns> RELEASE_NAME=<name> ./scripts/e2e-test.sh
#   Optional env vars: BACKEND_PORT (default 3001), E2E_ORIGIN (default
#   http://localhost:3002, must match the deployed backend.env.BASE_URL).
#
# Requires: kubectl, curl, jq and a deployed release (see scripts/test-kind.sh).

NAMESPACE="${NAMESPACE:-rybbit}"
RELEASE_NAME="${RELEASE_NAME:-rybbit}"
BACKEND_PORT="${BACKEND_PORT:-3001}"
# Origin of the dashboard client. The chart must be deployed with
# `backend.env.BASE_URL` set to this origin — production enforces it: the
# backend rejects unsafe methods whose Origin is not trusted (fastify hook +
# better-auth origin check). This mirrors a real deployment.
E2E_ORIGIN="${E2E_ORIGIN:-http://localhost:3002}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

PASS=0
FAIL=0

# Capture the port-forward PID for cleanup on exit
PF_PID=""
cleanup() {
  if [ -n "$PF_PID" ] && kill -0 "$PF_PID" 2>/dev/null; then
    kill "$PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo -e "${GREEN}  ✓${NC} $1"; }
fail() { FAIL=$((FAIL + 1)); echo -e "${RED}  ✗${NC} $1"; }

kubectl_ns() { kubectl -n "$NAMESPACE" "$@"; }

wait_for_pod_ready() {
  local label="$1" timeout="${2:-180}"
  local i=0
  while [ "$i" -lt "$timeout" ]; do
    local ready
    ready=$(kubectl_ns get pods -l "$label" --no-headers 2>/dev/null | awk '$2 ~ /^[0-9]+\/1$|^[0-9]+\/[0-9]+$/ {print $2}' | head -1 || true)
    if [ "$ready" = "1/1" ]; then
      return 0
    fi
    i=$((i + 5))
    sleep 5
  done
  return 1
}

echo "=========================================="
echo "  Rybbit End-to-End Test"
echo "=========================================="
echo ""
log_info "Namespace: $NAMESPACE"
log_info "Release: $RELEASE_NAME"
echo ""

if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  log_error "Namespace '$NAMESPACE' not found — is the chart deployed?"
  exit 1
fi

# ============================================================================
# 1. VALKEY — auth + read/write round-trip with the generated credentials
# ============================================================================
echo ""
log_info "1. Valkey"

VALKEY_POD=$(kubectl_ns get pods -l "app.kubernetes.io/name=valkey,app.kubernetes.io/instance=${RELEASE_NAME}" -o jsonpath='{.items[0].metadata.name}')
VALKEY_PASSWORD=$(kubectl_ns get secret "${RELEASE_NAME}-valkey-auth" -o jsonpath='{.data.default-password}' | base64 -d)

if [ -z "$VALKEY_POD" ]; then
  log_error "Valkey pod not found — is the valkey subchart enabled?"
  exit 1
fi

VALKEY_CMD="valkey-cli -a '${VALKEY_PASSWORD}' --no-auth-warning"

TEST_KEY="e2e:$(date +%s)"
if kubectl_ns exec "$VALKEY_POD" -- sh -c "$VALKEY_CMD ping" | grep -q PONG; then
  pass "Valkey PING with generated password"
else
  fail "Valkey PING with generated password"
fi

if kubectl_ns exec "$VALKEY_POD" -- sh -c "$VALKEY_CMD set $TEST_KEY e2e-value" | grep -q OK \
   && [ "$(kubectl_ns exec "$VALKEY_POD" -- sh -c "$VALKEY_CMD get $TEST_KEY" | tr -d '\r')" = "e2e-value" ]; then
  pass "Valkey SET/GET round-trip"
else
  fail "Valkey SET/GET round-trip"
fi

kubectl_ns exec "$VALKEY_POD" -- sh -c "$VALKEY_CMD del $TEST_KEY" >/dev/null 2>&1 || true

# ============================================================================
# 2. POSTGRESQL — connect with generated credentials, migrations applied
# ============================================================================
echo ""
log_info "2. PostgreSQL"

PG_POD="${RELEASE_NAME}-postgresql-1"
PG_SUPERUSER=$(kubectl_ns get secret "${RELEASE_NAME}-postgresql-superuser" -o jsonpath='{.data.user}' | base64 -d)
PG_SUPERUSER_PASSWORD=$(kubectl_ns get secret "${RELEASE_NAME}-postgresql-superuser" -o jsonpath='{.data.password}' | base64 -d)
PG_APP_DB=$(kubectl_ns get secret "${RELEASE_NAME}-postgresql-app" -o jsonpath='{.data.dbname}' | base64 -d)

if ! kubectl_ns get pod "$PG_POD" >/dev/null 2>&1; then
  log_error "PostgreSQL pod $PG_POD not found — is the CNPG cluster healthy?"
  exit 1
fi

psql_exec() { # $1 = psql args as a single shell string
  kubectl_ns exec "$PG_POD" -- bash -c "PGPASSWORD='${PG_SUPERUSER_PASSWORD}' psql -U '${PG_SUPERUSER}' -h localhost $1"
}

# Run a SQL query against the app database. SQL is piped via stdin so no
# inner-shell quoting is needed (avoids "user" reserved-word pitfalls).
pg_query() {
  echo "$1" | kubectl_ns exec -i "$PG_POD" -- bash -c "PGPASSWORD='${PG_SUPERUSER_PASSWORD}' psql -U '${PG_SUPERUSER}' -h localhost -d '$PG_APP_DB' -tA"
}

if [ "$(pg_query "SELECT 1" | tr -d ' ')" = "1" ]; then
  pass "PostgreSQL connection with generated superuser credentials"
else
  fail "PostgreSQL connection with generated superuser credentials"
fi

# The backend entrypoint runs `npm run db:migrate` against this database.
if psql_exec "-lqt" | cut -d'|' -f1 | grep -qw "$PG_APP_DB"; then
  pass "App database '$PG_APP_DB' exists"
else
  fail "App database '$PG_APP_DB' exists"
fi

MIGRATED_TABLES=$(pg_query "SELECT tablename FROM pg_tables WHERE schemaname='public'" 2>/dev/null || true)
MISSING_TABLES=""
for t in user organization sites member account session; do
  if ! echo "$MIGRATED_TABLES" | grep -qw "$t"; then
    MISSING_TABLES="$MISSING_TABLES $t"
  fi
done
if [ -z "$MISSING_TABLES" ]; then
  pass "Drizzle migrations applied (user, organization, sites, member, account, session tables present)"
else
  fail "Drizzle migrations applied — missing tables:$MISSING_TABLES"
fi

# ============================================================================
# 3. CLICKHOUSE — connect with generated credentials, tables initialized,
#    INSERT/SELECT round-trip
# ============================================================================
echo ""
log_info "3. ClickHouse"

CH_PASSWORD=$(kubectl_ns get secret "${RELEASE_NAME}-clickhouse-credentials" -o jsonpath='{.data.password}' | base64 -d)

CH_POD=""
for pod in $(kubectl_ns get pods -l "clickhouse.altinity.com/chi=${RELEASE_NAME}-clickhouse" -o jsonpath='{.items[*].metadata.name}'); do
  case "$pod" in
    keeper-*) ;;
    *) CH_POD="$pod"; break ;;
  esac
done

if [ -z "$CH_POD" ]; then
  log_error "ClickHouse pod not found — is the ClickHouseInstallation reconciled?"
  exit 1
fi

ch_query() { kubectl_ns exec "$CH_POD" -- clickhouse-client --password "$CH_PASSWORD" --query "$1"; }

if [ "$(ch_query 'SELECT 1' | tr -d ' ')" = "1" ]; then
  pass "ClickHouse connection with generated credentials ($CH_POD)"
else
  fail "ClickHouse connection with generated credentials ($CH_POD)"
fi

# Tables are created lazily on first use (first track event, first bot event).
# Defer the check to after the track round-trip in section 4.

SCRATCH_TABLE="e2e_test_$(date +%s)"
if ch_query "CREATE TABLE $SCRATCH_TABLE (id UInt8) ENGINE=Memory" \
   && [ "$(ch_query "INSERT INTO $SCRATCH_TABLE VALUES (1); SELECT count() FROM $SCRATCH_TABLE" | tr -d ' ')" = "1" ]; then
  pass "ClickHouse INSERT/SELECT round-trip"
  ch_query "DROP TABLE $SCRATCH_TABLE" >/dev/null 2>&1 || true
else
  fail "ClickHouse INSERT/SELECT round-trip"
  ch_query "DROP TABLE IF EXISTS $SCRATCH_TABLE" >/dev/null 2>&1 || true
fi

# ============================================================================
# 4. BACKEND — API + client wiring, real end-to-end paths
# ============================================================================
echo ""
log_info "4. Backend"

BACKEND_SVC="${RELEASE_NAME}-backend"
BACKEND_POD=$(kubectl_ns get pods -l app.kubernetes.io/component=backend -o jsonpath='{.items[0].metadata.name}')

if ! wait_for_pod_ready "app.kubernetes.io/component=backend" 180; then
  log_error "Backend pod not ready — dumping logs"
  kubectl_ns logs -l app.kubernetes.io/component=backend --tail=100 || true
  exit 1
fi
pass "Backend pod ready"

# --- Port-forward to the backend service ------------------------------------
kubectl port-forward -n "$NAMESPACE" "svc/${BACKEND_SVC}" "${BACKEND_PORT}:3000" >/dev/null 2>&1 &
PF_PID=$!
sleep 3

api() { curl -s -o /tmp/rybbit-e2e-body -w '%{http_code}' "$@"; }

HTTP_CODE=$(api http://localhost:${BACKEND_PORT}/api/health)
if [ "$HTTP_CODE" = "200" ] && grep -q OK /tmp/rybbit-e2e-body; then
  pass "GET /api/health returns 200 OK"
else
  fail "GET /api/health returns 200 OK (got $HTTP_CODE)"
fi

# --- Backend logs: ioredis clients must be connected to Valkey ---------------
log_info "  Checking backend logs for Redis/Valkey client connections..."
BACKEND_LOG_READY=false
for i in $(seq 1 12); do
  if kubectl_ns logs "$BACKEND_POD" -c backend 2>/dev/null | grep -q "Server is listening"; then
    BACKEND_LOG_READY=true
    break
  fi
  sleep 5
done
if [ "$BACKEND_LOG_READY" = true ]; then
  pass "Backend 'Server is listening' in logs"
else
  fail "Backend 'Server is listening' in logs"
fi

BACKEND_LOGS=$(kubectl_ns logs "$BACKEND_POD" -c backend 2>/dev/null || true)
MISSING_REDIS=""
for label in main session identity; do
  if ! echo "$BACKEND_LOGS" | grep -q "Redis connected (${label})"; then
    MISSING_REDIS="$MISSING_REDIS ${label}"
  fi
done
if [ -z "$MISSING_REDIS" ]; then
  pass "Backend Redis clients connected to Valkey (main, session, identity)"
else
  fail "Backend Redis clients connected to Valkey — missing:$MISSING_REDIS"
fi

if echo "$BACKEND_LOGS" | grep -qi "ClickHouse initialization step failed\|ECONNREFUSED.*clickhouse\|Could not connect to Redis"; then
  fail "Backend logs show store connection errors"
else
  pass "Backend logs clean (no ClickHouse/Redis connection errors)"
fi

# --- Sign-up round-trip: backend -> PostgreSQL write -------------------------
log_info "  Sign-up round-trip (backend -> PostgreSQL)..."
E2E_EMAIL="e2e+$(date +%s)@rybbit.test"
E2E_PASSWORD="RybbitE2E!2026"
COOKIE_JAR=/tmp/rybbit-e2e-cookies.txt
rm -f "$COOKIE_JAR"
HTTP_CODE=$(api -X POST http://localhost:${BACKEND_PORT}/api/auth/sign-up/email \
  -H 'Content-Type: application/json' \
  -c "$COOKIE_JAR" \
  -d "{\"email\":\"${E2E_EMAIL}\",\"password\":\"${E2E_PASSWORD}\",\"name\":\"E2E Test\",\"sendAutoEmailReports\":false}")
if [ "$HTTP_CODE" = "200" ] && jq -e .token /tmp/rybbit-e2e-body >/dev/null 2>&1; then
  pass "Sign-up via API (HTTP 200, session token issued)"
else
  fail "Sign-up via API (HTTP $HTTP_CODE)"
  cat /tmp/rybbit-e2e-body || true
fi

if [ -s "$COOKIE_JAR" ]; then
  USER_COUNT=$(pg_query "SELECT count(*) FROM \"user\" WHERE email='${E2E_EMAIL}'" 2>/dev/null | tr -d ' ' || true)
  if [ "$USER_COUNT" = "1" ]; then
    pass "Sign-up wrote user row to PostgreSQL"
  else
    fail "Sign-up wrote user row to PostgreSQL (found $USER_COUNT)"
  fi
fi

# --- Organization + site creation through the API ----------------------------
if [ -s "$COOKIE_JAR" ]; then
  log_info "  Organization + site creation through the API..."
  E2E_ORG="E2E Org $(date +%s)"
  E2E_ORG_SLUG="e2e-org-$(date +%s)"
  HTTP_CODE=$(api -X POST http://localhost:${BACKEND_PORT}/api/auth/organization/create \
    -H 'Content-Type: application/json' \
    -H "Origin: ${E2E_ORIGIN}" \
    -b "$COOKIE_JAR" \
    -d "{\"name\":\"${E2E_ORG}\",\"slug\":\"${E2E_ORG_SLUG}\"}")
  if [ "$HTTP_CODE" = "200" ] && jq -e .id /tmp/rybbit-e2e-body >/dev/null 2>&1; then
    ORG_ID=$(jq -r .id /tmp/rybbit-e2e-body)
    pass "Organization created via API"
  else
    fail "Organization created via API (HTTP $HTTP_CODE)"
    cat /tmp/rybbit-e2e-body || true
  fi

  if [ -n "${ORG_ID:-}" ]; then
    HTTP_CODE=$(api -X POST "http://localhost:${BACKEND_PORT}/api/organizations/${ORG_ID}/sites" \
      -H 'Content-Type: application/json' \
      -H "Origin: ${E2E_ORIGIN}" \
      -b "$COOKIE_JAR" \
      -d '{"name":"E2E Site","domain":"e2e.example.com","type":"web","blockBots":false}')
    if [ "$HTTP_CODE" = "201" ] && jq -e .siteId /tmp/rybbit-e2e-body >/dev/null 2>&1; then
      SITE_ID=$(jq -r .id /tmp/rybbit-e2e-body)
      SITE_NUMERIC_ID=$(jq -r .siteId /tmp/rybbit-e2e-body)
      pass "Site created via API (siteId=$SITE_NUMERIC_ID)"
    else
      fail "Site created via API (HTTP $HTTP_CODE)"
      cat /tmp/rybbit-e2e-body || true
    fi
  fi
fi

# --- Track round-trip: Postgres lookup + Valkey session + ClickHouse write ----
if [ -n "${SITE_ID:-}" ]; then
  log_info "  Track round-trip (backend -> Valkey session -> ClickHouse write)..."
  HTTP_CODE=$(api -X POST http://localhost:${BACKEND_PORT}/api/track \
    -H 'Content-Type: application/json' \
    -d "{\"type\":\"pageview\",\"site_id\":\"${SITE_ID}\",\"hostname\":\"e2e.example.com\",\"pathname\":\"/e2e-test\",\"screenWidth\":1280,\"screenHeight\":800}")
  if [ "$HTTP_CODE" = "200" ] && jq -e .success /tmp/rybbit-e2e-body >/dev/null 2>&1; then
    pass "POST /api/track accepted pageview"
  else
    fail "POST /api/track accepted pageview (HTTP $HTTP_CODE)"
    cat /tmp/rybbit-e2e-body || true
  fi

  # The backend flushes its in-process pageview queue to ClickHouse every ~1s.
  EVENT_COUNT=0
  for i in $(seq 1 12); do
    EVENT_COUNT=$(ch_query "SELECT count() FROM events WHERE site_id=${SITE_NUMERIC_ID} AND pathname='/e2e-test'" | tr -d ' ' || true)
    if [ "${EVENT_COUNT:-0}" -ge 1 ]; then
      break
    fi
    sleep 5
  done
  if [ "${EVENT_COUNT:-0}" -ge 1 ]; then
    pass "Pageview event landed in ClickHouse (${EVENT_COUNT} row(s))"
  else
    fail "Pageview event landed in ClickHouse"
    log_warn "  events table rows for site ${SITE_NUMERIC_ID}:"
    ch_query "SELECT site_id, pathname, type, timestamp FROM events WHERE site_id=${SITE_NUMERIC_ID} ORDER BY timestamp DESC LIMIT 5" 2>/dev/null || true
    log_warn "  bot_events table rows for site ${SITE_NUMERIC_ID}:"
    ch_query "SELECT site_id, pathname, type, timestamp FROM bot_events WHERE site_id=${SITE_NUMERIC_ID} ORDER BY timestamp DESC LIMIT 5" 2>/dev/null || true
  fi
fi

# --- Deferred ClickHouse table check: tables are created lazily on first use --
# At this point the events table must exist (a track event was just written).
CH_TABLES=$(ch_query "SELECT name FROM system.tables WHERE database='default'" 2>/dev/null || true)
if echo "$CH_TABLES" | grep -qw "events"; then
  pass "Backend-initialized ClickHouse tables exist (events)"
else
  fail "Backend-initialized ClickHouse tables exist (events)"
fi
# bot_events is created lazily on first bot event; no bot traffic in this test.
if echo "$CH_TABLES" | grep -qw "bot_events"; then
  pass "Backend-initialized ClickHouse tables exist (bot_events)"
else
  log_warn "  bot_events table not yet created (lazy init — requires bot traffic)"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=========================================="
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "=========================================="
echo ""

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

log_info "All end-to-end checks passed! ✓"
echo ""
echo "The full stack is operational:"
echo "  - Valkey: auth + read/write working, backend Redis clients connected"
echo "  - PostgreSQL: credentials valid, migrations applied"
echo "  - ClickHouse: credentials valid, tables initialized, write path working"
echo "  - Backend: sign-up, organization, site creation and event tracking all"
echo "    write through to their respective stores"

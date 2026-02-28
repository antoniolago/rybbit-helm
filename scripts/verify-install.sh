#!/bin/bash
set -e

NAMESPACE="${NAMESPACE:-rybbit}"
RELEASE_NAME="${RELEASE_NAME:-rybbit}"

echo "=========================================="
echo "  Rybbit Chart Installation Verification"
echo "=========================================="
echo ""

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function check() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓${NC} $1"
    else
        echo -e "${RED}✗${NC} $1"
        exit 1
    fi
}

function info() {
    echo -e "${YELLOW}ℹ${NC} $1"
}

# Check all pods are ready
info "Checking pod status..."
kubectl get pods -n $NAMESPACE

echo ""
info "Waiting for all pods to be ready..."
kubectl wait --for=condition=ready pod --all -n $NAMESPACE --timeout=300s
check "All pods are ready"

# Check ClickHouse
echo ""
info "Verifying ClickHouse..."
kubectl get chi -n $NAMESPACE | grep -q "Completed"
check "ClickHouse installation completed"

CLICKHOUSE_NETWORKS=$(kubectl get chi $RELEASE_NAME-clickhouse -n $NAMESPACE -o jsonpath='{.spec.configuration.users.default/networks/ip}' 2>/dev/null || echo "[]")
if echo "$CLICKHOUSE_NETWORKS" | grep -q "10.0.0.0/8"; then
    check "ClickHouse network access configured"
else
    echo -e "${RED}✗${NC} ClickHouse network access NOT configured"
    exit 1
fi

# Check PostgreSQL
echo ""
info "Verifying PostgreSQL..."
kubectl get cluster -n $NAMESPACE | grep -q "healthy"
check "PostgreSQL cluster healthy"

# Check if analytics database exists
kubectl exec $RELEASE_NAME-postgresql-1 -n $NAMESPACE -- psql -U postgres -c "\l" | grep -q "analytics"
check "Analytics database exists"

# Verify PostgreSQL password is set correctly
PG_PASSWORD=$(kubectl get secret $RELEASE_NAME-postgresql-app -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)
kubectl exec $RELEASE_NAME-postgresql-1 -n $NAMESPACE -- bash -c "PGPASSWORD='$PG_PASSWORD' psql -U postgres -d analytics -c 'SELECT 1;'" > /dev/null 2>&1
check "PostgreSQL password configured correctly"

# Check backend
echo ""
info "Verifying backend..."
kubectl get deployment $RELEASE_NAME-backend -n $NAMESPACE | grep -q "1/1"
check "Backend deployment ready"

# Check backend logs for errors
BACKEND_ERRORS=$(kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=backend --tail=100 | grep -i "error" | grep -v "DEBUG" | grep -v "R2Storage not enabled" || true)
if [ -z "$BACKEND_ERRORS" ]; then
    check "Backend logs clean (no errors)"
else
    echo -e "${RED}✗${NC} Backend has errors:"
    echo "$BACKEND_ERRORS"
    exit 1
fi

# Check if backend is listening
kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=backend --tail=50 | grep -q "Server listening"
check "Backend server is listening"

# Check database migrations
kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=backend --tail=200 | grep -q "Changes applied"
check "Database migrations completed"

# Test API endpoint
echo ""
info "Testing backend API..."
kubectl port-forward -n $NAMESPACE svc/$RELEASE_NAME-backend 3001:3000 > /dev/null 2>&1 &
PF_PID=$!
sleep 3

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3001/api/auth/get-session 2>/dev/null || echo "000")
kill $PF_PID 2>/dev/null || true

if [ "$HTTP_CODE" = "200" ]; then
    check "Backend API responding (HTTP 200)"
else
    echo -e "${RED}✗${NC} Backend API not responding correctly (HTTP $HTTP_CODE)"
    exit 1
fi

# Check client
echo ""
info "Verifying client..."
kubectl get deployment $RELEASE_NAME-client -n $NAMESPACE | grep -q "1/1"
check "Client deployment ready"

# Summary
echo ""
echo "=========================================="
echo -e "${GREEN}  All verifications passed! ✓${NC}"
echo "=========================================="
echo ""
echo "Your Rybbit installation is production-ready and fully operational."
echo ""
echo "To access the application:"
echo "  kubectl port-forward -n $NAMESPACE svc/$RELEASE_NAME-client 8080:3000"
echo "  Then visit: http://localhost:8080"
echo ""

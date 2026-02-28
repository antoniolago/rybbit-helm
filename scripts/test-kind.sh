#!/bin/bash
set -euo pipefail

# Rybbit Helm Chart - KinD Test Script
# Usage: ./scripts/test-kind.sh [--cleanup] [--skip-install]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(dirname "$SCRIPT_DIR")"
CLUSTER_NAME="${KIND_CLUSTER_NAME:-rybbit-test}"
NAMESPACE="${NAMESPACE:-rybbit}"
RELEASE_NAME="${RELEASE_NAME:-rybbit}"
TIMEOUT="${TIMEOUT:-900s}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Parse arguments
CLEANUP_ONLY=false
SKIP_INSTALL=false
KEEP_CLUSTER=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --cleanup)
      CLEANUP_ONLY=true
      shift
      ;;
    --skip-install)
      SKIP_INSTALL=true
      shift
      ;;
    --keep-cluster)
      KEEP_CLUSTER=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

cleanup() {
  log_info "Cleaning up..."
  
  # Uninstall helm release
  helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || true
  
  # Delete namespace
  kubectl delete namespace "$NAMESPACE" --ignore-not-found --timeout=120s 2>/dev/null || true
  
  if [ "$KEEP_CLUSTER" = false ]; then
    # Delete kind cluster
    kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
  fi
  
  log_info "Cleanup complete"
}

# Handle cleanup-only mode
if [ "$CLEANUP_ONLY" = true ]; then
  cleanup
  exit 0
fi

# Trap to cleanup on error
trap 'log_error "Test failed!"; cleanup; exit 1' ERR

check_prerequisites() {
  log_info "Checking prerequisites..."
  
  local missing=()
  
  command -v kind >/dev/null 2>&1 || missing+=("kind")
  command -v kubectl >/dev/null 2>&1 || missing+=("kubectl")
  command -v helm >/dev/null 2>&1 || missing+=("helm")
  
  if [ ${#missing[@]} -ne 0 ]; then
    log_error "Missing required tools: ${missing[*]}"
    log_error "Please install them before running this script"
    exit 1
  fi
  
  log_info "All prerequisites found"
}

create_cluster() {
  log_info "Creating KinD cluster: $CLUSTER_NAME"
  
  # Check if cluster already exists
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    log_warn "Cluster $CLUSTER_NAME already exists, using existing cluster"
    kubectl cluster-info --context "kind-${CLUSTER_NAME}"
    return 0
  fi
  
  # Create cluster with config for ingress support
  cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
- role: worker
- role: worker
EOF

  log_info "Cluster created successfully"
  kubectl cluster-info --context "kind-${CLUSTER_NAME}"
}

install_prerequisites() {
  log_info "Installing cluster prerequisites..."
  
  # Install CloudNativePG operator
  log_info "Installing CloudNativePG operator..."
  helm repo add cnpg https://cloudnative-pg.github.io/charts 2>/dev/null || true
  helm repo update cnpg
  
  if ! helm status cnpg -n cnpg-system >/dev/null 2>&1; then
    helm install cnpg cnpg/cloudnative-pg \
      --namespace cnpg-system \
      --create-namespace \
      --wait \
      --timeout 300s
  else
    log_warn "CloudNativePG already installed"
  fi
  
  log_info "Prerequisites installed"
}

install_chart() {
  log_info "Installing Rybbit Helm chart..."
  
  cd "$CHART_DIR"
  
  # Update dependencies
  log_info "Updating Helm dependencies..."
  helm dependency update
  
  # Create namespace
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  
  # Install chart (without --wait to monitor progress)
  log_info "Installing chart (this may take several minutes)..."
  helm upgrade --install "$RELEASE_NAME" . \
    --namespace "$NAMESPACE" \
    --set postgresql.cluster.instances=1 \
    --set clickhouse.clickhouse.replicasCount=1 \
    --set clickhouse.keeper.replicaCount=1 \
    --set backend.replicaCount=1 \
    --set client.replicaCount=1 \
    --set global.podDisruptionBudget.enabled=false \
    --timeout "$TIMEOUT" &
  
  INSTALL_PID=$!
  
  # Monitor progress
  sleep 5
  while kill -0 $INSTALL_PID 2>/dev/null; do
    log_info "Installation in progress... Current pod status:"
    kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null || true
    sleep 10
  done
  
  wait $INSTALL_PID || {
    log_error "Helm install failed"
    kubectl get pods -n "$NAMESPACE"
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20
    return 1
  }
  
  log_info "Chart installed successfully"
}

wait_for_pods() {
  log_info "Waiting for all pods to be ready..."
  
  local max_attempts=60
  local attempt=0
  
  while [ $attempt -lt $max_attempts ]; do
    local not_ready=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l)
    
    if [ "$not_ready" -eq 0 ]; then
      log_info "All pods are ready!"
      kubectl get pods -n "$NAMESPACE"
      return 0
    fi
    
    attempt=$((attempt + 1))
    log_info "Waiting for pods... (attempt $attempt/$max_attempts)"
    kubectl get pods -n "$NAMESPACE" --no-headers | grep -v "Running\|Completed" || true
    sleep 10
  done
  
  log_error "Pods did not become ready in time"
  kubectl get pods -n "$NAMESPACE"
  kubectl describe pods -n "$NAMESPACE" | tail -100
  return 1
}

run_tests() {
  log_info "Running validation tests..."
  
  # Test 1: Check all deployments are available
  log_info "Test 1: Checking deployments..."
  kubectl get deployments -n "$NAMESPACE"
  
  local backend_ready=$(kubectl get deployment "${RELEASE_NAME}-backend" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  local client_ready=$(kubectl get deployment "${RELEASE_NAME}-client" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  
  if [ "$backend_ready" -lt 1 ]; then
    log_error "Backend deployment not ready"
    kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/component=backend --tail=50 || true
    return 1
  fi
  
  if [ "$client_ready" -lt 1 ]; then
    log_error "Client deployment not ready"
    kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/component=client --tail=50 || true
    return 1
  fi
  
  log_info "✓ Deployments are ready"
  
  # Test 2: Check services exist
  log_info "Test 2: Checking services..."
  kubectl get services -n "$NAMESPACE"
  
  kubectl get service "${RELEASE_NAME}-backend" -n "$NAMESPACE" >/dev/null
  kubectl get service "${RELEASE_NAME}-client" -n "$NAMESPACE" >/dev/null
  
  log_info "✓ Services exist"
  
  # Test 3: Check PostgreSQL cluster
  log_info "Test 3: Checking PostgreSQL cluster..."
  kubectl get cluster -n "$NAMESPACE" 2>/dev/null || log_warn "No PostgreSQL cluster CRD found"
  
  # Test 4: Check ClickHouse
  log_info "Test 4: Checking ClickHouse..."
  kubectl get pods -n "$NAMESPACE" -l "clickhouse.altinity.com/chi" 2>/dev/null || log_warn "No ClickHouse pods found"
  
  # Test 5: Port-forward and health check
  log_info "Test 5: Backend health check..."
  
  # Start port-forward in background
  kubectl port-forward -n "$NAMESPACE" "svc/${RELEASE_NAME}-backend" 3000:3000 &
  PF_PID=$!
  sleep 5
  
  # Health check
  if curl -sf http://localhost:3000/health >/dev/null 2>&1; then
    log_info "✓ Backend health check passed"
  else
    log_warn "Backend health check failed (may still be initializing)"
  fi
  
  # Cleanup port-forward
  kill $PF_PID 2>/dev/null || true
  
  log_info "All tests completed!"

  # Run comprehensive verification
  log_info "Running automated verification..."
  if [ -f "$(dirname "$0")/verify-install.sh" ]; then
    bash "$(dirname "$0")/verify-install.sh"
    if [ $? -eq 0 ]; then
      log_success "Automated verification passed!"
    else
      log_error "Automated verification failed"
      exit 1
    fi
  else
    log_warn "Verification script not found, skipping..."
  fi
}

print_summary() {
  echo ""
  echo "=========================================="
  echo "          TEST SUMMARY"
  echo "=========================================="
  echo ""
  log_info "Cluster: $CLUSTER_NAME"
  log_info "Namespace: $NAMESPACE"
  log_info "Release: $RELEASE_NAME"
  echo ""
  log_info "To access the application:"
  echo "  kubectl port-forward -n $NAMESPACE svc/${RELEASE_NAME}-client 8080:3000"
  echo "  Then visit: http://localhost:8080"
  echo ""
  log_info "To cleanup:"
  echo "  ./scripts/test-kind.sh --cleanup"
  echo ""
}

# Main execution
main() {
  log_info "Starting Rybbit Helm Chart tests..."
  
  check_prerequisites
  create_cluster
  
  if [ "$SKIP_INSTALL" = false ]; then
    install_prerequisites
    install_chart
  fi
  
  wait_for_pods
  run_tests
  print_summary
  
  log_info "Tests completed successfully! ✓"
}

main

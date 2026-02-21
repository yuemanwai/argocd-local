#!/bin/bash
#
# Setup script for Kubernetes development environment with ArgoCD
# 
# This script will:
# 1. Start Minikube with required resources
# 2. Install ArgoCD via Helm (with checks for existing installation)
# 3. Deploy applications via ArgoCD
# 4. Setup port forwarding for services
# 5. Display all credentials and access URLs
#
# Usage: ./setup.sh
#
set -e  # Exit on any error

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

MINIKUBE_PROFILE="minikube"

ensure_minikube_context() {
    log_info "Refreshing kube context for Minikube profile: $MINIKUBE_PROFILE"

    minikube update-context -p "$MINIKUBE_PROFILE" >/dev/null 2>&1 || true

    if kubectl config get-contexts -o name | grep -qx "$MINIKUBE_PROFILE"; then
        kubectl config use-context "$MINIKUBE_PROFILE" >/dev/null 2>&1 || true
    fi
}

start_or_recover_minikube() {
    log_info "Starting Minikube profile: $MINIKUBE_PROFILE"

    ensure_minikube_context
    if kubectl get nodes >/dev/null 2>&1; then
        log_warning "Minikube cluster is already reachable"
        return 0
    fi

    log_info "Attempting to start Minikube profile..."
    minikube start -p "$MINIKUBE_PROFILE" --memory 8192 --cpus 6 --addons=metrics-server || true
    ensure_minikube_context
    if kubectl get nodes >/dev/null 2>&1; then
        log_success "Minikube started successfully"
        return 0
    fi

    log_warning "Minikube profile looks unhealthy. Recreating profile..."
    minikube delete -p "$MINIKUBE_PROFILE" >/dev/null 2>&1 || true
    minikube start -p "$MINIKUBE_PROFILE" --memory 8192 --cpus 6 --addons=metrics-server
    ensure_minikube_context
    if kubectl get nodes >/dev/null 2>&1; then
        log_success "Minikube recovered and started successfully"
        return 0
    fi

    log_error "Failed to start a reachable Minikube cluster"
    exit 1
}

ensure_cluster_reachable() {
    local retries=30
    local delay=2

    if ! command -v kubectl >/dev/null 2>&1; then
        log_error "kubectl is not installed or not in PATH"
        exit 1
    fi

    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_warning "Kubernetes API is not reachable. Refreshing Minikube context..."
        minikube update-context >/dev/null 2>&1 || true
    fi

    while [ "$retries" -gt 0 ]; do
        if kubectl get nodes >/dev/null 2>&1; then
            log_success "Kubernetes cluster is reachable"
            return 0
        fi

        retries=$((retries - 1))
        sleep "$delay"
    done

    log_error "Kubernetes cluster is still unreachable."
    log_info "Run these checks manually:"
    log_info "  minikube status"
    log_info "  kubectl config current-context"
    log_info "  minikube update-context"
    exit 1
}

wait_for_namespace() {
    local namespace=$1
    log_info "Waiting for namespace $namespace to be ready..."
    kubectl wait --for=condition=Ready --all pods -n "$namespace" --timeout=300s 2>/dev/null || true
}

# =============================================================================
# 1. Start Minikube
# =============================================================================
start_or_recover_minikube

# Wait for Minikube to be fully ready
log_info "Waiting for Minikube to be ready..."
sleep 10

log_info "Verifying Kubernetes connection..."
ensure_cluster_reachable

# =============================================================================
# 2. Install ArgoCD
# =============================================================================
log_info "Checking ArgoCD Helm repository..."
if helm repo list 2>/dev/null | grep -q "^argo\s"; then
    log_success "ArgoCD Helm repo already exists"
else
    log_info "Adding ArgoCD Helm repository..."
    helm repo add argo https://argoproj.github.io/argo-helm
    log_success "ArgoCD Helm repo added"
fi

log_info "Updating Helm repositories..."
helm repo update

log_info "Checking ArgoCD installation..."
if kubectl get namespace argocd &>/dev/null && helm list -n argocd 2>/dev/null | grep -q "^argocd\s"; then
    log_success "ArgoCD is already installed"
    read -p "Do you want to upgrade ArgoCD? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Upgrading ArgoCD..."
        helm upgrade --install argocd argo/argo-cd \
            --namespace argocd \
            --values ./argocd/values.yaml \
            --atomic
        log_success "ArgoCD upgraded successfully"
    else
        log_info "Skipping ArgoCD upgrade"
    fi
else
    log_info "Installing ArgoCD..."
    helm install argocd argo/argo-cd \
        --namespace argocd \
        --create-namespace \
        --values ./argocd/values.yaml \
        --version 9.4.3 \
        --wait
    log_success "ArgoCD installed successfully"
fi

# Wait for ArgoCD pods to be ready
wait_for_namespace argocd

# =============================================================================
# 3. Deploy Root Application (App of Apps pattern)
# =============================================================================
log_info "Deploying Root Application via ArgoCD (App of Apps pattern)..."

# First, apply git repository secret
if [ -f "bootstrap/repo-secret/git-creds.yaml" ]; then
    log_info "Applying Git credentials..."
    kubectl apply -f bootstrap/repo-secret/git-creds.yaml 2>/dev/null || log_warning "Git credentials already applied"
else
    log_warning "Git credentials not found at bootstrap/repo-secret/git-creds.yaml"
fi

# Then deploy the root-app bootstrap
log_info "Applying root-app bootstrap..."
kubectl apply -f bootstrap/bootstrap.yaml 2>/dev/null || log_warning "Bootstrap already applied"

log_info "Waiting for applications to sync (30 seconds)..."
sleep 30

# =============================================================================
# 4. Get Passwords
# =============================================================================
echo ""
log_info "==================== CREDENTIALS ===================="
echo ""

# ArgoCD password
log_info "ArgoCD Admin Password:"
ARGOCD_PASSWORD=$(kubectl get secret/argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
if [ -n "$ARGOCD_PASSWORD" ]; then
    echo -e "${GREEN}$ARGOCD_PASSWORD${NC}"
else
    log_error "Could not retrieve ArgoCD password"
fi

echo ""

# Grafana password (if monitoring is installed)
if kubectl get namespace monitoring &>/dev/null; then
    log_info "Grafana Admin Password:"
    GRAFANA_PASSWORD=$(kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)
    if [ -n "$GRAFANA_PASSWORD" ]; then
        echo -e "${GREEN}$GRAFANA_PASSWORD${NC}"
    else
        log_warning "Monitoring stack not ready yet"
    fi
    echo ""
fi

log_info "====================================================="
echo ""

# =============================================================================
# 5. Setup Port Forwarding
# =============================================================================
log_info "Setting up port forwarding..."

# Check for existing port-forwards
if pgrep -f "port-forward" >/dev/null 2>&1; then
    log_warning "Existing port-forward processes found"
    read -p "Kill existing port-forwards and restart? (Y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        pkill -f "port-forward" 2>/dev/null || true
        sleep 2
        log_success "Stopped existing port-forwards"
    else
        log_info "Keeping existing port-forwards, skipping setup"
        echo ""
        log_success "==================== SETUP COMPLETE ===================="
        exit 0
    fi
fi

# ArgoCD
log_info "Port-forwarding ArgoCD (https://localhost:8090)..."
kubectl port-forward service/argocd-server 8090:443 -n argocd > /dev/null 2>&1 &

# Application (wait for it to be ready first, if deployed)
if kubectl get service my-app-jp -n default &>/dev/null; then
    log_info "Waiting for application to be ready..."
    kubectl wait --for=condition=Ready pod -l component=app -n default --timeout=300s 2>/dev/null || log_warning "App pods not ready yet"
    
    log_info "Port-forwarding Application (http://localhost:8080)..."
    kubectl port-forward service/my-app-jp 8080:5000 -n default > /dev/null 2>&1 &
else
    log_info "Application service not found (may not be deployed yet)"
fi

# Grafana (if monitoring exists)
if kubectl get namespace monitoring &>/dev/null; then
    log_info "Port-forwarding Grafana (http://localhost:3000)..."
    kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80 > /dev/null 2>&1 &
    
    log_info "Port-forwarding Prometheus (http://localhost:9090)..."
    kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090 > /dev/null 2>&1 &
fi

sleep 3
log_success "Port forwarding is active!"

# =============================================================================
# Summary
# =============================================================================
echo ""
log_success "==================== SETUP COMPLETE ===================="
echo ""
echo -e "${GREEN}✓${NC} Minikube running"
echo -e "${GREEN}✓${NC} ArgoCD installed"
echo -e "${GREEN}✓${NC} Port forwarding active"
echo ""
echo -e "${BLUE}Access URLs:${NC}"
echo -e "  ArgoCD:      ${YELLOW}https://localhost:8090${NC}"
echo -e "  Application: ${YELLOW}http://localhost:8080${NC}"
if kubectl get namespace monitoring &>/dev/null; then
    echo -e "  Grafana:     ${YELLOW}http://localhost:3000${NC}"
    echo -e "  Prometheus:  ${YELLOW}http://localhost:9090${NC}"
fi
echo ""
echo -e "${BLUE}Credentials:${NC}"
echo -e "  ArgoCD:  admin / ${GREEN}$ARGOCD_PASSWORD${NC}"
if [ -n "$GRAFANA_PASSWORD" ]; then
    echo -e "  Grafana: admin / ${GREEN}$GRAFANA_PASSWORD${NC}"
fi
echo ""
log_info "To stop port forwarding: ${YELLOW}kill \$(jobs -p)${NC}"
log_info "To stop Minikube: ${YELLOW}minikube stop${NC}"
echo ""
log_success "========================================================"

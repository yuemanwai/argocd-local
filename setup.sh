#!/bin/bash
#
# Set up the local ArgoCD lab.
#
# What it does:
# 1. Chooses or starts a cluster (Minikube or OrbStack)
# 2. Installs or upgrades ArgoCD
# 3. Applies the root app bootstrap
# 4. Prints credentials and access URLs
# 5. Starts port-forwards for the common services
#
# Usage:
#   ./setup.sh [--cluster minikube|orbstack]
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

print_section() {
    echo ""
    log_info "================================================================"
    log_info "$1"
    log_info "================================================================"
    echo ""
}

has_existing_repo_secret() {
    kubectl -n argocd get secret repo-argocd-local >/dev/null 2>&1
}

git_creds_file_is_placeholder() {
    local creds_file=$1

    if grep -Eq '^[[:space:]]*username:[[:space:]]*(<GITHUB_USERNAME>|CHANGE_ME|""|)$' "$creds_file"; then
        return 0
    fi

    if grep -Eq '^[[:space:]]*password:[[:space:]]*(<GITHUB_PAT>|CHANGE_ME|""|)$' "$creds_file"; then
        return 0
    fi

    return 1
}

MINIKUBE_PROFILE="minikube"
CLUSTER_PROVIDER="minikube"

usage() {
    cat <<EOF
Usage: ./setup.sh [--cluster minikube|orbstack]

Options:
  --cluster   Kubernetes provider to use.
              minikube (default): start/recover Minikube automatically.
              orbstack: switch to OrbStack kube context and use existing cluster.
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --cluster)
                if [ -z "${2:-}" ]; then
                    log_error "Missing value for --cluster"
                    usage
                    exit 1
                fi
                CLUSTER_PROVIDER="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done

    if [ "$CLUSTER_PROVIDER" != "minikube" ] && [ "$CLUSTER_PROVIDER" != "orbstack" ]; then
        log_error "Unsupported --cluster value: $CLUSTER_PROVIDER"
        usage
        exit 1
    fi
}

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

ensure_orbstack_context() {
    local orbstack_context="orbstack"

    if ! kubectl config get-contexts -o name | grep -qx "$orbstack_context"; then
        log_error "Kubernetes context '$orbstack_context' not found"
        log_info "Open OrbStack and enable Kubernetes first, then retry."
        log_info "You can check contexts with: kubectl config get-contexts"
        exit 1
    fi

    log_info "Switching kube context to OrbStack..."
    kubectl config use-context "$orbstack_context" >/dev/null
    log_success "Using Kubernetes context: $orbstack_context"
}

ensure_cluster_reachable() {
    local retries=30
    local delay=2

    if ! command -v kubectl >/dev/null 2>&1; then
        log_error "kubectl is not installed or not in PATH"
        exit 1
    fi

    if ! kubectl cluster-info >/dev/null 2>&1; then
        if [ "$CLUSTER_PROVIDER" = "minikube" ]; then
            log_warning "Kubernetes API is not reachable. Refreshing Minikube context..."
            minikube update-context >/dev/null 2>&1 || true
        else
            log_warning "Kubernetes API is not reachable on OrbStack context."
        fi
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
    if [ "$CLUSTER_PROVIDER" = "minikube" ]; then
        log_info "  minikube status"
        log_info "  minikube update-context"
    else
        log_info "  kubectl config use-context orbstack"
        log_info "  kubectl cluster-info"
        log_info "  (Open OrbStack and confirm Kubernetes is enabled)"
    fi
    log_info "  kubectl config current-context"
    exit 1
}

ensure_metrics_server() {
    local apiservice="v1beta1.metrics.k8s.io"
    local retries=30

    print_section "1.1 Ensure Metrics API"

    if kubectl get apiservice "$apiservice" >/dev/null 2>&1; then
        log_info "metrics-server APIService already exists"
    else
        log_info "Installing metrics-server..."
        kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml >/dev/null
        log_success "metrics-server manifests applied"
    fi

    log_info "Patching metrics-server args for local kubelet TLS/address compatibility..."
    kubectl -n kube-system patch deployment metrics-server --type='json' \
        -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' >/dev/null 2>&1 || true
    kubectl -n kube-system patch deployment metrics-server --type='json' \
        -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP"}]' >/dev/null 2>&1 || true

    log_info "Waiting for metrics API to report Available=True..."
    while [ "$retries" -gt 0 ]; do
        local available
        available=$(kubectl get apiservice "$apiservice" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)

        if [ "$available" = "True" ]; then
            log_success "Metrics API is available"
            return 0
        fi

        retries=$((retries - 1))
        sleep 2
    done

    log_warning "Metrics API is not available yet. Setup will continue, but HPA may show <unknown> temporarily."
}

wait_for_namespace() {
    local namespace=$1
    log_info "Waiting for namespace $namespace to be ready..."

    # Ignore completed/failed pods (for example one-shot init Jobs),
    # otherwise `kubectl wait --all` can block until timeout.
    local active_pods
    active_pods=$(kubectl get pods -n "$namespace" \
        --field-selector=status.phase!=Succeeded,status.phase!=Failed \
        -o name 2>/dev/null || true)

    if [ -z "$active_pods" ]; then
        log_warning "No active pods found in namespace $namespace"
        return 0
    fi

    if ! kubectl wait --for=condition=Ready -n "$namespace" --timeout=180s $active_pods 2>/dev/null; then
        log_warning "Some active pods in namespace $namespace were not ready before timeout"
    fi
}

wait_for_applications_sync() {
    local timeout_seconds=120
    local interval_seconds=5
    local elapsed=0

    log_info "Waiting for ArgoCD applications to sync (up to ${timeout_seconds}s)..."

    while [ "$elapsed" -lt "$timeout_seconds" ]; do
        local app_count
        app_count=$(kubectl get applications.argoproj.io -n argocd --no-headers 2>/dev/null | wc -l | tr -d ' ')

        if [ "$app_count" -eq 0 ]; then
            sleep "$interval_seconds"
            elapsed=$((elapsed + interval_seconds))
            continue
        fi

        local sync_values
        local health_values
        local not_synced
        local not_healthy

        sync_values=$(kubectl get applications.argoproj.io -n argocd -o jsonpath='{range .items[*]}{.status.sync.status}{"\n"}{end}' 2>/dev/null || true)
        health_values=$(kubectl get applications.argoproj.io -n argocd -o jsonpath='{range .items[*]}{.status.health.status}{"\n"}{end}' 2>/dev/null || true)

        not_synced=$(echo "$sync_values" | grep -vc '^Synced$' || true)
        not_healthy=$(echo "$health_values" | grep -Evc '^(Healthy|Suspended)$' || true)

        if [ "$not_synced" -eq 0 ] && [ "$not_healthy" -eq 0 ]; then
            log_success "ArgoCD applications are synced and healthy"
            return 0
        fi

        sleep "$interval_seconds"
        elapsed=$((elapsed + interval_seconds))
    done

    log_warning "Application sync is still in progress; continuing setup"
}

print_section "1. Prepare Kubernetes Cluster"
parse_args "$@"

if [ "$CLUSTER_PROVIDER" = "minikube" ]; then
    start_or_recover_minikube

    # Wait for Minikube to be fully ready
    log_info "Waiting for Minikube to be ready..."
    sleep 5
else
    ensure_orbstack_context
fi

log_info "Verifying Kubernetes connection..."
ensure_cluster_reachable
ensure_metrics_server

print_section "2. Install ArgoCD"
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

print_section "3. Deploy Root Application"
log_info "Deploying root application via ArgoCD..."

# First, apply git repository secret
if [ -f "bootstrap/repo-secret/github-repo-secret.template.yaml" ]; then
    if git_creds_file_is_placeholder "bootstrap/repo-secret/github-repo-secret.template.yaml"; then
        if has_existing_repo_secret; then
            log_info "github-repo-secret.template.yaml still has placeholders; using existing repo secret in cluster"
        else
            log_warning "github-repo-secret.template.yaml still has placeholders and no repo secret exists in cluster"
            log_info "Run ./bootstrap/repo-secret/apply-github-repo-secret-from-prompts.sh to apply credentials securely"
        fi
    else
        log_info "Applying Git credentials..."
        kubectl apply -f bootstrap/repo-secret/github-repo-secret.template.yaml >/dev/null 2>&1 || log_warning "Git credentials apply returned non-zero"
    fi
else
    if has_existing_repo_secret; then
        log_info "Git credentials file not found; using existing repo secret in cluster"
    else
        log_warning "Git credentials file not found and no repo secret exists in cluster"
        log_info "Run ./bootstrap/repo-secret/apply-github-repo-secret-from-prompts.sh to apply credentials securely"
    fi
fi

# Then deploy the root-app bootstrap
log_info "Applying root-app bootstrap..."
kubectl apply -f bootstrap/bootstrap.yaml 2>/dev/null || log_warning "Bootstrap already applied"

wait_for_applications_sync

print_section "4. Credentials"

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

print_section "5. Setup Port Forwarding"
log_info "Setting up port forwards..."

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

# Kubecost (if kubecost exists)
if kubectl get namespace kubecost &>/dev/null; then
    KUBECOST_SERVICE=""
    if kubectl get service kubecost-cost-analyzer -n kubecost &>/dev/null; then
        KUBECOST_SERVICE="kubecost-cost-analyzer"
    elif kubectl get service cost-analyzer -n kubecost &>/dev/null; then
        KUBECOST_SERVICE="cost-analyzer"
    fi

    if [ -n "$KUBECOST_SERVICE" ]; then
        log_info "Port-forwarding Kubecost (http://localhost:9091)..."
        kubectl port-forward "service/$KUBECOST_SERVICE" 9091:9090 -n kubecost > /dev/null 2>&1 &
    else
        log_warning "Kubecost namespace found but service not ready yet"
    fi
fi

sleep 3
log_success "Port forwarding is active!"

# =============================================================================
# Summary
# =============================================================================
echo ""
log_success "==================== SETUP COMPLETE ===================="
echo ""
echo -e "${GREEN}✓${NC} Kubernetes provider: ${YELLOW}${CLUSTER_PROVIDER}${NC}"
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
if kubectl get namespace kubecost &>/dev/null; then
    echo -e "  Kubecost:    ${YELLOW}http://localhost:9091${NC}"
fi
echo ""
echo -e "${BLUE}Credentials:${NC}"
echo -e "  ArgoCD:  admin / ${GREEN}$ARGOCD_PASSWORD${NC}"
if [ -n "$GRAFANA_PASSWORD" ]; then
    echo -e "  Grafana: admin / ${GREEN}$GRAFANA_PASSWORD${NC}"
fi
echo ""
log_info "To stop port forwarding: ${YELLOW}kill \$(jobs -p)${NC}"
if [ "$CLUSTER_PROVIDER" = "minikube" ]; then
    log_info "To stop Minikube: ${YELLOW}minikube stop${NC}"
else
    log_info "To stop OrbStack Kubernetes: disable Kubernetes in OrbStack UI"
fi
echo ""
log_success "========================================================"

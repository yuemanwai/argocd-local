#!/bin/bash
#
# Clean up the local ArgoCD lab.
#
# What it does:
# 1. Removes the bootstrap application
# 2. Clears finalizers from stuck resources
# 3. Deletes managed namespaces and CRDs
# 4. Uninstalls Helm releases
# 5. Stops port-forwards and optionally stops the cluster runtime
#
# Usage:
#   ./cleanup.sh [--cluster auto|minikube|orbstack]
#
set +e  # Don't exit on error - we need to handle cleanup even if some commands fail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

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

CLUSTER_PROVIDER="auto"

usage() {
    cat <<EOF
Usage: ./cleanup.sh [--cluster auto|minikube|orbstack]

Options:
  --cluster   Select cleanup provider behavior.
              auto (default): detect from current kube context.
              minikube: stop minikube at the end.
              orbstack: stop OrbStack at the end.
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

    if [ "$CLUSTER_PROVIDER" != "auto" ] && [ "$CLUSTER_PROVIDER" != "minikube" ] && [ "$CLUSTER_PROVIDER" != "orbstack" ]; then
        log_error "Unsupported --cluster value: $CLUSTER_PROVIDER"
        usage
        exit 1
    fi
}

detect_cluster_provider() {
    if [ "$CLUSTER_PROVIDER" != "auto" ]; then
        return
    fi

    local current_context
    current_context=$(kubectl config current-context 2>/dev/null || true)

    case "$current_context" in
        *orbstack*)
            CLUSTER_PROVIDER="orbstack"
            ;;
        *minikube*)
            CLUSTER_PROVIDER="minikube"
            ;;
        *)
            CLUSTER_PROVIDER="orbstack"
            log_warning "Could not detect provider from context '$current_context'; defaulting to orbstack"
            ;;
    esac
}

parse_args "$@"
detect_cluster_provider
log_info "Cleanup provider mode: $CLUSTER_PROVIDER"

# Confirmation prompt
print_section "Warning"
log_warning "This script will DELETE ArgoCD and ALL managed applications."
echo ""
read -p "Are you sure you want to continue? (yes/no): " -r
echo
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    log_info "Cleanup cancelled"
    exit 0
fi

# Helper function to remove finalizers from a resource
remove_finalizers() {
    local kind=$1
    local name=$2
    local namespace=${3:-}
    
    if [ -z "$namespace" ]; then
        kubectl patch "$kind" "$name" --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    else
        kubectl patch "$kind" "$name" -n "$namespace" --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    fi
}

print_section "1. Delete ArgoCD Applications (cascade delete)"
log_info "Deleting ArgoCD applications with cascade delete to auto-cleanup managed resources..."

# First, let ArgoCD clean up all managed resources by deleting Applications
# with cascade=foreground (wait for finalizers to finish)
log_info "Deleting all ArgoCD Applications with cascade delete..."
kubectl delete applications --all --all-namespaces --cascade=foreground --grace-period=30 2>/dev/null || true
sleep 3

# Delete bootstrap Application directly
if [ -f "bootstrap/bootstrap.yaml" ]; then
    log_info "Deleting bootstrap application..."
    kubectl delete -f bootstrap/bootstrap.yaml --cascade=foreground --grace-period=30 2>/dev/null || true
fi
sleep 2

# Remove any remaining ArgoCD Application finalizers if needed
log_info "Cleaning up any remaining ArgoCD Application finalizers..."
kubectl get applications --all-namespaces -o json 2>/dev/null | \
    jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' 2>/dev/null | while read ns name; do
        if [ ! -z "$ns" ] && [ ! -z "$name" ]; then
            remove_finalizers "application" "$name" "$ns"
        fi
    done 2>/dev/null || true

sleep 2

print_section "2. Delete Helm Releases"
log_info "Uninstalling Helm releases..."

for release in argocd kube-prometheus-stack loki my-app; do
    if helm list -n argocd 2>/dev/null | grep -q "^${release}"; then
        helm uninstall "$release" -n argocd --wait=false 2>/dev/null || true
    fi
done

log_info "Waiting for Helm releases to be removed..."
sleep 3

print_section "3. Force Delete Stuck Resources"
log_info "Removing finalizers from PVCs, PVs, and other stuck resources..."

# Remove finalizers from all PVCs across all namespaces
log_info "Removing finalizers from PersistentVolumeClaims..."
kubectl get pvc --all-namespaces -o json 2>/dev/null | \
    jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' 2>/dev/null | while read ns name; do
        if [ ! -z "$ns" ] && [ ! -z "$name" ]; then
            remove_finalizers "pvc" "$name" "$ns"
        fi
    done 2>/dev/null || true

# Remove finalizers from PVs
log_info "Removing finalizers from PersistentVolumes..."
kubectl get pv -o json 2>/dev/null | \
    jq -r '.items[].metadata.name' 2>/dev/null | while read pv; do
        if [ ! -z "$pv" ]; then
            remove_finalizers "pv" "$pv"
        fi
    done 2>/dev/null || true

# Force delete stuck PVCs and PVs
log_info "Force deleting PersistentVolumeClaims..."
kubectl delete pvc --all --all-namespaces --grace-period=0 --force 2>/dev/null || true

log_info "Force deleting PersistentVolumes..."
kubectl delete pv --all --grace-period=0 --force 2>/dev/null || true

sleep 2

print_section "4. Delete Namespaces, CRDs and WebHooks"
log_info "Deleting managed namespaces, CRDs, WebHooks and cluster roles..."

# Remove webhook configurations that might block namespace deletion
log_info "Deleting ValidatingWebhookConfigurations and MutatingWebhookConfigurations..."
kubectl get validatingwebhookconfigurations -o name 2>/dev/null | grep -E 'keda|prometheus|argocd' | while read webhook; do
    kubectl delete "$webhook" 2>/dev/null || true
done 2>/dev/null || true

kubectl get mutatingwebhookconfigurations -o name 2>/dev/null | grep -E 'keda|prometheus|argocd' | while read webhook; do
    kubectl delete "$webhook" 2>/dev/null || true
done 2>/dev/null || true

sleep 2

# Delete managed namespaces - try graceful first, then force
log_info "Deleting managed namespaces..."
for ns in argocd monitoring logging loki kubecost argo-rollouts keda; do
    if kubectl get namespace "$ns" 2>/dev/null; then
        log_info "Deleting namespace: $ns"
        # First attempt with grace period
        kubectl delete namespace "$ns" --grace-period=10 2>/dev/null || true
        sleep 1
        
        # If still exists, remove finalizers and force delete
        if kubectl get namespace "$ns" 2>/dev/null; then
            log_warning "Namespace $ns stuck, removing finalizers..."
            kubectl patch namespace "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            kubectl delete namespace "$ns" --grace-period=0 --force 2>/dev/null || true
        fi
    fi
done

sleep 2

# Delete ArgoCD CRDs
log_info "Deleting ArgoCD and related CRDs..."
kubectl get crd -o name 2>/dev/null | grep -E 'argoproj.io|keda.sh|monitoring.coreos.com|eventing.keda.sh' | while read crd; do
    kubectl delete "$crd" --wait=false 2>/dev/null || true
done 2>/dev/null || true

# Delete resources from default namespace
log_info "Cleaning default namespace..."
kubectl delete all --all -n default --wait=false 2>/dev/null || true
kubectl delete pvc --all -n default --wait=false 2>/dev/null || true
kubectl delete hpa --all -n default --wait=false 2>/dev/null || true

# Delete ClusterRoles and ClusterRoleBindings
log_info "Deleting ArgoCD and related cluster roles..."
kubectl get clusterrole -o name 2>/dev/null | grep -E 'argocd|keda|prometheus' | while read role; do
    kubectl delete "$role" 2>/dev/null || true
done 2>/dev/null || true

kubectl get clusterrolebinding -o name 2>/dev/null | grep -E 'argocd|keda|prometheus' | while read binding; do
    kubectl delete "$binding" 2>/dev/null || true
done 2>/dev/null || true

sleep 3

print_section "5. Final Cleanup"
log_info "Stopping port-forwards and checking whether the cluster runtime should stop..."

# Stop port forwards
if [ -f "./port-forward.sh" ]; then
    ./port-forward.sh stop 2>/dev/null || true
fi
pkill -f "port-forward" 2>/dev/null || true

# Ask about cluster runtime stop based on provider
if [ "$CLUSTER_PROVIDER" = "minikube" ]; then
    if command -v minikube >/dev/null 2>&1 && minikube status >/dev/null 2>&1; then
        read -p "Stop Minikube now? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Stopping Minikube..."
            minikube stop || log_warning "Failed to stop Minikube"
        fi
    fi
elif [ "$CLUSTER_PROVIDER" = "orbstack" ]; then
    if command -v orbctl >/dev/null 2>&1 && orbctl status 2>/dev/null | grep -q "Running"; then
        read -p "Stop OrbStack now? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Stopping OrbStack..."
            orbctl stop || log_warning "Failed to stop OrbStack"
        fi
    fi
fi

print_section "Cleanup Complete"
log_success "All resources have been cleaned up:"
log_info "  ✓ Bootstrap application deleted"
log_info "  ✓ All finalizers removed from stuck resources"
log_info "  ✓ Helm releases uninstalled"
log_info "  ✓ ArgoCD namespace deleted"
log_info "  ✓ Managed namespaces deleted"
log_info "  ✓ ArgoCD CRDs removed"
log_info "  ✓ Port forwards stopped"
echo ""
log_info "Verification commands:"
log_info "  kubectl get ns"
log_info "  kubectl get pv"
log_info "  kubectl get crd | grep argoproj"
echo ""
log_success "=========================================================="

#!/bin/bash
#
# ArgoCD Cleanup Script - Complete cleanup of ArgoCD and all managed applications
#
# This script will:
# 1. Delete bootstrap configuration (triggers cascade deletion)
# 2. Remove all finalizers from stuck resources
# 3. Delete all managed resources and namespaces
# 4. Clean up ArgoCD Helm release and CRDs
# 5. Stop port-forwards and optionally stop Minikube
#
# Usage: ./cleanup.sh
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

# Confirmation prompt
echo ""
log_warning "==================== WARNING ===================="
log_warning "This script will DELETE ArgoCD and ALL managed applications!"
log_warning "=================================================="
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

# =============================================================================
# 1. Delete Bootstrap and Remove All Finalizers
# =============================================================================
log_info "Step 1/5: Deleting root-app and removing finalizers from all resources..."

# Delete bootstrap
if [ -f "bootstrap/bootstrap.yaml" ]; then
    kubectl delete -f bootstrap/bootstrap.yaml --wait=false 2>/dev/null || true
fi
sleep 2

# Remove finalizers from Applications
log_info "Removing finalizers from ArgoCD Applications..."
for app in $(kubectl get applications -n argocd -o name 2>/dev/null); do
    remove_finalizers "$(echo $app | cut -d'/' -f1)" "$(echo $app | cut -d'/' -f2)" "argocd"
done 2>/dev/null || true

# Delete all applications
kubectl delete applications --all --all-namespaces --wait=false 2>/dev/null || true
sleep 2

# Remove finalizers from namespace objects
log_info "Removing finalizers from namespaces..."
for ns in argocd monitoring logging loki; do
    if kubectl get namespace "$ns" 2>/dev/null; then
        remove_finalizers "namespace" "$ns"
    fi
done
sleep 1

# =============================================================================
# 2. Delete Helm Releases
# =============================================================================
log_info "Step 2/5: Uninstalling Helm releases..."

for release in argocd kube-prometheus-stack loki my-app; do
    if helm list -n argocd 2>/dev/null | grep -q "^${release}"; then
        helm uninstall "$release" -n argocd --wait=false 2>/dev/null || true
    fi
done

log_info "Waiting for Helm releases to be removed..."
sleep 3

# =============================================================================
# 3. Remove Finalizers and Force Delete Resources
# =============================================================================
log_info "Step 3/5: Force removing finalizers from stuck resources..."

# Remove finalizers from ArgoCD CRDs
log_info "Removing finalizers from ArgoCD CRD resources..."
kubectl get applications.argoproj.io --all-namespaces -o json 2>/dev/null | \
    grep -o '"namespace":"[^"]*","name":"[^"]*"' 2>/dev/null | while read item; do
    ns=$(echo "$item" | grep -o '"namespace":"[^"]*"' | cut -d'"' -f4)
    name=$(echo "$item" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
    remove_finalizers "application" "$name" "$ns"
done 2>/dev/null || true

# Remove finalizers from all PVCs
log_info "Removing finalizers from PersistentVolumeClaims..."
kubectl get pvc --all-namespaces -o json 2>/dev/null | \
    grep -o '"namespace":"[^"]*","name":"[^"]*"' 2>/dev/null | while read item; do
    ns=$(echo "$item" | grep -o '"namespace":"[^"]*"' | cut -d'"' -f4)
    name=$(echo "$item" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
    remove_finalizers "pvc" "$name" "$ns"
done 2>/dev/null || true

# Remove finalizers from PVs
log_info "Removing finalizers from PersistentVolumes..."
kubectl get pv -o json 2>/dev/null | \
    jq -r '.items[].metadata.name' 2>/dev/null | while read pv; do
    remove_finalizers "pv" "$pv"
done 2>/dev/null || true

sleep 2

# =============================================================================
# 4. Delete Namespaces and CRDs
# =============================================================================
log_info "Step 4/5: Deleting namespaces and CRDs..."

# Delete managed namespaces
for ns in monitoring logging loki argocd; do
    if kubectl get namespace "$ns" 2>/dev/null; then
        log_info "Deleting namespace: $ns"
        kubectl delete namespace "$ns" --grace-period=0 --force 2>/dev/null || true
    fi
done

# Delete ArgoCD CRDs
log_info "Deleting ArgoCD CRDs..."
kubectl get crd -o name 2>/dev/null | grep 'argoproj.io' | while read crd; do
    kubectl delete "$crd" --wait=false 2>/dev/null || true
done 2>/dev/null || true

# Delete resources from default namespace
log_info "Cleaning default namespace..."
kubectl delete all --all -n default --wait=false 2>/dev/null || true
kubectl delete pvc --all -n default --wait=false 2>/dev/null || true
kubectl delete hpa --all -n default --wait=false 2>/dev/null || true

# Delete ClusterRoles and ClusterRoleBindings
log_info "Deleting ArgoCD cluster roles..."
kubectl get clusterrole -o name 2>/dev/null | grep 'argocd' | while read role; do
    kubectl delete "$role" 2>/dev/null || true
done 2>/dev/null || true

kubectl get clusterrolebinding -o name 2>/dev/null | grep 'argocd' | while read binding; do
    kubectl delete "$binding" 2>/dev/null || true
done 2>/dev/null || true

sleep 3

# =============================================================================
# 5. Cleanup and Port Forwards
# =============================================================================
log_info "Step 5/5: Final cleanup..."

# Stop port forwards
if [ -f "./port-forward.sh" ]; then
    ./port-forward.sh stop 2>/dev/null || true
fi
pkill -f "port-forward" 2>/dev/null || true

# Ask about Minikube
if command -v minikube >/dev/null 2>&1 && minikube status >/dev/null 2>&1; then
    read -p "Stop Minikube now? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Stopping Minikube..."
        minikube stop || log_warning "Failed to stop Minikube"
    fi
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
log_success "==================== CLEANUP COMPLETE ===================="
echo ""
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

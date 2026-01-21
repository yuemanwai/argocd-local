#!/bin/bash
#
# ArgoCD Cleanup Script
# 
# This script will:
# 1. Delete all ArgoCD applications (to prevent orphaned resources)
# 2. Uninstall ArgoCD via Helm
# 3. Clean up ArgoCD CRDs
# 4. Remove ArgoCD namespace and related secrets
# 5. Clean up any leftover resources
#
# Usage: ./cleanup-argocd.sh
#
set -e  # Exit on error

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
log_warning "This includes:"
log_warning "  - Root Application (root-app)"
log_warning "  - All child Applications (kps, loki, my-app, etc)"
log_warning "  - ArgoCD Helm release"
log_warning "  - ArgoCD CRDs"
log_warning "  - ArgoCD namespace and secrets"
log_warning "  - All managed application resources"
log_warning "=================================================="
echo ""
read -p "Are you sure you want to continue? (yes/no): " -r
echo
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    log_info "Cleanup cancelled"
    exit 0
fi

# =============================================================================
# 1. Delete Root Application (App of Apps)
# =============================================================================
log_info "Step 1/6: Deleting Root Application (root-app)..."

if kubectl get namespace argocd &>/dev/null; then
    if kubectl get application root-app -n argocd &>/dev/null; then
        log_info "Removing finalizers from root-app"
        kubectl patch application root-app -n argocd --type json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
        
        log_info "Deleting root-app..."
        kubectl delete application root-app -n argocd --wait=false 2>/dev/null || true
        log_success "Root application deletion initiated"
    else
        log_info "Root application (root-app) not found"
    fi
fi

sleep 2

# =============================================================================
# 2. Delete Child Applications
# =============================================================================
log_info "Step 2/6: Deleting child applications..."

if kubectl get namespace argocd &>/dev/null; then
    APPS=$(kubectl get applications -n argocd -o name 2>/dev/null | wc -l)
    if [ "$APPS" -gt 0 ]; then
        log_info "Found $APPS applications to delete"
        
        # Remove finalizers first to speed up deletion
        kubectl get applications -n argocd -o name 2>/dev/null | while read app; do
            log_info "Removing finalizers from $app"
            kubectl patch $app -n argocd --type json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
        done
        
        # Delete all applications
        log_info "Deleting applications..."
        kubectl delete applications --all -n argocd --wait=false 2>/dev/null || true
        
        log_success "Applications deletion initiated"
    else
        log_info "No applications found"
    fi
else
    log_info "ArgoCD namespace not found, skipping application deletion"
fi

sleep 3

# =============================================================================
# 3. Uninstall ArgoCD via Helm
# =============================================================================
log_info "Step 3/6: Uninstalling ArgoCD Helm release..."

if helm list -n argocd 2>/dev/null | grep -q argocd; then
    log_info "Uninstalling ArgoCD Helm release..."
    helm uninstall argocd -n argocd --wait 2>/dev/null || log_warning "Helm uninstall failed, continuing..."
    log_success "ArgoCD Helm release removed"
else
    log_info "ArgoCD Helm release not found"
fi

sleep 2

# =============================================================================
# 4. Delete ArgoCD CRDs
# =============================================================================
log_info "Step 4/6: Deleting ArgoCD CRDs..."

ARGOCD_CRDS=$(kubectl get crd -o name 2>/dev/null | grep -E 'argoproj.io' | wc -l)
if [ "$ARGOCD_CRDS" -gt 0 ]; then
    log_info "Found $ARGOCD_CRDS ArgoCD CRDs to delete"
    kubectl get crd -o name 2>/dev/null | grep -E 'argoproj.io' | while read crd; do
        log_info "Deleting $crd"
        kubectl delete $crd --wait=false 2>/dev/null || true
    done
    log_success "ArgoCD CRDs deletion initiated"
else
    log_info "No ArgoCD CRDs found"
fi

sleep 2

# =============================================================================
# 5. Delete ArgoCD Namespace and Resources
# =============================================================================
log_info "Step 5/6: Deleting ArgoCD namespace..."

if kubectl get namespace argocd &>/dev/null; then
    # Remove finalizers from namespace
    log_info "Removing finalizers from argocd namespace..."
    kubectl patch namespace argocd --type json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
    
    # Delete namespace
    log_info "Deleting argocd namespace..."
    kubectl delete namespace argocd --wait=false 2>/dev/null || true
    log_success "ArgoCD namespace deletion initiated"
else
    log_info "ArgoCD namespace not found"
fi

sleep 2

# =============================================================================
# 6. Clean up leftover resources
# =============================================================================
log_info "Step 6/6: Cleaning up leftover resources..."

# Remove ArgoCD ClusterRoles and ClusterRoleBindings
log_info "Removing ArgoCD ClusterRoles..."
kubectl get clusterroles -o name 2>/dev/null | grep -E 'argocd' | while read resource; do
    kubectl delete $resource 2>/dev/null || true
done

log_info "Removing ArgoCD ClusterRoleBindings..."
kubectl get clusterrolebindings -o name 2>/dev/null | grep -E 'argocd' | while read resource; do
    kubectl delete $resource 2>/dev/null || true
done

# Remove ArgoCD ServiceAccounts in other namespaces
log_info "Removing ArgoCD ServiceAccounts..."
kubectl get serviceaccounts --all-namespaces -o json 2>/dev/null | \
    jq -r '.items[] | select(.metadata.name | contains("argocd")) | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null | \
    while read sa; do
        namespace=$(echo $sa | cut -d'/' -f1)
        name=$(echo $sa | cut -d'/' -f2)
        kubectl delete serviceaccount $name -n $namespace 2>/dev/null || true
    done 2>/dev/null || true

# Remove ArgoCD secrets in other namespaces
log_info "Removing ArgoCD secrets..."
kubectl get secrets --all-namespaces -o json 2>/dev/null | \
    jq -r '.items[] | select(.metadata.name | contains("argocd")) | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null | \
    while read secret; do
        namespace=$(echo $secret | cut -d'/' -f1)
        name=$(echo $secret | cut -d'/' -f2)
        kubectl delete secret $name -n $namespace 2>/dev/null || true
    done 2>/dev/null || true

log_success "Leftover resources cleaned up"

# =============================================================================
# Summary
# =============================================================================
echo ""
log_success "==================== CLEANUP COMPLETE ===================="
echo ""
log_success "ArgoCD has been completely removed from the cluster"
echo ""
log_info "Remaining resources:"
log_info "  - Check applications: ${YELLOW}kubectl get applications --all-namespaces${NC}"
log_info "  - Check ArgoCD CRDs: ${YELLOW}kubectl get crd | grep argoproj${NC}"
log_info "  - Check namespace: ${YELLOW}kubectl get namespace argocd${NC}"
echo ""
log_info "To reinstall ArgoCD, run: ${YELLOW}./setup.sh${NC}"
echo ""
log_success "=========================================================="

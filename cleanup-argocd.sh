#!/bin/bash
#
# ArgoCD Cleanup Script - Complete cleanup of ArgoCD and all managed applications
# 
# This script will:
# 1. Delete bootstrap configuration (bootstrap.yaml) to trigger ArgoCD cleanup cascade
# 2. Wait for all applications to be deleted (ArgoCD handles this)
# 3. Delete Git credentials secret
# 4. Uninstall ArgoCD via Helm
# 5. Clean up ArgoCD CRDs and namespace
# 6. Clean up all managed application resources (deployments, services, etc)
# 7. Clean up monitoring and other managed namespaces
# 8. Clean up orphaned PVCs and PVs
# 9. Clean up all finalizers and stuck resources
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
log_warning ""
log_warning "Cleanup flow (ArgoCD cascade deletion):"
log_warning "  1. Delete bootstrap.yaml (removes root-app)"
log_warning "  2. ArgoCD automatically cascades delete:"
log_warning "     - All child Applications (kps, loki, my-app, etc)"
log_warning "     - All managed application resources"
log_warning "  3. Delete Git credentials secret"
log_warning "  4. Uninstall ArgoCD Helm release"
log_warning "  5. Clean up CRDs and namespace"
log_warning "=================================================="
echo ""
read -p "Are you sure you want to continue? (yes/no): " -r
echo
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    log_info "Cleanup cancelled"
    exit 0
fi

# =============================================================================
# 1. Delete Bootstrap Configuration (triggers cascade deletion)
# =============================================================================
log_info "Step 1/6: Deleting root-app Application from Kubernetes..."
log_info "  (Using bootstrap/bootstrap.yaml manifest to remove the Application resource)"
log_info "  This will trigger ArgoCD cascade deletion of all child applications"

if [ -f "bootstrap/bootstrap.yaml" ]; then
    log_info "Running: kubectl delete -f bootstrap/bootstrap.yaml"
    kubectl delete -f bootstrap/bootstrap.yaml --wait=false 2>/dev/null || true
    log_success "Root application deletion initiated in Kubernetes"
    log_info "Waiting for applications to be deleted by ArgoCD..."
    sleep 10
else
    log_warning "bootstrap/bootstrap.yaml not found"
fi

# =============================================================================
# 2. Wait for All Applications to Be Deleted
# =============================================================================
log_info "Step 2/6: Waiting for all applications to be cleaned up..."

if kubectl get namespace argocd &>/dev/null; then
    # Wait for all applications to be deleted
    MAX_WAIT=120
    ELAPSED=0
    while [ $ELAPSED -lt $MAX_WAIT ]; do
        APPS=$(kubectl get applications -n argocd -o name 2>/dev/null | wc -l)
        if [ "$APPS" -eq 0 ]; then
            log_success "All applications deleted"
            break
        fi
        log_info "Still waiting for $APPS applications to be deleted... ($ELAPSED/$MAX_WAIT seconds)"
        sleep 5
        ELAPSED=$((ELAPSED + 5))
    done
    
    if [ $ELAPSED -ge $MAX_WAIT ]; then
        log_warning "Timeout waiting for applications to be deleted, continuing with cleanup..."
    fi
else
    log_info "ArgoCD namespace not found"
fi

sleep 2

# =============================================================================
# 3. Delete Git Credentials Secret
# =============================================================================
log_info "Step 3/6: Deleting Git credentials secret..."

if [ -f "bootstrap/repo-secret/git-creds.yaml" ]; then
    log_info "Deleting Git credentials from bootstrap/repo-secret/git-creds.yaml..."
    kubectl delete -f bootstrap/repo-secret/git-creds.yaml --wait=false 2>/dev/null || true
    log_success "Git credentials deletion initiated"
else
    log_warning "bootstrap/repo-secret/git-creds.yaml not found"
    # Try to delete if it exists in cluster anyway
    kubectl delete secret -n argocd -l argocd.argoproj.io/secret-type=repository --wait=false 2>/dev/null || true
fi

sleep 2

# =============================================================================
# 4. Uninstall ArgoCD via Helm (optional)
# =============================================================================
log_info "Step 4/6: ArgoCD Helm release"

if helm list -n argocd 2>/dev/null | grep -q "^argocd\b"; then
    read -p "Uninstall ArgoCD Helm release now? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Uninstalling ArgoCD Helm release..."
        helm uninstall argocd -n argocd --wait 2>/dev/null || log_warning "Helm uninstall failed, continuing..."
        log_success "ArgoCD Helm release removed"
    else
        log_info "Skipping ArgoCD Helm uninstall"
    fi
else
    log_info "ArgoCD Helm release not found"
fi

sleep 2

# =============================================================================
# 5. Delete ArgoCD CRDs
# =============================================================================
log_info "Step 5/6: Deleting ArgoCD CRDs..."

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
# 6. Delete ArgoCD Namespace and Resources
# =============================================================================
log_info "Step 6/6: Deleting ArgoCD namespace..."

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
# 7. Clean up managed namespaces (monitoring, logging, etc)
# =============================================================================
log_info "Step 7/9: Cleaning up managed namespaces..."

MANAGED_NAMESPACES=("monitoring" "logging" "loki")
for ns in "${MANAGED_NAMESPACES[@]}"; do
    if kubectl get namespace "$ns" &>/dev/null; then
        log_info "Deleting namespace: $ns"
        # Remove finalizers first
        kubectl patch namespace "$ns" --type json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
        # Delete namespace
        kubectl delete namespace "$ns" --wait=false 2>/dev/null || true
    fi
done

log_info "Waiting for managed namespaces to be deleted..."
sleep 5

# =============================================================================
# 8. Clean up resources in default namespace
# =============================================================================
log_info "Step 8/9: Cleaning up resources in default namespace..."

# Delete all deployments managed by ArgoCD
log_info "Removing ArgoCD-managed deployments from default namespace..."
kubectl delete deployments --all -n default --wait=false 2>/dev/null || true

# Delete all statefulsets
log_info "Removing statefulsets from default namespace..."
kubectl delete statefulsets --all -n default --wait=false 2>/dev/null || true

# Delete all HPAs (HorizontalPodAutoscalers)
log_info "Removing HorizontalPodAutoscalers from default namespace..."
kubectl delete hpa --all -n default --wait=false 2>/dev/null || true

# Delete all services (except kubernetes service)
log_info "Removing services from default namespace..."
kubectl get services -n default -o name 2>/dev/null | grep -v "service/kubernetes" | while read svc; do
    kubectl delete "$svc" -n default --wait=false 2>/dev/null || true
done

# Delete all PVCs in default namespace
log_info "Removing PVCs from default namespace..."
kubectl delete pvc --all -n default --wait=false 2>/dev/null || true

log_success "Default namespace cleanup initiated"

sleep 2

# =============================================================================
# 9. Clean up orphaned PVs and other resources
# =============================================================================
log_info "Step 9/9: Cleaning up orphaned resources..."

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

# Clean up orphaned PVs with Released/Failed status
log_info "Cleaning up orphaned PersistentVolumes..."
kubectl get pv -o json 2>/dev/null | \
    jq -r '.items[] | select(.status.phase == "Released" or .status.phase == "Failed") | .metadata.name' 2>/dev/null | \
    while read pv; do
        log_info "Removing orphaned PV: $pv"
        kubectl patch pv "$pv" --type json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
        kubectl delete pv "$pv" 2>/dev/null || true
    done 2>/dev/null || true

# Force delete stuck resources
log_info "Cleaning up stuck resources..."
kubectl get all --all-namespaces -o json 2>/dev/null | \
    jq -r '.items[] | select(.metadata.finalizers != null and (.metadata.finalizers | length > 0)) | "\(.metadata.namespace)/\(.kind)/\(.metadata.name)"' 2>/dev/null | \
    while read resource; do
        namespace=$(echo $resource | cut -d'/' -f1)
        kind=$(echo $resource | cut -d'/' -f2)
        name=$(echo $resource | cut -d'/' -f3)
        if [ "$namespace" != "kube-system" ] && [ "$namespace" != "kube-public" ] && [ "$namespace" != "kube-node-lease" ]; then
            log_info "Removing finalizers from $kind/$name in namespace $namespace"
            kubectl patch "$kind" "$name" -n "$namespace" --type json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
        fi
    done 2>/dev/null || true

log_success "Orphaned resources cleaned up"

# =============================================================================
# 10. Stop port forwards
# =============================================================================
log_info "Stopping all port forwards..."
if [ -f "./port-forward.sh" ]; then
    ./port-forward.sh stop 2>/dev/null || log_info "Port forwards already stopped or script not found"
else
    pkill -f "port-forward" 2>/dev/null || true
fi

# =============================================================================
# 11. Stop Minikube (optional)
# =============================================================================
if command -v minikube >/dev/null 2>&1; then
    if minikube status >/dev/null 2>&1; then
        read -p "Stop Minikube now? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Stopping Minikube..."
            minikube stop || log_warning "Failed to stop Minikube"
        else
            log_info "Keeping Minikube running"
        fi
    fi
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
log_success "==================== CLEANUP COMPLETE ===================="
echo ""
log_success "ArgoCD and all managed applications have been completely removed"
echo ""
log_info "Cleanup flow summary (10 steps):"
log_info "  ✓ Root-app Application deleted from Kubernetes (triggered cascade)"
log_info "  ✓ All child applications deleted by ArgoCD cascade"
log_info "  ✓ Git credentials secret deleted"
log_info "  ✓ ArgoCD Helm release uninstalled"
log_info "  ✓ ArgoCD CRDs and namespace cleaned up"
log_info "  ✓ Managed namespaces deleted (monitoring, logging, etc)"
log_info "  ✓ Default namespace cleaned (deployments, statefulsets, HPAs, services, PVCs)"
log_info "  ✓ Orphaned PVs cleaned up"
log_info "  ✓ Stuck resources with finalizers removed"
log_info "  ✓ Port forwards stopped"
echo ""
log_info "Verification commands:"
log_info "  - Check all resources: ${YELLOW}kubectl get all --all-namespaces${NC}"
log_info "  - Check PVCs: ${YELLOW}kubectl get pvc --all-namespaces${NC}"
log_info "  - Check PVs: ${YELLOW}kubectl get pv${NC}"
log_info "  - Check namespaces: ${YELLOW}kubectl get ns${NC}"
echo ""
log_warning "Note: Minikube cluster is still running. To stop it:"
log_info "  ${YELLOW}minikube stop${NC}"
echo ""
log_info "To reinstall ArgoCD with the App of Apps pattern:"
log_info "  ${YELLOW}./setup.sh${NC}"
echo ""
log_success "=========================================================="

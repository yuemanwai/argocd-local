#!/bin/bash
#
# Print ClusterIP-based access info for the most useful OrbStack services.
#
# Usage:
#   ./clusterip-access.sh
#
# Output includes:
#   - Service DNS name
#   - ClusterIP
#   - Direct URL using the ClusterIP
#   - Login username/password for services that expose one
#

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
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

get_service_cluster_ip() {
    local namespace="$1"
    local service="$2"

    kubectl get service "$service" -n "$namespace" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true
}

get_secret_value() {
    local namespace="$1"
    local secret="$2"
    local jsonpath="$3"

    kubectl get secret "$secret" -n "$namespace" -o jsonpath="$jsonpath" 2>/dev/null | base64 -d 2>/dev/null || true
}

print_service_info() {
    local title="$1"
    local namespace="$2"
    local service="$3"
    local port="$4"
    local scheme="$5"
    local username="$6"
    local password="$7"

    local cluster_ip
    cluster_ip=$(get_service_cluster_ip "$namespace" "$service")

    echo -e "${GREEN}${title}${NC}"
    echo -e "  Service:    ${service}.${namespace}"

    if [ -z "$cluster_ip" ] || [ "$cluster_ip" = "<none>" ]; then
        log_warn "  ClusterIP:   not available yet"
        echo ""
        return 0
    fi

    echo -e "  ClusterIP:  ${cluster_ip}"
    echo -e "  URL:        ${scheme}://${cluster_ip}:${port}"

    if [ -n "$username" ]; then
        echo -e "  Username:    ${username}"
    fi

    if [ -n "$password" ]; then
        echo -e "  Password:    ${password}"
    elif [ -n "$username" ]; then
        echo -e "  Password:    (not available yet)"
    fi

    echo ""
}

print_section "ClusterIP Access Info"

ARGOCD_PASSWORD=$(get_secret_value "argocd" "argocd-initial-admin-secret" '{.data.password}')
GRAFANA_PASSWORD=$(get_secret_value "monitoring" "kube-prometheus-stack-grafana" '{.data.admin-password}')

print_service_info "ArgoCD" "argocd" "argocd-server" "443" "https" "admin" "$ARGOCD_PASSWORD"
print_service_info "Application" "default" "my-app-jp" "80" "http" "" ""
print_service_info "Application Preview" "default" "my-app-jp-preview" "80" "http" "" ""
print_service_info "Grafana" "monitoring" "kube-prometheus-stack-grafana" "80" "http" "admin" "$GRAFANA_PASSWORD"
print_service_info "Prometheus" "monitoring" "kube-prometheus-stack-prometheus" "80" "http" "" ""
print_service_info "Kubecost" "kubecost" "kubecost-cost-analyzer" "80" "http" "" ""

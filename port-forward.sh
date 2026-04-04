#!/bin/bash
#
# Manage local port-forwards for the ArgoCD lab.
#
# Usage:
#   ./port-forward.sh start   - Start all port forwards and print access info
#   ./port-forward.sh stop    - Stop all port forwards
#   ./port-forward.sh status  - Show running port forwards
#

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

show_status() {
    print_section "Port Forwards Status"

    if ! pgrep -f "kubectl port-forward" >/dev/null 2>&1; then
        log_error "No port-forward processes running"
        echo ""
        return
    fi

    echo -e "${BLUE}PID     PORT    SERVICE                NAMESPACE${NC}"
    echo "-------------------------------------------------------------------"

    pgrep -f "kubectl port-forward" | while read -r pid; do
        line=$(ps -p "$pid" -o command=)
        service=$(echo "$line" | grep -oE '(service|svc)/[^ ]*' | head -1 | cut -d'/' -f2)
        port=$(echo "$line" | grep -oE '[0-9]+:[0-9]+' | head -1 | cut -d':' -f1)
        namespace=$(echo "$line" | sed -nE 's/.* -n ([^ ]+).*/\1/p' | head -1)

        if [ -n "$service" ] && [ -n "$port" ]; then
            printf "${GREEN}%-7s${NC} ${YELLOW}%-7s${NC} %-24s %s\n" "$pid" "$port" "$service" "${namespace:-default}"
        fi
    done

    log_info "To stop one process: ${YELLOW}kill <PID>${NC}"
    log_info "To stop everything: ${YELLOW}./port-forward.sh stop${NC}"
    echo ""
}

print_access_info() {
    local argocd_password=""
    local grafana_password=""

    argocd_password=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
    grafana_password=$(kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true)

    echo ""
    print_section "Access Info"
    echo -e "  ArgoCD:      ${YELLOW}https://localhost:8090${NC}"
    echo -e "  Application: ${YELLOW}http://localhost:8080${NC}"
    echo -e "  Grafana:     ${YELLOW}http://localhost:3000${NC}"
    echo -e "  Prometheus:  ${YELLOW}http://localhost:9090${NC}"
    echo -e "  Kubecost:    ${YELLOW}http://localhost:9091${NC}"
    echo ""
    echo -e "  ${YELLOW}ArgoCD${NC} username: admin"
    if [ -n "$argocd_password" ]; then
        echo -e "  ${YELLOW}ArgoCD${NC} password: $argocd_password"
    else
        echo -e "  ${YELLOW}ArgoCD${NC} password: (not available yet)"
    fi

    echo -e "  ${YELLOW}Grafana${NC} username: admin"
    if [ -n "$grafana_password" ]; then
        echo -e "  ${YELLOW}Grafana${NC} password: $grafana_password"
    else
        echo -e "  ${YELLOW}Grafana${NC} password: (not available yet)"
    fi
    echo ""
}

start_forwards() {
    log_info "Starting port forwards..."
    
    # ArgoCD
    if ! pgrep -f "port-forward.*argocd-server" >/dev/null 2>&1; then
        kubectl port-forward service/argocd-server 8090:443 -n argocd > /dev/null 2>&1 &
        ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
        log_success "ArgoCD: https://localhost:8090"
        echo -e "  ${YELLOW}Username:${NC} admin"
        echo -e "  ${YELLOW}Password:${NC} $ARGOCD_PASSWORD"
    else
        log_info "ArgoCD port-forward already running"
    fi
    
    # Application (my-app-jp)
    if kubectl get service my-app-jp -n default &>/dev/null; then
        if ! pgrep -f "port-forward.*my-app-jp" >/dev/null 2>&1; then
            kubectl port-forward service/my-app-jp 8080:5000 -n default > /dev/null 2>&1 &
            log_success "Application (my-app-jp): http://localhost:8080"
        else
            log_info "Application (my-app-jp) port-forward already running"
        fi
    fi
    
    # Grafana (from kube-prometheus-stack)
    if kubectl get namespace monitoring &>/dev/null; then
        if ! pgrep -f "port-forward.*grafana" >/dev/null 2>&1; then
            kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80 > /dev/null 2>&1 &
            GRAFANA_PASSWORD=$(kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)
            log_success "Grafana: http://localhost:3000"
            echo -e "  ${YELLOW}Username:${NC} admin"
            echo -e "  ${YELLOW}Password:${NC} $GRAFANA_PASSWORD"
        else
            log_info "Grafana port-forward already running"
        fi
        
        if ! pgrep -f "port-forward.*prometheus.*9090" >/dev/null 2>&1; then
            kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090 > /dev/null 2>&1 &
            log_success "Prometheus: http://localhost:9090"
        else
            log_info "Prometheus port-forward already running"
        fi
    fi

    # Kubecost
    if kubectl get namespace kubecost &>/dev/null; then
        KUBECOST_SERVICE=""
        if kubectl get service kubecost-cost-analyzer -n kubecost &>/dev/null; then
            KUBECOST_SERVICE="kubecost-cost-analyzer"
        elif kubectl get service cost-analyzer -n kubecost &>/dev/null; then
            KUBECOST_SERVICE="cost-analyzer"
        fi

        if [ -n "$KUBECOST_SERVICE" ]; then
            if ! pgrep -f "port-forward.*$KUBECOST_SERVICE.*9091:9090" >/dev/null 2>&1; then
                kubectl port-forward "service/$KUBECOST_SERVICE" -n kubecost 9091:9090 > /dev/null 2>&1 &
                log_success "Kubecost: http://localhost:9091"
            else
                log_info "Kubecost port-forward already running"
            fi
        else
            log_info "Kubecost namespace found but service not ready yet"
        fi
    fi
    
    sleep 2
    echo ""
    log_success "Port forwards are active."
    print_access_info
}

stop_forwards() {
    log_info "Stopping all port forwards..."
    
    if pgrep -f "port-forward" >/dev/null 2>&1; then
        pkill -f "port-forward"
        sleep 1
        log_success "All port forwards stopped"
    else
        log_info "No port forwards running"
    fi
    echo ""
}

case "${1:-status}" in
    start)
        start_forwards
        ;;
    stop)
        stop_forwards
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: $0 {start|stop|status}"
        echo ""
        echo "  start   - Start all port forwards and print access info"
        echo "  stop    - Stop all port forwards"
        echo "  status  - Show running port forwards"
        exit 1
        ;;
esac

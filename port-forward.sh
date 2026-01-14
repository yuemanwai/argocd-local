#!/bin/bash
#
# Port forwarding management script
# Usage: 
#   ./port-forward.sh start   - Start all port forwards
#   ./port-forward.sh stop    - Stop all port forwards
#   ./port-forward.sh status  - Show running port forwards
#   ./port-forward.sh restart - Restart all port forwards
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

show_status() {
    echo ""
    log_info "==================== PORT FORWARDS STATUS ===================="
    echo ""
    
    if ! pgrep -f "port-forward" >/dev/null 2>&1; then
        log_error "No port-forward processes running"
        echo ""
        return
    fi
    
    echo -e "${BLUE}PID     PORT    SERVICE${NC}"
    echo "-----------------------------------------------------------"
    
    ps aux | grep -E "port-forward" | grep -v grep | while read -r line; do
        pid=$(echo "$line" | awk '{print $2}')
        service=$(echo "$line" | grep -o "service/[^ ]*" | cut -d'/' -f2)
        port=$(echo "$line" | grep -o "[0-9]\+:[0-9]\+" | cut -d':' -f1)
        
        if [ -n "$service" ] && [ -n "$port" ]; then
            echo -e "${GREEN}$pid${NC}     ${YELLOW}$port${NC}    $service"
        fi
    done
    
    echo ""
    log_info "To kill a specific port-forward: ${YELLOW}kill <PID>${NC}"
    log_info "To kill all port-forwards: ${YELLOW}./port-forward.sh stop${NC}"
    echo ""
}

start_forwards() {
    log_info "Starting port forwards..."
    
    # ArgoCD
    if ! pgrep -f "port-forward.*argocd-server" >/dev/null 2>&1; then
        kubectl port-forward service/argocd-server 8090:443 -n argocd > /dev/null 2>&1 &
        ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d)
        log_success "ArgoCD: https://localhost:8090"
        echo -e "  ${YELLOW}Username:${NC} admin"
        echo -e "  ${YELLOW}Password:${NC} $ARGOCD_PASSWORD"
    else
        log_info "ArgoCD port-forward already running"
    fi
    
    # Application
    if kubectl get service my-app-jp -n default &>/dev/null; then
        if ! pgrep -f "port-forward.*my-app-jp" >/dev/null 2>&1; then
            kubectl port-forward service/my-app-jp 8080:5000 -n default > /dev/null 2>&1 &
            log_success "Application: http://localhost:8080"
        else
            log_info "Application port-forward already running"
        fi
    fi
    
    # Grafana
    if kubectl get namespace monitoring &>/dev/null; then
        if ! pgrep -f "port-forward.*grafana" >/dev/null 2>&1; then
            kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80 > /dev/null 2>&1 &
            GRAFANA_PASSWORD=$(kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d)
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
    
    sleep 2
    echo ""
    log_success "Port forwards started!"
    show_status
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
    restart)
        stop_forwards
        sleep 1
        start_forwards
        ;;
    *)
        echo "Usage: $0 {start|stop|status|restart}"
        echo ""
        echo "  start   - Start all port forwards"
        echo "  stop    - Stop all port forwards"
        echo "  status  - Show running port forwards"
        echo "  restart - Restart all port forwards"
        exit 1
        ;;
esac

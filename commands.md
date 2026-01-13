# Commands Reference

## 📋 Table of Contents
- [Minikube Setup](#minikube-setup)
- [ArgoCD Management](#argocd-management)
- [Helm Operations](#helm-operations)
- [Port Forwarding](#port-forwarding)
- [Monitoring Stack](#monitoring-stack)
- [Kubernetes Utils](#kubernetes-utils)

---

## 🚀 Minikube Setup

### Start Minikube (Alternative to k3s)
```bash
minikube start --memory 8192 --cpus 6 --addons=metrics-server
```

### Check Minikube Resource Usage
```bash
docker stats
```

---

## 🔄 ArgoCD Management

### Install ArgoCD via Helm (Alternative to kubectl apply)

#### Add Helm Repository
```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
```

#### Install ArgoCD (Locked Version)
```bash
# Lock version to avoid unwanted upgrades
helm install argocd argo/argo-cd \
    --namespace argocd \
    --create-namespace \
    --values ./infrastructure/argocd/values.yaml \
    --version 5.51.6
```

#### Upgrade ArgoCD
```bash
# 永遠都要加 --atomic：一係更新成功，一係維持原狀，絕對唔會爛
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --values ./argocd/values.yaml \
  --atomic
```

#### Uninstall ArgoCD
```bash
helm uninstall argocd -n argocd
```

### Setup ArgoCD via Kubectl
```bash
k apply -f bootstrap/ -R
```

### Cleanup ArgoCD Applications
```bash
k delete -f bootstrap/ -R
```

### Get ArgoCD Admin Password
```bash
k get secret/argocd-initial-admin-secret -n argocd -o jsonpath={.data.password} | base64 -d
```

---

## 📦 Helm Operations

### Display Available Helm Values
```bash
helm show values argo-cd --repo https://argoproj.github.io/argo-helm > values.yaml
```

### Check All Helm Releases
```bash
# List all releases across namespaces
helm list -A

# Get current values
helm get values argocd -n argocd > current-values.yaml

# Get all values (including defaults)
helm get values argocd -n argocd --all > all-values.yaml
```

---

## 🌐 Port Forwarding

### ArgoCD Web UI
```bash
k port-forward service/argocd-server 8090:443 -n argocd > /dev/null 2>&1 &
```
Access at: https://localhost:8090

### Application Service
```bash
k port-forward service/app-svc 8080:80 > /dev/null 2>&1 &
```
Access at: http://localhost:8080

### Kubernetes Dashboard
```bash
k port-forward service/kubernetes-dashboard 9000:80 -n kubernetes-dashboard > /dev/null 2>&1 &
```
Access at: http://localhost:9000

### Kill All Port-Forward Processes
```bash
kill $(jobs -p)
```

---

## 📊 Monitoring Stack

### Grafana

#### Get Grafana Admin Password
```bash
kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d
```

#### Forward Grafana Port
```bash
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80 > /dev/null 2>&1 &
```
Access at: http://localhost:3000

### Prometheus

#### Forward Prometheus Port
```bash
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090 > /dev/null 2>&1 &
```
Access at: http://localhost:9090

#### Check Prometheus Label Values
```bash
kubectl get prometheus -n monitoring -o yaml | grep serviceMonitorSelector -A 5
```

### Grafana Dashboards for ArgoCD
- [Official Metrics Documentation](https://argo-cd.readthedocs.io/en/release-1.8/operator-manual/metrics/#dashboards)
- [Dashboard JSON](https://github.com/argoproj/argo-cd/blob/master/examples/dashboard.json)

---

## 🛠️ Kubernetes Utils

### Check CPU and Memory Usage
```bash
k top pod
```
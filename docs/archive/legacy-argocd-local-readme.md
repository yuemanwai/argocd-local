# argocd
Kubernetes manifest for learning Argo CD


## 📋 Table of Contents
- [Minikube Setup](#minikube-setup)
- [ArgoCD Management](#argocd-management)
- [Helm Operations](#helm-operations)
- [Port Forwarding](#port-forwarding)
- [Argo Rollouts: Blue-Green Deployment Workflow](#-argo-rollouts-blue-green-deployment-workflow)
- [Monitoring Stack](#monitoring-stack)
- [Kubernetes Utils](#kubernetes-utils)

---

## 🚀 Minikube Setup

### Start Minikube (Alternative to k3s)
```bash
minikube start --memory 8192 --cpus 6 --addons=metrics-server
```

### Run Project Setup (Minikube mode, default)
```bash
./setup.sh
# or explicit
./setup.sh --cluster minikube
```

### Check Minikube Resource Usage
```bash
docker stats
```

---

## 🍎 OrbStack Kubernetes Setup (macOS)

### 1) Install OrbStack and enable Kubernetes
- Install OrbStack from the official website
- Open OrbStack and enable Kubernetes
- Confirm context exists:

```bash
kubectl config get-contexts
```

You should see an `orbstack` context.

### 2) Run project setup in OrbStack mode
```bash
./setup.sh --cluster orbstack
```

This keeps your original Minikube flow intact, so you can still use old Windows setup when needed.

Setup now auto-ensures metrics-server (including local kubelet TLS compatibility flags), so HPA and kubectl top work after bootstrap without extra manual install.

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
  --values ./infrastructure/argocd/values.yaml \
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
k port-forward service/my-app-jp 8080:5000 > /dev/null 2>&1 &
```
Access at: http://localhost:8080

### Kubernetes Dashboard
```bash
k port-forward service/kubernetes-dashboard 9000:80 -n kubernetes-dashboard > /dev/null 2>&1 &
```
Access at: http://localhost:9000

### Application Preview Service (Argo Rollouts)
When Blue-Green Rollout is enabled, the preview service allows testing new versions before switching live traffic:

```bash
# Automatically managed by port-forward.sh, but manual forward:
k port-forward service/my-app-jp-preview 8081:5000 > /dev/null 2>&1 &
```
Access preview at: http://localhost:8081

### Kill All Port-Forward Processes
```bash
kill $(jobs -p)
```

---

## 🚀 Argo Rollouts: Blue-Green Deployment Workflow

### 📋 Prerequisites
- Install Argo Rollouts CLI (auto-installed via setup.sh):
  ```bash
  brew install argoproj/tap/kubectl-argo-rollouts
  kubectl argo rollouts version
  ```

### 📌 Real-World Deployment Workflow

#### 1️⃣ **Prepare & Commit New Version**
```bash
# Update docker image tag in values.yaml
edit gitops/apps/jp/values.yaml
# Change image.tag from <current> to <new-tag>

# Commit and push to Git
git add gitops/apps/jp/values.yaml
git commit -m "chore: upgrade my-app-jp to tag <new-tag>"
git push origin main
```

#### 2️⃣ **Monitor Rollout Progress**
ArgoCD auto-syncs and triggers the Rollout. Open 3 terminals:

```bash
# Terminal 1: Watch Rollout state changes (5s auto-refresh)
kubectl argo rollouts get rollout my-app-jp -n default -w

# Terminal 2: Watch Pod status (show Blue/Green instances)
kubectl get pods -n default -l app=my-app-jp -w

# Terminal 3: Watch Events (Rollout messages, errors, state transitions)
kubectl get events -n default -w --field-selector involvedObject.name=my-app-jp
```

#### 3️⃣ **Test Preview Service (New Version)**
```bash
# Port-forward already running via ./port-forward.sh start
# Or manual:
kubectl port-forward svc/my-app-jp-preview 8081:5000 &

# Test new version in browser or via curl
curl http://localhost:8081/health
# Verify logs, metrics, functionality...
```

#### 4️⃣ **Validate and Promote to Active**
Once preview is verified stable:

```bash
# ✅ Option A: Using Argo Rollouts CLI (recommended)
kubectl argo rollouts promote my-app-jp -n default

# ✅ Option B: Using kubectl patch (no CLI needed)
kubectl patch rollout my-app-jp -n default --type merge \
  -p '{"status":{"promotionApproved":true}}'
```

**What happens after promotion:**
- Active service (`my-app-jp`) switches to new version pods
- Preview service (`my-app-jp-preview`) is decommissioned after 30s
- Old pods gradually scale down

#### 5️⃣ **Observe Traffic Switch**
Monitor the transition:
```bash
# Watch new version take over
kubectl argo rollouts get rollout my-app-jp -n default -w

# Verify active service now points to new pods
kubectl get pods -n default -l app=my-app-jp --show-labels

# Check application is responsive on active endpoint
curl http://localhost:8080/health
```

### ❌ **Rollback / Abort (If Issues Found)**

```bash
# ❌ Option A: Using CLI (immediate abort)
kubectl argo rollouts abort my-app-jp -n default

# ❌ Option B: Using kubectl patch
kubectl patch rollout my-app-jp -n default --type merge \
  -p '{"status":{"abortStatus":"true"}}'
```

**What happens after abort:**
- Preview pods are immediately terminated
- Active service remains on old version (zero downtime)
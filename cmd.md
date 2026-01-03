# 1. 停止並卸載 k3s
sudo systemctl stop k3s
sudo /usr/local/bin/k3s-uninstall.sh

# 2. 清理殘留 (可選，徹底)
sudo rm -rf /var/lib/rancher /etc/rancher /var/lib/cni /etc/cni

# 3. 重裝 k3s (啟用 metrics-server)
curl -sfL https://get.k3s.io | sh -

# 4. 啟動
sudo systemctl start k3s
sudo systemctl enable k3s

# 4. 授權及驗證
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
export KUBECONFIG=~/.kube/config
kubectl get nodes

# ----------------------------------------------------------

# Alternative: Use minikube instead of k3s
minikube start --memory 8192 --cpus 6 --addons=metrics-server

# check minikube resource usage
docker stats

# ----------------------------------------------------------

# install argocd
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# setup argocd
k apply -f applicationset/

# access argocd webui
k port-forward service/argocd-server 8090:443 -n argocd > /dev/null 2>&1 &

# get pw for argocd admin
k get secret/argocd-initial-admin-secret -n argocd -o jsonpath={.data.password} | base64 -d

# access fyp website
k port-forward service/app-svc 8080:80 > /dev/null 2>&1 &

# Check CPU and memory usage of pods
k top pod

# Cleanup argocd applications
k delete -f applicationset/

# Kill all background port-forward processes
kill $(jobs -p)

# ----------------------------------------------------------

# kubernetes-dashboard
k port-forward service/kubernetes-dashboard 9000:80 -n kubernetes-dashboard > /dev/null 2>&1 &

# ----------------------------------------------------------

# kube-prometheus-stack

## add prometheus-community repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts

## update list
helm repo update

## create namespace
kubectl create namespace monitoring

## install stable version (first installation)
helm install monitoring prometheus-community/kube-prometheus-stack -n monitoring --create-namespace -f ./monitoring/monitoring-values.yaml

## wait a few minute
kubectl get all -n monitoring

## get grafana admin pw
kubectl get secret prometheus-stack-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d

## forward port 3000
kubectl port-forward svc/prometheus-stack-grafana -n monitoring 3000:80 > /dev/null 2>&1 &

## delete prometheus-stack
helm delete prometheus-stack -n monitoring

# get current values
helm get values monitoring -n monitoring > ./monitoring/current-values.yaml
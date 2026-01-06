
# Alternative: Use minikube instead of k3s
minikube start --memory 8192 --cpus 6 --addons=metrics-server

# check minikube resource usage
docker stats

# ----------------------------------------------------------

# argocd via helm (alternative to kubectl apply)
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Lock version to avoid unwanted upgrades
helm install argocd argo/argo-cd \
    --namespace argocd \
    --create-namespace \
    --values ./infrastructure/argocd/values.yaml \
    --version 5.51.6

# upgrade argocd via helm (永遠都要加 --atomic：一係更新成功，一係維持原狀，絕對唔會爛)
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --values ./argocd/values.yaml \
  --atomic

## uninstall argocd
helm uninstall argocd -n argocd
  
# setup argocd
k apply -f bootstrap/ -R

# access argocd webui
k port-forward service/argocd-server 8090:443 -n argocd > /dev/null 2>&1 &

# get pw for argocd admin
k get secret/argocd-initial-admin-secret -n argocd -o jsonpath={.data.password} | base64 -d

# Check CPU and memory usage of pods
k top pod

# Cleanup argocd applications
k delete -f bootstrap/ -R

# Kill all background port-forward processes
kill $(jobs -p)

# ----------------------------------------------------------

# display all available helm values for argo-cd chart
helm show values argo-cd --repo https://argoproj.github.io/argo-helm > values.yaml

# check all helm releases across namespaces
helm list -A
helm get values argocd -n argocd > current-values.yaml
helm get values argocd -n argocd --all > all-values.yaml

# ----------------------------------------------------------

# access fyp website
k port-forward service/app-svc 8080:80 > /dev/null 2>&1 &

# ----------------------------------------------------------

# kubernetes-dashboard
k port-forward service/kubernetes-dashboard 9000:80 -n kubernetes-dashboard > /dev/null 2>&1 &

# ----------------------------------------------------------

# kube-prometheus-stack

## get grafana admin pw
kubectl get secret monitoring-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d

## forward grafana port 3000
kubectl port-forward svc/monitoring-grafana -n monitoring 3000:80 > /dev/null 2>&1 &

# forward prometheus port
kubectl port-forward svc/monitoring-kube-prometheus-prometheus -n monitoring 9090:9090 > /dev/null 2>&1 & 

# ----------------------------------------------------------

# check prometheus label value for integrate with other services
kubectl get prometheus -n monitoring -o yaml | grep serviceMonitorSelector -A 5

# ----------------------------------------------------------

# grafana dashboard
## dashboard for argocd
https://argo-cd.readthedocs.io/en/release-1.8/operator-manual/metrics/#dashboards
https://github.com/argoproj/argo-cd/blob/master/examples/dashboard.json
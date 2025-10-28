# jp-academy-k8s-manifest
Kubernetes manifest for JP Academy, my Final Year Project (FYP) app, configured for deployment via Argo CD

# to know more (example)
k explain deploy
k explain deploy.spec
k explain deploy.metadata

# cmd to gen a k8s yaml (they required diff cmd)
k run pod
k create deploy
k create secret
k create cm
k autoscale deploy <target-name> --name='' --min=1 --max=3 --dry-run=client -o yaml > hpa.yaml

# Argo Rollouts Workflow

This repository uses Argo Rollouts for blue-green delivery of `my-app-jp`.
ArgoCD syncs the Rollout from Git; the Rollouts CLI is used to inspect, promote,
or abort a rollout.

## Prerequisites

Install the Argo Rollouts kubectl plugin:

```bash
brew install argoproj/tap/kubectl-argo-rollouts
kubectl argo rollouts version
```

The controller is installed by the ArgoCD root application in the
`argo-rollouts` namespace.

## Start Local Access

Start the local forwards and dashboard:

```bash
./port-forward.sh start
```

Useful URLs:

- Application: http://localhost:8080
- Preview service: http://localhost:8081
- Rollouts dashboard: http://localhost:3100/rollouts

## Deploy a New Version

1. Update the image tag in `gitops/apps/jp/values.yaml`.
2. Commit and push the change to Git.
3. Wait for ArgoCD to sync the `my-app` Application.
4. Inspect the rollout:

```bash
kubectl argo rollouts get rollout my-app-jp -n default -w
```

Useful supporting checks:

```bash
kubectl get pods -n default -l app=my-app-jp -w
kubectl get events -n default -w --field-selector involvedObject.name=my-app-jp
```

## Test and Promote

The new ReplicaSet is exposed through the preview service while the active
service continues serving the current version:

```bash
curl http://localhost:8081/health
```

After the preview is verified, promote it:

```bash
kubectl argo rollouts promote my-app-jp -n default
```

Then confirm the active service and rollout state:

```bash
kubectl argo rollouts get rollout my-app-jp -n default
curl http://localhost:8080/health
```

## Abort a Rollout

If the preview is unhealthy, abort the rollout and keep the active version:

```bash
kubectl argo rollouts abort my-app-jp -n default
```

The dashboard and CLI show the rollout state; Git remains the source of truth
for the desired image tag and future synchronization.
